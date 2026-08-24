//! Pure dial planning and Host-owned dial lookup for the C ABI Host subject.
//!
//! Bindings ask this one Zig authority which byte connector to use; this leaf
//! only projects borrowed plans and capability homing facts into C views.

const driver_core = @import("driver_core");

const shared = @import("c_abi_shared");
const c = @import("mod.zig");
const common = @import("common.zig");

pub fn pendingDial(
    host: ?*c.PancakeHost,
    ticket: u64,
    route_index: usize,
    hint_storage: ?[*]c.PancakeLocatorHintView,
    hint_capacity: usize,
    out_locator: ?*c.PancakeLocatorView,
    out_hint_count: ?*usize,
) i32 {
    const inst = common.instanceFrom(host) orelse return shared.PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "pending_dial")) return shared.PANCAKE_ERR_INVALID_ARGUMENT;
    const locator_slot = out_locator orelse return shared.PANCAKE_ERR_NULL_POINTER;
    const count_slot = out_hint_count orelse return shared.PANCAKE_ERR_NULL_POINTER;
    const view = inst.core.pendingDial(ticket, route_index) orelse {
        shared.setLastError("host: pending dial: unknown ticket {d} route {d}", .{ ticket, route_index });
        return shared.PANCAKE_ERR_INVALID_ARGUMENT;
    };
    count_slot.* = view.locator.hints.entries.len;
    if (hint_capacity < view.locator.hints.entries.len) return shared.PANCAKE_ERR_BUFFER_TOO_SMALL;
    if (view.locator.hints.entries.len == 0) {
        var no_hints: [0]c.PancakeLocatorHintView = .{};
        locator_slot.* = shared.locator_adapter.project(view.locator, &no_hints) catch
            return shared.PANCAKE_ERR_INVALID_ARGUMENT;
    } else {
        const hints = (hint_storage orelse return shared.PANCAKE_ERR_NULL_POINTER)[0..view.locator.hints.entries.len];
        locator_slot.* = shared.locator_adapter.project(view.locator, hints) catch
            return shared.PANCAKE_ERR_INVALID_ARGUMENT;
    }
    return shared.PANCAKE_OK;
}

pub fn referenceExporter(
    host: ?*c.PancakeHost,
    reference: ?*const shared.PancakeReference,
    out_session: ?*?*c.PancakeHostSession,
) i32 {
    const inst = common.instanceFrom(host) orelse return shared.PANCAKE_ERR_NULL_POINTER;
    const slot = out_session orelse return shared.PANCAKE_ERR_NULL_POINTER;
    const ref_ptr = reference orelse return shared.PANCAKE_ERR_NULL_POINTER;
    const ref = inst.core.capabilityFromRaw(ref_ptr.id);
    slot.* = if (inst.core.capabilitySession(ref)) |session| @ptrCast(session) else null;
    return shared.PANCAKE_OK;
}

pub fn planDial(
    transport: ?[*]const u8,
    transport_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    direct_addresses_hint: ?[*]const u8,
    direct_addresses_hint_len: usize,
    posture_policy: u32,
    posture_value: u32,
    out_plan: ?*c.PancakeDialPlan,
) i32 {
    const slot = out_plan orelse return shared.PANCAKE_ERR_NULL_POINTER;
    const selected_transport = shared.sliceFromC(transport, transport_len) catch |err|
        return shared.marshalErrorToCode(err);
    const selected_designator = shared.sliceFromC(designator, designator_len) catch |err|
        return shared.marshalErrorToCode(err);
    const direct_addresses = shared.sliceFromC(direct_addresses_hint, direct_addresses_hint_len) catch |err|
        return shared.marshalErrorToCode(err);
    const posture: driver_core.DialPosture = switch (posture_policy) {
        c.PANCAKE_DIAL_POSTURE_REDEEM => .redeem,
        c.PANCAKE_DIAL_POSTURE_EXPLICIT => .{ .explicit = posture_value },
        c.PANCAKE_DIAL_POSTURE_EXPLICIT_NONE => .explicit_none,
        else => {
            shared.setLastError("host: plan_dial: unknown posture policy {d}", .{posture_policy});
            return shared.PANCAKE_ERR_INVALID_ARGUMENT;
        },
    };
    const plan = driver_core.planDial(
        selected_transport,
        selected_designator,
        direct_addresses,
        posture,
    ) catch |err| return common.errToCode(err);
    slot.reach_value = 0;
    switch (plan) {
        .host_port => |host_port| {
            slot.shape = c.PANCAKE_DIAL_SHAPE_HOST_PORT;
            common.setView(host_port.host, &slot.host, &slot.host_len);
            slot.port = host_port.port;
            common.setView(&.{}, &slot.addresses, &slot.addresses_len);
            slot.reach_kind = c.PANCAKE_DIAL_REACH_DIRECT;
        },
        .peer_id => |peer| {
            slot.shape = c.PANCAKE_DIAL_SHAPE_PEER_ID;
            common.setView(&.{}, &slot.host, &slot.host_len);
            slot.port = 0;
            common.setView(peer.addresses, &slot.addresses, &slot.addresses_len);
            slot.reach_kind = switch (peer.reach) {
                .direct => c.PANCAKE_DIAL_REACH_DIRECT,
                .configured => c.PANCAKE_DIAL_REACH_CONFIGURED,
                .explicit => |value| blk: {
                    slot.reach_value = value;
                    break :blk c.PANCAKE_DIAL_REACH_EXPLICIT;
                },
            };
        },
        .signaling => {
            slot.shape = c.PANCAKE_DIAL_SHAPE_SIGNALING;
            common.setView(&.{}, &slot.host, &slot.host_len);
            slot.port = 0;
            common.setView(&.{}, &slot.addresses, &slot.addresses_len);
            slot.reach_kind = c.PANCAKE_DIAL_REACH_DIRECT;
        },
        .rendezvous => {
            slot.shape = c.PANCAKE_DIAL_SHAPE_RENDEZVOUS;
            common.setView(&.{}, &slot.host, &slot.host_len);
            slot.port = 0;
            common.setView(&.{}, &slot.addresses, &slot.addresses_len);
            slot.reach_kind = c.PANCAKE_DIAL_REACH_DIRECT;
        },
    }
    return shared.PANCAKE_OK;
}
