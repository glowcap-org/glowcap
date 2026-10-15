//! A table keyed by a bearer secret and looked up with a name the wire
//! supplied: a sturdyref's swissnum, which grants its object to whoever
//! presents it. The ordinary string table compares a candidate to a stored
//! key byte by byte and stops at the first difference, so the time a lookup
//! takes says how long a prefix of a guess was right. This table compares in
//! constant time over the stored key's length (`std.crypto.timing_safe`), so
//! a near miss costs what a far miss costs.
//!
//! What a lookup can still show is the table's own shape: a probe stops at an
//! empty slot and compares only a stored key whose hash fingerprint matches
//! the candidate's, so timing can tell which bucket and fingerprint a stored
//! key has, a few bits of its public hash, never a prefix of the key itself.
//! A key this process mints from `durable_swiss_entropy_len` random bytes
//! keeps far more entropy than those bits. Lengths are compared first and
//! plainly, because a durable name's length is fixed and public.

const std = @import("std");

/// Equality in constant time over the key's bytes. Two keys of different
/// lengths are unequal at once.
pub const Context = struct {
    pub fn hash(_: Context, key: []const u8) u64 {
        return std.hash_map.hashString(key);
    }

    pub fn eql(_: Context, a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        return std.crypto.timing_safe.compare(u8, a, b, .big) == .eq;
    }
};

/// The standard unmanaged hash map, keyed by bytes the owner keeps alive,
/// with `Context` as its equality.
pub fn Table(comptime V: type) type {
    return std.HashMapUnmanaged([]const u8, V, Context, std.hash_map.default_max_load_percentage);
}
