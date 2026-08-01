//! The buffer-explicit form of the application surface.
//!
//! Chapter 01 rides the owning `driver.Session`, where one `frame_cap`
//! option sizes the buffers and the session limit together. This example is
//! the same conversation one layer down, where every allocation is visible at
//! the call site: the caller owns the negotiating `engine.Peer` (and sets its
//! frame limit), owns both read/write buffers, and passes all three to
//! `driver.connectTcp` / `driver.acceptTcp`. The buffers size the steady
//! state, not the largest admissible frame. An inbound frame that outgrows
//! the read buffer assembles once in the connection's bounded spill, capped by
//! the peer's `max_frame_bytes`. The reply is observed with the explicit
//! vow idiom: `send` returns a vow, `on` registers a listener, and the
//! caller pumps the socket one `step` at a time until it settles.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const pancake = @import("pancake");

/// A finite handshake budget. The library default is unbounded, so a partner
/// that opens a socket and then says nothing would park this example forever.
/// A reader copies this line, which is why it names a real number.
const handshake_budget: driver.Budget = .{ .ms = 10_000 };

/// A finite budget for every wait after the session opens. Same reason: the
/// library default waits forever, and a reader copies this line.
const settle_budget: driver.Budget = .{ .ms = 10_000 };

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const tcp = pancake.net.tcp;

const frame_cap: usize = 4096;

/// The published actor: answers `greet(name)` with a greeting built in the
/// turn's arena.
const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        if (!std.mem.eql(u8, msg.verb, "greet")) return error.NoSuchMethod;
        if (msg.args.len != 1) return error.BadInvocation;
        const name = switch (msg.args[0]) {
            .string => |s| s,
            else => return error.BadInvocation,
        };
        return .{ .string = try std.fmt.allocPrint(turn.arena, "Hello, {s}", .{name}) };
    }
};

/// The hosting half with the caller owning every piece: the peer, its frame
/// limit, and both buffers. The keyed handshake completes inside `acceptTcp`.
fn host(listener: *tcp.Listener, allocator: std.mem.Allocator) !void {
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .limits = .{ .max_frame_bytes = frame_cap } });
    defer peer.deinit();
    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var session = try driver.acceptTcp(allocator, &peer, listener, read_buf, write_buf, handshake_budget);
    // The accepting side gets the same budget as the dialing side. It only
    // serves here, and serving does not wait on an answer, but a reader copies
    // this block into code that does.
    session.settle = settle_budget;
    defer session.deinit();

    _ = try session.publish("greeter", Greeter, .{});
    try session.serve();
}

/// The reply listener fires once, during the settling step, with a
/// turn-borrowed resolution. Copy out what must outlive it. Two bools are all
/// this client keeps.
const Reply = struct {
    done: bool = false,
    ok: bool = false,
};

fn onReply(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const reply: *Reply = @ptrCast(@alignCast(ctx.?));
    reply.done = true;
    reply.ok = switch (resolution) {
        .fulfilled => |arg| arg == .string and std.mem.eql(u8, arg.string, "Hello, world"),
        .broken, .give => false,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = try tcp.Listener.bind(io, .{ .ip4 = std.Io.net.Ip4Address.loopback(0) });
    defer listener.deinit();

    var hosting = try io.concurrent(host, .{ &listener, allocator });

    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .limits = .{ .max_frame_bytes = frame_cap } });
    defer peer.deinit();
    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var session = try driver.connectTcp(allocator, io, &peer, listener.localAddress(), read_buf, write_buf, handshake_budget);
    // The other budget, and the other default. `fetch`, `call`, and `settle`
    // all wait on the partner to answer, and they wait forever unless this is
    // set. It is a field rather than a parameter because those waits happen
    // after the session is open, which is the whole difference from the
    // handshake budget above.
    session.settle = settle_budget;
    const greeter = try session.fetch("greeter");

    var reply = Reply{};
    const vow = try session.send(greeter, .{
        .verb = "greet",
        .args = &.{.{ .string = "world" }},
    });
    try session.on(vow, .{ .ctx = &reply, .func = onReply });
    while (!reply.done) {
        const progress = try session.step();
        if (progress == .closed) break;
    }

    session.deinit();
    try hosting.await(io);

    if (!reply.done or !reply.ok) return error.UnexpectedReply;
    std.debug.print("explicit buffers: the same greeter round-trip with every allocation at the call site\n", .{});
}
