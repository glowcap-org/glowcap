//! Live real-internet iroh reachability: two glowcap peers
//! reach each other by node id ALONE over n0's public relay and DNS/pkarr
//! discovery with no direct-address hints and no in-process address book.
//!
//! Both endpoints bind with the `.discovery` posture (`presets::N0`: the
//! number-0 relays plus DNS/pkarr discovery). The server publishes its node
//! info to pkarr on bind. The client dials the server by its 64-hex node id with
//! an empty hint set, so a session that opens proves the dial was resolved over
//! real discovery infrastructure and carried over a real relay / hole-punched
//! path, not hinted and not loopback-booked. It is the live counterpart of the
//! deterministic `local_discovery` dial-by-id run in `iroh-interop`.
//!
//! Scoped to the `.discovery` posture deliberately: `.discovery_no_relay`
//! (DNS/pkarr with no relay fallback) needs the node to own a publishable,
//! reachable direct address, which a NAT'd host or container does not have, so
//! its dial-by-id is unreachable there and cannot be a portable build check. The
//! The runtime's staged dial retries transient faults under `.discovery_no_relay`
//! on the same shared budget (it resolves by id). Only a *live build check* for
//! it is infeasible without a publicly-addressable host.
//!
//! Not part of the in-tree check (needs network). This step touches public n0
//! infrastructure (`*.relay.iroh.network`, `dns.iroh.link`), and discovery-
//! propagation timing makes it unsuitable for `zig build check` or even the
//! deterministic `zig build iroh-interop`. It runs only as the opt-in sibling
//! `zig build iroh-reachability`, the same cargo-linking posture as
//! `iroh-interop`, so it can never make `check` flaky.
//!
//! What this proves. Two endpoints in one process prove the discoverability
//! claim end to end: resolve a peer by id over real DNS/pkarr, then reach it.
//! True cross-NAT hole-punching between two *distinct* NATs needs two hosts on
//! two networks. Run this driver's two halves on separate machines to exercise
//! that seam. The single-process form proves everything reachable from one host.

const std = @import("std");
const glowcap = @import("glowcap");
const iroh = @import("iroh");
const harness = @import("interop_harness");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;

const frame_cap: usize = 4096;
const greeting = "hello over the public internet";

/// Session budgets. Every partner here is this process, so a wait that never
/// ends is a defect in the code under test, and the step's own deadline
/// reports it.
const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .unbounded,
    .settle = .unbounded,
};

/// The published actor: answers `greet` with a static greeting.
const Greeter = harness.StaticReplyBehavior("greet", greeting);

/// Server half: accept one partner discovered over the public network on a
/// server keyed with the endpoint's own secret, so the dialing client's
/// identity pin verifies the node id it dialed, publish the greeter, serve
/// until the client hangs up.
const hostOnce = harness.AcceptServeOne(Greeter, "greeter", "iroh-reachability: server accepted a discovered partner and opened the keyed session").run;

/// How long to let the server's pkarr record propagate to the n0 DNS resolver
/// before the first dial. Publish visibility over real discovery
/// infrastructure is seconds-scale and variable, which is exactly why this
/// step is opt-in and never part of the in-tree check.
const publish_settle_ms: u64 = 8_000;

/// How long the server waits for the client: the runtime's whole dial-retry
/// window (`driver.DialPolicy.discovery()`, the budget the bindings share),
/// with one handshake-sized grace on top of each attempt, so the server never
/// gives up before the client has.
const accept_budget_ms: u64 = publish_settle_ms + @as(u64, glowcap.driver.discovery_max_attempts) * (glowcap.driver.discovery_retry_ms + 10_000);

/// Client half: dial the server by node id ALONE, empty hint set, over real
/// n0 discovery, then fetch and call the greeter so the discovered session is
/// proven to carry real traffic.
fn callByIdOnly(
    io: std.Io,
    allocator: std.mem.Allocator,
    providers: []const driver.HostRuntime.ProviderRegistration,
    server_id: []const u8,
) !void {
    const locator: model.PeerLocator = .{
        .transport = iroh.transport_name,
        .designator = server_id,
        .hints = model.Hints.emptyFalse(),
    };
    const session = try driver.connect(allocator, io, .{ .residents = providers }, locator, .ephemeral, opts);
    defer session.deinit();
    std.debug.print("iroh-reachability: client dialed by node id alone and opened the keyed session\n", .{});

    const greeter = try session.fetch("greeter");
    try harness.expectStringReply(session, allocator, greeter, "greet", &.{.{ .string = "world" }}, greeting);
    std.debug.print("iroh-reachability: client called greet over the discovered session and the reply matched\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A fresh random seed per run (never a fixed one, the node id is
    // published to public pkarr), shared between the endpoint and the accept
    // signing key so the session key equals the node id the client dials,
    // which the client's dial-side identity pin verifies.
    var server_seed: [32]u8 = undefined;
    io.randomSecure(&server_seed) catch |err| {
        std.debug.print("iroh-reachability: drawing the server seed failed: {s}\n", .{@errorName(err)});
        return err;
    };
    const server_secret = glowcap.foundation.crypto.SecretKey.fromSeed(server_seed);
    var server = iroh.Resident.init(io, &server_seed, .{ .reachability = .discovery }) catch |err| {
        std.debug.print("iroh-reachability: server endpoint bind failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer server.deinit() catch |err| std.log.err("iroh server teardown failed: {s}", .{@errorName(err)});
    var client = iroh.Resident.init(io, null, .{ .reachability = .discovery }) catch |err| {
        std.debug.print("iroh-reachability: client endpoint bind failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer client.deinit() catch |err| std.log.err("iroh client teardown failed: {s}", .{@errorName(err)});

    var id_buf: [iroh.node_id_len]u8 = undefined;
    const server_id = server.nodeId(&id_buf);
    std.debug.print("iroh-reachability: server endpoint id {s} (published to pkarr; no direct addrs shared)\n", .{server_id});

    // Each endpoint's adapter borrows it and outlives the runtime built over it.
    var server_adapter = try iroh.MultiplexedAdapter.init(allocator, &server);
    defer if (server_adapter.deinit()) |failure| std.log.err("iroh server adapter: {s}", .{failure.primaryName()});
    var client_adapter = try iroh.MultiplexedAdapter.init(allocator, &client);
    defer if (client_adapter.deinit()) |failure| std.log.err("iroh client adapter: {s}", .{failure.primaryName()});
    const server_providers = [_]driver.HostRuntime.ProviderRegistration{.{ .profile = iroh.transport_profile, .resident = server_adapter.multiplexed() }};
    const client_providers = [_]driver.HostRuntime.ProviderRegistration{.{ .profile = iroh.transport_profile, .resident = client_adapter.multiplexed() }};

    const listener = try driver.listen(allocator, io, .{ .residents = &server_providers }, iroh.transport_name, .{ .designator = "" }, .{ .keyed = server_secret }, opts);
    defer listener.deinit();

    var host_future = try io.concurrent(hostOnce, .{ io, listener, accept_budget_ms });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(publish_settle_ms), .real);
    const client_result = callByIdOnly(io, allocator, &client_providers, server_id);
    if (client_result) |_| {} else |err| {
        std.debug.print("iroh-reachability: client failed: {s}\n", .{@errorName(err)});
        server.close();
    }
    const host_result = host_future.await(io);

    try client_result;
    try host_result;

    std.debug.print("iroh-reachability: OK, two glowcap peers reached each other by node id alone over n0 relays + DNS/pkarr discovery, no direct-address hints\n", .{});
}
