//! Direct-message introduce and outbox drain for `rooms-peer`.
//!
//! Caps and back-channels live on `PeerState`; this file is the operations
//! that fill, age, and send through them. Room join is `wire.zig`.

const std = @import("std");
const log = @import("../../operability/log.zig");
const common = @import("common.zig");
const harness = @import("harness.zig");
const phase_mod = @import("phase.zig");
const st = @import("state.zig");

const model = common.model;
const actors = common.actors;
const HostSession = common.HostSession;
const redial_cooldown_wakes = common.redial_cooldown_wakes;
const readFile = harness.readFile;
const overwriteFile = harness.overwriteFile;
const recordInbox = harness.recordInbox;
const compactOutboxRemainder = harness.compactOutboxRemainder;
const lockLeaf = harness.lockLeaf;
const OutboxLine = harness.OutboxLine;
const OutboxLineFate = harness.OutboxLineFate;
const clampOutboxOffset = harness.clampOutboxOffset;

// --- outbox -----------------------------------------------------------------

const IntroCtx = struct {
    state: *st.PeerState,
    peer: []u8,
};

fn onIntroduced(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const ic: *IntroCtx = @ptrCast(@alignCast(ctx.?));
    const state = ic.state;
    const peer = ic.peer;
    defer {
        state.gpa.free(peer);
        state.gpa.destroy(ic);
    }
    // Room wire may have been cleared while introduce was in flight.
    if (state.phase != .joined) return;
    if (state.pending_introduces.fetchRemove(peer)) |kv| state.gpa.free(kv.key);
    if (st.refOf(resolution)) |dm| {
        const cloned = model.cloneReference(state.gpa, dm) catch {
            log.err(state.io, "introduce \"{s}\": clone failed", .{peer});
            rememberFailedIntroduce(state, peer);
            return;
        };
        const key = state.gpa.dupe(u8, peer) catch {
            model.freeReference(state.gpa, cloned);
            rememberFailedIntroduce(state, peer);
            return;
        };
        if (state.dm_caps.fetchRemove(key)) |old| {
            state.gpa.free(old.key);
            model.freeReference(state.gpa, old.value);
        }
        state.dm_caps.put(state.gpa, key, cloned) catch {
            state.gpa.free(key);
            model.freeReference(state.gpa, cloned);
            rememberFailedIntroduce(state, peer);
        };
        return;
    }
    // Host-tier vows should auto-redeem gives before the listener fires; name
    // the settle arm so a redeem miss is distinguishable from a directory refuse.
    switch (resolution) {
        .fulfilled => |value| log.err(state.io, "introduce \"{s}\" broke: fulfilled non-ref ({s})", .{ peer, @tagName(value) }),
        .broken => |reason| log.err(state.io, "introduce \"{s}\" broke: {s}", .{ peer, reason }),
        .give => |g| log.err(state.io, "introduce \"{s}\" settled as unredeemed give (exporter={s})", .{ peer, g.exporter_locator_uri }),
    }
    rememberFailedIntroduce(state, peer);
}

fn rememberFailedIntroduce(state: *st.PeerState, peer: []const u8) void {
    if (state.failed_introduces.getPtr(peer)) |cooldown| {
        cooldown.* = redial_cooldown_wakes;
        return;
    }
    const key = state.gpa.dupe(u8, peer) catch return;
    state.failed_introduces.put(state.gpa, key, redial_cooldown_wakes) catch state.gpa.free(key);
}

/// How many wakes an unsettled `introduce` is waited on before the peer is
/// moved to the refusal cooldown. A directory that answers at all answers
/// within a wake or two; one that never answers must not pin the outbox.
const introduce_wait_wakes: u32 = 13;

/// Age every refusal, and forget the ones whose wait is over. Called once per
/// maintained wake, before the outbox drain reads them, so a peer who has come
/// back is retried on the same wake rather than the next one.
pub fn tickFailedIntroduces(state: *st.PeerState) void {
    _ = phase_mod.expireCooldowns(state.gpa, &state.failed_introduces);
}

/// Age every in-flight introduce, and give up on the ones whose wait is over.
/// A settle that arrives later finds no pending row and is ignored, which is
/// the same thing that happens when the room wire is cleared under it.
pub fn tickPendingIntroduces(state: *st.PeerState) void {
    var expired: [16][]const u8 = undefined;
    var n: usize = 0;
    var it = state.pending_introduces.iterator();
    while (it.next()) |entry| {
        if (!phase_mod.tickCooldown(entry.value_ptr)) continue;
        if (n == expired.len) break;
        expired[n] = entry.key_ptr.*;
        n += 1;
    }
    for (expired[0..n]) |key| {
        log.err(state.io, "introduce \"{s}\" never settled", .{key});
        if (state.pending_introduces.fetchRemove(key)) |old| {
            rememberFailedIntroduce(state, old.key);
            state.gpa.free(old.key);
        }
    }
}

fn startIntroduce(state: *st.PeerState, peer: []const u8) void {
    if (state.phase != .joined) return;
    if (state.pending_introduces.contains(peer) or state.failed_introduces.contains(peer)) return;
    const directory = state.phase.joined.directory;
    const session = state.phase.joined.session;
    // Map key and IntroCtx peer are separate owned copies so clearRoomWire can
    // free the map without racing the settle callback's free of ic.peer.
    const map_key = state.gpa.dupe(u8, peer) catch return;
    const ctx_peer = state.gpa.dupe(u8, peer) catch {
        state.gpa.free(map_key);
        return;
    };
    state.pending_introduces.put(state.gpa, map_key, introduce_wait_wakes) catch {
        state.gpa.free(map_key);
        state.gpa.free(ctx_peer);
        return;
    };
    const ic = state.gpa.create(IntroCtx) catch {
        if (state.pending_introduces.fetchRemove(peer)) |kv| state.gpa.free(kv.key);
        state.gpa.free(ctx_peer);
        return;
    };
    ic.* = .{ .state = state, .peer = ctx_peer };
    const vow = state.host.send(session, directory, .{
        .verb = "introduce",
        .args = &.{.{ .string = peer }},
    }) catch |err| {
        log.err(state.io, "introduce send failed: {s}", .{@errorName(err)});
        if (state.pending_introduces.fetchRemove(peer)) |kv| state.gpa.free(kv.key);
        state.gpa.free(ctx_peer);
        state.gpa.destroy(ic);
        return;
    };
    state.host.vowOn(vow, .{ .ctx = ic, .func = onIntroduced }) catch |err| {
        log.err(state.io, "introduce vowOn failed: {s}", .{@errorName(err)});
        if (state.pending_introduces.fetchRemove(peer)) |kv| state.gpa.free(kv.key);
        state.gpa.free(ctx_peer);
        state.gpa.destroy(ic);
        return;
    };
    _ = st.flushBridge(state, .host);
}

fn evictDmCap(state: *st.PeerState, peer: []const u8) void {
    if (state.dm_caps.fetchRemove(peer)) |kv| {
        state.gpa.free(kv.key);
        model.freeReference(state.gpa, kv.value);
    }
}

fn evictDmBack(state: *st.PeerState, peer: []const u8) void {
    if (state.dm_back.fetchRemove(peer)) |kv| {
        state.gpa.free(kv.key);
        _ = state.host.capabilities.release(kv.value, 1) catch {};
    }
}

/// Drain outbox lines past `st.g_offset`. A blocked DM is held in the remainder
/// so it is not dropped; later room posts and sendable DMs still send. Fail
/// closed: a line leaves the remainder only after tell + drainActions both
/// succeed. A failed post keeps that line and everything after it.
pub fn drainOutbox(state: *st.PeerState) void {
    if (state.phase != .joined) return;
    const room = state.phase.joined.room;
    const session = state.phase.joined.session;
    const lock = lockLeaf(state.io, state.dir, "outbox.jsonl") catch return;
    defer lock.unlock();
    const contents = readFile(state.io, state.gpa, state.dir, "outbox.jsonl") catch return;
    defer state.gpa.free(contents);
    st.g_offset = clampOutboxOffset(st.g_offset, contents.len);
    if (contents.len <= st.g_offset) return;

    const remainder = contents[st.g_offset..];
    const Drain = struct {
        state: *st.PeerState,
        session: *HostSession,
        room: model.Reference,

        fn decide(self: @This(), parsed: OutboxLine) OutboxLineFate {
            if (parsed.is_dm) return dmOutboxFate(self.state, self.session, parsed);
            return roomOutboxFate(self.state, self.session, self.room, parsed);
        }
    };
    const kept = compactOutboxRemainder(
        state.gpa,
        remainder,
        Drain{ .state = state, .session = session, .room = room },
        Drain.decide,
    ) catch return;
    defer state.gpa.free(kept);
    if (std.mem.eql(u8, kept, remainder)) return;

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(state.gpa);
    list.appendSlice(state.gpa, contents[0..st.g_offset]) catch return;
    list.appendSlice(state.gpa, kept) catch return;
    overwriteFile(state.io, state.dir, "outbox.jsonl", list.items) catch {
        log.err(state.io, "outbox compact write failed; holding remainder", .{});
    };
}

fn dmOutboxFate(state: *st.PeerState, session: *HostSession, parsed: OutboxLine) OutboxLineFate {
    if (parsed.peer.len == 0) {
        log.err(state.io, "dm outbox line missing peer", .{});
        return .drop;
    }
    const msg: actors.Message = .{
        .verb = "dm",
        .args = &.{.{ .string = parsed.text }},
    };
    // Prefer ADR-0088 back-channel, then introduce result, over the
    // introduce-failure cooldown: a live route must not sit blocked
    // behind a stale refuse. The reply cap lives on the partner's
    // direct session — tellCapability routes there. Lowering it onto
    // the room session is UnknownCapability.
    if (state.dm_back.get(parsed.peer)) |back| {
        if (state.host.tellCapability(session, back, msg)) |_| {
            if (!st.flushBridge(state, .dm)) return .stop;
            recordInbox(state.io, state.gpa, state.dir, "sent", "dm", state.nick, parsed.text, parsed.peer) catch {};
            return .drop;
        } else |err| {
            log.err(state.io, "dm back-channel tell failed: {s}", .{@errorName(err)});
            evictDmBack(state, parsed.peer);
        }
    }
    if (state.dm_caps.get(parsed.peer)) |dm| {
        if (state.host.tell(session, dm, msg)) |_| {
            if (!st.flushBridge(state, .dm)) return .stop;
            recordInbox(state.io, state.gpa, state.dir, "sent", "dm", state.nick, parsed.text, parsed.peer) catch {};
            return .drop;
        } else |err| {
            log.err(state.io, "dm tell failed: {s}", .{@errorName(err)});
            evictDmCap(state, parsed.peer);
        }
    }
    if (state.failed_introduces.contains(parsed.peer) or state.pending_introduces.contains(parsed.peer)) {
        return .hold;
    }
    startIntroduce(state, parsed.peer);
    return .hold;
}

fn roomOutboxFate(state: *st.PeerState, session: *HostSession, room: model.Reference, parsed: OutboxLine) OutboxLineFate {
    state.host.tell(session, room, .{ .verb = "post", .args = &.{.{ .string = parsed.text }} }) catch |err| {
        log.err(state.io, "post failed: {s}", .{@errorName(err)});
        return .stop;
    };
    if (!st.flushBridge(state, .post)) return .stop;
    recordInbox(state.io, state.gpa, state.dir, "sent", "room", state.nick, parsed.text, "") catch {};
    return .drop;
}
