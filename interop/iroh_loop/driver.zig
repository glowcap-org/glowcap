//! Live iroh scale: many concurrent connections served from one thread
//! through `iroh.Backend` + `driver.Bridge` + `driver.core.Host` (ADR-0057,
//! ADR-0076).
//!
//! The blocking iroh resident serves one connection per OS thread: one
//! `accept`, one `conn_read`, one `conn_write` parked per partner. That is the
//! shipped path (ADR-0053) and `iroh-interop` proves it correct, but it caps at
//! as many connections as the host can hold threads for, not the ~500k the
//! `bench-peer-scaling` report targets.
//!
//! This gate proves the event-driven scale path instead. One server endpoint
//! feeds `completion.Loop(iroh.Backend, iroh.DialResolver)` through `driver.Bridge` into a full
//! multi-connection `driver.core.Host`: readiness fd, ready-queue drain,
//! non-blocking accept/read/write, adoption, keyed handshake, and per-event
//! serving on one thread. Many clients dial it at once, each over its own iroh
//! endpoint, fetch the published greeter, and call it several times. Every
//! call's reply must come back correct, so the one loop thread is provably
//! multiplexing all the connections at once, not serving them one at a time.
//!
//! Not part of the hermetic `zig build check`: it links the Rust sidecar
//! staticlib, so it runs as the sibling step `zig build iroh-loop`.

const std = @import("std");
const pancake = @import("pancake");
const iroh = @import("iroh");
const harness = @import("interop_harness");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;

const frame_cap: usize = 4096;
const greeting = "hello over the iroh loop";

/// Concurrent connections, each served on the one loop thread.
const num_conns: usize = 16;
/// Calls each connection makes before closing, several turns per connection so
/// the proof is sustained multiplexing, not a single round trip.
const calls_per_conn: usize = 4;

const IrohLoop = net.completion.Loop(iroh.Backend, iroh.DialResolver);
const IrohBridge = driver.Bridge(IrohLoop);
const runLoop = harness.LoopRunner(IrohLoop).runAfterClosed;

/// The published actor: answers `greet` with a static greeting. A fresh instance
/// is published per connection by `publishGreeter`.
const Greeter = harness.StaticReplyActor("greet", greeting);
const publishGreeter = harness.publisher("greeter", Greeter);

/// One client: bind its own iroh endpoint, dial the server by id alone (the
/// `local_discovery` book resolves it), fetch the greeter, and call it
/// `calls_per_conn` times, checking every reply.
fn clientOnce(io: std.Io, allocator: std.mem.Allocator, server_id: []const u8) anyerror!void {
    var client = try iroh.Resident.init(io, null, .{ .reachability = .local_discovery });
    defer client.deinit() catch |err| std.log.err("iroh client teardown failed: {s}", .{@errorName(err)});

    const entries = [_]net.netlayer.Netlayer{client.netlayer()};

    var scaffold = try harness.PeerScaffold.init(allocator, frame_cap);
    defer scaffold.deinit();

    const locator: model.PeerLocator = .{
        .transport = iroh.transport_name,
        .designator = server_id,
        .hints = model.Hints.emptyFalse(),
    };
    var cv = try driver.connectVia(allocator, &entries, &scaffold.peer, locator, .ephemeral, scaffold.read_buf, scaffold.write_buf, .{
        .handshake = .unbounded,
        .settle = .unbounded,
    });
    defer cv.deinit();

    const greeter = try cv.fetch("greeter");
    var i: usize = 0;
    while (i < calls_per_conn) : (i += 1) {
        try harness.expectStringReply(&cv, allocator, greeter, "greet", &.{.{ .string = "world" }}, greeting);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Seed the endpoint and the Host with the same secret so every accepted
    // session signs with the endpoint's own key: iroh is a key-designator
    // transport, and each dialing client pins the session identity to the
    // node id it dialed.
    const server_seed: [32]u8 = @splat(0x47);
    var server = iroh.Resident.init(io, &server_seed, .{ .reachability = .local_discovery }) catch |err| {
        std.debug.print("iroh-loop: server endpoint bind failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer server.deinit() catch |err| std.log.err("iroh server teardown failed: {s}", .{@errorName(err)});

    var id_buf: [iroh.node_id_len]u8 = undefined;
    const server_id = server.nodeId(&id_buf);
    std.debug.print("iroh-loop: server endpoint id {s}\n", .{server_id});

    var session_root: [32]u8 = undefined;
    io.randomSecure(&session_root) catch return error.HandshakeEntropyFailed;
    var host = try driver.core.Host.init(allocator, server_seed, session_root, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .local_turn_budget = driver.core.default_loop_local_turn_budget,
    });
    defer host.deinit();
    var loop: IrohLoop = undefined;
    var bridge = IrohBridge.init(allocator, &host, io, &loop, .{ .publish = publishGreeter });
    defer bridge.deinit();

    const read_buffer_bytes: u32 = @intCast(@min(frame_cap, 16 * 1024));
    const backend = try iroh.Backend.initBound(allocator, &server, 256, 256, read_buffer_bytes);
    loop = try IrohLoop.initWithBackend(allocator, backend, IrohBridge.makePeer, @ptrCast(&bridge), IrohBridge.hookOptions(.{
        .max_conns = 64,
        .listen = 0,
    }));
    defer loop.deinit();
    try bridge.attach(model.transport.Known.iroh.metadata(), server_id, &.{});

    var loop_err: ?anyerror = null;
    var loop_future = try io.concurrent(runLoop, .{ &loop, num_conns, &loop_err });

    var futures: [num_conns]@TypeOf(io.concurrent(clientOnce, .{ io, allocator, server_id }) catch unreachable) = undefined;
    var started: usize = 0;
    while (started < num_conns) : (started += 1) {
        futures[started] = try io.concurrent(clientOnce, .{ io, allocator, server_id });
    }

    var first_err: ?anyerror = null;
    for (futures[0..started]) |*f| {
        if (f.await(io)) |_| {} else |err| {
            if (first_err == null) first_err = err;
            std.debug.print("iroh-loop: a client failed: {s}\n", .{@errorName(err)});
        }
    }

    loop_future.await(io);
    if (loop_err) |err| return err;
    if (first_err) |err| return err;

    std.debug.print(
        "iroh-loop: OK, {d} concurrent iroh connections, {d} calls each, served from one loop thread over Backend + Bridge + Host\n",
        .{ num_conns, calls_per_conn },
    );
}
