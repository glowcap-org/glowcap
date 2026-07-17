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

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
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

/// The published actor: answers `greet` with a static greeting. A fresh instance
/// is published per connection by `publishGreeter`.
const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "greet")) return error.NoSuchMethod;
        return .{ .string = greeting };
    }
};

fn publishGreeter(ctx: ?*anyopaque, served: *driver.Served) anyerror!void {
    _ = ctx;
    _ = try served.publish("greeter", Greeter, .{});
}

fn runLoop(loop: *IrohLoop, until_closed: usize, out_err: *?anyerror) void {
    loop.run(.{ .after_closed = until_closed }) catch |err| {
        out_err.* = err;
    };
}

/// One client: bind its own iroh endpoint, dial the server by id alone (the
/// `local_discovery` book resolves it), fetch the greeter, and call it
/// `calls_per_conn` times, checking every reply.
fn clientOnce(io: std.Io, allocator: std.mem.Allocator, server_id: []const u8) anyerror!void {
    var client = try iroh.Resident.init(io, null, .{ .reachability = .local_discovery });
    defer client.deinit();

    const entries = [_]net.netlayer.Netlayer{client.netlayer()};

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    const locator: model.PeerLocator = .{
        .transport = iroh.transport_name,
        .designator = server_id,
        .hints = model.Hints.emptyFalse(),
    };
    var cv = try driver.connectVia(allocator, &entries, &peer, locator, .ephemeral, read_buf, write_buf, 0);
    defer cv.deinit();

    const greeter = try cv.fetch("greeter");
    var i: usize = 0;
    while (i < calls_per_conn) : (i += 1) {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const settled = try cv.call(greeter, .{ .verb = "greet", .args = &.{.{ .string = "world" }} }, arena_state.allocator());
        const ok = switch (settled) {
            .fulfilled => |arg| arg == .string and std.mem.eql(u8, arg.string, greeting),
            .broken, .give => false,
        };
        if (!ok) return error.WrongReply;
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
    defer server.deinit();

    var id_buf: [iroh.node_id_len]u8 = undefined;
    const server_id = server.nodeId(&id_buf);
    std.debug.print("iroh-loop: server endpoint id {s}\n", .{server_id});

    var host = driver.core.Host.init(allocator, server_seed, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .local_turn_budget = actors.Vat.max_batch_local_turns,
    });
    defer host.deinit();
    var loop: IrohLoop = undefined;
    var bridge = IrohBridge.init(allocator, &host, io, &loop, .{ .publish = publishGreeter });
    defer bridge.deinit();

    const read_buffer_bytes: u32 = @intCast(@min(frame_cap, 16 * 1024));
    const backend = try iroh.Backend.initBound(allocator, &server, 256, 256, read_buffer_bytes);
    loop = try IrohLoop.initWithBackend(allocator, backend, IrohBridge.makePeer, @ptrCast(&bridge), .{
        .frame_cap = frame_cap,
        .max_conns = 64,
        .listen = 0,
        .make_conn_ctx = IrohBridge.makeConnCtx,
        .serve = IrohBridge.serve,
        .free_conn_ctx = IrohBridge.freeConnCtx,
        .on_close = IrohBridge.onClose,
    });
    defer loop.deinit();
    try bridge.attach(iroh.transport_name, server_id, &.{});

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
