//! Peer daemon: CapTP/iroh room presence loop for `pancake app rooms-peer`.
const std = @import("std");
const pancake = @import("pancake");
const iroh = @import("iroh");
const signals = @import("../../operability/signals.zig");
const identity_mod = @import("../../operability/identity.zig");
const log = @import("../../operability/log.zig");
const common = @import("common.zig");
const harness = @import("harness.zig");
const phase_mod = @import("phase.zig");
const Flags = @import("flags.zig").Flags;

const Io = common.Io;
const Allocator = common.Allocator;
const model = common.model;
const actors = common.actors;
const driver = common.driver;
const net = common.net;
const Host = common.Host;
const HostSession = common.HostSession;
const IrohLoop = common.IrohLoop;
const IrohBridge = common.IrohBridge;
const frame_cap = common.frame_cap;
const timer_ms = common.timer_ms;
const redial_cooldown_wakes = common.redial_cooldown_wakes;
const dial_timeout_ms = common.dial_timeout_ms;
const emitStdout = common.emitStdout;
const emitStdoutFmt = common.emitStdoutFmt;

const pathIn = harness.pathIn;
const readFile = harness.readFile;
const overwriteFile = harness.overwriteFile;
const removeFile = harness.removeFile;
const recordInbox = harness.recordInbox;
const writeState = harness.writeState;
const scanInbox = harness.scanInbox;
const markReplied = harness.markReplied;
const parseOutboxLine = harness.parseOutboxLine;
const OutboxLine = harness.OutboxLine;
const saveOutboxOffset = harness.saveOutboxOffset;
const loadOutboxOffset = harness.loadOutboxOffset;
const clampOutboxOffset = harness.clampOutboxOffset;
const advanceInboxWatermark = harness.advanceInboxWatermark;

// These outlive an iroh-stack rebuild: the supervisor tears the per-attempt
// stack (and its PeerState) down on a fatal loop error and builds a fresh one, so
// the wake flag, the outbox drain offset, and the "did we ever join this attempt"
// signal live at process scope.
pub var g_wake = std.atomic.Value(bool).init(false);
pub var g_offset: usize = 0;
pub var g_ever_joined: bool = false;

// --- the peer daemon --------------------------------------------------------

/// Everything the loop thread, the timer future, and the inbox actor share. The
/// wire-facing fields are touched only on the loop-owner thread — inside a
/// serve/vow callback or between two `runUntil` returns — so they need no
/// synchronization. The cross-thread stop latch lives in `operability/signals`
/// (SIGINT/SIGTERM + supervisor teardown); the loop and timer both read it.
const PeerState = struct {
    io: Io,
    gpa: Allocator,
    host: *Host,
    bridge: *IrohBridge,

    dir: []const u8,
    nick: []const u8,
    room_name: []const u8,
    locator_str: []const u8,
    /// This peer's dialable `ocapn://…iroh` URI for directory `register`.
    member_locator: []const u8,
    transport: []const u8,
    designator: []const u8,
    hint: []const u8,

    /// Room-session lifecycle (`phase.zig`): exactly one arm live at a time,
    /// carrying that arm's payload (session, directory/room refs, countdowns).
    /// The DM tables below stay orthogonal, cleared on wire teardown.
    phase: phase_mod.Phase = .{ .down = .{ .cooldown = 0 } },
    /// Abandoned joins since the last successful subscribe (or stack start):
    /// incremented when `maintain` executes an abandon, reset in
    /// `subscribeRoom`, and written into state.json for the supervisor.
    join_attempts: u32 = 0,

    /// Cached DM caps from `directory.introduce(nick)` (owned refs + keys).
    dm_caps: std.StringHashMapUnmanaged(model.Reference) = .{},
    /// Nicks with an introduce in flight, and how many wakes are left before
    /// the wait is abandoned (owned keys). A directory that accepts
    /// `introduce` and never settles the vow would otherwise hold its entry
    /// for the session's life, and the outbox drain stops at that peer's DM
    /// lines without advancing, so every later line stops behind it — the same
    /// stall the refusal cooldown below was added to end, one state over.
    /// Expiry demotes to that cooldown rather than retrying at once, so an
    /// unresponsive directory is not hammered.
    pending_introduces: std.StringHashMapUnmanaged(u32) = .{},
    /// Nicks whose introduce broke, and how many wakes to wait before trying
    /// again (owned keys). The outbox drain stops at their DM lines without
    /// advancing the offset, so nothing is dropped while the cooldown runs.
    ///
    /// A countdown rather than a verdict, because a negative result has no
    /// object whose death can clear it. A capability caches the thing it names
    /// and is repaired when that thing reports gone; a *refusal* names
    /// something that was never there, so the only thing that can invalidate it
    /// is a clock. This used to clear only when our own room session dropped —
    /// which for a healthy long-lived session never happens, so a peer who was
    /// briefly offline stayed unreachable forever, and because the drain stops
    /// without advancing, every later line behind it stopped too, including
    /// room posts.
    failed_introduces: std.StringHashMapUnmanaged(u32) = .{},

    fn stopRequested() bool {
        return signals.stopRequested();
    }

    fn writeStateNow(self: *PeerState, status: []const u8) void {
        writeState(self.io, self.gpa, self.dir, status, self.nick, self.room_name, self.locator_str, self.isRegistered(), self.join_attempts);
    }

    /// The live room session, across every phase arm that holds one.
    fn phaseSession(self: *const PeerState) ?*HostSession {
        return self.phase.session();
    }

    fn isRegistered(self: *const PeerState) bool {
        return self.phase.isRegistered();
    }

    fn clearDmTables(self: *PeerState) void {
        var cap_it = self.dm_caps.iterator();
        while (cap_it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            model.freeReference(self.gpa, e.value_ptr.*);
        }
        self.dm_caps.clearRetainingCapacity();
        var pend_it = self.pending_introduces.keyIterator();
        while (pend_it.next()) |k| self.gpa.free(k.*);
        self.pending_introduces.clearRetainingCapacity();
        var fail_it = self.failed_introduces.keyIterator();
        while (fail_it.next()) |k| self.gpa.free(k.*);
        self.failed_introduces.clearRetainingCapacity();
    }

    fn clearRoomWire(self: *PeerState) void {
        self.phase = .{ .down = .{ .cooldown = 0 } };
        self.clearDmTables();
    }

    /// Schedule a join-path recovery. Vow callbacks may run under the host latch,
    /// so we only move to `.abandoning` here; `maintain` closes the slot and
    /// redials outside it. No-op in any phase but `.joining`, so a stale
    /// callback after teardown or after a successful join cannot clobber.
    fn requestAbandonJoin(self: *PeerState) void {
        if (phase_mod.requestAbandon(&self.phase)) self.writeStateNow("reconnecting");
    }

    fn deinitTables(self: *PeerState) void {
        self.clearDmTables();
        self.dm_caps.deinit(self.gpa);
        self.pending_introduces.deinit(self.gpa);
        self.failed_introduces.deinit(self.gpa);
    }
};

/// The room calls `notify(from, text, ...)` back on this exported inbox. A
/// presence line carries a string kind at args[2]; a plain chat line does not.
/// We record only chat lines from another member.
const RoomInbox = struct {
    state: *PeerState,

    pub fn handle(self: *RoomInbox, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "notify")) return error.NoSuchMethod;
        const from = if (msg.args.len > 0 and msg.args[0] == .string) msg.args[0].string else "";
        const text = if (msg.args.len > 1 and msg.args[1] == .string) msg.args[1].string else "";
        const is_presence = msg.args.len >= 3 and msg.args[2] == .string;
        if (!is_presence and from.len > 0 and !std.mem.eql(u8, from, "room") and !std.mem.eql(u8, from, self.state.nick)) {
            recordInbox(self.state.io, self.state.gpa, self.state.dir, "msg", "room", from, text, "") catch {};
        }
        return .{ .void = {} };
    }
};

/// Giftable inbox: partners call `dm(from, text)` after redeeming an introduce.
const DmInbox = struct {
    state: *PeerState,

    pub fn handle(self: *DmInbox, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "dm")) return error.NoSuchMethod;
        const from = if (msg.args.len > 0 and msg.args[0] == .string) msg.args[0].string else "";
        const text = if (msg.args.len > 1 and msg.args[1] == .string) msg.args[1].string else "";
        if (from.len > 0 and text.len > 0) {
            recordInbox(self.state.io, self.state.gpa, self.state.dir, "msg", "dm", from, text, from) catch {};
        }
        return .{ .void = {} };
    }
};

/// Directory `register` readiness: `notify("registered", nick)`.
const RegInbox = struct {
    state: *PeerState,

    pub fn handle(self: *RegInbox, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "notify")) return error.NoSuchMethod;
        const kind = if (msg.args.len > 0 and msg.args[0] == .string) msg.args[0].string else "";
        if (std.mem.eql(u8, kind, "registered")) {
            // Outside `.joined` this no-ops: a late notify after teardown must
            // not write status "joined" with the wire down.
            if (phase_mod.noteRegistered(&self.state.phase)) {
                self.state.writeStateNow("joined");
            }
        }
        return .{ .void = {} };
    }
};

fn publishDm(ctx: ?*anyopaque, served: *driver.Served) anyerror!void {
    const state: *PeerState = @ptrCast(@alignCast(ctx.?));
    _ = try served.publish("dm", DmInbox, .{ .state = state });
}

fn refOf(resolution: actors.Resolution) ?model.Reference {
    return switch (resolution) {
        .fulfilled => |value| if (value == .reference) value.reference else null,
        .broken, .give => null,
    };
}

/// Bridge `on_open`: a session opened. Only the app-dial leg while we are
/// `.dialing` is the room session — accepted DM partners and redeem legs open
/// through here too and must not fetch "directory" or touch the phase. Fetch
/// the directory; the enter/open/subscribe chain runs from the settle
/// callbacks.
fn onOpen(ctx: ?*anyopaque, bridge: *IrohBridge, slot: *IrohBridge.Slot) anyerror!void {
    _ = bridge;
    const state: *PeerState = @ptrCast(@alignCast(ctx.?));
    if (state.phase != .dialing or slot.leg != .app_dial) return;
    state.phase = .{ .joining = .{ .session = slot.session } };
    state.writeStateNow("joining");
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
    const state: *PeerState = @ptrCast(@alignCast(ctx.?));
    if (state.phase != .joining) return;
    const directory = refOf(resolution) orelse {
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
    const state: *PeerState = @ptrCast(@alignCast(ctx.?));
    if (state.phase != .joining) return;
    if (refOf(resolution)) |room| {
        subscribeRoom(state, room);
    } else {
        sendDirectoryVerb(state, "open", onOpened);
    }
}

fn onOpened(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *PeerState = @ptrCast(@alignCast(ctx.?));
    if (state.phase != .joining) return;
    if (refOf(resolution)) |room| {
        subscribeRoom(state, room);
    } else {
        sendDirectoryVerb(state, "enter", onEnteredAgain);
    }
}

fn onEnteredAgain(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *PeerState = @ptrCast(@alignCast(ctx.?));
    if (state.phase != .joining) return;
    if (refOf(resolution)) |room| {
        subscribeRoom(state, room);
    } else {
        log.err(state.io, "could not enter or open room \"{s}\"", .{state.room_name});
        state.requestAbandonJoin();
    }
}

/// Eventual-send a directory verb naming the room, and wait on its answer.
fn sendDirectoryVerb(state: *PeerState, verb: []const u8, cb: *const fn (?*anyopaque, actors.Resolution) void) void {
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
    _ = flushBridge(state, .host);
}

/// Spawn our room inbox, hand it to the room in `subscribe`, register for
/// introductions, and mark joined.
fn subscribeRoom(state: *PeerState, room: model.Reference) void {
    if (state.phase != .joining) return;
    const joining = state.phase.joining;
    const session = joining.session;
    // The chain guarantees a directory (onDirectory set it before any verb
    // could settle); fail toward a redial rather than crash if that breaks.
    const directory = joining.directory orelse {
        state.requestAbandonJoin();
        return;
    };
    const inbox = session.served.spawn(RoomInbox, .{ .state = state }) catch |err| {
        log.err(state.io, "inbox spawn failed: {s}", .{@errorName(err)});
        state.requestAbandonJoin();
        return;
    };
    _ = state.host.send(session, room, .{
        .verb = "subscribe",
        .args = &.{ .{ .string = state.nick }, inbox.arg() },
    }) catch |err| {
        log.err(state.io, "subscribe failed: {s}", .{@errorName(err)});
        state.requestAbandonJoin();
        return;
    };
    _ = flushBridge(state, .host);
    state.phase = .{ .joined = .{
        .session = session,
        .directory = directory,
        .room = room,
        .reg = .{ .pending = redial_cooldown_wakes },
    } };
    state.join_attempts = 0;
    g_ever_joined = true;
    state.writeStateNow("joined");
    // Publish `dm` on this dialed room session so the directory can fetch it
    // during register. The Bridge still auto-publishes on accepted desks for
    // inbound redeem.
    _ = session.served.publish("dm", DmInbox, .{ .state = state }) catch |err| {
        log.err(state.io, "publish dm on room session failed: {s}", .{@errorName(err)});
    };
    _ = flushBridge(state, .host);
    registerWithDirectory(state);
}

/// Offer this peer for introduce: directory fetches `dm` on this session, then
/// `notify("registered", …)` on our register inbox.
fn registerWithDirectory(state: *PeerState) void {
    if (state.phase != .joined) return;
    const joined = state.phase.joined;
    if (joined.reg != .pending or state.member_locator.len == 0) return;
    const session = joined.session;
    const directory = joined.directory;
    const inbox = session.served.spawn(RegInbox, .{ .state = state }) catch |err| {
        log.err(state.io, "register inbox spawn failed: {s}", .{@errorName(err)});
        return;
    };
    _ = state.host.send(session, directory, .{
        .verb = "register",
        .args = &.{
            .{ .string = state.nick },
            .{ .string = state.member_locator },
            inbox.arg(),
        },
    }) catch |err| {
        log.err(state.io, "register failed: {s}", .{@errorName(err)});
        return;
    };
    _ = flushBridge(state, .host);
}

/// Loop `on_close`: bridge refuse handling, then clear room wire state only when
/// the room session itself drops (accepted DM redeem sessions must not tear
/// presence down).
fn onClose(ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, opened: bool, reason: net.completion.CloseReason) void {
    IrohBridge.onClose(ctx, slot, conn_ctx, opened, reason);
    const bridge: *IrohBridge = @ptrCast(@alignCast(ctx.?));
    const state: *PeerState = @ptrCast(@alignCast(bridge.on_open_ctx.?));
    if (conn_ctx) |raw| {
        const shell: *IrohBridge.Slot = @ptrCast(@alignCast(raw));
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
    if (!opened) phase_mod.connectRefused(&state.phase);
}

// --- outbox -----------------------------------------------------------------

const IntroCtx = struct {
    state: *PeerState,
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
    if (refOf(resolution)) |dm| {
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
    log.err(state.io, "introduce \"{s}\" broke", .{peer});
    rememberFailedIntroduce(state, peer);
}

fn rememberFailedIntroduce(state: *PeerState, peer: []const u8) void {
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
fn tickFailedIntroduces(state: *PeerState) void {
    _ = phase_mod.expireCooldowns(state.gpa, &state.failed_introduces);
}

/// Age every in-flight introduce, and give up on the ones whose wait is over.
/// A settle that arrives later finds no pending row and is ignored, which is
/// the same thing that happens when the room wire is cleared under it.
fn tickPendingIntroduces(state: *PeerState) void {
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

fn startIntroduce(state: *PeerState, peer: []const u8) void {
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
    _ = flushBridge(state, .host);
}

fn evictDmCap(state: *PeerState, peer: []const u8) void {
    if (state.dm_caps.fetchRemove(peer)) |kv| {
        state.gpa.free(kv.key);
        model.freeReference(state.gpa, kv.value);
    }
}

/// Drain outbox lines past `g_offset`. Room posts go immediately; DM lines wait
/// on introduce (offset stops at the first blocked DM so a later wake retries).
/// Fail closed: advance/persist the offset only after tell + drainActions both
/// succeed. A failed post must not record "sent" or skip the line on restart.
fn drainOutbox(state: *PeerState) void {
    if (state.phase != .joined) return;
    const room = state.phase.joined.room;
    const session = state.phase.joined.session;
    const contents = readFile(state.io, state.gpa, state.dir, "outbox.jsonl") catch return;
    defer state.gpa.free(contents);
    g_offset = clampOutboxOffset(g_offset, contents.len);
    if (contents.len <= g_offset) return;

    var pos: usize = g_offset;
    while (pos < contents.len) {
        const nl = std.mem.indexOfScalar(u8, contents[pos..], '\n');
        const line_end = if (nl) |n| pos + n else contents.len;
        const raw = contents[pos..line_end];
        const next = if (nl) |_| line_end + 1 else contents.len;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) {
            pos = next;
            commitOutboxOffset(state, pos);
            continue;
        }

        if (parseOutboxLine(state.gpa, line)) |parsed| {
            defer parsed.deinit(state.gpa);
            if (parsed.is_dm) {
                if (parsed.peer.len == 0) {
                    log.err(state.io, "dm outbox line missing peer", .{});
                    pos = next;
                    commitOutboxOffset(state, pos);
                    continue;
                }
                if (state.failed_introduces.contains(parsed.peer)) {
                    // Do not advance: dropping the line would make the DM
                    // vanish. The refusal ages out on its own, so this stops
                    // for a cooldown rather than until the room session drops.
                    log.err(state.io, "dm outbox blocked: introduce failed for {s} (retry after reconnect)", .{parsed.peer});
                    break;
                }
                if (state.dm_caps.get(parsed.peer)) |dm| {
                    state.host.tell(session, dm, .{
                        .verb = "dm",
                        .args = &.{ .{ .string = state.nick }, .{ .string = parsed.text } },
                    }) catch |err| {
                        log.err(state.io, "dm tell failed: {s}", .{@errorName(err)});
                        evictDmCap(state, parsed.peer);
                        break;
                    };
                    if (!flushBridge(state, .dm)) break;
                    recordInbox(state.io, state.gpa, state.dir, "sent", "dm", state.nick, parsed.text, parsed.peer) catch {};
                    pos = next;
                    commitOutboxOffset(state, pos);
                    continue;
                }
                startIntroduce(state, parsed.peer);
                break;
            }
            state.host.tell(session, room, .{ .verb = "post", .args = &.{.{ .string = parsed.text }} }) catch |err| {
                log.err(state.io, "post failed: {s}", .{@errorName(err)});
                break;
            };
            if (!flushBridge(state, .post)) break;
            recordInbox(state.io, state.gpa, state.dir, "sent", "room", state.nick, parsed.text, "") catch {};
            pos = next;
            commitOutboxOffset(state, pos);
            continue;
        }

        log.err(state.io, "skipping non-JSON outbox line", .{});
        pos = next;
        commitOutboxOffset(state, pos);
    }
}

fn commitOutboxOffset(state: *PeerState, pos: usize) void {
    // Disk first. A cursor that did not persist must not advance in memory
    // either, or a restart resends every line since it — silently, and long
    // after the write that failed. One duplicate now beats a replay later.
    saveOutboxOffset(state.io, state.dir, pos) catch {
        log.err(state.io, "outbox cursor not persisted at {d}; holding at {d}", .{ pos, g_offset });
        return;
    };
    g_offset = pos;
}

/// Why `flushBridge` was called — outbox paths fail closed on `ReenteredHost`.
const FlushKind = enum {
    post,
    dm,
    host,
    maintain,

    fn label(self: FlushKind) []const u8 {
        return switch (self) {
            .post => "post",
            .dm => "dm",
            .host => "host",
            .maintain => "maintain",
        };
    }

    fn isOutbox(self: FlushKind) bool {
        return self == .post or self == .dm;
    }
};

/// Arm bridge outbound for queued HostActions (flush/close/dial).
///
/// `ReenteredHost` means we are inside a host callback latch: actions stay
/// queued. That is NOT success for outbox posts — `dirtyThenPump` only queues
/// a flush; without a later `drainActions` the bridge never `armOutbound`s and
/// the room never sees the line (the "Bueller" silence). Outbox callers must
/// get `false` and retry; join-path callers may continue and rely on `maintain`
/// always flushing outside the latch.
fn flushBridge(state: *PeerState, kind: FlushKind) bool {
    state.bridge.drainActions() catch |err| {
        if (err == error.ReenteredHost) {
            if (kind.isOutbox()) {
                log.err(state.io, "{s} drainActions deferred: ReenteredHost (will retry)", .{kind.label()});
                return false;
            }
            return true;
        }
        log.err(state.io, "{s} drainActions failed: {s}", .{ kind.label(), @errorName(err) });
        return false;
    };
    return true;
}

// --- loop maintenance -------------------------------------------------------

fn maintain(state: *PeerState) void {
    switch (state.phase) {
        // Join failed under a live session: close the slot so we are not stuck
        // open-but-unjoined with no redial. This arm clears PeerState before
        // any deferred onClose lands, so a late close finds `.down` and no-ops
        // instead of racing a half-cleared state. The redial then waits out
        // the ordinary cooldown: a room that keeps refusing the join backs off
        // like a down room, it does not become a per-tick dial storm.
        .abandoning => |session| {
            state.bridge.closeConn(session.peer_id);
            state.clearRoomWire();
            state.phase = .{ .down = .{ .cooldown = redial_cooldown_wakes } };
            state.join_attempts += 1;
        },
        // Back off between redials so a down room is retried steadily, not
        // thrashed every wake tick.
        .down => |*down| {
            if (!phase_mod.tickCooldown(&down.cooldown)) return;
            if (PeerState.stopRequested()) return;
            state.bridge.dialOutbound(state.transport, state.designator, state.hint) catch |err| {
                log.err(state.io, "redial failed: {s}", .{@errorName(err)});
                state.writeStateNow("reconnecting");
                state.phase = .{ .down = .{ .cooldown = redial_cooldown_wakes } };
                return;
            };
            state.writeStateNow("reconnecting");
            state.phase = .{ .dialing = .{ .cooldown = redial_cooldown_wakes } };
        },
        // Connect in flight: keep the countdown running so a refused connect
        // resumes pacing in `.down` (onClose carries it over).
        .dialing => |*dialing| {
            _ = phase_mod.tickCooldown(&dialing.cooldown);
        },
        .joining => |*joining| {
            if (phase_mod.joinDeadlineFires(joining, common.join_deadline_wakes)) {
                log.err(state.io, "join did not complete within the deadline; abandoning", .{});
                state.requestAbandonJoin();
                return;
            }
            // Always flush outside the callback latch so join-path
            // ReenteredHost deferrals (subscribe/register) still armOutbound.
            _ = flushBridge(state, .maintain);
        },
        .joined => |*joined| {
            switch (joined.reg) {
                .pending => |*cooldown| {
                    if (phase_mod.tickCooldown(cooldown)) {
                        registerWithDirectory(state);
                        // Re-arm the retry countdown; the phase cannot have
                        // left `.joined` inside registerWithDirectory, but
                        // re-check rather than write through a stale capture.
                        if (state.phase == .joined and state.phase.joined.reg == .pending) {
                            state.phase.joined.reg = .{ .pending = redial_cooldown_wakes };
                        }
                    }
                },
                .registered => {},
            }
            tickPendingIntroduces(state);
            tickFailedIntroduces(state);
            drainOutbox(state);
            _ = flushBridge(state, .maintain);
        },
    }
}

fn wakePacer(io: Io) void {
    while (!PeerState.stopRequested()) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(timer_ms), .real) catch {};
        g_wake.store(true, .release);
    }
}

/// Sleep up to `total_ms`, waking promptly on a stop. A `Threaded` sleep
/// swallows the SIGTERM `EINTR` and re-waits, so one long sleep is signal-deaf;
/// chunking it at the tick cadence lets the supervisor observe the shared stop
/// latch during a reconnect backoff instead of parking past `stop`'s SIGTERM grace.
fn sleepUntilStop(io: Io, total_ms: i64) void {
    var slept: i64 = 0;
    while (slept < total_ms and !PeerState.stopRequested()) {
        const chunk = @min(@as(i64, @intCast(timer_ms)), total_ms - slept);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(chunk), .real) catch {};
        slept += chunk;
    }
}

// --- peer daemon entry ------------------------------------------------------

/// Treat current inbox scrollback as already answered without stuffing
/// replied.json (which caps and can resurface ancient ids after restart).
fn seedRepliedBacklog(io: Io, gpa: Allocator, dir: []const u8, nick: []const u8) void {
    _ = nick;
    advanceInboxWatermark(io, gpa, dir);
}

pub fn runPeer(init: std.process.Init, flags: Flags) !void {
    const io = init.io;
    const gpa = init.gpa;
    if (init.environ_map.get("ROOMS_PEER_SUPERVISED") == null) {
        log.err(io, "`peer` is the internal daemon — start it with: pancake app rooms-peer start --dir <DIR> --nick <NICK>", .{});
        return error.Unsupervised;
    }
    if (flags.dir.len == 0 or flags.nick.len == 0 or flags.locator.len == 0) return error.MissingFlags;

    // Detach into our own session so a reaped launcher shell cannot SIGHUP us.
    _ = std.os.linux.setsid();
    signals.install();

    Io.Dir.cwd().createDirPath(io, flags.dir) catch {};
    var pid_buf: [24]u8 = undefined;
    const pid_text = std.fmt.bufPrint(&pid_buf, "{d}\n", .{std.os.linux.getpid()}) catch "0\n";
    overwriteFile(io, flags.dir, "peer.pid", pid_text) catch {};
    // Mark the existing scrollback answered once, so a restart never re-answers
    // lines from before we joined.
    seedRepliedBacklog(io, gpa, flags.dir, flags.nick);

    // Resume the outbox drain cursor from disk. Never seed to EOF: that skipped
    // undrained lines written while the peer was down or wedged before tell.
    const outbox_bytes = readFile(io, gpa, flags.dir, "outbox.jsonl") catch try gpa.dupe(u8, "");
    defer gpa.free(outbox_bytes);
    g_offset = clampOutboxOffset(loadOutboxOffset(io, gpa, flags.dir), outbox_bytes.len);

    // The wake pacer runs for the whole daemon life, flipping g_wake so each
    // stack's loop hands control back on its own cadence.
    var pacer = try io.concurrent(wakePacer, .{io});
    defer {
        signals.requestStop();
        pacer.await(io);
    }

    // Supervisor. Keep a functional iroh stack up until a stop signal. A
    // connection drop is recovered inside runStack (maintain redials in place); a
    // fatal loop error — the endpoint or backend itself failing — returns out of
    // runStack, and we build a fresh stack and reconnect. Each rebuild re-resolves
    // an `http(s)://…/locator` bootstrap so a reminted room node id is followed
    // instead of hammering a dead `ocapn://`. Back off when the environment stays
    // broken, and snap back to a fast retry once a stack has actually joined.
    // Only a stop signal ends the daemon.
    var backoff_ms: i64 = 500;
    while (!PeerState.stopRequested()) {
        g_ever_joined = false;
        const dial_target = common.resolveLocator(io, gpa, flags.locator) catch |err| {
            log.err(io, "locator resolve failed: {s}; retrying", .{@errorName(err)});
            writeState(io, gpa, flags.dir, "reconnecting", flags.nick, flags.room, flags.locator, false, 0);
            sleepUntilStop(io, backoff_ms);
            backoff_ms = @min(backoff_ms * 2, 30_000);
            continue;
        };
        defer gpa.free(dial_target);
        const loc = model.uri.parsePeer(gpa, dial_target) catch |err| {
            log.err(io, "locator parse failed: {s}; retrying", .{@errorName(err)});
            writeState(io, gpa, flags.dir, "reconnecting", flags.nick, flags.room, flags.locator, false, 0);
            sleepUntilStop(io, backoff_ms);
            backoff_ms = @min(backoff_ms * 2, 30_000);
            continue;
        };
        defer model.freePeerLocator(gpa, loc);
        if (!std.mem.eql(u8, loc.transport, model.transport.iroh)) {
            log.err(io, "locator is not iroh; refusing", .{});
            return error.NotIroh;
        }
        const hint = net.netlayer.directAddrHint(loc.hints) orelse "";
        const reachability: iroh.Reachability = if (hint.len > 0) .direct else .discovery;
        runStack(io, gpa, flags, loc, hint, reachability, dial_target) catch |err| {
            log.err(io, "iroh stack failed: {s}; rebuilding", .{@errorName(err)});
        };
        if (PeerState.stopRequested()) break;
        writeState(io, gpa, flags.dir, "reconnecting", flags.nick, flags.room, dial_target, false, 0);
        sleepUntilStop(io, backoff_ms);
        backoff_ms = if (g_ever_joined) 500 else @min(backoff_ms * 2, 30_000);
    }

    writeState(io, gpa, flags.dir, "closed", flags.nick, flags.room, flags.locator, false, 0);
    removeFile(io, flags.dir, "peer.pid");
}

/// Resolve the CapTP Host seed: `--identity PATH`, else `DIR/identity` (minted
/// if missing), so presence is stable across restart under the same harness dir.
fn hostSeed(io: Io, dir: []const u8, identity_flag: []const u8) ![32]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path: []const u8 = if (identity_flag.len > 0)
        identity_flag
    else
        try std.fmt.bufPrint(&path_buf, "{s}/identity", .{dir});
    const secret = try identity_mod.loadOrMint(io, path);
    return secret.seed();
}

/// Wait until the endpoint reports at least one direct address (Direct posture
/// register URIs need them), or until `budget_ms` elapses.
fn waitDirectAddrs(io: Io, resident: *iroh.Resident, out: []u8, budget_ms: i64) []const u8 {
    var slept: i64 = 0;
    while (slept <= budget_ms) {
        if (resident.directAddrs(out)) |addrs| {
            if (addrs.len > 0) return addrs;
        } else |_| {}
        if (slept == budget_ms) break;
        const chunk = @min(@as(i64, 50), budget_ms - slept);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(chunk), .real) catch {};
        slept += chunk;
    }
    return "";
}

/// Build a fresh iroh stack (endpoint, host, bridge, completion loop), dial the
/// room, and run the loop. Returns normally when a stop is requested, or returns
/// the error when the loop fails fatally so the supervisor can rebuild. A
/// per-connection drop is recovered here without a rebuild: `on_close` nulls the
/// session and `maintain` redials it.
fn runStack(
    io: Io,
    gpa: Allocator,
    flags: Flags,
    loc: model.PeerLocator,
    hint: []const u8,
    reachability: iroh.Reachability,
    dial_target: []const u8,
) !void {
    // Key unification: the CapTP Host and the iroh endpoint share one seed so
    // accepted hellos (redeem dials) sign the dialed node id.
    const seed = try hostSeed(io, flags.dir, flags.identity);
    var resident = try iroh.Resident.init(io, &seed, .{
        .reachability = reachability,
        .connect_timeout_ms = dial_timeout_ms,
    });
    defer resident.deinit();

    var id_buf: [iroh.node_id_len]u8 = undefined;
    const node_id = resident.nodeId(&id_buf);
    if (node_id.len == 0) {
        log.err(io, "iroh endpoint has no node id", .{});
        return error.NoNodeId;
    }

    // Direct demos stamp address hints on the registered locator so a redeem
    // dial reaches the member without Discovery. Discovery peers advertise a
    // bare node id — the same shape `web.ts` uses for browser DM members — so
    // redeem uses Discovery rather than private container/LAN binds the public
    // recipient cannot reach.
    var addrs_buf: [512]u8 = undefined;
    const addrs: []const u8 = if (reachability == .direct)
        waitDirectAddrs(io, &resident, &addrs_buf, 5_000)
    else
        "";
    if (reachability == .direct and addrs.len == 0) {
        log.err(io, "iroh endpoint has no direct addresses (needed for DM register)", .{});
        return error.NoDirectAddrs;
    }

    var hint_entry: [1]model.HintEntry = undefined;
    const member_hints = model.Hints.forDirectAddresses(addrs, &hint_entry);
    const member_locator = try model.uri.writePeer(gpa, .{
        .transport = iroh.transport_name,
        .designator = node_id,
        .hints = member_hints,
    });
    defer gpa.free(member_locator);

    var host = Host.init(gpa, seed, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .local_turn_budget = actors.Vat.max_batch_local_turns,
    });
    defer host.deinit();

    var loop: IrohLoop = undefined;
    var state = PeerState{
        .io = io,
        .gpa = gpa,
        .host = &host,
        .bridge = undefined,
        .dir = flags.dir,
        .nick = flags.nick,
        .room_name = flags.room,
        .locator_str = dial_target,
        .member_locator = member_locator,
        .transport = loc.transport,
        .designator = loc.designator,
        .hint = hint,
    };
    defer state.deinitTables();
    var bridge = IrohBridge.init(gpa, &host, io, &loop, .{
        .publish = publishDm,
        .publish_ctx = &state,
        .on_open = onOpen,
        .on_open_ctx = &state,
    });
    defer bridge.deinit();
    state.bridge = &bridge;

    const read_buffer_bytes: u32 = @intCast(@min(frame_cap, 16 * 1024));
    const backend = try iroh.Backend.initBound(gpa, &resident, 256, 256, read_buffer_bytes);
    // This peer interposes its own close hook (DM lifecycle bookkeeping), so
    // it overrides the bridge's spliced `on_close` after `hookOptions`.
    var loop_options = IrohBridge.hookOptions(.{
        .frame_cap = frame_cap,
        .max_conns = 32,
        .listen = 0,
    });
    loop_options.on_close = onClose;
    loop = try IrohLoop.initWithBackend(gpa, backend, IrohBridge.makePeer, @ptrCast(&bridge), loop_options);
    defer loop.deinit();

    // Identity for accepted hellos (redeem). Gift exporter location still comes
    // from the directory's `setExporterLocator` on the registered URI — attach
    // keeps the hint empty (bridge buffer is short).
    try bridge.attach(iroh.transport_name, node_id, &.{});

    state.phase = .{ .dialing = .{ .cooldown = 0 } };
    bridge.dialOutbound(loc.transport, loc.designator, hint) catch |err| {
        log.err(io, "dial failed: {s}", .{@errorName(err)});
        state.phase = .{ .down = .{ .cooldown = 0 } };
    };

    while (!PeerState.stopRequested()) {
        // Bounded poll, not `0`. A zero deadline polls forever, and the pacer
        // sets `g_wake` from another thread without waking this loop's poll, so
        // a quiet room would never re-read the stop flag and the daemon would
        // sit through its SIGTERM grace. A timeout is an ordinary tick.
        loop.runUntil(&g_wake, timer_ms) catch |err| switch (err) {
            error.Timeout => {},
            else => {
                loop.closeAndDrain() catch {};
                return err;
            },
        };
        g_wake.store(false, .release);
        maintain(&state);
    }
    loop.closeAndDrain() catch {};
}
