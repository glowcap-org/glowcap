//! Host-wide publication projection for the C ABI Host subject.
//!
//! The core Host owns names and actors. This leaf owns the host-wide publish
//! exports, their C argument admission, and the exactly-once transfer of a
//! foreign behavior context.

const engine = @import("engine");

const shared = @import("c_abi_shared");
const c = @import("mod.zig");
const common = @import("common.zig");

/// Spawn a hosted actor and adopt its first root into an owned Host reference.
/// No session, alias or wire export is created. Release the returned reference
/// through glowcap_host_ref_release. The ctx/free transfer follows publish:
/// null-pointer and reentry refusals leave ctx with the caller. After admission
/// free runs exactly once on failure, final actor collection or Host release.
pub fn glowcap_host_spawn(
    host: ?*c.GlowcapHost,
    behavior: ?c.GlowcapHostBehavior,
    ctx: ?*anyopaque,
    free: ?c.GlowcapHostCtxFree,
    out_ref: ?*shared.GlowcapReference,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const selected = behavior orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const out = out_ref orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    if (common.preflightHostedTransfer(inst)) |code| return code;
    const hosted = common.hostedBridge(inst.allocator, selected, ctx, free) catch |err| return common.errToCode(err);
    const reference = inst.core.spawnHosted(null, hosted) catch |err| return common.errToCode(err);
    out.* = .{ .id = reference.raw() };
    return shared.GLOWCAP_OK;
}

pub fn publish(
    host: ?*c.GlowcapHost,
    name: ?[*]const u8,
    name_len: usize,
    behavior: ?c.GlowcapHostBehavior,
    ctx: ?*anyopaque,
    free: ?c.GlowcapHostCtxFree,
) i32 {
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const selected_behavior = behavior orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const name_bytes = shared.sliceFromC(name, name_len) catch |err|
        return shared.marshalErrorToCode(err);
    if (common.preflightHostedTransfer(inst)) |code| return code;
    const hosted = common.hostedBridge(inst.allocator, selected_behavior, ctx, free) catch |err|
        return common.errToCode(err);
    _ = inst.core.publishHosted(name_bytes, hosted) catch |err|
        return common.errToCode(err);
    return shared.GLOWCAP_OK;
}

pub fn publishDurable(
    host: ?*c.GlowcapHost,
    entropy: ?[*]const u8,
    entropy_len: usize,
    behavior: ?c.GlowcapHostBehavior,
    ctx: ?*anyopaque,
    free: ?c.GlowcapHostCtxFree,
    out_swiss: ?[*]u8,
    swiss_cap: usize,
) i32 {
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const selected_behavior = behavior orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const out = out_swiss orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const entropy_bytes = shared.sliceFromC(entropy, entropy_len) catch |err|
        return shared.marshalErrorToCode(err);
    if (entropy_bytes.len != engine.durable_swiss_entropy_len) {
        shared.setLastError("host: durable entropy must be exactly {d} bytes", .{engine.durable_swiss_entropy_len});
        return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    if (swiss_cap < engine.durable_swiss_len) {
        shared.setLastError("host: durable swiss buffer needs {d} bytes", .{engine.durable_swiss_len});
        return shared.GLOWCAP_ERR_BUFFER_TOO_SMALL;
    }
    if (common.preflightHostedTransfer(inst)) |code| return code;
    const hosted = common.hostedBridge(inst.allocator, selected_behavior, ctx, free) catch |err|
        return common.errToCode(err);
    var entropy_fixed: [engine.durable_swiss_entropy_len]u8 = undefined;
    @memcpy(&entropy_fixed, entropy_bytes);
    const minted = inst.core.publishHostedDurable(entropy_fixed, hosted) catch |err|
        return common.errToCode(err);
    @memcpy(out[0..engine.durable_swiss_len], minted.slice());
    return @intCast(engine.durable_swiss_len);
}

pub fn removeDurable(host: ?*c.GlowcapHost, swiss: ?[*]const u8, swiss_len: usize) i32 {
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const swiss_bytes = shared.sliceFromC(swiss, swiss_len) catch |err|
        return shared.marshalErrorToCode(err);
    inst.core.removeDurable(swiss_bytes) catch |err| return common.errToCode(err);
    return shared.GLOWCAP_OK;
}

pub fn publishReference(
    host: ?*c.GlowcapHost,
    reference: ?*const shared.GlowcapReference,
    entropy: ?[*]const u8,
    entropy_len: usize,
    out_swiss: ?[*]u8,
    swiss_cap: usize,
) i32 {
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const selected = reference orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const out = out_swiss orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const bytes = shared.sliceFromC(entropy, entropy_len) catch |err| return shared.marshalErrorToCode(err);
    if (bytes.len != engine.durable_swiss_entropy_len) return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    if (swiss_cap < engine.durable_swiss_len) return shared.GLOWCAP_ERR_BUFFER_TOO_SMALL;
    var fixed: [engine.durable_swiss_entropy_len]u8 = undefined;
    @memcpy(&fixed, bytes);
    const minted = inst.core.publishDurableCapability(fixed, inst.core.capabilityFromRaw(selected.id)) catch |err|
        return common.errToCode(err);
    @memcpy(out[0..engine.durable_swiss_len], minted.slice());
    return @intCast(engine.durable_swiss_len);
}

pub fn unpublish(host: ?*c.GlowcapHost, name: ?[*]const u8, name_len: usize) i32 {
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const name_bytes = shared.sliceFromC(name, name_len) catch |err|
        return shared.marshalErrorToCode(err);
    inst.core.unpublish(name_bytes) catch |err| return common.errToCode(err);
    return shared.GLOWCAP_OK;
}

/// Publish one hosted object in the Vat owned by this Host and bind `name` as its host-wide
/// alias. Fetch lazily projects the actor onto the requesting Port. A deposited
/// gift retains the exact actor and never consults the alias at withdrawal. The
/// publication row owns `ctx`:
/// `free`, if non-null, runs exactly once: at `glowcap_host_release` on
/// success, or before this returns on any non-OK outcome (except the
/// null-pointer and reentry refusals, which touch nothing and leave ctx the
/// caller's). All-or-nothing over this call's own work: registration failure
/// discards the fresh actor and frees `ctx`, so a retry starts with no partial
/// alias or projection.
pub fn glowcap_host_publish(
    host: ?*c.GlowcapHost,
    name: ?[*]const u8,
    name_len: usize,
    behavior: ?c.GlowcapHostBehavior,
    ctx: ?*anyopaque,
    free: ?c.GlowcapHostCtxFree,
) callconv(.c) i32 {
    shared.lastErrorClear();
    return publish(host, name, name_len, behavior, ctx, free);
}

/// Publish one hosted object under a freshly minted durable swiss name
/// (ADR-0007): the reserved-prefix namespace, unpredictable, never
/// reassigned, removable only through `glowcap_host_remove_durable`, and
/// structurally disjoint from every mutable alias. `entropy` supplies
/// exactly GLOWCAP_HOST_DURABLE_ENTROPY_LEN caller-drawn random bytes: the
/// embedder owns the entropy boundary, as it does for gift ids. The minted
/// swiss (the name to place in a sturdyref beside this host's own locator)
/// is written into `out_swiss`. `swiss_cap` must be at least
/// GLOWCAP_HOST_DURABLE_SWISS_LEN or the call refuses BUFFER_TOO_SMALL and
/// publishes nothing. Returns the written length. `ctx`/`free` follow
/// `glowcap_host_publish`'s ownership exactly.
pub fn glowcap_host_publish_durable(
    host: ?*c.GlowcapHost,
    entropy: ?[*]const u8,
    entropy_len: usize,
    behavior: ?c.GlowcapHostBehavior,
    ctx: ?*anyopaque,
    free: ?c.GlowcapHostCtxFree,
    out_swiss: ?[*]u8,
    swiss_cap: usize,
) callconv(.c) i32 {
    shared.lastErrorClear();
    return publishDurable(
        host,
        entropy,
        entropy_len,
        behavior,
        ctx,
        free,
        out_swiss,
        swiss_cap,
    );
}

/// Publish an already-held local capability under a durable name. The
/// publication retains its own root. The caller's reference stays owned by
/// the caller on success and failure. Entropy and output use the same bounds
/// as glowcap_host_publish_durable. Foreign capabilities are refused.
pub fn glowcap_host_publish_reference(
    host: ?*c.GlowcapHost,
    reference: ?*const shared.GlowcapReference,
    entropy: ?[*]const u8,
    entropy_len: usize,
    out_swiss: ?[*]u8,
    swiss_cap: usize,
) callconv(.c) i32 {
    shared.lastErrorClear();
    return publishReference(host, reference, entropy, entropy_len, out_swiss, swiss_cap);
}

/// Remove a minted durable publication (ADR-0007): the sturdyref misses
/// afterward, while capabilities already issued and deposited gifts keep
/// the exact actor. A swiss outside the reserved durable namespace returns
/// GLOWCAP_ERR_INVALID_ARGUMENT (mutable aliases leave through
/// `glowcap_host_unpublish`). An unknown durable name returns
/// GLOWCAP_ERR_NOT_FOUND.
pub fn glowcap_host_remove_durable(
    host: ?*c.GlowcapHost,
    swiss: ?[*]const u8,
    swiss_len: usize,
) callconv(.c) i32 {
    shared.lastErrorClear();
    return removeDurable(host, swiss, swiss_len);
}

/// Remove the host-wide alias `name`. Discovery-only, alias-only (ADR-0026): a
/// later fetch of the name misses on every session, while capabilities already
/// issued, live Port projections, and deposited gifts keep naming the exact
/// actor, which stays in the Host's Vat until `glowcap_host_release`. An
/// absent alias returns GLOWCAP_ERR_NOT_FOUND, so a typo is loud instead of an
/// idempotent no-op.
pub fn glowcap_host_unpublish(
    host: ?*c.GlowcapHost,
    name: ?[*]const u8,
    name_len: usize,
) callconv(.c) i32 {
    shared.lastErrorClear();
    return unpublish(host, name, name_len);
}
