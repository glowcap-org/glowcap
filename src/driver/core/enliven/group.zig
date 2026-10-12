//! One wire fetch and answer release, with independently owned Host observers.
const std = @import("std");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");
const host_mod = @import("../host.zig");
const vows = @import("../vows.zig");
const pump = @import("../host/pump.zig");
const observation = @import("observation.zig");
const Host = host_mod.Host;
const HostSession = host_mod.HostSession;

const Key = struct { peer: engine.PeerHandle, answer: model.AnswerPosition };
pub const Map = std.AutoHashMapUnmanaged(Key, *Group);

const Member = struct {
    group: *Group,
    id: u64,
    previous: ?*Member = null,
    next: ?*Member = null,
};

/// A group owns the sole Port listener and reserved GC carrier. Its members own
/// separate vows and result retains. Settled public vows keep their shared
/// pipeline answer alive until the last handle releases. The Host-wide index
/// exists only for pending fetches, adding no per-session state. Stable heap
/// rows allow O(1) cancellation even when the first observer leaves.
const Group = struct {
    host: *Host,
    key: Key,
    release: engine.Peer.PendingReservation,
    listener: actors.Listener,
    head: ?*Member = null,
    pending: bool = true,

    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *Group = @ptrCast(@alignCast(ctx.?));
        const host = self.host;
        std.debug.assert(host.enliven_groups.remove(self.key));
        self.pending = false;
        var routed = resolution;
        var retained: ?@import("../capability.zig").Ref = null;
        if (host.sessions.get(self.key.peer)) |session| {
            const peer = session.served.port.peer;
            if (peer.session_state.pendingEnlivenSwissnum(self.key.answer)) |swissnum| {
                if (if (resolution == .fulfilled) host_mod.asFarRef(resolution.fulfilled) else null) |far|
                    peer.session_state.settlePendingEnlivenIntoCache(swissnum, far)
                else
                    peer.finishPendingEnliven(swissnum);
            }
            // One wire occurrence must survive every consumer projection,
            // including an allocation failure in the first. This temporary
            // retain keeps later observations from reviving a released import.
            if (resolution == .fulfilled) {
                if (resolution.fulfilled == .reference) {
                    retained = host.liftCapability(session, resolution.fulfilled.reference) catch |err| blk: {
                        host.discardValueObservation(session, resolution.fulfilled);
                        routed = .{ .broken = @errorName(err) };
                        break :blk null;
                    };
                } else {
                    host.discardValueObservation(session, resolution.fulfilled);
                    routed = .{ .broken = "NotCapability" };
                }
            }
        }
        defer if (retained) |cap| host.releaseCapabilityTerminal(cap, null);
        var cursor = self.head;
        while (cursor) |member| {
            cursor = member.next;
            // An owned observer consumes its member here; the final one can
            // free the group. Nothing dereferences self after this callback.
            host.fireVow(member.id, routed);
        }
    }
};

pub const Reservation = struct {
    vow: vows.VowReservation,
    member: *Member,
    spare: *Group,
};

/// Reserve before engine admission, including the first producer's exact
/// listener, group index and answer-release carrier. Cache hits and followers
/// cancel the unused producer reservation without publishing a wire effect.
pub fn reserve(host: *Host, session: *HostSession, id: u64, recipient: observation.Recipient, provenance: host_mod.PeerProvenance) !Reservation {
    const spare = try host.allocator.create(Group);
    errdefer host.allocator.destroy(spare);
    const member = try host.allocator.create(Member);
    errdefer host.allocator.destroy(member);
    const vow = try host.reserveVowAt(session, .far, .plain, .shared_peer_visible, id);
    errdefer host.cancelVowReservation(vow);
    const release = try session.served.port.peer.reserveAnswerRelease();
    errdefer session.served.port.peer.cancelPendingReservation(release);
    try host.enliven_groups.ensureUnusedCapacity(host.allocator, 1);
    try recipient.observe(host, session, vow.row, provenance);
    spare.* = .{ .host = host, .key = undefined, .release = release, .listener = .{ .ctx = spare, .func = Group.fire } };
    return .{ .vow = vow, .member = member, .spare = spare };
}

pub fn cancel(host: *Host, session: *HostSession, reservation: Reservation) void {
    session.served.port.peer.cancelPendingReservation(reservation.spare.release);
    host.cancelVowReservation(reservation.vow);
    host.allocator.destroy(reservation.member);
    host.allocator.destroy(reservation.spare);
}

pub fn hasProducer(host: *const Host, session: *const HostSession, answer: model.AnswerPosition) bool {
    return host.enliven_groups.contains(.{ .peer = session.peer_handle, .answer = answer });
}

pub fn commit(host: *Host, session: *HostSession, answer: model.AnswerPosition, reservation: Reservation) u64 {
    const key: Key = .{ .peer = session.peer_handle, .answer = answer };
    const group = if (host.enliven_groups.get(key)) |existing| blk: {
        session.served.port.peer.cancelPendingReservation(reservation.spare.release);
        host.allocator.destroy(reservation.spare);
        break :blk existing;
    } else blk: {
        const fresh = reservation.spare;
        fresh.key = key;
        std.debug.assert(session.served.port.peer.session_state.claimOutboundAnswerRelease(answer));
        host.enliven_groups.putAssumeCapacity(key, fresh);
        session.served.port.onReserved(&host.vat, reservation.vow.listener, .{ .far = answer }, fresh.listener);
        break :blk fresh;
    };
    const row = reservation.vow.row;
    const member = reservation.member;
    member.* = .{ .group = group, .id = row.id, .next = group.head };
    if (group.head) |head| head.previous = member;
    group.head = member;
    row.vow = .{ .far = answer };
    row.pending_cancel = .{ .shared_answer = .{ .owner = @intFromPtr(member), .func = releaseMember } };
    vows.publishRow(host, row);
    host.beginSessionOperation(session);
    return row.id;
}

fn releaseMember(host: *Host, id: u64, owner: u64) void {
    const member: *Member = @ptrFromInt(@as(usize, @intCast(owner)));
    const group = member.group;
    std.debug.assert(member.id == id and group.host == host);
    const row = host.vows.get(id) orelse unreachable;
    row.answer_release = .none;
    row.pending_cancel = .unpublished;
    if (member.previous) |previous| previous.next = member.next else group.head = member.next;
    if (member.next) |next| next.previous = member.previous;
    host.allocator.destroy(member);
    if (group.head != null) return;
    const session = host.sessions.get(group.key.peer) orelse unreachable;
    const peer = session.served.port.peer;
    if (group.pending) {
        const installed = session.served.port.takeListener(&host.vat, .{ .far = group.key.answer }) orelse unreachable;
        std.debug.assert(installed.func == group.listener.func and installed.ctx == group.listener.ctx);
        std.debug.assert(host.enliven_groups.remove(group.key));
        if (peer.session_state.pendingEnlivenSwissnum(group.key.answer)) |swissnum| peer.finishPendingEnliven(swissnum);
    }
    if (peer.session_state.outboundAnswer(group.key.answer) != null and session.sessionOpen() and switch (session.lifecyclePhase()) {
        .active, .finishing => true,
        .cancel_pending, .terminating => false,
    }) {
        peer.publishAnswerRelease(group.release, group.key.answer);
        pump.markDirty(host, session.peer_handle);
    } else {
        peer.cancelPendingReservation(group.release);
    }
    host.allocator.destroy(group);
}
