//! 01 — The application surface: connect, listen, fetch, call, serve, close.
//!
//! This chapter is the surface an application actually rides — the same nine
//! verbs every binding exposes, in native Zig. Chapters 02–04 peel back the
//! layers underneath it, one at a time, down to the raw engine. Each side
//! holds one owning `driver.Connection` over
//! a real TCP socket with the keyed, authenticated `op:start-session`
//! handshake on both ends. The host listens, accepts a partner, publishes an
//! actor by name, and `serve`s until the partner leaves. The client connects,
//! fetches the actor by name, `call`s it, and switches on the settled outcome.
//! There are no export positions, no manual flush, and no hand-rolled receive
//! loop. One `frame_cap` option sizes the owned buffers and the session's
//! frame limit together; the buffer-explicit spelling of the same surface
//! lives in `connect_explicit_buffers.zig`.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;

/// The published actor: answers `greet(name)` with a greeting built in the
/// turn's arena, which outlives the reply encode and nothing more.
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

/// The hosting half: accept one partner (the keyed handshake completes inside
/// `accept`), publish the greeter by name, and serve until the partner leaves.
fn host(server: *driver.Server) !void {
    var conn = try server.accept();
    defer conn.close();
    _ = try conn.publish("greeter", Greeter, .{});
    try conn.serve();
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try driver.listen(io, allocator, .{ .ip4 = std.Io.net.Ip4Address.loopback(0) }, .{});
    defer server.close();

    // The host serves on a concurrent fiber; the client drives this one.
    var hosting = try io.concurrent(host, .{&server});

    // The client half: connect, fetch, call, switch on the settled outcome.
    var conn = try driver.connect(io, allocator, server.localAddress(), .{});
    const greeter = try conn.fetch("greeter");

    // `call` blocks until the reply settles and materializes the outcome into
    // the arena, so nothing in `settled` borrows the turn that resolved it.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const settled = try conn.call(greeter, .{
        .verb = "greet",
        .args = &.{.{ .string = "world" }},
    }, arena_state.allocator());

    // Closing the connection is what ends the host's serve.
    conn.close();
    try hosting.await(io);

    const ok = switch (settled) {
        .fulfilled => |arg| arg == .string and std.mem.eql(u8, arg.string, "Hello, world"),
        .broken => false,
    };
    if (!ok) return error.UnexpectedReply;
    std.debug.print("01: greeter fetched by name and called over a real OCapN/TCP session\n", .{});
}
