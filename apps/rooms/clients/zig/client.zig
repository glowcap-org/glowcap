//! A rooms chat client, written on pancake actors in native Zig. Zig is the home
//! language; this runs on the same core every binding wraps, and it drives the
//! real TCP netlayer pancake ships.
//!
//! On the driver surface this reads like the other languages: one owning
//! `driver.connect`, `fetch` the directory by name, `call` it to enter or open
//! the named room (which hands back a live reference to that room), `spawn` an
//! inbox the room can call back, `send` the room a subscribe with that
//! capability, `tell` it the post, and `step` the connection with one explicit pump
//! per step, with the loop still owned by the caller the Zig way.
//!
//!   pancake-rooms-client <locator> <room> <nick> <line> [roster]
//!
//! The locator is transport-neutral: a `host:port` reaches a TCP room, and an
//! `ocapn://<nodeid>.iroh?direct-addresses=…` URI reaches an iroh room (when
//! this client was built with the iroh transport (`zig build demo-rooms-iroh`).
//! the default `demo-rooms` build is TCP-only and refuses a URI with a typed
//! message rather than dragging the Rust sidecar into the hermetic build).
//!
//! The last argument is the roster: a comma-separated list of the member nicks
//! to expect (default: just you). The client posts only once every roster member
//! is present. It learns who is present from the structured presence the room
//! attaches to each membership line (the roster on arrival and each join), and
//! exits 0 once it has seen a line from every roster member. Members outside the roster
//! (people already chatting in an attached room, say) are printed but never
//! counted, so a busy room cannot fake or break the assertion.

const std = @import("std");
const pancake = @import("pancake");
const build_options = @import("rooms_client_build_options");

const demo_rooms = @import("demo_rooms_cli");
const demo_usage = @import("demo_usage");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;
const tcp = pancake.net.tcp;

const frame_cap: usize = 1 << 16;
/// The whole roster wait is bounded, like the Deno/Python/Racket clients'
/// deadlines: a member that never completes exits 1 with its seen-count
/// instead of wedging the demo.
const roster_wait_budget_ms: i64 = 60_000;
/// One bounded readable-wait per loop turn, so the deadline above is checked
/// even while the wire is silent.
const step_poll_ms: i32 = 250;

/// State the inbox actor and the main loop share: which roster members are
/// present, and which we have seen a chat line from.
const State = struct {
    nick: []const u8,
    roster: []const []const u8,
    present: []bool,
    seen: []bool,

    fn markPresent(self: *State, name: []const u8) void {
        for (self.roster, 0..) |member, i| {
            if (std.mem.eql(u8, member, name)) self.present[i] = true;
        }
    }

    fn markSeen(self: *State, name: []const u8) void {
        for (self.roster, 0..) |member, i| {
            if (std.mem.eql(u8, member, name)) self.seen[i] = true;
        }
    }

    fn markAbsent(self: *State, name: []const u8) void {
        for (self.roster, 0..) |member, i| {
            if (std.mem.eql(u8, member, name)) self.present[i] = false;
        }
    }

    fn allPresent(self: *const State) bool {
        for (self.present) |p| if (!p) return false;
        return true;
    }

    fn seenCount(self: *const State) usize {
        var n: usize = 0;
        for (self.seen) |s| {
            if (s) n += 1;
        }
        return n;
    }
};

/// The inbox the room calls back on. A `notify(from, text, ...presence)` is either
/// a room announcement (from "room", carrying a structured presence change after
/// the text) or a plain chat line from a member.
const Inbox = struct {
    state: *State,

    pub fn handle(self: *Inbox, ht: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        _ = ht;
        if (!std.mem.eql(u8, verb, "notify")) return error.NoSuchMethod;
        const from = if (args.len > 0 and args[0] == .string) args[0].string else "?";
        const text = if (args.len > 1 and args[1] == .string) args[1].string else "";
        std.debug.print("[{s}] {s}: {s}\n", .{ self.state.nick, from, text });
        // A membership line carries its change as structured args; a plain chat
        // line does not, and a line from a member is presence too.
        if (!applyPresence(self.state, args) and !std.mem.eql(u8, from, "room")) {
            self.state.markPresent(from);
            self.state.markSeen(from);
        }
        return .{ .void = {} };
    }
};

/// The directory's watch observer: the room list's live feed. The directory
/// calls `notify(kind, name, count)` on it for every open/close/count change.
const Watcher = struct {
    nick: []const u8,

    pub fn handle(self: *Watcher, ht: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        _ = ht;
        if (!std.mem.eql(u8, verb, "notify")) return error.NoSuchMethod;
        const kind = if (args.len > 0 and args[0] == .string) args[0].string else "?";
        const name = if (args.len > 1 and args[1] == .string) args[1].string else "";
        const count = if (args.len > 2 and args[2] == .integer) args[2].integer else 0;
        std.debug.print("[{s}] directory: {s} {s} ({d})\n", .{ self.nick, kind, name, count });
        return .{ .void = {} };
    }
};

/// Print a `list`/`watch` snapshot — a list of `[name, count]` pairs — on one
/// line, so discovery is visible before this client enters its room.
fn printRooms(nick: []const u8, arg: driver.Value) void {
    std.debug.print("[{s}] rooms:", .{nick});
    var any = false;
    if (arg == .list) {
        for (arg.list) |item| {
            if (item != .list or item.list.len < 2) continue;
            const name = if (item.list[0] == .string) item.list[0].string else "?";
            const count = if (item.list[1] == .integer) item.list[1].integer else 0;
            std.debug.print(" {s} ({d})", .{ name, count });
            any = true;
        }
    }
    if (!any) std.debug.print(" (none yet)", .{});
    std.debug.print("\n", .{});
}

/// Apply the structured presence a room line carries after its display text, if
/// any: `notify("room", text, "roster", names…)` names everyone already here (our
/// welcome), and `notify("room", text, "join"|"leave", nick)` marks that one member
/// present or absent. Returns true when the line was a presence change, so the
/// caller does not also count it as a chat line.
fn applyPresence(state: *State, args: []const driver.Value) bool {
    if (args.len < 3 or args[2] != .string) return false;
    const kind = args[2].string;
    if (std.mem.eql(u8, kind, "roster")) {
        for (args[3..]) |name_arg| {
            if (name_arg == .string) state.markPresent(name_arg.string);
        }
        return true;
    }
    if (args.len > 3 and args[3] == .string) {
        const name = args[3].string;
        if (std.mem.eql(u8, kind, "join")) {
            state.markPresent(name);
            return true;
        }
        if (std.mem.eql(u8, kind, "leave")) {
            state.markAbsent(name);
            return true;
        }
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // program name
    const locator = args.next() orelse return fail("missing <locator>");
    const room_name = args.next() orelse return fail("missing <room>");
    const nick = args.next() orelse return fail("missing <nick>");
    const line = args.next() orelse return fail("missing <line>");
    const roster_str = args.next() orelse nick;

    var roster: std.ArrayList([]const u8) = .empty;
    defer roster.deinit(allocator);
    var roster_names = std.mem.splitScalar(u8, roster_str, ',');
    while (roster_names.next()) |name| {
        if (name.len > 0) try roster.append(allocator, name);
    }
    if (roster.items.len == 0) return fail("empty <roster>");

    const present = try allocator.alloc(bool, roster.items.len);
    defer allocator.free(present);
    @memset(present, false);
    const seen = try allocator.alloc(bool, roster.items.len);
    defer allocator.free(seen);
    @memset(seen, false);
    var state = State{ .nick = nick, .roster = roster.items, .present = present, .seen = seen };

    if (std.mem.indexOf(u8, locator, "://") != null) {
        if (build_options.iroh_enabled) {
            try dialIroh(io, allocator, locator, &state, room_name, nick, line);
        } else {
            return fail("this Zig rooms client is TCP-only; build the iroh variant (`zig build demo-rooms-iroh`) to dial an ocapn:// URI");
        }
    } else {
        var session = try dialRoomsLocator(io, allocator, locator);
        defer session.deinit();
        try runRoom(io, session, allocator, &state, room_name, nick, line);
    }

    if (state.seenCount() < state.roster.len) {
        std.debug.print("rooms-client: {s} saw lines from {d}/{d} members before the stream ended\n", .{ nick, state.seenCount(), state.roster.len });
        std.process.exit(1);
    }
}

/// Dial a `host:port` designator over the TCP netlayer pancake ships. A bare
/// `host:port` is the designator of a `tcp` locator (`tcp.at`); dial it through
/// the one dialer against a TCP-only transport slice.
fn dialRoomsLocator(io: std.Io, allocator: std.mem.Allocator, locator: []const u8) !*driver.Session {
    var tcp_resident = tcp.Resident{ .io = io };
    return driver.connect(allocator, &.{tcp_resident.netlayer()}, tcp.at(locator), .ephemeral, .{ .frame_cap = frame_cap, .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } });
}

/// Dial an `ocapn://<nodeid>.iroh?direct-addresses=…` URI over iroh's encrypted
/// QUIC. Compiled only into the iroh-enabled build (the `iroh` import links the
/// Rust sidecar), so the default TCP build never pulls cargo into its graph. A
/// URI carrying direct-addresses dials those directly (relay-less Direct); a
/// node-id-only URI resolves the peer through discovery.
fn dialIroh(io: std.Io, allocator: std.mem.Allocator, uri: []const u8, state: *State, room_name: []const u8, nick: []const u8, line: []const u8) !void {
    const loc = try model.uri.parsePeer(allocator, uri);
    defer model.freePeerLocator(allocator, loc);
    if (!std.mem.eql(u8, loc.transport, model.transport.iroh)) {
        return fail("rooms expected an iroh ocapn:// URI");
    }
    const hints = net.netlayer.directAddrHint(loc.hints) orelse "";
    const reachability: @import("iroh").Reachability = if (hints.len > 0) .direct else .discovery;
    const iroh = @import("iroh");
    var resident = try iroh.Resident.init(io, null, .{ .reachability = reachability });
    defer resident.deinit();
    var session = try driver.connect(allocator, &.{resident.netlayer()}, loc, .ephemeral, .{ .frame_cap = frame_cap, .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } });
    defer session.deinit();
    try runRoom(io, session, allocator, state, room_name, nick, line);
}

/// The capability a `call` returned, or a refusal when the reply carried
/// something else.
fn roomRefFromArg(arg: driver.Value) !driver.Capability {
    if (arg != .capability) return error.NotACapability;
    return arg.capability;
}

/// Enter-or-open lives here because it materializes settled outcomes through the
/// Zig driver's blocking `session.call`; see `_demo/rooms_cli.{py,rkt,rs}` for the
/// same CLI leniency in other languages.
/// Enter the named room, opening it if it does not exist. The wire stays strict
/// — `enter` breaks if there is no such room, `open` breaks if the name is taken
/// — so this tries `enter`, falls back to `open`, and on a creation race falls
/// back to `enter` once more. The settled outcomes are materialized into a
/// scratch arena that frees here; the returned far ref is POD and outlives it.
fn enterOrOpen(session: *driver.Session, allocator: std.mem.Allocator, directory: driver.Capability, room_name: []const u8) !driver.Capability {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const name_arg = driver.Value{ .string = room_name };

    switch (try session.call(directory, "enter", &.{name_arg}, scratch)) {
        .fulfilled => |arg| return roomRefFromArg(arg),
        .broken => |reason| if (!std.mem.eql(u8, demo_rooms.errorCode(reason), demo_rooms.no_such_room)) {
            std.debug.print("rooms-client: enter \"{s}\" broke: {s}\n", .{ room_name, reason });
            return error.EnterFailed;
        },
    }
    switch (try session.call(directory, "open", &.{name_arg}, scratch)) {
        .fulfilled => |arg| return roomRefFromArg(arg),
        .broken => |reason| if (!std.mem.eql(u8, demo_rooms.errorCode(reason), demo_rooms.room_exists)) {
            std.debug.print("rooms-client: open \"{s}\" broke: {s}\n", .{ room_name, reason });
            return error.OpenFailed;
        },
    }
    switch (try session.call(directory, "enter", &.{name_arg}, scratch)) {
        .fulfilled => |arg| return roomRefFromArg(arg),
        .broken => return error.EnterFailed,
    }
}

/// Enter the room, subscribe our inbox, and pump until every roster member's
/// line has arrived, the transport-neutral body both dial paths share.
fn runRoom(io: std.Io, session: *driver.Session, allocator: std.mem.Allocator, state: *State, room_name: []const u8, nick: []const u8, line: []const u8) !void {
    const directory = try session.fetch("directory");

    // Discovery: list the live rooms once, then watch the directory so the room
    // list's changes print as members come and go. The watcher actor outlives
    // this scope on the connection's vat, receiving deltas as we step below.
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        switch (try session.call(directory, "list", &.{}, scratch)) {
            .fulfilled => |arg| printRooms(nick, arg),
            .broken => |reason| std.debug.print("[{s}] list broke: {s}\n", .{ nick, reason }),
        }
        const watcher = try session.spawn(Watcher, .{ .nick = nick });
        switch (try session.call(directory, "watch", &.{.{ .capability = watcher }}, scratch)) {
            .fulfilled => {}, // the snapshot reply; we already listed, so ignore it
            .broken => |reason| std.debug.print("[{s}] watch broke: {s}\n", .{ nick, reason }),
        }
    }

    const room = try enterOrOpen(session, allocator, directory, room_name);
    const inbox = try session.spawn(Inbox, .{ .state = state });

    // Subscribe, handing the room a capability to our inbox. Success is the
    // resolution; the room delivers the welcome and roster as our first `notify`
    // (the roster line), not as a return value.
    _ = try session.send(room, "subscribe", &.{ .{ .string = nick }, .{ .capability = inbox } });

    // Bounded like every sibling client: if the roster never completes (a
    // member failed to join), fail loud with the seen-count message below
    // instead of parking the demo in an unbounded socket wait.
    var posted = false;
    const deadline = net.clock.nowMs(io) + roster_wait_budget_ms;
    while (state.seenCount() < state.roster.len) {
        if (net.clock.nowMs(io) >= deadline) break;
        const progress = session.stepReadable(step_poll_ms) catch |err| {
            std.debug.print("rooms-client: step error: {s}\n", .{@errorName(err)});
            break;
        };
        if (!posted and state.allPresent()) {
            try session.tell(room, "post", &.{.{ .string = line }});
            posted = true;
        }
        if (progress) |p| {
            if (p == .closed) break;
        }
    }
}

fn fail(message: []const u8) error{Usage} {
    return demo_usage.usage("usage: pancake-rooms-client <locator> <room> <nick> <line> [roster]\n  (locator: host:port or an ocapn:// URI; roster: comma-separated nicks to expect; default just you)", message);
}
