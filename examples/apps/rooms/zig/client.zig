//! A rooms chat client, written on pancake actors in native Zig. Zig is the home
//! language, this runs on the same core every binding wraps, and it drives the
//! real TCP netlayer pancake ships.
//!
//! On the new driver surface this reads like the other languages: `connectTcp`,
//! `fetch` the room by name, `spawn` an inbox the room can call back, `send` the
//! room a subscribe with that capability, and `step` the connection. The
//! pump/poll/serve loop the old version hand-wrote is now one `step()` call — but
//! allocation, ownership, and I/O all stay visible, the Zig way: the caller still
//! owns the peer, the buffers, and the loop.
//!
//!   pancake-rooms-client <port> <nick> <line> [expectMembers]
//!
//! It exits 0 once it has seen a line from every member.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.model;
const engine = pancake.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const tcp = pancake.net_adapter.tcp;

const host = "127.0.0.1";
const frame_cap: usize = 1 << 16;

/// State the inbox actor and the main loop share: how many real chat lines have
/// arrived, and how full the room is (from the room's join announcements).
const State = struct {
    nick: []const u8,
    chat_lines: usize = 0,
    present: u64 = 0,
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
            if (parseRoster(text)) |count| self.state.present = @max(self.state.present, count);
        } else {
            self.state.chat_lines += 1;
        }
        return .{ .void = {} };
    }
};

/// The room announces each arrival as `<nick> joined (<count> here)`; pull the
/// head count back out so the client can wait for the room to fill.
fn parseRoster(text: []const u8) ?u64 {
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    const rest = text[open + 1 ..];
    const close = std.mem.indexOf(u8, rest, " here)") orelse return null;
    return std.fmt.parseInt(u64, rest[0..close], 10) catch null;
}

fn onWelcome(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    _ = resolution;
    const welcomed: *bool = @ptrCast(@alignCast(ctx.?));
    welcomed.* = true;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // program name
    const port_str = args.next() orelse return fail("missing <port>");
    const nick = args.next() orelse return fail("missing <nick>");
    const line = args.next() orelse return fail("missing <line>");
    const expect = try std.fmt.parseInt(usize, args.next() orelse "1", 10);
    const port = try std.fmt.parseInt(u16, port_str, 10);

    var state = State{ .nick = nick };

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    const address = try tcp.parseHostPort(host, port);
    var conn = try driver.connectTcp(io, allocator, &peer, address, read_buf, write_buf);
    defer conn.deinit();

    // Fetch the room by name, then publish our inbox and subscribe with it.
    const room = try conn.fetch("room");
    const inbox = try conn.spawn(Inbox, .{ .state = &state });

    var welcomed = false;
    const sub = try conn.send(room, .{
        .verb = "subscribe",
        .args = &.{ .{ .string = nick }, .{ .reference = inbox.nearRef() } },
    });
    try conn.on(sub, .{ .ctx = &welcomed, .func = onWelcome });

    var posted = false;
    while (state.chat_lines < expect) {
        const progress = conn.step() catch |err| {
            std.debug.print("rooms-client: step error: {s}\n", .{@errorName(err)});
            break;
        };
        // Post once the room is full, so every member is on the roster. The send
        // enqueues; the next step flushes it.
        if (!posted and welcomed and state.present >= expect) {
            _ = try conn.send(room, .{ .verb = "post", .args = &.{.{ .string = line }} });
            posted = true;
        }
        if (progress == .closed) break;
    }

    if (state.chat_lines < expect) {
        std.debug.print("rooms-client: {s} saw {d}/{d} chat lines before the stream ended\n", .{ nick, state.chat_lines, expect });
        std.process.exit(1);
    }
}

fn fail(message: []const u8) error{Usage} {
    std.debug.print("usage: pancake-rooms-client <port> <nick> <line> [expectMembers]\n  ({s})\n", .{message});
    return error.Usage;
}
