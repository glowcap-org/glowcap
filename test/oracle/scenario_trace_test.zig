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

test "driven projections resolve the projected answers when each source settles" {
    const allocator = std.testing.allocator;

    const actual = try oracle.runDrivenProjections(allocator, .syrup);
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(
        "scenario=driven_projections\n" ++
            "p1=sent:deliver:answer=11\n" ++
            "p2=event:deliver\n" ++
            "p1=sent:deliver:answer=21\n" ++
            "p2=event:deliver\n" ++
            "p1=sent:deliver:answer=31\n" ++
            "p2=event:deliver\n" ++
            // Each projection send also carries the engine-synthesized
            // `op:listen` on the projected answer (ADR-0007), so the
            // settlement can ride back as a V1.0 resolver callback.
            "p1=sent:get\n" ++
            "p2=event:get\n" ++
            "p2=event:listen\n" ++
            "p1=sent:index\n" ++
            "p2=event:index\n" ++
            "p2=event:listen\n" ++
            "p1=sent:untag\n" ++
            "p2=event:untag\n" ++
            "p2=event:listen\n" ++
            "p2=sent:resolve:answer=11\n" ++
            "p1=event:resolve:answer=11:fulfill=struct\n" ++
            "p1=event:resolve:answer=12:fulfill=tabby\n" ++
            "p2=sent:resolve:answer=21\n" ++
            "p1=event:resolve:answer=21:fulfill=list\n" ++
            "p1=event:resolve:answer=22:fulfill=one\n" ++
            "p2=sent:resolve:answer=31\n" ++
            "p1=event:resolve:answer=31:fulfill=tagged\n" ++
            "p1=event:resolve:answer=32:fulfill=5\n\n",
        actual,
    );
}

test "driven gc releases the export and the answer across paired peers" {
    const allocator = std.testing.allocator;

    const actual = try oracle.runDrivenGcPair(allocator, .syrup);
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(
        "scenario=driven_gc\n" ++
            "p1=sent:deliver:answer=21\n" ++
            "p2=event:deliver\n" ++
            "p1=sent:gc_export:position=3:delta=1\n" ++
            "p2=event:gc_export\n" ++
            // The partner's gc releases only its wire holds: the exporter's
            // baseline floats, so the row lives until the local release.
            "p2=export3_refs=1:live=true\n" ++
            "p2=released:baseline:export3_live=false\n" ++
            "p1=sent:gc_answer:position=21\n" ++
            "p2=event:gc_answer\n" ++
            "p2=answer21_live=false\n\n",
        actual,
    );
}

test "driven handoff parks the early withdraw, settles it on deposit, and the redeemed cap answers directly" {
    const allocator = std.testing.allocator;

    const actual = try oracle.runDrivenHandoff(allocator, .syrup);
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(
        "scenario=driven_handoff\n" ++
            "exporter=registered:swissnum=thermostat:gifter_session=84776744564817920\n" ++
            "gifter=sent:fetch\n" ++
            "exporter=event:deliver\n" ++
            "gifter=fetched:thermostat:import=84776744564817920\n" ++
            "recipient=sent:deliver:answer=42\n" ++
            "gifter=event:deliver\n" ++
            "gifter=sent:deposit_gift\n" ++
            "gifter=sent:resolve_give:answer=42\n" ++
            "recipient=event:resolve:answer=42:fulfill=handoff\n" ++
            "recipient=sent:withdraw_gift:answer=1\n" ++
            "exporter=event:deliver\n" ++
            // The withdraw outran its deposit (they travel on different
            // sessions), so the exporter parks it rather than refusing — the
            // arrival-order contract the upstream OCapN suite pins.
            "exporter=withdraw_parked=1:gift_live=false\n" ++
            "exporter=event:deliver\n" ++
            "exporter=deposit_recorded:gift_live=true\n" ++
            // Settling consumes the gift row; replay stays blocked by the
            // monotonic handoff count, not a retained row.
            "exporter=withdraw_settled:parked=0:gift_live=false\n" ++
            "recipient=event:resolve:answer=1:fulfill=import=84776744581595136\n" ++
            "recipient=sent:deliver:answer=2:direct\n" ++
            "exporter=event:deliver\n" ++
            "exporter=sent:resolve:answer=2\n" ++
            "recipient=event:resolve:answer=2:fulfill=72F\n\n",
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

test "projections trace is identical on Syrup and Cap'n Proto" {
    const allocator = std.testing.allocator;

    const syrup = try oracle.runDrivenProjections(allocator, .syrup);
    defer allocator.free(syrup);
    const capnp = try oracle.runDrivenProjections(allocator, .capnp);
    defer allocator.free(capnp);

    try std.testing.expectEqualStrings(syrup, capnp);
}

test "handoff trace is identical on Syrup and Cap'n Proto" {
    const allocator = std.testing.allocator;

    const syrup = try oracle.runDrivenHandoff(allocator, .syrup);
    defer allocator.free(syrup);
    const capnp = try oracle.runDrivenHandoff(allocator, .capnp);
    defer allocator.free(capnp);

    try std.testing.expectEqualStrings(syrup, capnp);
}

test "gc trace is identical on Syrup and Cap'n Proto" {
    const allocator = std.testing.allocator;

    const syrup = try oracle.runDrivenGcPair(allocator, .syrup);
    defer allocator.free(syrup);
    const capnp = try oracle.runDrivenGcPair(allocator, .capnp);
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
