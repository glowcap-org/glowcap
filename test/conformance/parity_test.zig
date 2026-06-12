const std = @import("std");
const conformance = @import("conformance");

test "stage0 abort scenario matches oracle trace" {
    const allocator = std.testing.allocator;
    const expected = @embedFile("../oracles/stage0_abort.trace");

    const actual = try conformance.runStage0Abort(allocator);
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(expected, actual);
}

test "driven runner transfers outbound frame between peers" {
    const allocator = std.testing.allocator;

    const actual = try conformance.runDrivenAbort(allocator);
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(
        "scenario=driven_abort\np1=sent:abort\np2=event:abort:bye\np2=session:closed\n\n",
        actual,
    );
}

test "driven deliver/resolve round-trips a question across paired peers" {
    const allocator = std.testing.allocator;

    const actual = try conformance.runDrivenDeliverResolve(allocator, .syrup);
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

    const actual = try conformance.runHandshakeThenBootstrapFetch(allocator, .syrup);
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

// Cross-codec semantic parity — a feature in one codec without the other is
// incomplete: a scenario driven over Syrup and over Cap'n Proto must produce
// byte-identical semantic traces. The session state machine is codec-neutral; the codec only decides
// wire bytes, so the observable trace cannot depend on which codec carried it.
test "deliver/resolve trace is identical on Syrup and Cap'n Proto" {
    const allocator = std.testing.allocator;

    const syrup = try conformance.runDrivenDeliverResolve(allocator, .syrup);
    defer allocator.free(syrup);
    const capnp = try conformance.runDrivenDeliverResolve(allocator, .capnp);
    defer allocator.free(capnp);

    try std.testing.expectEqualStrings(syrup, capnp);
}

test "bootstrap-fetch trace is identical on Syrup and Cap'n Proto" {
    const allocator = std.testing.allocator;

    const syrup = try conformance.runHandshakeThenBootstrapFetch(allocator, .syrup);
    defer allocator.free(syrup);
    const capnp = try conformance.runHandshakeThenBootstrapFetch(allocator, .capnp);
    defer allocator.free(capnp);

    try std.testing.expectEqualStrings(syrup, capnp);
}

test "inbound dispatch is identical across the borrowed and owned entry points" {
    const allocator = std.testing.allocator;

    // Both inbound entries converge on one dispatcher, so the same frame must
    // produce byte-identical observable output (events, outbound, session
    // state) regardless of which entry carried it.
    const borrowed = try conformance.runInboundMode(allocator, .borrowed);
    defer allocator.free(borrowed);
    const owned = try conformance.runInboundMode(allocator, .owned);
    defer allocator.free(owned);

    try std.testing.expectEqualStrings(borrowed, owned);

    // Pin the shape too: a malformed frame is rejected, the abort projection
    // emits exactly one outbound op:abort, and the session closes.
    try std.testing.expect(std.mem.indexOf(u8, borrowed, "dispatch_error=MalformedFrame\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, borrowed, "events=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, borrowed, "outbound_frames=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, borrowed, "session_closed=true\n") != null);
}
