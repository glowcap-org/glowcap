//! Host identity designator and advertised-locator projection for the C ABI.
//!
//! The core Host owns its acceptable locations. This leaf admits borrowed C
//! locator views, transfers their owned form into that Host, and exposes the
//! pure durable-seed helper used to construct keyed locator designators. status-allow: purpose clause

const foundation = @import("foundation");
const model = @import("model");

const shared = @import("c_abi_shared");
const c = @import("mod.zig");
const common = @import("common.zig");

/// Derive the canonical key designator (exactly 64 lowercase hex digits) from
/// a 32-byte Ed25519 durable-identity seed, the public half represented by
/// the first half of `glowcap_host_new`'s 64-byte input. Session signing keys
/// derive from that input's fresh second half instead. Writes 64 bytes into
/// `out` (`out_len` must be at least 64). A keyed-tcp listener uses this so its
/// locator designator names the Host's durable identity (ADR-0028).
pub fn glowcap_host_designator_from_seed(
    seed: ?[*]const u8,
    seed_len: usize,
    out: ?[*]u8,
    out_len: usize,
) callconv(.c) i32 {
    shared.lastErrorClear();
    if (seed_len != foundation.crypto.seed_bytes) {
        shared.setLastError("host: designator_from_seed: seed_len must be 32", .{});
        return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    const seed_bytes = shared.sliceFromC(seed, seed_len) catch |err| return shared.marshalErrorToCode(err);
    const out_buf = out orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    if (out_len < foundation.crypto.PeerKey.designator_len) {
        shared.setLastError("host: designator_from_seed: out_len must be at least 64", .{});
        return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    var seed_arr: [foundation.crypto.seed_bytes]u8 = undefined;
    @memcpy(&seed_arr, seed_bytes);
    const designator = foundation.crypto.SecretKey.fromSeed(seed_arr).publicKey().toDesignator();
    @memcpy(out_buf[0..designator.len], &designator);
    return shared.GLOWCAP_OK;
}

/// Retain and select this host's complete acceptable location. The Host
/// validates and deep-copies the borrowed locator view before returning.
pub fn glowcap_host_set_advertised_locator(host: ?*c.GlowcapHost, locator: ?*const shared.GlowcapLocatorView) callconv(.c) i32 {
    shared.lastErrorClear();
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "set_advertised_locator")) return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    const view = locator orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    var hint_stack: [shared.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
    var borrowed = shared.locator_adapter.BorrowedLocator.init(inst.allocator, view, &hint_stack) catch |err| {
        if (err == error.OutOfMemory) return common.errToCode(err);
        shared.setLastError("host: set_advertised_locator received an invalid locator view", .{});
        return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    };
    defer borrowed.deinit(inst.allocator);
    inst.core.setAdvertisedLocator(borrowed.value) catch |err| return common.errToCode(err);
    return shared.GLOWCAP_OK;
}

/// Retain the deterministic dial fallback for `transport` without displacing
/// an acceptable location already selected for another transport.
pub fn glowcap_host_ensure_advertised_locator(host: ?*c.GlowcapHost, transport: ?[*]const u8, transport_len: usize) callconv(.c) i32 {
    shared.lastErrorClear();
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "ensure_advertised_locator")) return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    const bytes = shared.sliceFromC(transport, transport_len) catch |err| return shared.marshalErrorToCode(err);
    inst.core.ensureAdvertisedLocator(bytes) catch |err| return common.errToCode(err);
    return shared.GLOWCAP_OK;
}

/// Remove the retained locator for `transport`. Removing the selected route
/// leaves no acceptable location. Existing sessions retain their signed hello.
pub fn glowcap_host_remove_advertised_locator(host: ?*c.GlowcapHost, transport: ?[*]const u8, transport_len: usize) callconv(.c) i32 {
    shared.lastErrorClear();
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "remove_advertised_locator")) return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    const bytes = shared.sliceFromC(transport, transport_len) catch |err| return shared.marshalErrorToCode(err);
    inst.core.removeAdvertisedLocator(bytes) catch |err| return common.errToCode(err);
    return shared.GLOWCAP_OK;
}
