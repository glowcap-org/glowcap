//! The per-session wire-hash multipliers one `Node` hands its sessions
//! (ADR-0218): a root derived from the node's identity seed, mixed with each
//! peer handle so what a peer learns about its own tables says nothing about
//! another session's.

const std = @import("std");

const foundation = @import("foundation");
const crypto = foundation.crypto;

/// The root of the wire-hash multipliers, derived from the identity seed
/// under its own domain so neither is recoverable from the other.
pub fn secret(seed: [crypto.seed_bytes]u8) u64 {
    var out: [8]u8 = undefined;
    var hasher = std.crypto.hash.Blake3.initKdf("glowcap wire hash v1", .{});
    hasher.update(&seed);
    hasher.final(&out);
    return std.mem.readInt(u64, &out, .little);
}

/// One session's multiplier: the root mixed with the peer handle.
pub fn multiplier(root_secret: u64, peer_handle: u64) u64 {
    const root = foundation.identity_hash.multiplierFromSeed(root_secret);
    return foundation.identity_hash.multiplierFromSeed(foundation.identity_hash.wireHash(peer_handle, root));
}
