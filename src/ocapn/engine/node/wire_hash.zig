//! The per-session wire-hash multipliers one `Node` hands its sessions
//! (ADR-0037): a root derived from the node's identity seed, mixed with each
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

/// The multiplier of the Node's own tables keyed by a peer's wire positions
/// (the promise-proxy topology): the root under a second domain, so no
/// session's multiplier is also the Node's.
pub fn nodeMultiplier(root_secret: u64) u64 {
    var out: [8]u8 = undefined;
    var hasher = std.crypto.hash.Blake3.initKdf("glowcap node table hash v1", .{});
    hasher.update(std.mem.asBytes(&root_secret));
    hasher.final(&out);
    return foundation.identity_hash.multiplierFromSeed(std.mem.readInt(u64, &out, .little));
}

/// One session's multiplier: the root mixed with the peer handle.
pub fn multiplier(root_secret: u64, peer_handle: u64) u64 {
    const root = foundation.identity_hash.multiplierFromSeed(root_secret);
    return foundation.identity_hash.multiplierFromSeed(foundation.identity_hash.wireHash(peer_handle, root));
}

/// The bearer secret for a byte-named table kept outside any session (the
/// Host's publications): the root under its own domain, so no session's word
/// is also the owner's.
pub fn hostBearerSecret(root_secret: u64) u64 {
    var out: [8]u8 = undefined;
    var hasher = std.crypto.hash.Blake3.initKdf("glowcap host publication hash v1", .{});
    hasher.update(std.mem.asBytes(&root_secret));
    hasher.final(&out);
    return std.mem.readInt(u64, &out, .little);
}

/// One session's bearer secret, the word its byte-named tables (swissnums,
/// gift ids, cached sturdyrefs) hash under: the root and the peer handle
/// under a third domain, so a peer that learned the position multiplier
/// through its own tables' buckets has learned nothing about this word.
pub fn bearerSecret(root_secret: u64, peer_handle: u64) u64 {
    var out: [8]u8 = undefined;
    var hasher = std.crypto.hash.Blake3.initKdf("glowcap bearer table hash v1", .{});
    hasher.update(std.mem.asBytes(&root_secret));
    hasher.update(std.mem.asBytes(&peer_handle));
    hasher.final(&out);
    return std.mem.readInt(u64, &out, .little);
}
