//! Scenario traces compared against the oracle.
//!
//! Each test drives a whole CapTP conversation through the `oracle` layer and
//! asserts the observable trace it produces. The authority here is the oracle's
//! canonical trace, so a failure points at a behavior change in the session or
//! engine, not at a codec or a transport. The cross-codec and cross-entry-point
//! cases assert that the same conversation produces the same trace regardless of
//! which codec carried it or which inbound entry point dispatched it.

const std = @import("std");
const oracle = @import("oracle");

test "stage0 abort scenario matches oracle trace" {
    const allocator = std.testing.allocator;
    const expected = @embedFile("stage0_abort.trace");

    const actual = try oracle.runStage0Abort(allocator);
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(expected, actual);
}

test "driven runner transfers outbound frame between peers" {
    const allocator = std.testing.allocator;

    const actual = try oracle.runDrivenAbort(allocator);
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(
        "scenario=driven_abort\np1=sent:abort\np2=event:abort:bye\np2=session:closed\n\n",
        actual,
    );
}

test "driven deliver/resolve round-trips a question across paired peers" {
    const allocator = std.testing.allocator;

    const actual = try oracle.runDrivenDeliverResolve(allocator, .syrup);
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(
        "scenario=driven_deliver_resolve\n" ++
            "p1=sent:deliver:answer=42\n" ++
            "p2=event:deliver\n" ++
            "p2=sent:resolve:answer=42\n" ++
            "p1=event:resolve:answer=42:fulfill=pong\n\n",
        actual,
    );
}

test "handshake then bootstrap-fetch auto-serves the registered cap" {
    const allocator = std.testing.allocator;

    const actual = try oracle.runHandshakeThenBootstrapFetch(allocator, .syrup);
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(
        "scenario=handshake_bootstrap_fetch\n" ++
            "p2=registered:swissnum=thermostat:export=1\n" ++
            "p1=sent:fetch\n" ++
            "p2=event:deliver\n" ++
            "p2=auto:resolved\n" ++
            "p1=fulfilled:import=1\n\n",
        actual,
    );
}

// Cross-codec semantic parity, a feature in one codec without the other is
// incomplete: a scenario driven over Syrup and over Cap'n Proto must produce
// byte-identical semantic traces. The session state machine is codec-neutral; the codec only decides
// wire bytes, so the observable trace cannot depend on which codec carried it.
test "driven listen/resolve fires the registered listener across paired peers" {
    const allocator = std.testing.allocator;

    const actual = try oracle.runDrivenListenResolve(allocator, .syrup);
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(
        "scenario=driven_listen_resolve\n" ++
            "p1=sent:deliver:answer=42\n" ++
            "p2=event:deliver\n" ++
            "p1=sent:listen:answer=42\n" ++
            "p2=event:listen\n" ++
            "p2=sent:resolve:answer=42\n" ++
            "p1=event:resolve\n" ++
            "p1=event:deliver:listener=9:fulfill=ok\n\n",
        actual,
    );
}

test "deliver/resolve trace is identical on Syrup and Cap'n Proto" {
    const allocator = std.testing.allocator;

    const syrup = try oracle.runDrivenDeliverResolve(allocator, .syrup);
    defer allocator.free(syrup);
    const capnp = try oracle.runDrivenDeliverResolve(allocator, .capnp);
    defer allocator.free(capnp);

    try std.testing.expectEqualStrings(syrup, capnp);
}

test "listen/resolve trace is identical on Syrup and Cap'n Proto" {
    const allocator = std.testing.allocator;

    const syrup = try oracle.runDrivenListenResolve(allocator, .syrup);
    defer allocator.free(syrup);
    const capnp = try oracle.runDrivenListenResolve(allocator, .capnp);
    defer allocator.free(capnp);

    try std.testing.expectEqualStrings(syrup, capnp);
}

test "bootstrap-fetch trace is identical on Syrup and Cap'n Proto" {
    const allocator = std.testing.allocator;

    const syrup = try oracle.runHandshakeThenBootstrapFetch(allocator, .syrup);
    defer allocator.free(syrup);
    const capnp = try oracle.runHandshakeThenBootstrapFetch(allocator, .capnp);
    defer allocator.free(capnp);

    try std.testing.expectEqualStrings(syrup, capnp);
}

test "inbound dispatch is identical across the borrowed and owned entry points" {
    const allocator = std.testing.allocator;

    // Both inbound entries converge on one dispatcher, so the same frame must
    // produce byte-identical observable output (events, outbound, session
    // state) regardless of which entry carried it.
    const borrowed = try oracle.runInboundMode(allocator, .borrowed);
    defer allocator.free(borrowed);
    const owned = try oracle.runInboundMode(allocator, .owned);
    defer allocator.free(owned);

    try std.testing.expectEqualStrings(borrowed, owned);

    // Pin the shape too: a malformed frame is rejected, the abort projection
    // emits exactly one outbound op:abort, and the session closes.
    try std.testing.expect(std.mem.indexOf(u8, borrowed, "dispatch_error=MalformedFrame\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, borrowed, "events=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, borrowed, "outbound_frames=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, borrowed, "session_closed=true\n") != null);
}
