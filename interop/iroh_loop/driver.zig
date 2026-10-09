//! Live iroh scale: many concurrent connections served from one thread by a
//! `driver.Server` over a managed iroh resident (ADR-0057, ADR-0193).
//!
//! One server endpoint feeds the iroh resident, and the Server's runtime
//! serves every accepted session on its one thread: readiness descriptor,
//! ready-queue drain, nonblocking accept, read and write, adoption, keyed
//! handshake, and per-event serving. Many clients dial it at once, each over
//! its own iroh endpoint, fetch the published greeter, and call it several
//! times. Every call's reply must come back correct, so the one serving
//! thread is provably multiplexing all the connections at once, not serving
//! them one at a time.
//!
//! Not part of the hermetic `zig build check`: it links the Rust sidecar
//! staticlib, so it runs as the sibling step `zig build iroh-loop`.

const std = @import("std");
const glowcap = @import("glowcap");
const iroh = @import("iroh");
const harness = @import("interop_harness");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;

const frame_cap: usize = 4096;
const greeting = "hello over the iroh loop";

/// Concurrent connections, each served on the one serving thread.
const num_conns: usize = 16;
/// Calls each connection makes before closing, several turns per connection so
/// the proof is sustained multiplexing, not a single round trip.
const calls_per_conn: usize = 4;

const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 15_000 },
    .settle = .{ .ms = 15_000 },
};

const Greeter = harness.StaticReplyBehavior("greet", greeting);

/// One client: bind its own iroh endpoint, dial the server by id alone (the
/// `local_discovery` book resolves it), fetch the greeter, and call it
/// `calls_per_conn` times, checking every reply.
fn clientOnce(io: std.Io, allocator: std.mem.Allocator, server_id: []const u8) anyerror!void {
    var endpoint = try iroh.Resident.init(io, null, .{ .reachability = .local_discovery });
    defer endpoint.deinit() catch |err| std.log.err("iroh client teardown failed: {s}", .{@errorName(err)});
    var adapter = try iroh.MultiplexedAdapter.init(allocator, &endpoint);
    defer if (adapter.deinit()) |failure| std.log.err("iroh client adapter: {s}", .{failure.primaryName()});
    const providers = [_]driver.HostRuntime.ProviderRegistration{.{ .profile = iroh.transport_profile, .resident = adapter.multiplexed() }};

    const session = try driver.connect(allocator, io, .{ .residents = &providers }, .{
        .transport = iroh.transport_name,
        .designator = server_id,
        .hints = model.Hints.emptyFalse(),
    }, .ephemeral, opts);
    defer session.deinit();

    const greeter = try session.fetch("greeter");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (0..calls_per_conn) |_| {
        _ = arena.reset(.retain_capacity);
        switch (try session.call(greeter, "greet", &.{.{ .string = "world" }}, arena.allocator())) {
            .fulfilled => |value| if (value != .string or !std.mem.eql(u8, value.string, greeting)) return error.WrongReply,
            .broken => return error.BrokenReply,
        }
    }
}

/// Accept every client and serve them all from this one thread until the
/// main thread has joined the clients.
fn serve(server: *driver.Server, done: *std.atomic.Value(bool)) anyerror!void {
    var sessions: [num_conns]*driver.Session = undefined;
    var accepted: usize = 0;
    defer for (sessions[0..accepted]) |session| session.deinit();
    while (!done.load(.acquire)) {
        if (accepted < num_conns and try server.waitAcceptable(0)) {
            sessions[accepted] = try server.accept();
            accepted += 1;
            // An accepted session dispatches nothing until its owner attends.
            try sessions[accepted - 1].attend();
            continue;
        }
        _ = try server.runtime.stepAny(10);
    }
    if (accepted != num_conns) return error.MissingAccepts;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Key the endpoint and the Host with the same secret: iroh is a
    // key-designator transport, and each client pins the session identity to
    // the node id it dialed.
    const server_seed: [32]u8 = @splat(0x47);
    var endpoint = iroh.Resident.init(io, &server_seed, .{ .reachability = .local_discovery }) catch |err| {
        std.debug.print("iroh-loop: server endpoint bind failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer endpoint.deinit() catch |err| std.log.err("iroh server teardown failed: {s}", .{@errorName(err)});
    var adapter = try iroh.MultiplexedAdapter.init(allocator, &endpoint);
    defer if (adapter.deinit()) |failure| std.log.err("iroh server adapter: {s}", .{failure.primaryName()});
    const providers = [_]driver.HostRuntime.ProviderRegistration{.{ .profile = iroh.transport_profile, .resident = adapter.multiplexed() }};

    var server = try driver.listen(allocator, io, .{ .residents = &providers }, iroh.transport_name, .{ .designator = "" }, .{
        .keyed = glowcap.foundation.crypto.SecretKey.fromSeed(server_seed),
    }, opts);
    defer server.deinit();
    try server.publish("greeter", Greeter, .{});
    var id_buf: [iroh.node_id_len]u8 = undefined;
    const server_id = endpoint.nodeId(&id_buf);
    std.debug.print("iroh-loop: server endpoint id {s}\n", .{server_id});

    var done = std.atomic.Value(bool).init(false);
    var serving = try io.concurrent(serve, .{ server, &done });

    var futures: [num_conns]@TypeOf(io.concurrent(clientOnce, .{ io, allocator, server_id }) catch unreachable) = undefined;
    var started: usize = 0;
    var first_err: ?anyerror = null;
    while (started < num_conns) : (started += 1) {
        futures[started] = io.concurrent(clientOnce, .{ io, allocator, server_id }) catch |err| {
            first_err = err;
            break;
        };
    }
    for (futures[0..started]) |*f| {
        if (f.await(io)) |_| {} else |err| {
            if (first_err == null) first_err = err;
            std.debug.print("iroh-loop: a client failed: {s}\n", .{@errorName(err)});
        }
    }
    done.store(true, .release);
    const served = serving.await(io);
    if (first_err) |err| return err;
    try served;

    std.debug.print(
        "iroh-loop: OK, {d} concurrent iroh connections, {d} calls each, served from one Server thread\n",
        .{ num_conns, calls_per_conn },
    );
}
