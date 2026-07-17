//! Peer daemon: CapTP/iroh room presence loop for `pancake app rooms-peer`.
const std = @import("std");
const pancake = @import("pancake");
const iroh = @import("iroh");
const signals = @import("../../operability/signals.zig");
const identity_mod = @import("../../operability/identity.zig");
const log = @import("../../operability/log.zig");
const common = @import("common.zig");
const harness = @import("harness.zig");
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
const default_locator = common.default_locator;
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

    session: ?*HostSession = null,
    directory: ?model.Reference = null,
    room: ?model.Reference = null,
    joined: bool = false,
    registered: bool = false,
    dialing: bool = false,
    redial_cooldown: u32 = 0,

    /// Cached DM caps from `directory.introduce(nick)` (owned refs + keys).
    dm_caps: std.StringHashMapUnmanaged(model.Reference) = .{},
    /// Nicks with an introduce in flight (owned keys).
    pending_introduces: std.StringHashMapUnmanaged(void) = .{},
    /// Nicks whose introduce broke; skip further outbox lines until reconnect.
    failed_introduces: std.StringHashMapUnmanaged(void) = .{},

    fn stopRequested() bool {
        return signals.stopRequested();
    }

    fn writeStateNow(self: *PeerState, status: []const u8) void {
        writeState(self.io, self.gpa, self.dir, status, self.nick, self.room_name, self.locator_str);
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
        self.session = null;
        self.directory = null;
        self.room = null;
        self.joined = false;
        self.registered = false;
        self.dialing = false;
        self.clearDmTables();
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
        if (std.mem.eql(u8, kind, "registered")) self.state.registered = true;
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

/// Bridge `on_open`: the dialed room session opened. Fetch the directory; the
/// enter/open/subscribe chain runs from the settle callbacks.
fn onOpen(ctx: ?*anyopaque, bridge: *IrohBridge, slot: *IrohBridge.Slot) anyerror!void {
    _ = bridge;
    const state: *PeerState = @ptrCast(@alignCast(ctx.?));
    state.session = slot.session;
    state.dialing = false;
    const vow = try state.host.fetch(slot.session, "directory");
    try state.host.vowOn(vow, .{ .ctx = state, .func = onDirectory });
}

fn onDirectory(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *PeerState = @ptrCast(@alignCast(ctx.?));
    const directory = refOf(resolution) orelse {
        log.err(state.io, "directory fetch did not fulfill", .{});
        return;
    };
    state.directory = directory;
    // The wire stays strict: `enter` breaks if the room is absent, `open` breaks
    // if the name is taken. Try enter, fall back to open, then enter once more on
    // a creation race — the same leniency the blocking client applies.
    sendDirectoryVerb(state, "enter", onEntered);
}

fn onEntered(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *PeerState = @ptrCast(@alignCast(ctx.?));
    if (refOf(resolution)) |room| {
        subscribeRoom(state, room);
    } else {
        sendDirectoryVerb(state, "open", onOpened);
    }
}

fn onOpened(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *PeerState = @ptrCast(@alignCast(ctx.?));
    if (refOf(resolution)) |room| {
        subscribeRoom(state, room);
    } else {
        sendDirectoryVerb(state, "enter", onEnteredAgain);
    }
}

fn onEnteredAgain(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *PeerState = @ptrCast(@alignCast(ctx.?));
    if (refOf(resolution)) |room| {
        subscribeRoom(state, room);
    } else {
        log.err(state.io, "could not enter or open room \"{s}\"", .{state.room_name});
    }
}

/// Eventual-send a directory verb naming the room, and wait on its answer.
fn sendDirectoryVerb(state: *PeerState, verb: []const u8, cb: *const fn (?*anyopaque, actors.Resolution) void) void {
    const directory = state.directory orelse return;
    const session = state.session orelse return;
    const vow = state.host.send(session, directory, .{
        .verb = verb,
        .args = &.{.{ .string = state.room_name }},
    }) catch |err| {
        log.err(state.io, "{s} send failed: {s}", .{ verb, @errorName(err) });
        return;
    };
    state.host.vowOn(vow, .{ .ctx = state, .func = cb }) catch |err| {
        log.err(state.io, "{s} vowOn failed: {s}", .{ verb, @errorName(err) });
        return;
    };
    state.bridge.drainActions() catch {};
}

/// Spawn our room inbox, hand it to the room in `subscribe`, register for
/// introductions, and mark joined.
fn subscribeRoom(state: *PeerState, room: model.Reference) void {
    const session = state.session orelse return;
    const inbox = session.served.spawn(RoomInbox, .{ .state = state }) catch |err| {
        log.err(state.io, "inbox spawn failed: {s}", .{@errorName(err)});
        return;
    };
    state.room = room;
    _ = state.host.send(session, room, .{
        .verb = "subscribe",
        .args = &.{ .{ .string = state.nick }, inbox.arg() },
    }) catch |err| {
        log.err(state.io, "subscribe failed: {s}", .{@errorName(err)});
        return;
    };
    state.bridge.drainActions() catch {};
    state.joined = true;
    g_ever_joined = true;
    state.writeStateNow("joined");
    registerWithDirectory(state);
}

/// Offer this peer for introduce: directory dials `member_locator` back, fetches
/// the giftable `dm`, then `notify("registered", …)` on our register inbox.
fn registerWithDirectory(state: *PeerState) void {
    if (state.registered or state.member_locator.len == 0) return;
    const session = state.session orelse return;
    const directory = state.directory orelse return;
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
    state.bridge.drainActions() catch {};
}

/// Loop `on_close`: bridge refuse handling, then clear room wire state only when
/// the room session itself drops (accepted DM / register dial-backs must not
/// tear presence down).
fn onClose(ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, opened: bool, reason: net.completion.CloseReason) void {
    IrohBridge.onClose(ctx, slot, conn_ctx, opened, reason);
    const bridge: *IrohBridge = @ptrCast(@alignCast(ctx.?));
    const state: *PeerState = @ptrCast(@alignCast(bridge.on_open_ctx.?));
    if (conn_ctx) |raw| {
        const shell: *IrohBridge.Slot = @ptrCast(@alignCast(raw));
        if (state.session) |room_session| {
            if (shell.session == room_session) state.clearRoomWire();
        }
        return;
    }
    if (!opened and state.dialing) state.dialing = false;
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
    if (state.session == null) return;
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
    if (state.failed_introduces.contains(peer)) return;
    const key = state.gpa.dupe(u8, peer) catch return;
    state.failed_introduces.put(state.gpa, key, {}) catch state.gpa.free(key);
}

fn startIntroduce(state: *PeerState, peer: []const u8) void {
    if (state.pending_introduces.contains(peer) or state.failed_introduces.contains(peer)) return;
    const directory = state.directory orelse return;
    const session = state.session orelse return;
    // Map key and IntroCtx peer are separate owned copies so clearRoomWire can
    // free the map without racing the settle callback's free of ic.peer.
    const map_key = state.gpa.dupe(u8, peer) catch return;
    const ctx_peer = state.gpa.dupe(u8, peer) catch {
        state.gpa.free(map_key);
        return;
    };
    state.pending_introduces.put(state.gpa, map_key, {}) catch {
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
    state.bridge.drainActions() catch {};
}

fn evictDmCap(state: *PeerState, peer: []const u8) void {
    if (state.dm_caps.fetchRemove(peer)) |kv| {
        state.gpa.free(kv.key);
        model.freeReference(state.gpa, kv.value);
    }
}

/// Drain outbox lines past `g_offset`. Room posts go immediately; DM lines wait
/// on introduce (offset stops at the first blocked DM so a later wake retries).
fn drainOutbox(state: *PeerState) void {
    const room = state.room orelse return;
    const session = state.session orelse return;
    const contents = readFile(state.io, state.gpa, state.dir, "outbox.jsonl") catch return;
    defer state.gpa.free(contents);
    if (contents.len <= g_offset) return;

    var posted = false;
    var pos: usize = g_offset;
    while (pos < contents.len) {
        const nl = std.mem.indexOfScalar(u8, contents[pos..], '\n');
        const line_end = if (nl) |n| pos + n else contents.len;
        const raw = contents[pos..line_end];
        const next = if (nl) |_| line_end + 1 else contents.len;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) {
            pos = next;
            continue;
        }

        if (parseOutboxLine(state.gpa, line)) |parsed| {
            defer parsed.deinit(state.gpa);
            if (parsed.is_dm) {
                if (parsed.peer.len == 0) {
                    log.err(state.io, "dm outbox line missing peer", .{});
                    pos = next;
                    continue;
                }
                if (state.failed_introduces.contains(parsed.peer)) {
                    pos = next;
                    continue;
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
                    recordInbox(state.io, state.gpa, state.dir, "sent", "dm", state.nick, parsed.text, parsed.peer) catch {};
                    posted = true;
                    pos = next;
                    continue;
                }
                startIntroduce(state, parsed.peer);
                break;
            }
            state.host.tell(session, room, .{ .verb = "post", .args = &.{.{ .string = parsed.text }} }) catch |err| {
                log.err(state.io, "post failed: {s}", .{@errorName(err)});
            };
            recordInbox(state.io, state.gpa, state.dir, "sent", "room", state.nick, parsed.text, "") catch {};
            posted = true;
            pos = next;
            continue;
        }

        // Legacy bare-text line → room post.
        state.host.tell(session, room, .{ .verb = "post", .args = &.{.{ .string = line }} }) catch |err| {
            log.err(state.io, "post failed: {s}", .{@errorName(err)});
        };
        recordInbox(state.io, state.gpa, state.dir, "sent", "room", state.nick, line, "") catch {};
        posted = true;
        pos = next;
    }
    g_offset = pos;
    if (posted) state.bridge.drainActions() catch {};
}

// --- loop maintenance -------------------------------------------------------

fn maintain(state: *PeerState) void {
    if (state.session == null) {
        // Back off between redials so a down room is retried steadily, not
        // thrashed every wake tick.
        if (state.redial_cooldown > 0) {
            state.redial_cooldown -= 1;
            return;
        }
        if (!state.dialing and !PeerState.stopRequested()) {
            state.dialing = true;
            state.bridge.dialOutbound(state.transport, state.designator, state.hint) catch |err| {
                state.dialing = false;
                log.err(state.io, "redial failed: {s}", .{@errorName(err)});
            };
            state.writeStateNow("reconnecting");
            state.redial_cooldown = redial_cooldown_wakes;
        }
        return;
    }
    if (!state.joined) return;
    drainOutbox(state);
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

fn seedRepliedBacklog(io: Io, gpa: Allocator, dir: []const u8, nick: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const items = scanInbox(arena, io, dir, nick);
    if (items.items.len == 0) return;
    var ids: std.ArrayList([]const u8) = .empty;
    for (items.items) |item| ids.append(arena, item.id) catch {};
    _ = markReplied(io, gpa, dir, ids.items);
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

    const loc = try model.uri.parsePeer(gpa, flags.locator);
    defer model.freePeerLocator(gpa, loc);
    if (!std.mem.eql(u8, loc.transport, model.transport.iroh)) return error.NotIroh;
    const hint = net.netlayer.directAddrHint(loc.hints) orelse "";
    const reachability: iroh.Reachability = if (hint.len > 0) .direct else .discovery;

    // Seed the outbox drain offset to the file's end so a restart never re-posts
    // an already-drained queue.
    const seed_outbox = readFile(io, gpa, flags.dir, "outbox.jsonl") catch try gpa.dupe(u8, "");
    g_offset = seed_outbox.len;
    gpa.free(seed_outbox);

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
    // runStack, and we build a fresh stack and reconnect. Back off when the
    // environment stays broken, and snap back to a fast retry once a stack has
    // actually joined. Only a stop signal ends the daemon.
    var backoff_ms: i64 = 500;
    while (!PeerState.stopRequested()) {
        g_ever_joined = false;
        runStack(io, gpa, flags, loc, hint, reachability) catch |err| {
            log.err(io, "iroh stack failed: {s}; rebuilding", .{@errorName(err)});
        };
        if (PeerState.stopRequested()) break;
        writeState(io, gpa, flags.dir, "reconnecting", flags.nick, flags.room, flags.locator);
        sleepUntilStop(io, backoff_ms);
        backoff_ms = if (g_ever_joined) 500 else @min(backoff_ms * 2, 30_000);
    }

    writeState(io, gpa, flags.dir, "closed", flags.nick, flags.room, flags.locator);
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
) !void {
    // Key unification: the CapTP Host and the iroh endpoint share one seed so
    // accepted hellos (register dial-back, redeem) sign the dialed node id.
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

    var addrs_buf: [512]u8 = undefined;
    const addrs: []const u8 = if (reachability == .direct)
        waitDirectAddrs(io, &resident, &addrs_buf, 5_000)
    else
        resident.directAddrs(&addrs_buf) catch "";
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
        .locator_str = flags.locator,
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
    loop = try IrohLoop.initWithBackend(gpa, backend, IrohBridge.makePeer, @ptrCast(&bridge), .{
        .frame_cap = frame_cap,
        .max_conns = 32,
        .listen = 0,
        .make_conn_ctx = IrohBridge.makeConnCtx,
        .serve = IrohBridge.serve,
        .free_conn_ctx = IrohBridge.freeConnCtx,
        .on_close = onClose,
    });
    defer loop.deinit();

    // Identity for accepted hellos (register dial-back + redeem). Gift exporter
    // location still comes from the directory's `setExporterLocator` on the
    // registered URI — attach keeps the hint empty (bridge buffer is short).
    try bridge.attach(iroh.transport_name, node_id, &.{});

    state.dialing = true;
    bridge.dialOutbound(loc.transport, loc.designator, hint) catch |err| {
        log.err(io, "dial failed: {s}", .{@errorName(err)});
        state.dialing = false;
    };

    while (!PeerState.stopRequested()) {
        loop.runUntil(&g_wake, 0) catch |err| {
            loop.closeAndDrain() catch {};
            return err;
        };
        g_wake.store(false, .release);
        maintain(&state);
    }
    loop.closeAndDrain() catch {};
}
