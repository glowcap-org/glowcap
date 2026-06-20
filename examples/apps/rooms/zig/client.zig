//! A rooms chat client, written on pancake actors in native Zig. Zig is the home
//! language, this runs on the same core every binding wraps, and it drives the
//! real TCP netlayer pancake ships.
//!
//! On the driver surface this reads like the other languages: one owning
//! `driver.connect`, `fetch` the directory by name, `call` it to enter or open
//! the named room (which hands back a live reference to that room), `spawn` an
//! inbox the room can call back, `send` the room a subscribe with that
//! capability, `tell` it the post, and `step` the connection — one explicit pump
//! per step, with the loop still owned by the caller the Zig way.
//!
//!   pancake-rooms-client <locator> <room> <nick> <line> [roster]
//!
//! The locator is transport-neutral: a `host:port` reaches a TCP room, and an
//! `ocapn://<nodeid>.iroh?direct-addresses=…` URI reaches an iroh room (when
//! this client was built with the iroh transport — `zig build demo-rooms-iroh`;
//! the default `demo-rooms` build is TCP-only and refuses a URI with a typed
//! message rather than dragging the Rust sidecar into the hermetic build).
//!
//! The last argument is the roster: a comma-separated list of the member nicks
//! to expect (default: just you). The client posts only once every roster member
//! is present — it learns who is present from its welcome (which names everyone
//! already in the room) and from the room's join announcements — and exits 0
//! once it has seen a line from every roster member. Members outside the roster
//! (people already chatting in an attached room, say) are printed but never
//! counted, so a busy room cannot fake or break the assertion.

const std = @import("std");
const pancake = @import("pancake");
const build_options = @import("rooms_client_build_options");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;
const tcp = pancake.net.tcp;

const frame_cap: usize = 1 << 16;

/// State the inbox actor, the welcome listener, and the main loop share: which
/// roster members are present, and which we have seen a chat line from.
const State = struct {
    nick: []const u8,
    roster: []const []const u8,
    present: []bool,
    seen: []bool,
    welcomed: bool = false,

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

/// The inbox the room calls back on. A `notify(from, text)` is either a room
/// announcement (from "room") or a chat line from a member.
const Inbox = struct {
    state: *State,

    pub fn handle(self: *Inbox, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "notify")) return error.NoSuchMethod;
        const from = if (msg.args.len > 0 and msg.args[0] == .string) msg.args[0].string else "?";
        const text = if (msg.args.len > 1 and msg.args[1] == .string) msg.args[1].string else "";
        std.debug.print("[{s}] {s}: {s}\n", .{ self.state.nick, from, text });
        if (std.mem.eql(u8, from, "room")) {
            if (parseJoinedNick(text)) |name| self.state.markPresent(name);
        } else {
            self.state.markPresent(from); // a line is presence too
            self.state.markSeen(from);
        }
        return .{ .void = {} };
    }
};

/// The directory's watch observer: the room list's live feed. The directory
/// calls `notify(kind, name, count)` on it for every open/close/count change.
const Watcher = struct {
    nick: []const u8,

    pub fn handle(self: *Watcher, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "notify")) return error.NoSuchMethod;
        const kind = if (msg.args.len > 0 and msg.args[0] == .string) msg.args[0].string else "?";
        const name = if (msg.args.len > 1 and msg.args[1] == .string) msg.args[1].string else "";
        const count = if (msg.args.len > 2 and msg.args[2] == .integer) msg.args[2].integer else 0;
        std.debug.print("[{s}] directory: {s} {s} ({d})\n", .{ self.nick, kind, name, count });
        return .{ .void = {} };
    }
};

/// Print a `list`/`watch` snapshot — a list of `[name, count]` pairs — on one
/// line, so discovery is visible before this client enters its room.
fn printRooms(nick: []const u8, arg: model.Argument) void {
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

/// The room announces each arrival as `<nick> joined (<count> here)`; pull the
/// nick back out so the client knows that roster member is present.
fn parseJoinedNick(text: []const u8) ?[]const u8 {
    const marker = std.mem.indexOf(u8, text, " joined (") orelse return null;
    if (!std.mem.endsWith(u8, text, " here)")) return null;
    return text[0..marker];
}

/// The welcome (the subscribe reply) ends with the nicks already present:
/// `… in the room: a, b, c` — the only way to learn about earlier arrivals.
fn onWelcome(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    state.welcomed = true;
    const text = switch (resolution) {
        .fulfilled => |value| if (value == .string) value.string else return,
        .broken => return,
    };
    const marker = std.mem.indexOf(u8, text, " in the room: ") orelse return;
    var names = std.mem.splitSequence(u8, text[marker + " in the room: ".len ..], ", ");
    while (names.next()) |name| state.markPresent(name);
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
        var conn = try dialTcp(io, allocator, locator);
        defer conn.close();
        try runRoom(conn, allocator, &state, room_name, nick, line);
    }

    if (state.seenCount() < state.roster.len) {
        std.debug.print("rooms-client: {s} saw lines from {d}/{d} members before the stream ended\n", .{ nick, state.seenCount(), state.roster.len });
        std.process.exit(1);
    }
}

/// Dial a `host:port` locator over the TCP netlayer pancake ships. A bare
/// `host:port` is the designator of a `tcp` locator (`tcp.at`); dial it through
/// the one dialer against a TCP-only transport slice.
fn dialTcp(io: std.Io, allocator: std.mem.Allocator, locator: []const u8) !*driver.Connection {
    var tcp_resident = tcp.Resident{ .io = io };
    return driver.connect(&.{tcp_resident.netlayer()}, allocator, tcp.at(locator), .ephemeral, .{ .frame_cap = frame_cap });
}

/// Dial an `ocapn://<nodeid>.iroh?direct-addresses=…` URI over iroh's encrypted
/// QUIC. Compiled only into the iroh-enabled build (the `iroh` import links the
/// Rust sidecar), so the default TCP build never pulls cargo into its graph. The
/// own iroh endpoint and its netlayer slice outlive the connection they dial.
fn dialIroh(io: std.Io, allocator: std.mem.Allocator, uri: []const u8, state: *State, room_name: []const u8, nick: []const u8, line: []const u8) !void {
    const iroh = @import("iroh");
    var resident = try iroh.Resident.init(io, null, .direct);
    defer resident.deinit();
    var conn = try driver.connectUriOwned(&.{resident.netlayer()}, allocator, uri, .ephemeral, .{ .frame_cap = frame_cap });
    defer conn.close();
    try runRoom(conn, allocator, state, room_name, nick, line);
}

/// Lift a capability a `call` returned (a reference argument) into an
/// `actors.Ref` we can send to.
fn roomRefFromArg(arg: model.Argument) !actors.Ref {
    if (arg != .reference) return error.NotACapability;
    return switch (arg.reference) {
        .far => |far_ref| actors.Ref{ .far = far_ref },
        else => error.NotACapability,
    };
}

/// Enter the named room, opening it if it does not exist. The wire stays strict
/// — `enter` breaks if there is no such room, `open` breaks if the name is taken
/// — so this tries `enter`, falls back to `open`, and on a creation race falls
/// back to `enter` once more. The settled outcomes are materialized into a
/// scratch arena that frees here; the returned far ref is POD and outlives it.
fn enterOrOpen(conn: *driver.Connection, allocator: std.mem.Allocator, directory: actors.Ref, room_name: []const u8) !actors.Ref {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const name_arg = model.Argument{ .string = room_name };

    switch (try conn.call(directory, .{ .verb = "enter", .args = &.{name_arg} }, scratch)) {
        .fulfilled => |arg| return roomRefFromArg(arg),
        .broken => |reason| if (std.mem.indexOf(u8, reason, "no room named") == null) {
            std.debug.print("rooms-client: enter \"{s}\" broke: {s}\n", .{ room_name, reason });
            return error.EnterFailed;
        },
    }
    switch (try conn.call(directory, .{ .verb = "open", .args = &.{name_arg} }, scratch)) {
        .fulfilled => |arg| return roomRefFromArg(arg),
        .broken => |reason| if (std.mem.indexOf(u8, reason, "already exists") == null) {
            std.debug.print("rooms-client: open \"{s}\" broke: {s}\n", .{ room_name, reason });
            return error.OpenFailed;
        },
    }
    switch (try conn.call(directory, .{ .verb = "enter", .args = &.{name_arg} }, scratch)) {
        .fulfilled => |arg| return roomRefFromArg(arg),
        .broken => return error.EnterFailed,
    }
}

/// Enter the room, subscribe our inbox, and pump until every roster member's
/// line has arrived, the transport-neutral body both dial paths share.
fn runRoom(conn: *driver.Connection, allocator: std.mem.Allocator, state: *State, room_name: []const u8, nick: []const u8, line: []const u8) !void {
    const directory = try conn.fetch("directory");

    // Discovery: list the live rooms once, then watch the directory so the room
    // list's changes print as members come and go. The watcher actor outlives
    // this scope on the connection's vat, receiving deltas as we step below.
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        switch (try conn.call(directory, .{ .verb = "list", .args = &.{} }, scratch)) {
            .fulfilled => |arg| printRooms(nick, arg),
            .broken => |reason| std.debug.print("[{s}] list broke: {s}\n", .{ nick, reason }),
        }
        const watcher = try conn.spawn(Watcher, .{ .nick = nick });
        switch (try conn.call(directory, .{ .verb = "watch", .args = &.{watcher.arg()} }, scratch)) {
            .fulfilled => {}, // the snapshot reply; we already listed, so ignore it
            .broken => |reason| std.debug.print("[{s}] watch broke: {s}\n", .{ nick, reason }),
        }
    }

    const room = try enterOrOpen(conn, allocator, directory, room_name);
    const inbox = try conn.spawn(Inbox, .{ .state = state });

    const sub = try conn.send(room, .{
        .verb = "subscribe",
        .args = &.{ .{ .string = nick }, inbox.arg() },
    });
    try conn.on(sub, .{ .ctx = state, .func = onWelcome });

    var posted = false;
    while (state.seenCount() < state.roster.len) {
        const progress = conn.step() catch |err| {
            std.debug.print("rooms-client: step error: {s}\n", .{@errorName(err)});
            break;
        };
        if (!posted and state.welcomed and state.allPresent()) {
            try conn.tell(room, .{ .verb = "post", .args = &.{.{ .string = line }} });
            posted = true;
        }
        if (progress == .closed) break;
    }
}

fn fail(message: []const u8) error{Usage} {
    std.debug.print("usage: pancake-rooms-client <locator> <room> <nick> <line> [roster]\n  (locator: host:port or an ocapn:// URI; roster: comma-separated nicks to expect; default just you)\n  ({s})\n", .{message});
    return error.Usage;
}
