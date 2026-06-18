//! `driver.LoopHost` end to end: the nine-verb actor surface on the completion
//! loop, reached through the ergonomic driver API on both sides.
//!
//! A `LoopHost` publishes a `Greeter` on every accepted connection and runs on
//! its own thread over the platform completion backend (io_uring / kqueue).
//! Several `driver.connectTcp` clients dial concurrently, each completing the
//! real keyed `op:start-session` handshake (mutual signature verification on),
//! then `fetch` the greeter and `send` it a call, asserting the reply round-trips
//! — an object answering on the scalable path, assembled by the host API rather
//! than hand-wired loop hooks.

const std = @import("std");
const builtin = @import("builtin");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;

const frame_cap = 4096;
const client_count = 8;

/// The object every connection hosts: answers `greet(name)` with a greeting.
const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        if (!std.mem.eql(u8, msg.verb, "greet")) return error.NoSuchMethod;
        if (msg.args.len != 1) return error.BadInvocation;
        const who = switch (msg.args[0]) {
            .string => |s| s,
            else => return error.BadInvocation,
        };
        return .{ .string = try std.fmt.allocPrint(turn.arena, "hello {s} from the loop", .{who}) };
    }
};

/// The host's per-connection setup: publish the greeter fetchable by name.
fn publishGreeter(ctx: ?*anyopaque, vat: *actors.Vat) anyerror!void {
    _ = ctx;
    _ = try driver.publishNamed(vat, "greeter", Greeter, .{});
}

fn runHost(host: *driver.LoopHost, until_closed: usize, out_err: *?anyerror) void {
    host.run(.{ .after_closed = until_closed }) catch |err| {
        out_err.* = err;
    };
}

/// One client: keyed dial via `connectTcp`, fetch the greeter, call it, assert
/// the reply — all through the `ConnectedVat` surface.
fn callOnce(io: std.Io, port: u16, allocator: std.mem.Allocator) anyerror!void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    const address = try pancake.net.tcp.parseHostPort("127.0.0.1", port);
    var cv = try driver.connectTcp(io, allocator, &peer, address, read_buf, write_buf);
    defer cv.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const greeter = try cv.fetch("greeter");
    const settled = try cv.call(greeter, .{ .verb = "greet", .args = &.{.{ .string = "pancake" }} }, arena_state.allocator());
    switch (settled) {
        .fulfilled => |arg| {
            try std.testing.expect(arg == .string);
            try std.testing.expectEqualStrings("hello pancake from the loop", arg.string);
        },
        .broken => return error.CallBroke,
    }
}

test "driver.LoopHost: hosted actors answer keyed calls at fan-out over the completion loop" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The host at a stable address (run binds the loop's hooks back to it).
    var host = try driver.LoopHost.init(io, allocator, publishGreeter, null, .{
        .frame_cap = frame_cap,
        .max_conns = 32,
        .port = 0,
        // Run with stateless GC on, so the round-trip is proven to survive the
        // post-turn gc emission, not just the bare serve path.
        .gc_stateless = true,
    });
    defer host.deinit();
    const port = host.port();

    var host_err: ?anyerror = null;
    const host_thread = try std.Thread.spawn(.{}, runHost, .{ &host, @as(usize, client_count), &host_err });

    var futures: [client_count]std.Io.Future(anyerror!void) = undefined;
    for (&futures) |*f| f.* = try io.concurrent(callOnce, .{ io, port, allocator });
    var first_err: ?anyerror = null;
    for (&futures) |*f| f.await(io) catch |err| {
        if (first_err == null) first_err = err;
    };

    host_thread.join();
    if (host_err) |err| return err;
    if (first_err) |err| return err;
}
