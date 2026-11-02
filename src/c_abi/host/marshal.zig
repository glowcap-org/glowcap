//! The C argument and action layout of the byte-fed host: the owned and plain
//! value decode from C, the Host value projection to C, the settled or failed
//! action shape, `ptr + len` view pairs, and the provenance spelling. Declares
//! no `export fn`.

const std = @import("std");

const driver_core = @import("driver_core");
const model = @import("model");
const shared = @import("c_abi_shared");

const c = @import("mod.zig");
const instance = @import("instance.zig");

pub const zero_action = c.GlowcapHostAction{
    .kind = 0,
    .ticket = 0,
    .route_index = 0,
    .session = null,
    .value = shared.zero_argument,
    .message = null,
    .message_len = 0,
    .result = shared.GLOWCAP_OK,
};

/// Project one settled/failed completion onto the shared C action shape.
/// The caller resets `completion_scratch` once before this operation.
pub fn projectCompletionInto(inst: *instance.Instance, action: driver_core.HostAction, slot: *c.GlowcapHostAction) i32 {
    const projection = inst.core.projectCompletion(
        action,
        inst.completion_scratch.allocator(),
        valueToC,
    );
    slot.* = zero_action;
    switch (projection) {
        .settled => |settled| {
            slot.kind = c.GLOWCAP_HOST_ACTION_SETTLE;
            slot.ticket = settled.vow_id;
            slot.value = settled.value;
        },
        .failed => |failed| {
            slot.kind = c.GLOWCAP_HOST_ACTION_FAIL;
            slot.ticket = failed.vow_id;
            slot.result = switch (failed.failure) {
                .broken => shared.GLOWCAP_ERR_BROKEN,
                .closed => shared.GLOWCAP_ERR_CLOSED,
            };
            if (failed.message.len != 0) slot.message = failed.message.ptr;
            slot.message_len = failed.message.len;
        },
    }
    return shared.GLOWCAP_OK;
}

/// Write a borrowed byte slice into a C `ptr + len` view pair, spelling an
/// empty slice as NULL. Every host view-struct field goes through this, so
/// "empty" has one representation across the archive rather than one per
/// call site.
pub fn setView(slice: []const u8, out_ptr: *?[*]const u8, out_len: *usize) void {
    out_ptr.* = if (slice.len == 0) null else slice.ptr;
    out_len.* = slice.len;
}

pub const ValueMessage = struct {
    verb: ?[]const u8,
    args: []const driver_core.Value,
};

/// Decode one C application message without manufacturing wire references.
/// Capability leaves remain opaque. The core operation routes its target and
/// lowers the complete value tree on the session that will actually carry it.
pub fn valueMessageFromC(
    inst: *instance.Instance,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.GlowcapArgument,
    args_len: usize,
) !ValueMessage {
    const verb_slice = try shared.sliceFromC(verb, verb_len);
    // The scratch is Host state: a caller off the owner thread is refused
    // before the reset, not after the operation it feeds notices.
    try inst.core.claimOwner();
    if (!inst.core.withinCallback())
        _ = inst.arg_scratch.reset(.{ .retain_with_limit = instance.steady_scratch_bytes });
    return .{
        .verb = if (verb != null) verb_slice else null,
        .args = try shared.valuesFromCWith(
            driver_core.Value,
            anyerror,
            inst,
            decodeHostCapability,
            inst.arg_scratch.allocator(),
            args,
            args_len,
            0,
            false,
        ),
    };
}

pub fn decodeHostCapability(inst: *instance.Instance, ref: shared.GlowcapReference) anyerror!driver_core.Capability {
    return inst.core.capabilityFromRaw(ref.id);
}

const HostRefContext = struct {
    inst: *instance.Instance,
    session: *driver_core.HostSession,
};

fn decodeHostReference(ctx: HostRefContext, ref: shared.GlowcapReference) anyerror!model.Reference {
    return ctx.inst.core.lowerCapability(ctx.session, ctx.inst.core.capabilityFromRaw(ref.id));
}

/// The plain-data decode behind a resolver settle (ADR-0014): every
/// reference arm refuses, because the settle carries no session to home a
/// capability. An answer that carries authority takes the turn's
/// forward-to-send path instead.
fn refusePlainReference(ctx: void, ref: shared.GlowcapReference) anyerror!model.Reference {
    _ = ctx;
    _ = ref;
    return driver_core.HostError.ForeignArgument;
}

/// Convert one capability-free C argument for a resolver settle, into the
/// instance's argument scratch (borrowed byte payloads; the vat's settle
/// spine clones what a listener may outlive). Resets the scratch exactly as
/// `valueMessageFromC` does at a top-level call.
pub fn plainArgumentFromC(inst: *instance.Instance, arg: shared.GlowcapArgument) !model.Argument {
    try inst.core.claimOwner();
    if (!inst.core.withinCallback())
        _ = inst.arg_scratch.reset(.{ .retain_with_limit = instance.steady_scratch_bytes });
    return shared.argumentFromCWith(anyerror, {}, refusePlainReference, inst.arg_scratch.allocator(), arg, 0, false);
}

pub fn hostArgumentFromCOwned(
    inst: *instance.Instance,
    session: *driver_core.HostSession,
    arena: std.mem.Allocator,
    arg: shared.GlowcapArgument,
    depth: usize,
) !model.Argument {
    return shared.argumentFromCWith(anyerror, HostRefContext{ .inst = inst, .session = session }, decodeHostReference, arena, arg, depth, true);
}

/// Argument leaves borrow their owner. Every struct value is already counted
/// among values. Its key adds one C slot. Container requests split that total.
pub fn valueProjectionBound(comptime Bound: type, values: usize, entries: usize) !Bound {
    const slots = try std.math.add(usize, values, entries);
    var bound: Bound = .{};
    try bound.includeTotal(try std.math.mul(usize, slots, @sizeOf(shared.GlowcapArgument)), @alignOf(shared.GlowcapArgument), slots);
    return bound;
}

/// The Host's capability leaf on the C argument layout: the opaque id, which
/// the embedder hands back through `decodeHostCapability`.
fn capabilityToC(_: void, capability: driver_core.Capability) error{}!shared.GlowcapReference {
    return .{ .id = capability.raw() };
}

/// Project one Host value onto the C argument layout. Children land in
/// `arena`, and byte leaves are lent from the value where they lie.
pub fn valueToC(arena: std.mem.Allocator, value: driver_core.Value) shared.MarshalError!shared.GlowcapArgument {
    return shared.valueToCWith(driver_core.Value, error{}, {}, capabilityToC, arena, value);
}

pub fn valuesToC(arena: std.mem.Allocator, values: []const driver_core.Value) shared.MarshalError![]shared.GlowcapArgument {
    return shared.valuesToCWith(driver_core.Value, error{}, {}, capabilityToC, arena, values);
}

/// One `DurableProvenance` in its C spelling.
///
/// Two surfaces report this fact (the partner-identity query and the trace's
/// session-open) and they must agree, so the mapping lives here once rather
/// than being spelled at each of them.
pub fn provenanceToC(provenance: driver_core.DurableProvenance) u32 {
    return switch (provenance) {
        .authenticated_transport => c.GLOWCAP_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT,
        .unauthenticated => c.GLOWCAP_DURABLE_PROVENANCE_UNAUTHENTICATED,
    };
}
