//! C projection of the shared transport dial planner.

const std = @import("std");
const c = @import("c_abi");
const cd = @import("c_abi_host");

const harness = @import("harness.zig");
const expectOk = harness.expectOk;
const key64 = harness.key_designator;

fn planDialC(
    transport: []const u8,
    designator: []const u8,
    hint: []const u8,
    policy: u32,
    posture_value: u32,
    out: *cd.PancakeDialPlan,
) i32 {
    return cd.pancake_host_plan_dial(
        transport.ptr,
        transport.len,
        designator.ptr,
        designator.len,
        if (hint.len == 0) null else hint.ptr,
        hint.len,
        policy,
        posture_value,
        out,
    );
}

test "plan_dial C: tcp resolves the designator to host:port" {
    var plan: cd.PancakeDialPlan = undefined;
    try expectOk(planDialC("tcp", "127.0.0.1:9000", "", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_SHAPE_HOST_PORT, plan.shape);
    try std.testing.expectEqualStrings("127.0.0.1", plan.host.?[0..plan.host_len]);
    try std.testing.expectEqual(@as(u16, 9000), plan.port);
}

test "plan_dial C: keyed-tcp resolves host:port off the hint, no hint is a typed refusal" {
    var plan: cd.PancakeDialPlan = undefined;
    try expectOk(planDialC("keyed-tcp", key64, "10.0.0.5:8000", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_SHAPE_HOST_PORT, plan.shape);
    try std.testing.expectEqualStrings("10.0.0.5", plan.host.?[0..plan.host_len]);
    try std.testing.expectEqual(@as(u16, 8000), plan.port);
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, planDialC("keyed-tcp", key64, "", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
}

test "plan_dial C: iroh redeem picks direct with a hint, configured without" {
    var plan: cd.PancakeDialPlan = undefined;
    try expectOk(planDialC("iroh", key64, "1.2.3.4:5", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_SHAPE_PEER_ID, plan.shape);
    try std.testing.expectEqual(cd.PANCAKE_DIAL_REACH_DIRECT, plan.reach_kind);
    try std.testing.expectEqualStrings("1.2.3.4:5", plan.addresses.?[0..plan.addresses_len]);
    try expectOk(planDialC("iroh", key64, "", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_REACH_CONFIGURED, plan.reach_kind);
}

test "plan_dial C: keyed-relay resolves to the rendezvous shape" {
    var plan: cd.PancakeDialPlan = undefined;
    try expectOk(planDialC("keyed-relay", key64, "", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_SHAPE_RENDEZVOUS, plan.shape);
}

test "plan_dial C: iroh connect carries the explicit posture, none is a typed refusal" {
    var plan: cd.PancakeDialPlan = undefined;
    try expectOk(planDialC("iroh", key64, "", cd.PANCAKE_DIAL_POSTURE_EXPLICIT, 2, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_REACH_EXPLICIT, plan.reach_kind);
    try std.testing.expectEqual(@as(u32, 2), plan.reach_value);
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, planDialC("iroh", key64, "", cd.PANCAKE_DIAL_POSTURE_EXPLICIT_NONE, 0, &plan));
}

test "plan_dial C: an unknown transport is a typed refusal" {
    var plan: cd.PancakeDialPlan = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, planDialC("x-nope", "whatever", "", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
}

test "plan_dial C: webrtc produces a signaling shape with any posture" {
    var plan: cd.PancakeDialPlan = undefined;
    try expectOk(planDialC("webrtc", key64, "", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_SHAPE_SIGNALING, plan.shape);
}

test "plan_dial C: webrtc ignores a direct-addresses hint" {
    var plan: cd.PancakeDialPlan = undefined;
    try expectOk(planDialC("webrtc", key64, "1.2.3.4:5", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_SHAPE_SIGNALING, plan.shape);
}

test "plan_dial C: webrtc non-key designator is a typed refusal" {
    var plan: cd.PancakeDialPlan = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, planDialC("webrtc", "not-a-key", "", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
}
