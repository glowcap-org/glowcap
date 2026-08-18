//! Live real-internet iroh reachability (Milestone 1): two pancake peers
//! reach each other by node id ALONE over n0's public relay and DNS/pkarr
//! discovery with no direct-address hints and no in-process address book.
//!
//! Both endpoints bind with the `.discovery` posture (`presets::N0`: the
//! number-0 relays plus DNS/pkarr discovery). The server publishes its node
//! info to pkarr on bind; the client dials the server by its 64-hex node id with
//! an empty hint set, so a session that opens proves the dial was resolved over
//! real discovery infrastructure and carried over a real relay / hole-punched
//! path, not hinted and not loopback-booked. It is the live counterpart of the
//! deterministic `local_discovery` dial-by-id run in `iroh-interop`.
//!
//! Scoped to the `.discovery` posture deliberately: `.discovery_no_relay`
//! (DNS/pkarr with no relay fallback) needs the node to own a publishable,
//! reachable direct address, which a NAT'd host or container does not have, so
//! its dial-by-id is unreachable there and cannot be a portable build check. The
//! `connect(locator)` dialers still settle/retry under `.discovery_no_relay` on the
//! same propagation principle (it resolves by id); only a *live build check* for
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
//! two networks; run this driver's two halves on separate machines to exercise
//! that seam. The single-process form proves everything reachable from one host.

const std = @import("std");
const pancake = @import("pancake");
const iroh = @import("iroh");
const harness = @import("interop_harness");

const model = pancake.ocapn.model;
const driver = pancake.driver;
const net = pancake.net;

const frame_cap: usize = 4096;
const greeting = "hello over the public internet";

/// The published actor: answers `greet` with a static greeting.
const Greeter = harness.StaticReplyActor("greet", greeting);

/// Server half: accept one partner discovered over the public network signing
/// with `secret` — the endpoint's own key, so the dialing client's identity pin
/// verifies the node id it dialed — publish the greeter, serve until the
/// client hangs up.
const hostOnce = harness.AcceptServeOne(
    Greeter,
    "greeter",
    frame_cap,
    "iroh-reachability: server accepted a discovered partner and opened the keyed session",
).run;

/// How long to let the server's pkarr record propagate to the n0 DNS resolver
/// before the first dial, and the bounded retry budget afterward. Publish
/// visibility over real discovery infrastructure is seconds-scale and variable,
/// which is exactly why this step is opt-in and never part of the in-tree check.
const publish_settle_ms: u64 = 8_000;
// Discovery dial budget: lockstep with `driver.DialRetry` / ADR-0082
// (`PANCAKE_DISCOVERY_DIAL_*`). Was 5s×12; unified to the binding budget.
// Attempt/backoff values are read from `pancake.driver.discovery_*` inside
// `callByIdOnlyRetrying` so this file cannot drift from the policy owner.

/// Dial by id alone, retrying while discovery has not yet resolved the partner.
/// Only a dial-stage `ConnectionLost` (the sidecar's "no addressing information"
/// while the publish propagates) is retried; a post-dial fault is a real
/// failure and surfaces immediately.
fn callByIdOnlyRetrying(
    io: std.Io,
    netlayers: []const net.netlayer.Netlayer,
    server_id: []const u8,
    allocator: std.mem.Allocator,
) !void {
    // Continuity policy is `driver.DialRetry` / `isTransientDialError`
    // (ADR-0082). This harness owns `std.Io` sleep, so it applies the same
    // classifier inline rather than remapping CapTP faults (e.g. WrongReply)
    // onto DialError.
    const max = pancake.driver.discovery_max_attempts;
    const retry_ms = pancake.driver.discovery_retry_ms;
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        if (callByIdOnly(netlayers, server_id, allocator)) |_| {
            return;
        } else |err| {
            const transient = switch (err) {
                error.InvalidAddress => pancake.driver.isTransientDialError(error.InvalidAddress),
                error.ConnectionRefused => pancake.driver.isTransientDialError(error.ConnectionRefused),
                error.NetworkUnreachable => pancake.driver.isTransientDialError(error.NetworkUnreachable),
                error.TimedOut => pancake.driver.isTransientDialError(error.TimedOut),
                error.ConnectionLost => pancake.driver.isTransientDialError(error.ConnectionLost),
                error.OutOfMemory => pancake.driver.isTransientDialError(error.OutOfMemory),
                else => false,
            };
            if (!transient or attempt >= max) return err;
            std.debug.print("iroh-reachability: dial attempt {d} not yet resolvable ({s}); retrying after publish propagates\n", .{ attempt, @errorName(err) });
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(retry_ms), .real) catch {};
        }
    }
}

/// Client half: dial the server by node id ALONE — empty hint set — over real
/// n0 discovery, then fetch and call the greeter so the discovered session is
/// proven to carry real traffic.
fn callByIdOnly(
    netlayers: []const net.netlayer.Netlayer,
    server_id: []const u8,
    allocator: std.mem.Allocator,
) !void {
    var scaffold = try harness.PeerScaffold.init(allocator, frame_cap);
    defer scaffold.deinit();

    const locator: model.PeerLocator = .{
        .transport = iroh.transport_name,
        .designator = server_id,
        .hints = model.Hints.emptyFalse(),
    };
    var cv = try driver.connectVia(allocator, netlayers, &scaffold.peer, locator, .ephemeral, scaffold.read_buf, scaffold.write_buf, .{
        .handshake = .unbounded,
        .settle = .unbounded,
    });
    defer cv.deinit();
    std.debug.print("iroh-reachability: client dialed by node id alone and opened the keyed session\n", .{});

    const greeter = try cv.fetch("greeter");
    try harness.expectStringReply(&cv, allocator, greeter, "greet", &.{.{ .string = "world" }}, greeting);
    std.debug.print("iroh-reachability: client called greet over the discovered session and the reply matched\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A fresh random seed per run (never a fixed one — the node id is
    // published to public pkarr), shared between the endpoint and the accept
    // signing key so the session key equals the node id the client dials —
    // which the client's dial-side identity pin now verifies.
    var server_seed: [32]u8 = undefined;
    io.randomSecure(&server_seed) catch |err| {
        std.debug.print("iroh-reachability: drawing the server seed failed: {s}\n", .{@errorName(err)});
        return err;
    };
    const server_secret = pancake.foundation.crypto.SecretKey.fromSeed(server_seed);
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

    const server_entries = [_]net.netlayer.Netlayer{server.netlayer()};
    const client_entries = [_]net.netlayer.Netlayer{client.netlayer()};

    var listen_result = switch (net.netlayer.resolve(&server_entries, iroh.transport_name).?.listen(allocator, .{
        .designator = "",
    })) {
        .admitted => |result| result,
        .failed => |failure| return failure.cause,
    };
    var listener = switch (listen_result.requireReady()) {
        .ready => |listener| listener,
        .failed => |failure| return failure.cause,
    };
    defer std.debug.assert(listener.close() == null);

    var host_future = try io.concurrent(hostOnce, .{ listener, allocator, server_secret });
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(publish_settle_ms), .real) catch {};
    const client_result = callByIdOnlyRetrying(io, &client_entries, server_id, allocator);
    if (client_result) |_| {} else |err| {
        std.debug.print("iroh-reachability: client failed: {s}\n", .{@errorName(err)});
        server.close();
    }
    const host_result = host_future.await(io);

    try client_result;
    try host_result;

    std.debug.print("iroh-reachability: OK, two pancake peers reached each other by node id alone over n0 relays + DNS/pkarr discovery, no direct-address hints\n", .{});
}
