//! Host action projection and completion acknowledgements for the C ABI.
//!
//! The Host owns the queue and all transaction semantics. This leaf turns one
//! borrowed action into its C carrier and sends embedder acknowledgements back
//! to that same owner; it introduces no scheduling or policy.
//! A pop is consume-on-success: allocator refusal leaves the action and the
//! preceding borrowed projection intact. Embedders drain through WOULD_BLOCK;
//! ignoring a returned action intentionally leaves its dial, flush, handoff,
//! or settlement consequence unsettled.

const shared = @import("c_abi_shared");
const model = @import("model");
const c = @import("mod.zig");
const common = @import("common.zig");

pub fn resolverFulfill(
    host: ?*c.GlowcapHost,
    resolver_id: u64,
    value: ?*const shared.GlowcapArgument,
) i32 {
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const c_value = value orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const converted = common.plainArgumentFromC(inst, c_value.*) catch |err|
        return common.errToCode(err);
    inst.core.resolverFulfill(resolver_id, converted) catch |err| return common.errToCode(err);
    return shared.GLOWCAP_OK;
}

pub fn resolverBreak(
    host: ?*c.GlowcapHost,
    resolver_id: u64,
    message: ?[*]const u8,
    message_len: usize,
) i32 {
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const reason = shared.sliceFromC(message, message_len) catch |err|
        return shared.marshalErrorToCode(err);
    inst.core.resolverBreak(resolver_id, reason) catch |err| return common.errToCode(err);
    return shared.GLOWCAP_OK;
}

pub fn enliven(
    host: ?*c.GlowcapHost,
    sturdyref_uri: ?[*]const u8,
    sturdyref_uri_len: usize,
    out_vow: ?*u64,
) i32 {
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const slot = out_vow orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const uri = shared.sliceFromC(sturdyref_uri, sturdyref_uri_len) catch |err|
        return shared.marshalErrorToCode(err);
    slot.* = inst.core.enlivenUri(uri) catch |err| return common.errToCode(err);
    return shared.GLOWCAP_OK;
}

pub fn enlivenForVersion(
    host: ?*c.GlowcapHost,
    captp_version: u32,
    sturdyref_uri: ?[*]const u8,
    sturdyref_uri_len: usize,
    out_vow: ?*u64,
) i32 {
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const version = shared.captpVersionFromC(captp_version) orelse {
        shared.setLastError("host: enliven captp_version must be a GLOWCAP_CAPTP_* value", .{});
        return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    };
    const slot = out_vow orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const uri = shared.sliceFromC(sturdyref_uri, sturdyref_uri_len) catch |err|
        return shared.marshalErrorToCode(err);
    slot.* = inst.core.enlivenUriForVersion(version, uri) catch |err| return common.errToCode(err);
    return shared.GLOWCAP_OK;
}

pub fn fetchAt(
    host: ?*c.GlowcapHost,
    locator_view: ?*const shared.GlowcapLocatorView,
    name: ?[*]const u8,
    name_len: usize,
    out_vow: ?*u64,
) i32 {
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const view = locator_view orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const slot = out_vow orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const swiss = shared.sliceFromC(name, name_len) catch |err|
        return shared.marshalErrorToCode(err);
    var hint_stack: [shared.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
    var locator = shared.locator_adapter.BorrowedLocator.init(inst.allocator, view, &hint_stack) catch |err| {
        if (err == error.OutOfMemory) return common.errToCode(err);
        shared.setLastError("host: fetch_at received an invalid locator view", .{});
        return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    };
    defer locator.deinit(inst.allocator);
    slot.* = inst.core.enlivenSelectOrDial(.{
        .peer = locator.value,
        .swissnum = swiss,
    }) catch |err| return common.errToCode(err);
    return shared.GLOWCAP_OK;
}

pub fn next(host: ?*c.GlowcapHost, out_action: ?*c.GlowcapHostAction) i32 {
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "next_action")) return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    const slot = out_action orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    // A refused core pop leaves the preceding action and all of its borrowed C
    // views intact. Reset projection scratch only after the pop commits.
    var popped = inst.core.nextAction() catch |err| return common.errToCode(err);
    _ = inst.completion_scratch.reset(.{ .retain_with_limit = common.steady_scratch_bytes });
    while (popped) |action| : (popped = inst.core.nextAction() catch |err| return common.errToCode(err)) {
        switch (action) {
            .dial => |dial| {
                slot.* = common.zero_action;
                slot.kind = c.GLOWCAP_HOST_ACTION_DIAL;
                slot.ticket = dial.ticket;
                slot.route_index = dial.route_index;
                return shared.GLOWCAP_OK;
            },
            .cancel_dial => |dial| {
                slot.* = common.zero_action;
                slot.kind = c.GLOWCAP_HOST_ACTION_CANCEL_DIAL;
                slot.ticket = dial.ticket;
                slot.route_index = dial.route_index;
                return shared.GLOWCAP_OK;
            },
            .flush => |peer_handle| {
                const session = inst.core.sessionForPeer(peer_handle) orelse continue;
                slot.* = common.zero_action;
                slot.kind = c.GLOWCAP_HOST_ACTION_FLUSH;
                slot.session = @ptrCast(session);
                return shared.GLOWCAP_OK;
            },
            .close => |peer_handle| {
                const session = inst.core.sessionForPeer(peer_handle) orelse continue;
                slot.* = common.zero_action;
                slot.kind = c.GLOWCAP_HOST_ACTION_CLOSE;
                slot.session = @ptrCast(session);
                if (inst.core.sessionCloseOutcome(session, true) == .timed_out)
                    slot.result = shared.GLOWCAP_ERR_TIMEOUT;
                return shared.GLOWCAP_OK;
            },
            .resume_work => {
                slot.* = common.zero_action;
                slot.kind = c.GLOWCAP_HOST_ACTION_RESUME;
                return shared.GLOWCAP_OK;
            },
            .need_gift_id => |request| {
                slot.* = common.zero_action;
                slot.kind = c.GLOWCAP_HOST_ACTION_NEED_GIFT_ID;
                slot.ticket = request.ticket;
                return shared.GLOWCAP_OK;
            },
            .settled, .failed => return common.projectCompletionInto(inst, action, slot),
        }
    }
    return shared.GLOWCAP_ERR_WOULD_BLOCK;
}

pub fn retryBorrowed(host: ?*c.GlowcapHost) bool {
    const inst = common.instanceFrom(host) orelse return false;
    return inst.core.retryBorrowedAction();
}

pub fn dialed(
    host: ?*c.GlowcapHost,
    ticket: u64,
    route_index: usize,
    raw: ?*c.GlowcapHostSession,
    out_adopted: ?*u8,
) i32 {
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const adopted_slot = out_adopted orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    adopted_slot.* = 0;
    if (!common.embedderOwnsDrive(inst, "dialed")) return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    const session = common.sessionFrom(raw) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    if (common.instOf(session.host) != inst) {
        shared.setLastError("host: dialed: session belongs to another host", .{});
        return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    const adopted = inst.core.exporterDialed(ticket, route_index, session) catch |err| return common.errToCode(err);
    adopted_slot.* = @intFromBool(adopted);
    return shared.GLOWCAP_OK;
}

pub fn dialFailed(
    host: ?*c.GlowcapHost,
    ticket: u64,
    route_index: usize,
    reason: ?[*]const u8,
    reason_len: usize,
) i32 {
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "dial_failed")) return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    const reason_bytes = shared.sliceFromC(reason, reason_len) catch |err|
        return shared.marshalErrorToCode(err);
    inst.core.dialFailed(ticket, route_index, reason_bytes) catch |err| return common.errToCode(err);
    return shared.GLOWCAP_OK;
}

pub fn dialCancelled(host: ?*c.GlowcapHost, ticket: u64, route_index: usize) i32 {
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "dial_cancelled")) return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    inst.core.dialCancelled(ticket, route_index) catch |err| return common.errToCode(err);
    return shared.GLOWCAP_OK;
}

pub fn provideGiftId(
    host: ?*c.GlowcapHost,
    ticket: u64,
    gift_id: ?[*]const u8,
    gift_id_len: usize,
) i32 {
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "provide_gift_id")) return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    const bytes = shared.sliceFromC(gift_id, gift_id_len) catch |err|
        return shared.marshalErrorToCode(err);
    inst.core.provideGiftId(ticket, bytes) catch |err| return common.errToCode(err);
    return shared.GLOWCAP_OK;
}

pub fn giftIdFailed(host: ?*c.GlowcapHost, ticket: u64) i32 {
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "gift_id_failed")) return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    inst.core.giftIdFailed(ticket) catch |err| return common.errToCode(err);
    return shared.GLOWCAP_OK;
}
