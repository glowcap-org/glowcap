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
const c = @import("mod.zig");
const common = @import("common.zig");

pub fn resolverFulfill(
    host: ?*c.PancakeHost,
    resolver_id: u64,
    value: ?*const shared.PancakeArgument,
) i32 {
    const inst = common.instanceFrom(host) orelse return shared.PANCAKE_ERR_NULL_POINTER;
    const c_value = value orelse return shared.PANCAKE_ERR_NULL_POINTER;
    const converted = common.plainArgumentFromC(inst, c_value.*) catch |err|
        return common.errToCode(err);
    inst.core.resolverFulfill(resolver_id, converted) catch |err| return common.errToCode(err);
    return shared.PANCAKE_OK;
}

pub fn resolverBreak(
    host: ?*c.PancakeHost,
    resolver_id: u64,
    message: ?[*]const u8,
    message_len: usize,
) i32 {
    const inst = common.instanceFrom(host) orelse return shared.PANCAKE_ERR_NULL_POINTER;
    const reason = shared.sliceFromC(message, message_len) catch |err|
        return shared.marshalErrorToCode(err);
    inst.core.resolverBreak(resolver_id, reason) catch |err| return common.errToCode(err);
    return shared.PANCAKE_OK;
}

pub fn enliven(
    host: ?*c.PancakeHost,
    sturdyref_uri: ?[*]const u8,
    sturdyref_uri_len: usize,
    out_vow: ?*u64,
) i32 {
    const inst = common.instanceFrom(host) orelse return shared.PANCAKE_ERR_NULL_POINTER;
    const slot = out_vow orelse return shared.PANCAKE_ERR_NULL_POINTER;
    const uri = shared.sliceFromC(sturdyref_uri, sturdyref_uri_len) catch |err|
        return shared.marshalErrorToCode(err);
    slot.* = inst.core.enlivenUri(uri) catch |err| return common.errToCode(err);
    return shared.PANCAKE_OK;
}

pub fn next(host: ?*c.PancakeHost, out_action: ?*c.PancakeHostAction) i32 {
    const inst = common.instanceFrom(host) orelse return shared.PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "next_action")) return shared.PANCAKE_ERR_INVALID_ARGUMENT;
    const slot = out_action orelse return shared.PANCAKE_ERR_NULL_POINTER;
    // A refused core pop leaves the preceding action and all of its borrowed C
    // views intact. Reset projection scratch only after the pop commits.
    var popped = inst.core.nextAction() catch |err| return common.errToCode(err);
    _ = inst.completion_scratch.reset(.{ .retain_with_limit = common.steady_scratch_bytes });
    while (popped) |action| : (popped = inst.core.nextAction() catch |err| return common.errToCode(err)) {
        switch (action) {
            .dial => |dial| {
                slot.* = common.zero_action;
                slot.kind = c.PANCAKE_HOST_ACTION_DIAL;
                slot.ticket = dial.ticket;
                return shared.PANCAKE_OK;
            },
            .cancel_dial => |dial| {
                slot.* = common.zero_action;
                slot.kind = c.PANCAKE_HOST_ACTION_CANCEL_DIAL;
                slot.ticket = dial.ticket;
                return shared.PANCAKE_OK;
            },
            .flush => |peer_handle| {
                const session = inst.core.sessionForPeer(peer_handle) orelse continue;
                slot.* = common.zero_action;
                slot.kind = c.PANCAKE_HOST_ACTION_FLUSH;
                slot.session = @ptrCast(session);
                return shared.PANCAKE_OK;
            },
            .close => |peer_handle| {
                const session = inst.core.sessionForPeer(peer_handle) orelse continue;
                slot.* = common.zero_action;
                slot.kind = c.PANCAKE_HOST_ACTION_CLOSE;
                slot.session = @ptrCast(session);
                if (inst.core.sessionCloseOutcome(session, true) == .timed_out)
                    slot.result = shared.PANCAKE_ERR_TIMEOUT;
                return shared.PANCAKE_OK;
            },
            .resume_work => {
                slot.* = common.zero_action;
                slot.kind = c.PANCAKE_HOST_ACTION_RESUME;
                return shared.PANCAKE_OK;
            },
            .need_gift_id => |request| {
                slot.* = common.zero_action;
                slot.kind = c.PANCAKE_HOST_ACTION_NEED_GIFT_ID;
                slot.ticket = request.ticket;
                return shared.PANCAKE_OK;
            },
            .settled, .failed => return common.projectCompletionInto(inst, action, slot),
        }
    }
    return shared.PANCAKE_ERR_WOULD_BLOCK;
}

pub fn retryBorrowed(host: ?*c.PancakeHost) bool {
    const inst = common.instanceFrom(host) orelse return false;
    return inst.core.retryBorrowedAction();
}

pub fn dialed(host: ?*c.PancakeHost, ticket: u64, raw: ?*c.PancakeHostSession) i32 {
    const inst = common.instanceFrom(host) orelse return shared.PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "dialed")) return shared.PANCAKE_ERR_INVALID_ARGUMENT;
    const session = common.sessionFrom(raw) orelse return shared.PANCAKE_ERR_NULL_POINTER;
    if (common.instOf(session.host) != inst) {
        shared.setLastError("host: dialed: session belongs to another host", .{});
        return shared.PANCAKE_ERR_INVALID_ARGUMENT;
    }
    inst.core.exporterDialed(ticket, session) catch |err| return common.errToCode(err);
    return shared.PANCAKE_OK;
}

pub fn dialFailed(
    host: ?*c.PancakeHost,
    ticket: u64,
    reason: ?[*]const u8,
    reason_len: usize,
) i32 {
    const inst = common.instanceFrom(host) orelse return shared.PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "dial_failed")) return shared.PANCAKE_ERR_INVALID_ARGUMENT;
    const reason_bytes = shared.sliceFromC(reason, reason_len) catch |err|
        return shared.marshalErrorToCode(err);
    inst.core.dialFailed(ticket, reason_bytes) catch |err| return common.errToCode(err);
    return shared.PANCAKE_OK;
}

pub fn dialCancelled(host: ?*c.PancakeHost, ticket: u64) i32 {
    const inst = common.instanceFrom(host) orelse return shared.PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "dial_cancelled")) return shared.PANCAKE_ERR_INVALID_ARGUMENT;
    inst.core.dialCancelled(ticket) catch |err| return common.errToCode(err);
    return shared.PANCAKE_OK;
}

pub fn provideGiftId(
    host: ?*c.PancakeHost,
    ticket: u64,
    gift_id: ?[*]const u8,
    gift_id_len: usize,
) i32 {
    const inst = common.instanceFrom(host) orelse return shared.PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "provide_gift_id")) return shared.PANCAKE_ERR_INVALID_ARGUMENT;
    const bytes = shared.sliceFromC(gift_id, gift_id_len) catch |err|
        return shared.marshalErrorToCode(err);
    inst.core.provideGiftId(ticket, bytes) catch |err| return common.errToCode(err);
    return shared.PANCAKE_OK;
}

pub fn giftIdFailed(host: ?*c.PancakeHost, ticket: u64) i32 {
    const inst = common.instanceFrom(host) orelse return shared.PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "gift_id_failed")) return shared.PANCAKE_ERR_INVALID_ARGUMENT;
    inst.core.giftIdFailed(ticket) catch |err| return common.errToCode(err);
    return shared.PANCAKE_OK;
}
