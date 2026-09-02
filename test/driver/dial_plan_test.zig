//! `driver_core.planDial` / `planAccept`: the pure transport dispatch,
//! designator validation, host:port resolution, and reachability decision the
//! bindings share. Every arm is covered here so a binding that routes through
//! the planner inherits proven behavior, and the borrow contract (plan views
//! alias the caller's input) is pinned so the collapse stays zero-copy.

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const transport = glowcap.ocapn.model.transport;

const planDial = driver.core.planDial;
const planDialProfile = driver.core.planDialProfile;
const planAccept = driver.core.planAccept;
const Shape = driver.core.DialShape;

// A canonical 64-hex Ed25519 key designator, the keyed-tcp / iroh designator.
const key_designator = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

test "planDial tcp: designator is the host:port" {
    const plan = try planDial(transport.tcp, "127.0.0.1:9000", "", .redeem);
    try std.testing.expectEqual(Shape.host_port, std.meta.activeTag(plan));
    try std.testing.expectEqualStrings("127.0.0.1", plan.host_port.host);
    try std.testing.expectEqual(@as(u16, 9000), plan.host_port.port);
}

test "provider profile plans an extension without a first-party symbol branch" {
    const plan = try planDialProfile(.{
        .symbol = "private-noise-stream",
        .designator_scheme = .key,
        .address_source = .direct_addresses_hint,
        .dial_shape = .host_port,
        .sealed_channel = true,
    }, key_designator, "10.0.0.8:4040", .redeem);
    try std.testing.expectEqual(Shape.host_port, std.meta.activeTag(plan));
    try std.testing.expectEqualStrings("10.0.0.8", plan.host_port.host);
    try std.testing.expectEqual(@as(u16, 4040), plan.host_port.port);
}

test "planDial tcp: bracketed IPv6 designator keeps its address" {
    const plan = try planDial(transport.tcp, "[::1]:9000", "", .redeem);
    try std.testing.expectEqualStrings("::1", plan.host_port.host);
    try std.testing.expectEqual(@as(u16, 9000), plan.host_port.port);
}

test "planDial tcp: a non-host:port designator is a typed refusal" {
    try std.testing.expectError(error.DesignatorNotHostPort, planDial(transport.tcp, key_designator, "", .redeem));
}

test "planDial keyed-tcp: host:port rides the hint, the key stays the designator" {
    const hint = "10.0.0.5:8000";
    const plan = try planDial(transport.keyed_tcp, key_designator, hint, .redeem);
    try std.testing.expectEqual(Shape.host_port, std.meta.activeTag(plan));
    try std.testing.expectEqualStrings("10.0.0.5", plan.host_port.host);
    try std.testing.expectEqual(@as(u16, 8000), plan.host_port.port);
    // Borrow contract: the resolved host aliases the caller's hint buffer, no copy.
    try std.testing.expect(plan.host_port.host.ptr == hint.ptr);
}

test "planDial keyed-tcp: a multi-address hint dials the first entry, trimmed" {
    const plan = try planDial(transport.keyed_tcp, key_designator, "10.0.0.1:1 , 10.0.0.2:2", .redeem);
    try std.testing.expectEqualStrings("10.0.0.1", plan.host_port.host);
    try std.testing.expectEqual(@as(u16, 1), plan.host_port.port);
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

test "planDial keyed-tcp: a non-key designator is DesignatorNotPeerKey before host:port" {
    try std.testing.expectError(error.DesignatorNotPeerKey, planDial(transport.keyed_tcp, "127.0.0.1:9000", "10.0.0.5:8000", .redeem));
}

test "planDial iroh: a non-key designator is DesignatorNotPeerKey" {
    try std.testing.expectError(error.DesignatorNotPeerKey, planDial(transport.iroh, "not-a-node-id", "", .{ .explicit = 1 }));
}

test "planDial iroh redeem: a hint takes the relay-less direct posture" {
    const hint = "1.2.3.4:5,6.7.8.9:10";
    const plan = try planDial(transport.iroh, key_designator, hint, .redeem);
    try std.testing.expectEqual(Shape.peer_id, std.meta.activeTag(plan));
    try std.testing.expectEqualStrings(hint, plan.peer_id.addresses);
    try std.testing.expect(plan.peer_id.addresses.ptr == hint.ptr); // verbatim, no copy
    try std.testing.expect(plan.peer_id.reach == .direct);
}

test "planDial iroh redeem: no hint takes the node's configured posture" {
    const plan = try planDial(transport.iroh, key_designator, "", .redeem);
    try std.testing.expectEqual(Shape.peer_id, std.meta.activeTag(plan));
    try std.testing.expect(plan.peer_id.reach == .configured);
}

test "planDial iroh connect: the caller's posture is used verbatim" {
    const plan = try planDial(transport.iroh, key_designator, "", .{ .explicit = 2 });
    try std.testing.expect(plan.peer_id.reach == .explicit);
    try std.testing.expectEqual(@as(u32, 2), plan.peer_id.reach.explicit);
}

test "planDial iroh connect: no posture is ReachabilityRequired" {
    try std.testing.expectError(error.ReachabilityRequired, planDial(transport.iroh, key_designator, "", .explicit_none));
}

test "planDial: an unknown transport is a typed refusal" {
    try std.testing.expectError(error.UnknownTransport, planDial("x-made-up", "whatever", "", .redeem));
    try std.testing.expectError(error.UnknownTransport, planDial(transport.inproc, "token", "", .redeem));
    try std.testing.expectError(error.UnknownTransport, planDial(transport.id, key_designator, "", .redeem));
}

test "planAccept tcp: signs the accepted address, no hint" {
    const plan = planAccept(.address, "", "127.0.0.1:5000");
    try std.testing.expectEqualStrings("127.0.0.1:5000", plan.designator);
    try std.testing.expectEqualStrings("", plan.direct_addresses_hint);
}

test "planAccept tcp: an absent accepted address signs the unreachable-client placeholder" {
    const plan = planAccept(.address, "", "");
    try std.testing.expectEqualStrings(driver.core.unreachable_client_designator, plan.designator);
    try std.testing.expectEqualStrings("", plan.direct_addresses_hint);
}

test "planAccept keyed-tcp: signs the server key, the accepted address is the hint" {
    const plan = planAccept(.key, key_designator, "127.0.0.1:6000");
    try std.testing.expectEqualStrings(key_designator, plan.designator);
    try std.testing.expectEqualStrings("127.0.0.1:6000", plan.direct_addresses_hint);
}

test "planAccept iroh: signs the node id and publishes the endpoint's direct addresses" {
    // A key designator says who this peer is, not where. A third party handed
    // this locator in a handoff has never spoken to the peer and still has to
    // dial it, so an accept publishes the addresses it knows. This is the arm
    // that used to drop them, leaving a give nobody could dial without a relay.
    const plan = planAccept(.key, key_designator, "127.0.0.1:7000,[::1]:7001");
    try std.testing.expectEqualStrings(key_designator, plan.designator);
    try std.testing.expectEqualStrings("127.0.0.1:7000,[::1]:7001", plan.direct_addresses_hint);
}

test "planAccept iroh: an endpoint with no addresses yet publishes none" {
    // Not a refusal: iroh is peer-id addressed, so an
    // empty hint is a dial that falls back to discovery rather than one that
    // cannot happen.
    const plan = planAccept(.key, key_designator, "");
    try std.testing.expectEqualStrings(key_designator, plan.designator);
    try std.testing.expectEqualStrings("", plan.direct_addresses_hint);
}

test "planDial webrtc: a key designator produces a signaling plan" {
    const plan = try planDial(transport.webrtc, key_designator, "", .redeem);
    try std.testing.expectEqual(Shape.signaling, std.meta.activeTag(plan));
}

test "planDial webrtc: ignores the direct-addresses hint" {
    const plan = try planDial(transport.webrtc, key_designator, "1.2.3.4:5", .redeem);
    try std.testing.expectEqual(Shape.signaling, std.meta.activeTag(plan));
}

test "planDial webrtc: ignores posture (webrtc has no reachability knob)" {
    const plan = try planDial(transport.webrtc, key_designator, "", .{ .explicit = 3 });
    try std.testing.expectEqual(Shape.signaling, std.meta.activeTag(plan));
}

test "planDial webrtc: a non-key designator is DesignatorNotPeerKey" {
    try std.testing.expectError(error.DesignatorNotPeerKey, planDial(transport.webrtc, "not-a-key", "", .redeem));
}

test "planDial keyed-relay: a key designator produces a rendezvous plan" {
    const plan = try planDial(transport.keyed_relay, key_designator, "", .redeem);
    try std.testing.expectEqual(Shape.rendezvous, std.meta.activeTag(plan));
}

test "planDial keyed-relay: ignores posture and hint (the relay mapping is host state)" {
    const plan = try planDial(transport.keyed_relay, key_designator, "1.2.3.4:5", .{ .explicit = 3 });
    try std.testing.expectEqual(Shape.rendezvous, std.meta.activeTag(plan));
}

test "planDial noise-relay: shares rendezvous shape and validates the responder key" {
    const plan = try planDial(transport.noise_relay, key_designator, "", .redeem);
    try std.testing.expect(plan == .rendezvous);
    try std.testing.expectError(
        error.DesignatorNotPeerKey,
        planDial(transport.noise_relay, "not-a-key", "", .redeem),
    );
}

test "planDial keyed-relay: a non-key designator is DesignatorNotPeerKey" {
    try std.testing.expectError(error.DesignatorNotPeerKey, planDial(transport.keyed_relay, "not-a-key", "", .redeem));
}

test "planAccept webrtc: signs the server key, and its netlayer offers no address to publish" {
    // Empty because a `webrtc` peer is reached through a signaling exchange and
    // has no dialable address to give (ADR-0089), and its resident reports
    // exactly that. The planner does not filter by transport: it publishes whatever
    // the netlayer — or, on the byte-fed path, the embedder that owns the
    // transport — said this side is reachable at. Which hints a locator carries
    // is the netlayer's business, so a second table here could only drift from
    // the vtable that produces the value.
    const plan = planAccept(.key, key_designator, "");
    try std.testing.expectEqualStrings(key_designator, plan.designator);
    try std.testing.expectEqualStrings("", plan.direct_addresses_hint);
}
