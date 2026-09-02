//! Process-wide opaque capability IDs for pointer-free C projections.
//!
//! `driver_core` owns capability identity and accepts an injected issuer, but
//! synchronization belongs at this process adapter seam. Native Zig refs keep
//! their Registry pointer and do not pay this atomic/permutation cost.

const std = @import("std");
const builtin = @import("builtin");

const foundation = @import("foundation");
const driver_core = @import("driver_core");

const crypto = foundation.crypto;

const first_id: u64 = 1 << 62;
const exhausted_id: u64 = 1 << 63;
var next_id_atomic: std.atomic.Value(u64) = .init(first_id);
var next_id_single: u64 = first_id;
var key_state: std.atomic.Value(u8) = .init(0);
var key_ready_single = false;
var key: [16]u8 = undefined;

pub fn issuer(seed: [crypto.SEED_BYTES]u8) driver_core.CapabilityIdIssuer {
    ensureKey(seed);
    return .{ .next = issue };
}

fn deriveKey(seed: [crypto.SEED_BYTES]u8) [16]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("glowcap opaque capability id permutation\x00");
    hasher.update(&seed);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest[0..16].*;
}

fn ensureKey(seed: [crypto.SEED_BYTES]u8) void {
    if (comptime builtin.single_threaded) {
        if (!key_ready_single) {
            key = deriveKey(seed);
            key_ready_single = true;
        }
        return;
    }

    if (key_state.load(.acquire) == 2) return;
    if (key_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        key = deriveKey(seed);
        key_state.store(2, .release);
        return;
    }
    while (key_state.load(.acquire) != 2) std.atomic.spinLoopHint();
}

fn round(half: u32, index: u8) u32 {
    const SipHash = std.crypto.auth.siphash.SipHash64(2, 4);
    var input: [5]u8 = undefined;
    std.mem.writeInt(u32, input[0..4], half, .little);
    input[4] = index;
    var tag: [SipHash.mac_length]u8 = undefined;
    SipHash.create(&tag, &input, &key);
    return @truncate(std.mem.readInt(u64, &tag, .little));
}

fn permute(value: u64) u64 {
    var left: u32 = @truncate(value >> 32);
    var right: u32 = @truncate(value);
    inline for (0..6) |index| {
        const next = left ^ round(right, index);
        left = right;
        right = next;
    }
    return (@as(u64, left) << 32) | right;
}

fn issue(_: ?*anyopaque) error{CapabilitySpaceExhausted}!u64 {
    if (comptime builtin.single_threaded) {
        if (next_id_single == exhausted_id) return error.CapabilitySpaceExhausted;
        const current = next_id_single;
        next_id_single += 1;
        return permute(current);
    }

    var current = next_id_atomic.load(.monotonic);
    while (current != exhausted_id) {
        if (next_id_atomic.cmpxchgStrong(current, current + 1, .monotonic, .monotonic)) |observed| {
            current = observed;
        } else {
            return permute(current);
        }
    }
    return error.CapabilitySpaceExhausted;
}
