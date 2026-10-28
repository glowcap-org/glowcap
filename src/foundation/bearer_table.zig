//! A table looked up with a name the wire supplied: a sturdyref's swissnum,
//! which grants its object to whoever presents it, a deposited gift's id, or
//! a cached sturdyref. Two things distinguish it from the ordinary string
//! table.
//!
//! Its hash is keyed. A peer that knows the hash function can choose names
//! that land in one bucket, and a table it fills that way degrades to a list
//! walk on every operation (ADR-0037). SipHash under a secret the owner
//! names at construction makes those names unguessable, so the table is built
//! with `keyed` and never with a default.
//!
//! Its equality runs in constant time over the stored key
//! (`std.crypto.timing_safe`). The ordinary table compares byte by byte and
//! stops at the first difference, so the time a lookup takes says how long a
//! prefix of a guess was right; here a near miss costs what a far miss costs.
//! Lengths are compared first and plainly, because a durable name's length is
//! fixed and public. A probe still stops at an empty slot and compares only a
//! stored key whose fingerprint matches, so timing can tell which bucket and
//! fingerprint a stored key has; under the keyed hash that says nothing about
//! the key's bytes.

const std = @import("std");

const SipHash = std.hash.SipHash64(1, 3);

/// Keyed hashing and constant-time equality over byte keys. Two keys of
/// different lengths are unequal at once.
pub const Context = struct {
    /// The owner's 64-bit bearer secret (ADR-0037), its own derivation and
    /// not the word the position tables multiply by, so what a peer learns
    /// about one table's buckets says nothing about the other's.
    secret: u64,

    pub fn keyed(secret: u64) Context {
        return .{ .secret = secret };
    }

    pub fn hash(self: Context, key: []const u8) u64 {
        // SipHash wants 128 key bits. The secret fills the low half and a
        // fixed tweak of it the high half, so the key has the secret's 64
        // bits of entropy. That keeps a peer from choosing names that share
        // a bucket, and nothing here needs more.
        var sip_key: [SipHash.key_length]u8 = undefined;
        std.mem.writeInt(u64, sip_key[0..8], self.secret, .little);
        std.mem.writeInt(u64, sip_key[8..16], self.secret ^ key_tweak, .little);
        return SipHash.toInt(key, &sip_key);
    }

    pub fn eql(_: Context, a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        return std.crypto.timing_safe.compare(u8, a, b, .big) == .eq;
    }
};

/// Makes the two key halves differ for every secret.
const key_tweak: u64 = 0x5bd1e9955bd1e995;

/// The standard unmanaged hash map, keyed by bytes the owner keeps alive,
/// hashing under `Context`. The table stores no secret: its owner holds the
/// one word and passes it to every verb, which hands the standard map's
/// context-taking form a `Context` built from it, so a session with three
/// name tables pays for the word once.
///
/// A removal leaves a tombstone, and an insert never turns one back into a
/// free slot. A bearer name is fresh every time (a new swissnum, a new gift
/// id), so a table that keeps evicting old names runs out of free slots, and
/// then every miss and every insert walks all of them. The table counts its
/// removals and rebuilds in place once they reach half the slots its live
/// names leave free, an amortized constant per removal. The rebuild moves
/// rows, so it runs only in the verbs that may already move them by growing:
/// `getOrPut`, `putNoClobber` and `ensureUnusedCapacity`.
pub fn Table(comptime V: type) type {
    return struct {
        const Self = @This();
        pub const Inner = std.HashMapUnmanaged([]const u8, V, Context, std.hash_map.default_max_load_percentage);
        pub const Entry = Inner.Entry;
        pub const KV = Inner.KV;
        pub const Iterator = Inner.Iterator;
        pub const ValueIterator = Inner.ValueIterator;
        pub const GetOrPutResult = Inner.GetOrPutResult;

        inner: Inner,
        /// Removals since the last rebuild, an upper bound on tombstones.
        removed: u32 = 0,

        pub const empty: Self = .{ .inner = .empty };

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.inner.deinit(allocator);
        }

        pub fn count(self: *const Self) usize {
            return self.inner.count();
        }

        pub fn iterator(self: *const Self) Iterator {
            return self.inner.iterator();
        }

        pub fn valueIterator(self: *const Self) ValueIterator {
            return self.inner.valueIterator();
        }

        pub fn get(self: *const Self, secret: u64, key: []const u8) ?V {
            return self.inner.getContext(key, .keyed(secret));
        }

        pub fn getPtr(self: *const Self, secret: u64, key: []const u8) ?*V {
            return self.inner.getPtrContext(key, .keyed(secret));
        }

        pub fn getKey(self: *const Self, secret: u64, key: []const u8) ?[]const u8 {
            return self.inner.getKeyContext(key, .keyed(secret));
        }

        pub fn contains(self: *const Self, secret: u64, key: []const u8) bool {
            return self.inner.containsContext(key, .keyed(secret));
        }

        pub fn getOrPut(self: *Self, secret: u64, allocator: std.mem.Allocator, key: []const u8) std.mem.Allocator.Error!GetOrPutResult {
            self.reclaim(secret);
            return self.inner.getOrPutContext(allocator, key, .keyed(secret));
        }

        pub fn putNoClobber(self: *Self, secret: u64, allocator: std.mem.Allocator, key: []const u8, value: V) std.mem.Allocator.Error!void {
            self.reclaim(secret);
            return self.inner.putNoClobberContext(allocator, key, value, .keyed(secret));
        }

        pub fn putAssumeCapacity(self: *Self, secret: u64, key: []const u8, value: V) void {
            self.inner.putAssumeCapacityContext(key, value, .keyed(secret));
        }

        pub fn ensureUnusedCapacity(self: *Self, secret: u64, allocator: std.mem.Allocator, additional: u32) std.mem.Allocator.Error!void {
            self.reclaim(secret);
            return self.inner.ensureUnusedCapacityContext(allocator, additional, .keyed(secret));
        }

        pub fn remove(self: *Self, secret: u64, key: []const u8) bool {
            const removed = self.inner.removeContext(key, .keyed(secret));
            self.removed += @intFromBool(removed);
            return removed;
        }

        pub fn fetchRemove(self: *Self, secret: u64, key: []const u8) ?KV {
            const removed = self.inner.fetchRemoveContext(key, .keyed(secret));
            self.removed += @intFromBool(removed != null);
            return removed;
        }

        /// The slots no live name occupies, free or tombstoned.
        pub fn spareSlots(self: *const Self) usize {
            return self.inner.capacity() - self.inner.count();
        }

        /// Rebuilds in place once removals reach half the spare slots. A
        /// removal implies a nonempty table, so the rebuild has storage.
        fn reclaim(self: *Self, secret: u64) void {
            if (self.removed == 0 or self.removed < self.spareSlots() / 2) return;
            self.inner.rehash(Context.keyed(secret));
            self.removed = 0;
        }
    };
}
