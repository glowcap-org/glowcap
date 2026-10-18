//! The secrets a session shell is minted from: the seed it signs with, the
//! salt its wire-keyed tables hash under, and the seed the sealed channel's
//! Noise ephemeral starts from. Each is derived under its own domain, so
//! none is recoverable from another and no two uses of the root share bytes.
//! Split from `sessions.zig` by subject.

const std = @import("std");
const foundation = @import("foundation");

const host_mod = @import("../host.zig");

const Host = host_mod.Host;
const crypto = foundation.crypto;
const session_seed_domain = host_mod.session_seed_domain;

/// Each call derives a distinct seed from the host's root and a
/// monotonic counter, so two sessions never sign with the same key and a
/// host restarted with a fresh root cannot recreate a prior session's
/// handoff names. The derivation is keyed and domain-separated, so the
/// root is not recoverable from a session key and these bytes cannot
/// collide with another use of the same material.
pub fn nextSessionSeed(self: *Host) [crypto.seed_bytes]u8 {
    self.session_seed_counter += 1;
    var counter_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &counter_bytes, self.session_seed_counter, .little);
    var out: [crypto.seed_bytes]u8 = undefined;
    var hasher = std.crypto.hash.Blake3.initKdf(session_seed_domain, .{});
    hasher.update(&self.session_seed_root);
    hasher.update(&counter_bytes);
    hasher.final(&out);
    return out;
}

/// The salt a session's wire-keyed tables hash under, derived from the
/// session's seed under its own domain so the seed is not recoverable from
/// a table's layout and the salt never equals a session key's bytes.
pub fn wireHashSalt(session_seed: [crypto.seed_bytes]u8) u64 {
    var out: [8]u8 = undefined;
    var hasher = std.crypto.hash.Blake3.initKdf("glowcap wire hash salt v1", .{});
    hasher.update(&session_seed);
    hasher.final(&out);
    return std.mem.readInt(u64, &out, .little);
}

/// The seed the sealed channel's Noise ephemeral starts from, under its own
/// domain, so the session's signing seed is not recoverable from a
/// handshake. The caller wipes it once the channel holds its keys.
pub fn noiseEphemeralSeed(session_seed: [crypto.seed_bytes]u8) [crypto.seed_bytes]u8 {
    var out: [crypto.seed_bytes]u8 = undefined;
    var hasher = std.crypto.hash.Blake3.initKdf("glowcap noise ephemeral v1", .{});
    hasher.update(&session_seed);
    hasher.final(&out);
    return out;
}
