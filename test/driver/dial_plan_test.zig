//! `driver_core.planDial` / `planAccept`: the pure transport dispatch,
//! designator validation, host:port resolution, and reachability decision the
//! bindings share. Every arm is covered here so a binding that routes through
//! the planner inherits proven behavior, and the borrow contract (plan views
//! alias the caller's input) is pinned so the collapse stays zero-copy.

const std = @import("std");
const pancake = @import("pancake");

const driver = pancake.driver;
const transport = pancake.ocapn.model.transport;

const planDial = driver.core.planDial;
const planAccept = driver.core.planAccept;
const Posture = driver.core.DialPosture;
const Shape = driver.core.DialShape;

// A canonical 64-hex Ed25519 key designator, the keyed-tcp / iroh designator.
const key_designator = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

test "planDial tcp: designator is the host:port" {
    const plan = try planDial(transport.tcp, "127.0.0.1:9000", "", .redeem);
    try std.testing.expectEqual(Shape.host_port, plan.shape);
    try std.testing.expectEqualStrings("127.0.0.1", plan.host);
    try std.testing.expectEqual(@as(u16, 9000), plan.port);
    try std.testing.expect(plan.reach == null);
}

test "planDial tcp: bracketed IPv6 designator keeps its address" {
    const plan = try planDial(transport.tcp, "[::1]:9000", "", .redeem);
    try std.testing.expectEqualStrings("::1", plan.host);
    try std.testing.expectEqual(@as(u16, 9000), plan.port);
}

test "planDial tcp: a non-host:port designator is a typed refusal" {
    try std.testing.expectError(error.DesignatorNotHostPort, planDial(transport.tcp, key_designator, "", .redeem));
}

test "planDial keyed-tcp: host:port rides the hint, the key stays the designator" {
    const hint = "10.0.0.5:8000";
    const plan = try planDial(transport.keyed_tcp, key_designator, hint, .redeem);
    try std.testing.expectEqual(Shape.host_port, plan.shape);
    try std.testing.expectEqualStrings("10.0.0.5", plan.host);
    try std.testing.expectEqual(@as(u16, 8000), plan.port);
    try std.testing.expectEqualStrings(key_designator, plan.designator);
    // Borrow contract: the resolved host aliases the caller's hint buffer, no copy.
    try std.testing.expect(plan.host.ptr == hint.ptr);
}

test "planDial keyed-tcp: a multi-address hint dials the first entry, trimmed" {
    const plan = try planDial(transport.keyed_tcp, key_designator, "10.0.0.1:1 , 10.0.0.2:2", .redeem);
    try std.testing.expectEqualStrings("10.0.0.1", plan.host);
    try std.testing.expectEqual(@as(u16, 1), plan.port);
}

test "planDial keyed-tcp: no hint is MissingDirectAddressesHint" {
    try std.testing.expectError(error.MissingDirectAddressesHint, planDial(transport.keyed_tcp, key_designator, "", .redeem));
}

test "planDial keyed-tcp: a hint that is only separators is MissingDirectAddressesHint" {
    try std.testing.expectError(error.MissingDirectAddressesHint, planDial(transport.keyed_tcp, key_designator, " ,x", .redeem));
}

test "planDial keyed-tcp: a first entry that is not host:port is DesignatorNotHostPort" {
    try std.testing.expectError(error.DesignatorNotHostPort, planDial(transport.keyed_tcp, key_designator, "notanaddress", .redeem));
}

test "planDial iroh redeem: a hint takes the relay-less direct posture" {
    const hint = "1.2.3.4:5,6.7.8.9:10";
    const plan = try planDial(transport.iroh, key_designator, hint, .redeem);
    try std.testing.expectEqual(Shape.iroh, plan.shape);
    try std.testing.expectEqualStrings(key_designator, plan.designator);
    try std.testing.expectEqualStrings(hint, plan.addresses);
    try std.testing.expect(plan.addresses.ptr == hint.ptr); // verbatim, no copy
    try std.testing.expect(plan.reach.? == .direct);
}

test "planDial iroh redeem: no hint takes the node's configured posture" {
    const plan = try planDial(transport.iroh, key_designator, "", .redeem);
    try std.testing.expectEqual(Shape.iroh, plan.shape);
    try std.testing.expect(plan.reach.? == .configured);
}

test "planDial iroh connect: the caller's posture is used verbatim" {
    const plan = try planDial(transport.iroh, key_designator, "", .{ .explicit = 2 });
    try std.testing.expect(plan.reach.? == .explicit);
    try std.testing.expectEqual(@as(u32, 2), plan.reach.?.explicit);
}

test "planDial iroh connect: no posture is ReachabilityRequired" {
    try std.testing.expectError(error.ReachabilityRequired, planDial(transport.iroh, key_designator, "", .{ .explicit = null }));
}

test "planDial: an unknown transport is a typed refusal" {
    try std.testing.expectError(error.UnknownTransport, planDial("x-made-up", "whatever", "", .redeem));
    try std.testing.expectError(error.UnknownTransport, planDial(transport.inproc, "token", "", .redeem));
}

test "planAccept tcp: signs the accepted address, no hint" {
    const plan = planAccept(transport.tcp, "", "127.0.0.1:5000");
    try std.testing.expectEqualStrings("127.0.0.1:5000", plan.designator);
    try std.testing.expectEqualStrings("", plan.direct_addresses_hint);
}

test "planAccept tcp: an absent accepted address signs the unreachable-client placeholder" {
    const plan = planAccept(transport.tcp, "", "");
    try std.testing.expectEqualStrings(driver.core.unreachable_client_designator, plan.designator);
    try std.testing.expectEqualStrings("", plan.direct_addresses_hint);
}

test "planAccept keyed-tcp: signs the server key, the accepted address is the hint" {
    const plan = planAccept(transport.keyed_tcp, key_designator, "127.0.0.1:6000");
    try std.testing.expectEqualStrings(key_designator, plan.designator);
    try std.testing.expectEqualStrings("127.0.0.1:6000", plan.direct_addresses_hint);
}

test "planAccept iroh: signs the node id, carries no hint" {
    const plan = planAccept(transport.iroh, key_designator, "127.0.0.1:7000");
    try std.testing.expectEqualStrings(key_designator, plan.designator);
    try std.testing.expectEqualStrings("", plan.direct_addresses_hint);
}
