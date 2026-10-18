//! A bijective map: every key maps to exactly one value and vice versa, with
//! both directions kept in lockstep by construction rather than by comment.
//!
//! The V1.0 inbound resolver link is one such bijection, an inbound answer's
//! resolver import. `BiMap` makes the "both rows appear together and drop
//! together" contract the type's own invariant: `put` maintains the
//! bijection and the removes take out a whole pair, so a half-installed link
//! is unconstructible.

const std = @import("std");
const foundation = @import("foundation");
const identity_hash = foundation.identity_hash;

/// A one-to-one map between `K` and `V`. `put` evicts any pair sharing the new
/// key or value so the bijection holds. A lookup or removal names either side.
/// Each side names who chooses its keys, since one side may hold positions
/// this process mints while the other holds the peer's.
pub fn BiMap(
    comptime K: type,
    comptime V: type,
    comptime key_provenance: foundation.identity_hash.Provenance,
    comptime value_provenance: foundation.identity_hash.Provenance,
) type {
    return struct {
        const Self = @This();

        forward: Side(K, V, key_provenance),
        /// Every pair keyed by the value's identity words. A value wider than
        /// one word is reduced to its words once per operation, and the table
        /// hashes and compares those words instead of calling back into the
        /// value.
        reverse: Side(ValueWords, K, value_provenance),

        const ValueWords = identity_hash.Words(V);

        /// Both sides are identity keys: a position newtype, or a type
        /// wider than one word that declares `identityWords`.
        fn Side(comptime Key: type, comptime Value: type, comptime provenance: foundation.identity_hash.Provenance) type {
            // Keys we mint use the cheap identity hash. Keys the peer picks
            // hash under a session secret. See the notes in `identity_hash`.
            return foundation.identity_hash.MapOf(provenance, Key, Value);
        }

        /// A link between positions this side allocates needs no secret. One
        /// between positions the peer chooses starts under the public constant
        /// this way and is keyed before it holds a row (`Session.keyWireTables`).
        pub const empty: Self = keyed(foundation.identity_hash.default_multiplier);

        /// A side keyed by positions the peer chooses hashes them under `multiplier`.
        pub fn keyed(multiplier: u64) Self {
            return .{
                .forward = sideKeyed(Side(K, V, key_provenance), multiplier),
                .reverse = sideKeyed(Side(ValueWords, K, value_provenance), multiplier),
            };
        }

        fn sideKeyed(comptime S: type, multiplier: u64) S {
            return if (@hasDecl(S, "keyed")) S.keyed(multiplier) else .empty;
        }

        /// Key an empty map's peer-chosen side under the session's secret.
        pub fn keyWire(self: *Self, multiplier: u64) void {
            sideKeyWire(&self.forward, multiplier);
            sideKeyWire(&self.reverse, multiplier);
        }

        fn sideKeyWire(side: anytype, multiplier: u64) void {
            if (@hasDecl(@TypeOf(side.*), "keyWire")) side.keyWire(multiplier);
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.forward.deinit(allocator);
            self.reverse.deinit(allocator);
        }

        /// Install `k <-> v`, evicting any existing pair that shares `k` or `v`
        /// so the bijection stays one-to-one. All-or-none: the only fallible
        /// step is the up-front capacity reserve, so a failure leaves the map
        /// as it was, no half-installed pair survives.
        pub fn put(self: *Self, allocator: std.mem.Allocator, k: K, v: V) !void {
            try self.ensureUnusedCapacity(allocator, 1);
            // Evict a stale pair sharing the new key or the new value, taking
            // its opposite row with it, before the infallible insert below.
            if (self.forward.fetchRemove(k)) |old| std.debug.assert(self.reverse.remove(identity_hash.words(old.value)));
            const value_words = identity_hash.words(v);
            if (self.reverse.fetchRemove(value_words)) |old| std.debug.assert(self.forward.remove(old.value));
            self.reverse.putAssumeCapacity(value_words, k);
            self.forward.putAssumeCapacity(k, v);
        }

        /// Reserve both directions for `additional` fresh pairs. A caller that
        /// has separately established key/value freshness can then commit with
        /// `putAssumeNoClobber` after its other fallible preparation succeeds.
        pub fn ensureUnusedCapacity(
            self: *Self,
            allocator: std.mem.Allocator,
            additional: u32,
        ) !void {
            try self.forward.ensureUnusedCapacity(allocator, additional);
            try self.reverse.ensureUnusedCapacity(allocator, additional);
        }

        /// Install one fresh pair without allocation or eviction. This is the
        /// transactional insertion shape for authority links: replacing either
        /// side would silently transfer an existing capability obligation.
        pub fn putAssumeNoClobber(self: *Self, k: K, v: V) void {
            std.debug.assert(!self.forward.contains(k));
            const value_words = identity_hash.words(v);
            std.debug.assert(!self.reverse.contains(value_words));
            self.reverse.putAssumeCapacity(value_words, k);
            self.forward.putAssumeCapacity(k, v);
        }

        pub fn getByKey(self: *const Self, k: K) ?V {
            return self.forward.get(k);
        }

        pub fn getByValue(self: *const Self, v: V) ?K {
            return self.reverse.get(identity_hash.words(v));
        }

        pub fn len(self: *const Self) usize {
            std.debug.assert(self.reverse.count() == self.forward.count());
            return self.forward.count();
        }

        /// Remove the pair keyed by `k` (both directions). Returns whether one
        /// was present.
        pub fn removeByKey(self: *Self, k: K) bool {
            const old = self.forward.fetchRemove(k) orelse return false;
            std.debug.assert(self.reverse.remove(identity_hash.words(old.value)));
            return true;
        }
    };
}
