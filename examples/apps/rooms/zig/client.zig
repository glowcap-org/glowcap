//! A rooms chat client, written on pancake actors in native Zig. Zig is the home
//! language, this runs on the same core every binding wraps, and it drives the
//! real TCP netlayer pancake ships.
//!
//! On the driver surface this reads like the other languages: one owning
//! `driver.connect`, `fetch` the room by name, `spawn` an inbox the room can
//! call back, `send` the room a subscribe with that capability, `tell` it the
//! post, and `step` the connection — one explicit pump per step, with the loop
//! still owned by the caller the Zig way.
//!
//!   pancake-rooms-client <locator> <nick> <line> [roster]
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
const tcp = pancake.net_adapter.tcp;

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

    // The locator picks the transport: a bare `host:port` dials TCP, an
    // `ocapn://` URI dials iroh (only in the iroh-enabled build). The room's
    // wire is identical either way; only how this client reaches it differs.
    if (std.mem.indexOf(u8, locator, "://") != null) {
        if (build_options.iroh_enabled) {
            try dialIroh(io, allocator, locator, &state, nick, line);
        } else {
            return fail("this Zig rooms client is TCP-only; build the iroh variant (`zig build demo-rooms-iroh`) to dial an ocapn:// URI");
        }
    } else {
        var conn = try dialTcp(io, allocator, locator);
        defer conn.close();
        try runRoom(conn, &state, nick, line);
    }

    if (state.seenCount() < state.roster.len) {
        std.debug.print("rooms-client: {s} saw lines from {d}/{d} members before the stream ended\n", .{ nick, state.seenCount(), state.roster.len });
        std.process.exit(1);
    }
}

/// Dial a `host:port` locator over the TCP netlayer pancake ships.
fn dialTcp(io: std.Io, allocator: std.mem.Allocator, locator: []const u8) !*driver.Connection {
    const colon = std.mem.lastIndexOfScalar(u8, locator, ':') orelse return fail("locator is neither host:port nor an ocapn:// URI");
    const port = std.fmt.parseInt(u16, locator[colon + 1 ..], 10) catch return fail("locator has no valid port");
    const address = try tcp.parseHostPort(locator[0..colon], port);
    return driver.connect(io, allocator, address, .{ .frame_cap = frame_cap });
}

/// Dial an `ocapn://<nodeid>.iroh?direct-addresses=…` URI over iroh's encrypted
/// QUIC. Compiled only into the iroh-enabled build (the `iroh` import links the
/// Rust sidecar), so the default TCP build never pulls cargo into its graph. The
/// own iroh endpoint and its registry outlive the connection they dial.
fn dialIroh(io: std.Io, allocator: std.mem.Allocator, uri: []const u8, state: *State, nick: []const u8, line: []const u8) !void {
    const iroh = @import("iroh");
    const net_adapter = pancake.net_adapter;
    // The room URI carries the server's direct addresses, so this client dials
    // in the relay-less `direct` posture — no relay or discovery service.
    var resident = try iroh.Resident.init(io, null, .direct);
    defer resident.deinit();
    const entries = [_]net_adapter.Netlayer{resident.netlayer()};
    const registry = net_adapter.NetlayerRegistry{ .entries = &entries };
    var conn = try driver.connectUriOwned(registry, allocator, uri, .{ .frame_cap = frame_cap });
    defer conn.close();
    try runRoom(conn, state, nick, line);
}

/// Fetch the room, subscribe our inbox, and pump until every roster member's
/// line has arrived — the transport-neutral body both dial paths share.
fn runRoom(conn: *driver.Connection, state: *State, nick: []const u8, line: []const u8) !void {
    const room = try conn.fetch("room");
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
        // Post once every roster member is present, so each one receives our
        // line. No reply is read, so this is a `tell`: one deliver, no answer
        // minted. It enqueues; the next step flushes it.
        if (!posted and state.welcomed and state.allPresent()) {
            try conn.tell(room, .{ .verb = "post", .args = &.{.{ .string = line }} });
            posted = true;
        }
        if (progress == .closed) break;
    }
}

fn fail(message: []const u8) error{Usage} {
    std.debug.print("usage: pancake-rooms-client <locator> <nick> <line> [roster]\n  (locator: host:port or an ocapn:// URI; roster: comma-separated nicks to expect; default just you)\n  ({s})\n", .{message});
    return error.Usage;
}
