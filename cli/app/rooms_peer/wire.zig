//! Room-wire presence: inboxes offered to the directory, join/subscribe, and
//! the bridge open/close hooks. Direct-message introduce and the outbox live
//! in `outbox.zig`.

const std = @import("std");
const log = @import("../../operability/log.zig");
const common = @import("common.zig");
const ledger = @import("harness/ledger.zig");
const phase_mod = @import("phase.zig");
const st = @import("state.zig");

const model = common.model;
const actors = common.actors;
const driver = common.driver;
const net = common.net;
const Hosting = driver.core.Hosting;
const HostTurn = driver.core.HostTurn;
const HostSession = common.HostSession;
const Value = driver.core.Value;
const Capability = driver.core.Capability;
const RoomsBridge = common.RoomsBridge;
const redial_cooldown_wakes = common.redial_cooldown_wakes;
const max_nick = common.max_nick;
const max_dm_inboxes = common.max_dm_inboxes;
const recordInbox = ledger.recordInbox;

pub const RoomLine = struct {
    from: []const u8,
    text: []const u8,
};

/// Parse the subset of room notifications this harness persists. The room's
/// structured vocabulary lives in the third argument: `line` is durable chat;
/// presence, typing, edits, and file lifecycle events are not new chat lines.
/// Untagged `(from, text)` is the protocol's plain-line form.
pub fn roomLine(args: []const model.Argument, own_nick: []const u8) ?RoomLine {
    const from = if (args.len > 0 and args[0] == .string) args[0].string else return null;
    const text = if (args.len > 1 and args[1] == .string) args[1].string else return null;
    const tag = if (args.len > 2 and args[2] == .string) args[2].string else "line";
    if (!std.mem.eql(u8, tag, "line")) return null;
    if (from.len == 0 or std.mem.eql(u8, from, "room") or std.mem.eql(u8, from, own_nick)) return null;
    return .{ .from = from, .text = text };
}

pub const SubscribeSettlement = enum { fulfilled, refused, malformed };

/// The room contract may grant topic authority as a capability or fulfill void
/// when it grants none. A broken vow is a server refusal; every other
/// fulfillment shape (and a handoff, which the Host tier should have redeemed)
/// is malformed and must not publish a false joined state.
pub fn classifySubscribeSettlement(resolution: actors.Resolution) SubscribeSettlement {
    return switch (resolution) {
        .fulfilled => |value| switch (value) {
            .reference, .void => .fulfilled,
            else => .malformed,
        },
        .broken => .refused,
        .give => .malformed,
    };
}

/// Persist one delivered line. Incoming room and DM callbacks must remain
/// available if the local scrollback cannot be appended, but losing the line
/// is never silent: the process diagnostic names the channel, author, and exact
/// failure.
pub fn recordReceived(
    io: common.Io,
    gpa: common.Allocator,
    dir: []const u8,
    channel: []const u8,
    author: []const u8,
    text: []const u8,
    peer: []const u8,
) bool {
    recordInbox(io, gpa, dir, "msg", channel, author, text, peer) catch |err| {
        log.err(io, "recording {s} line from \"{s}\" failed: {s}", .{ channel, author, @errorName(err) });
        return false;
    };
    return true;
}

/// The room calls `notify(from, text, ...)` back on this exported inbox, and
/// tags what kind of event it is with a string after the display text: `line`
/// is somebody talking, while `join`, `leave`, `typing`, `edited`, `withdrawn`
/// and `refiled` are presence or changes to a line this harness does not model.
/// We record only what was said, by another member.
///
/// The tag is read for its value, not counted. Every broadcast the room makes
/// carries one, and a posted line carries its line id after it, so asking
/// whether a third argument merely exists answered "presence" for every line
/// in the room: peers joined, appeared in the roster, sent normally, and heard
/// nothing at all.
const RoomInbox = struct {
    state: *st.PeerState,

    pub fn handle(self: *RoomInbox, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "notify")) return error.NoSuchMethod;
        if (roomLine(msg.args, self.state.nick)) |line| {
            if (!recordReceived(self.state.io, self.state.gpa, self.state.dir, "room", line.from, line.text, "")) {
                self.state.persistence_failed = true;
            }
        }
        return .{ .void = {} };
    }
};

/// One peer's inbox: partners call `dm(text, reply?)` after redeeming an
/// introduce. `peer` is the nick the directory minted this inbox for, which is
/// why the message need not name its sender. When `reply` is present it is the
/// ADR-0088 back-channel: answer on that capability (same arriving connection)
/// instead of introducing the partner, so a browser that never listens still
/// gets our DMs. Value-shaped (`Hosting`) so the reply lifts to an opaque Host
/// capability rather than a turn-local wire import.
const DmInbox = struct {
    state: *st.PeerState,
    peer: []const u8,
    swiss: []const u8,

    pub fn handle(self: *DmInbox, ht: *HostTurn, verb: []const u8, args: []const Value) !Value {
        _ = ht;
        if (!std.mem.eql(u8, verb, "dm")) return error.NoSuchMethod;
        const text = if (args.len > 0 and args[0] == .string) args[0].string else "";
        if (args.len > 1 and args[1] == .capability) {
            rememberDmBack(self.state, self.peer, args[1].capability);
        }
        if (text.len > 0) {
            if (!recordReceived(self.state.io, self.state.gpa, self.state.dir, "dm", self.peer, text, self.peer)) {
                self.state.persistence_failed = true;
            }
        }
        return .void;
    }

    pub fn deinit(self: *DmInbox, _: std.mem.Allocator) void {
        self.state.gpa.free(self.peer);
        self.state.gpa.free(self.swiss);
    }
};

/// The name of the inbox published for `peer`, minting and registering one the
/// first time; null only if the host refused the registration. The name is
/// unguessable because a guessable one would let anyone fetch the inbox by name
/// on a connection they opened themselves.
fn inboxNameFor(state: *st.PeerState, peer: []const u8) ?[]const u8 {
    if (state.dm_inbox_names.get(peer)) |name| return name;
    if (peer.len > max_nick) {
        log.err(state.io, "refusing a dm inbox for a nick over {d} bytes", .{max_nick});
        return null;
    }
    if (state.dm_inbox_names.count() >= max_dm_inboxes) {
        log.err(state.io, "already holding {d} dm inboxes; refusing one for \"{s}\"", .{ max_dm_inboxes, peer });
        return null;
    }

    var raw: [16]u8 = undefined;
    state.io.randomSecure(&raw) catch return null;
    const swiss = std.fmt.allocPrint(state.gpa, "dm-{s}-{s}", .{ peer, std.fmt.bytesToHex(raw, .lower) }) catch return null;
    const owned_peer = state.gpa.dupe(u8, peer) catch {
        state.gpa.free(swiss);
        return null;
    };
    // The map borrows the actor-owned bytes; the actor and publication live for
    // the Host's life.
    state.dm_inbox_names.put(state.gpa, owned_peer, swiss) catch {
        state.gpa.free(owned_peer);
        state.gpa.free(swiss);
        return null;
    };
    _ = state.host.publishGiftable(swiss, Hosting(DmInbox), .{ .inner = .{ .state = state, .peer = owned_peer, .swiss = swiss } }) catch |err| {
        log.err(state.io, "publishing a dm inbox for \"{s}\" failed: {s}", .{ peer, @errorName(err) });
        std.debug.assert(state.dm_inbox_names.remove(owned_peer));
        // `publishGiftable` consumes the behavior state on every outcome;
        // DmInbox.deinit owns both allocations after the call begins.
        return null;
    };
    return swiss;
}

/// Cache `reply` as the outbound DM back-channel to `peer` (ADR-0088).
/// A live route is not displaced — a second inbound while the first still works
/// must not drop the working cap (release the new lift instead). Clears any
/// introduce-failure cooldown so the outbox can drain immediately.
fn rememberDmBack(state: *st.PeerState, peer: []const u8, reply: Capability) void {
    if (state.dm_back.getPtr(peer)) |held| {
        if (state.host.capabilities.resolve(held.*) != null) {
            _ = state.releaseCapability(reply, "duplicate DM route");
            if (state.failed_introduces.fetchRemove(peer)) |kv| state.gpa.free(kv.key);
            return;
        }
        _ = state.releaseCapability(held.*, "replaced DM route");
        held.* = reply;
        if (state.failed_introduces.fetchRemove(peer)) |kv| state.gpa.free(kv.key);
        return;
    }
    const key = state.gpa.dupe(u8, peer) catch {
        _ = state.releaseCapability(reply, "DM route bookkeeping allocation");
        return;
    };
    state.dm_back.put(state.gpa, key, reply) catch {
        state.gpa.free(key);
        _ = state.releaseCapability(reply, "DM route bookkeeping insertion");
        return;
    };
    if (state.failed_introduces.fetchRemove(peer)) |kv| state.gpa.free(kv.key);
}

/// Queue a directory inbox offer for `peer`. Safe under the host callback
/// latch: `publishGiftable` and `tell` refuse `ReenteredHost`, so the real
/// work runs from `drainPendingInboxOffers` in `maintain`.
fn scheduleInboxOffer(state: *st.PeerState, peer: []const u8) void {
    if (peer.len > max_nick) return;
    switch (phase_mod.schedulePendingOffer(state.gpa, &state.pending_inbox_offers, peer, max_dm_inboxes)) {
        .allocation_failed => {
            // Keep the first exact bounded retry without asking the failing
            // allocator for another map entry. A later offer is bounded loss,
            // and must be visible rather than silently replacing the first.
            if (state.pending_inbox_offer_retry != null) {
                log.err(state.io, "dm inbox offer for \"{s}\" dropped: bounded retry slot already holds \"{s}\"", .{
                    peer,
                    state.pending_inbox_offer_retry.?.bytes[0..state.pending_inbox_offer_retry.?.len],
                });
            } else {
                var retry = st.PendingInboxOfferRetry{ .bytes = undefined, .len = 0 };
                @memcpy(retry.bytes[0..peer.len], peer);
                retry.len = peer.len;
                state.pending_inbox_offer_retry = retry;
            }
        },
        else => {},
    }
}

/// Offer the directory an inbox for `peer`, the answer to its `mintInboxFor`.
///
/// Call only outside the host callback latch. This uses `tell`, so nothing
/// waits on an answer the directory does not send. A refusal is therefore
/// invisible here, and the cost of one is that the peer stays unreachable
/// until the directory asks again. It does ask again on their next `introduce`,
/// since it only asks when it has no inbox filed. Returns whether the offer was
/// admitted to the Host.
fn offerInboxFor(state: *st.PeerState, peer: []const u8) bool {
    if (state.phase != .joined) return false;
    const session = state.phase.joined.session;
    const directory = state.phase.joined.directory;
    const swiss = inboxNameFor(state, peer) orelse return false;
    const position = state.host.publishedPosition(session, swiss) catch |err| {
        log.err(state.io, "reading the dm inbox position failed: {s}", .{@errorName(err)});
        return false;
    } orelse {
        log.err(state.io, "the dm inbox for \"{s}\" holds no position on the room session", .{peer});
        return false;
    };
    state.host.tell(session, directory, .{
        .verb = "offerInbox",
        .args = &.{
            .{ .string = peer },
            .{ .reference = .{ .near = model.NearRef.object(position) } },
        },
    }) catch |err| {
        log.err(state.io, "offerInbox for \"{s}\" failed: {s}", .{ peer, @errorName(err) });
        return false;
    };
    _ = st.flushBridge(state, .host);
    return true;
}

/// Drain `pending_inbox_offers` outside the callback latch. Keeps a nick until
/// `offerInboxFor` succeeds so a transient tell failure retries next wake.
pub fn drainPendingInboxOffers(state: *st.PeerState) void {
    phase_mod.drainPendingOffers(state.gpa, &state.pending_inbox_offers, state, offerInboxFor);
    if (state.pending_inbox_offer_retry) |retry| {
        switch (phase_mod.schedulePendingOffer(state.gpa, &state.pending_inbox_offers, retry.bytes[0..retry.len], max_dm_inboxes)) {
            .queued, .already_pending => state.pending_inbox_offer_retry = null,
            .at_capacity, .allocation_failed => {},
        }
    }
}

/// The directory's channel to this member: `notify("registered", nick)` once the
/// name is granted, `notify("mintInboxFor", peer)` when someone wants to reach us
/// and has no inbox yet, and `notify("introducible", peer)` when a peer we were
/// refused has offered us one.
const RegInbox = struct {
    state: *st.PeerState,

    pub fn handle(self: *RegInbox, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "notify")) return error.NoSuchMethod;
        const kind = if (msg.args.len > 0 and msg.args[0] == .string) msg.args[0].string else "";
        const peer = if (msg.args.len > 1 and msg.args[1] == .string) msg.args[1].string else "";
        if (std.mem.eql(u8, kind, "registered")) {
            // Outside `.joined` this no-ops: a late notify after teardown must
            // not write status "joined" with the wire down.
            if (phase_mod.noteRegistered(&self.state.phase)) {
                _ = self.state.writeStateNow("joined");
            }
        } else if (std.mem.eql(u8, kind, "mintInboxFor") and peer.len > 0) {
            // Queue only: publishGiftable/tell refuse ReenteredHost under this latch.
            scheduleInboxOffer(self.state, peer);
        } else if (std.mem.eql(u8, kind, "introducible") and peer.len > 0) {
            // Our introduce to them was refused because they had minted us no
            // inbox; they have now. Drop the refusal cooldown so the next wake
            // retries rather than waiting it out.
            if (self.state.failed_introduces.fetchRemove(peer)) |kv| self.state.gpa.free(kv.key);
        }
        return .{ .void = {} };
    }
};

/// Bridge `on_open`: a session opened. Only the app-dial leg while we are
/// `.dialing` is the room session — accepted DM partners and redeem legs open
/// through here too and must not fetch "directory" or touch the phase. Fetch
/// the directory; the enter/open/subscribe chain runs from the settle
/// callbacks.
pub fn onOpen(ctx: ?*anyopaque, bridge: *RoomsBridge, slot: *RoomsBridge.Slot) anyerror!void {
    _ = bridge;
    const state: *st.PeerState = @ptrCast(@alignCast(ctx.?));
    if (state.phase != .dialing or slot.leg != .app_dial) return;
    state.phase = .{ .joining = .{ .session = slot.session } };
    if (!state.writeStateNow("joining")) {
        state.requestAbandonJoin();
        return;
    }
    const vow = state.host.fetch(slot.session, "directory") catch |err| {
        log.err(state.io, "directory fetch failed: {s}", .{@errorName(err)});
        state.requestAbandonJoin();
        return;
    };
    state.host.vowOn(vow, .{ .ctx = state, .func = onDirectory }) catch |err| {
        log.err(state.io, "directory vowOn failed: {s}", .{@errorName(err)});
        state.requestAbandonJoin();
        return;
    };
}

fn onDirectory(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *st.PeerState = @ptrCast(@alignCast(ctx.?));
    if (state.phase != .joining) return;
    const directory = st.refOf(resolution) orelse {
        log.err(state.io, "directory fetch did not fulfill", .{});
        state.requestAbandonJoin();
        return;
    };
    state.phase.joining.directory = directory;
    // The wire stays strict: `enter` breaks if the room is absent, `open` breaks
    // if the name is taken. Try enter, fall back to open, then enter once more on
    // a creation race — the same leniency the blocking client applies.
    sendDirectoryVerb(state, "enter", onEntered);
}

fn onEntered(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *st.PeerState = @ptrCast(@alignCast(ctx.?));
    if (state.phase != .joining) return;
    if (st.refOf(resolution)) |room| {
        subscribeRoom(state, room);
    } else {
        sendDirectoryVerb(state, "open", onOpened);
    }
}

pub fn onOpened(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *st.PeerState = @ptrCast(@alignCast(ctx.?));
    if (state.phase != .joining) return;
    if (st.refOf(resolution)) |room| {
        subscribeRoom(state, room);
    } else {
        sendDirectoryVerb(state, "enter", onEnteredAgain);
    }
}

fn onEnteredAgain(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *st.PeerState = @ptrCast(@alignCast(ctx.?));
    if (state.phase != .joining) return;
    if (st.refOf(resolution)) |room| {
        subscribeRoom(state, room);
    } else {
        log.err(state.io, "could not enter or open room \"{s}\"", .{state.room_name});
        state.requestAbandonJoin();
    }
}

/// Eventual-send a directory verb naming the room, and wait on its answer.
fn sendDirectoryVerb(state: *st.PeerState, verb: []const u8, cb: *const fn (?*anyopaque, actors.Resolution) void) void {
    if (state.phase != .joining) return;
    const joining = state.phase.joining;
    const directory = joining.directory orelse return;
    const session = joining.session;
    const vow = state.host.send(session, directory, .{
        .verb = verb,
        .args = &.{.{ .string = state.room_name }},
    }) catch |err| {
        log.err(state.io, "{s} send failed: {s}", .{ verb, @errorName(err) });
        state.requestAbandonJoin();
        return;
    };
    state.host.vowOn(vow, .{ .ctx = state, .func = cb }) catch |err| {
        log.err(state.io, "{s} vowOn failed: {s}", .{ verb, @errorName(err) });
        state.requestAbandonJoin();
        return;
    };
    _ = st.flushBridge(state, .host);
}

/// Spawn our room inbox, hand it to the room in `subscribe`, and observe the
/// answer. The settlement callback alone may mark the peer joined.
fn subscribeRoom(state: *st.PeerState, room: model.Reference) void {
    if (state.phase != .joining) return;
    const joining = state.phase.joining;
    const session = joining.session;
    // The chain guarantees a directory (onDirectory set it before any verb
    // could settle); fail toward a redial rather than crash if that breaks.
    _ = joining.directory orelse {
        state.requestAbandonJoin();
        return;
    };
    const inbox = session.served.spawn(&session.host.vat, RoomInbox, .{ .state = state }) catch |err| {
        log.err(state.io, "inbox spawn failed: {s}", .{@errorName(err)});
        state.requestAbandonJoin();
        return;
    };
    state.phase.joining.room = room;
    const pending = state.gpa.create(SubscribeContext) catch {
        log.err(state.io, "subscribe listener allocation failed: OutOfMemory", .{});
        state.requestAbandonJoin();
        return;
    };
    pending.* = .{ .state = state, .session = session };
    const vow = state.host.queueSend(session, room, .{
        .verb = "subscribe",
        .args = &.{ .{ .string = state.nick }, inbox.arg() },
    }) catch |err| {
        state.gpa.destroy(pending);
        log.err(state.io, "subscribe failed: {s}", .{@errorName(err)});
        state.requestAbandonJoin();
        return;
    };
    state.host.vowOn(vow, .{ .ctx = pending, .func = onSubscribed }) catch |err| {
        state.gpa.destroy(pending);
        log.err(state.io, "subscribe vowOn failed: {s}", .{@errorName(err)});
        state.requestAbandonJoin();
        return;
    };
    _ = st.flushBridge(state, .host);
}

const SubscribeContext = struct {
    state: *st.PeerState,
    session: *HostSession,
};

fn onSubscribed(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const pending: *SubscribeContext = @ptrCast(@alignCast(ctx.?));
    const state = pending.state;
    const session = pending.session;
    // A registered far-vow listener fires exactly once, including when its
    // Port is broken during session/Host teardown, so this context has one
    // owner and one release point.
    defer state.gpa.destroy(pending);
    if (!phase_mod.isJoiningSession(&state.phase, session)) return;
    switch (classifySubscribeSettlement(resolution)) {
        .fulfilled => if (!phase_mod.noteSubscribed(&state.phase, redial_cooldown_wakes)) {
            log.err(state.io, "subscribe fulfilled without a complete joining state", .{});
            state.requestAbandonJoin();
            return;
        },
        .refused => {
            const reason = switch (resolution) {
                .broken => |text| text,
                else => unreachable,
            };
            log.err(state.io, "subscribe refused: {s}", .{reason});
            state.requestAbandonJoin();
            return;
        },
        .malformed => {
            log.err(state.io, "subscribe settled with an invalid result", .{});
            state.requestAbandonJoin();
            return;
        },
    }
    state.join_attempts = 0;
    st.g_ever_joined = true;
    if (!state.writeStateNow("joined")) return;
    registerWithDirectory(state);
}

/// Offer this peer for introduce: directory fetches `dm` on this session, then
/// `notify("registered", …)` on our register inbox.
pub fn registerWithDirectory(state: *st.PeerState) void {
    if (state.phase != .joined) return;
    const joined = state.phase.joined;
    if (joined.reg != .pending or state.member_locator.len == 0) return;
    const session = joined.session;
    const directory = joined.directory;
    const actor = state.reg_inbox_actor orelse actor: {
        const fresh = state.host.vat.spawn(RegInbox, .{ .state = state }) catch |err| {
            log.err(state.io, "register inbox spawn failed: {s}", .{@errorName(err)});
            return;
        };
        state.reg_inbox_actor = fresh;
        break :actor fresh;
    };
    const inbox = session.served.port.projectActor(&state.host.vat, actor) catch |err| {
        log.err(state.io, "register inbox projection failed: {s}", .{@errorName(err)});
        return;
    };
    _ = state.host.send(session, directory, .{
        .verb = "register",
        .args = &.{
            .{ .string = state.nick },
            .{ .string = state.member_locator },
            .{ .reference = .{ .near = inbox } },
        },
    }) catch |err| {
        log.err(state.io, "register failed: {s}", .{@errorName(err)});
        return;
    };
    _ = st.flushBridge(state, .host);
}

/// Loop `on_close`: bridge refuse handling, then clear room wire state only when
/// the room session itself drops (accepted DM redeem sessions must not tear
/// presence down).
pub fn onClose(ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, report: net.completion.CloseReport) void {
    const bridge: *RoomsBridge = @ptrCast(@alignCast(ctx.?));
    const pending_app_dial = conn_ctx == null and bridge.pendingAppDial(slot);
    RoomsBridge.onClose(ctx, slot, conn_ctx, report);
    const state: *st.PeerState = @ptrCast(@alignCast(bridge.on_open_ctx.?));
    if (conn_ctx) |raw| {
        const shell: *RoomsBridge.Slot = @ptrCast(@alignCast(raw));
        if (state.phaseSession()) |room_session| {
            // `.abandoning` is covered too: a remote close racing the abandon
            // tick lands `.down` cleanly instead of stranding the phase.
            if (shell.session == room_session) state.clearRoomWire();
            return;
        }
        // App-dial leg torn down before session open (handshake never
        // completed): the dial is dead, so carry the countdown into `.down`
        // exactly like a refused connect.
        if (shell.leg == .app_dial) phase_mod.connectRefused(&state.phase);
        return;
    }
    // Refused connect (no shell was ever built): resume redial pacing with the
    // countdown carried, `.dialing{cd}` becoming `.down{cd}`.
    if (!report.opened or pending_app_dial) phase_mod.connectRefused(&state.phase);
}
