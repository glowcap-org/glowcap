//! A bijective map: every key maps to exactly one value and vice versa, with
//! both directions kept in lockstep by construction rather than by comment.
//!
//! The V1.0 resolver links are two such bijections, an outbound answer's
//! resolver export and an inbound answer's resolver import. `BiMap` makes the
//! "both rows appear together and drop together" contract the type's own
//! invariant: `put` maintains the bijection and the two removes take out a
//! whole pair by either side, so a half-installed link is unconstructible.
//!
//! A value may name its own key. A retired resolver, for one, serves no
//! answer or promise any more, so the export it retired is its only name. Such
//! a value takes no reverse row: a lookup by that value reads the forward row
//! its key names, and the value's transitions touch one row (ADR-0224).

const std = @import("std");
const foundation = @import("foundation");
const identity_hash = foundation.identity_hash;

/// A one-to-one map between `K` and `V`. `put` evicts any pair sharing the new
/// key or value so the bijection holds. A lookup or removal names either side.
/// Each side names who chooses its keys, since one side may hold positions
/// this process mints while the other holds the peer's.
///
/// A `V` that declares `pub fn namedKey(self: V) ?K` says which of its values
/// name their own key. Such a value is only ever paired with that key and is
/// held in the forward row alone.
pub fn BiMap(
    comptime K: type,
    comptime V: type,
    comptime key_provenance: foundation.identity_hash.Provenance,
    comptime value_provenance: foundation.identity_hash.Provenance,
) type {
    return struct {
        const Self = @This();

        forward: Side(K, V, key_provenance),
        /// Every pair whose value does not name its own key, keyed by the
        /// value's identity words. A value wider than one word is then
        /// reduced to its words once per operation, and the table hashes and
        /// compares those words instead of calling back into the value.
        reverse: Side(ValueWords, K, value_provenance),

        const ValueWords = identity_hash.Words(V);

        /// The key `v` names, when `v` is its own name and takes no reverse row.
        fn namedKey(v: V) ?K {
            return if (@hasDecl(V, "namedKey")) v.namedKey() else null;
        }

        /// Both sides are identity keys. A side wider than one word, such as
        /// a purpose union, declares `identityWords`.
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
            if (self.forward.fetchRemove(k)) |old| self.dropReverse(old.value);
            if (namedKey(v)) |named| {
                // A self-named value shares a pair only with its own key, and
                // that pair left just above.
                std.debug.assert(identity_hash.eql(named, k));
            } else {
                const value_words = identity_hash.words(v);
                if (self.reverse.fetchRemove(value_words)) |old| std.debug.assert(self.forward.remove(old.value));
                self.reverse.putAssumeCapacity(value_words, k);
            }
            self.forward.putAssumeCapacity(k, v);
        }

        /// Drop the reverse row of a value leaving the map, when it has one.
        fn dropReverse(self: *Self, v: V) void {
            if (namedKey(v) == null) std.debug.assert(self.reverse.remove(identity_hash.words(v)));
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
            if (namedKey(v)) |named| {
                std.debug.assert(identity_hash.eql(named, k));
            } else {
                const value_words = identity_hash.words(v);
                std.debug.assert(!self.reverse.contains(value_words));
                self.reverse.putAssumeCapacity(value_words, k);
            }
            self.forward.putAssumeCapacity(k, v);
        }

        pub fn getByKey(self: *const Self, k: K) ?V {
            return self.forward.get(k);
        }

        /// The key paired with `v`. A self-named value is paired with the key
        /// it names exactly when that key's forward row holds it.
        pub fn getByValue(self: *const Self, v: V) ?K {
            const named = namedKey(v) orelse return self.reverse.get(identity_hash.words(v));
            const held = self.forward.get(named) orelse return null;
            return if (identity_hash.eql(held, v)) named else null;
        }

        pub fn len(self: *const Self) usize {
            std.debug.assert(self.reverse.count() <= self.forward.count());
            return self.forward.count();
        }

        /// Remove the pair keyed by `k` (both directions). Returns whether one
        /// was present.
        pub fn removeByKey(self: *Self, k: K) bool {
            const old = self.forward.fetchRemove(k) orelse return false;
            self.dropReverse(old.value);
            return true;
        }

        /// Replace the value paired with an existing key without growing either
        /// backing map. Used for resolver-purpose state transitions where the
        /// row identity stays live and only its phase changes. Presence is
        /// certain because every caller asserts the row with `getByKey` in the
        /// same dispatch immediately before (see
        /// `completeRetiredResolverCallback`). The forward row changes in
        /// place, so a transition into a self-named value touches that one row.
        pub fn replaceValueForKey(self: *Self, k: K, new_value: V) void {
            const old_value = self.forward.get(k) orelse unreachable;
            if (identity_hash.eql(old_value, new_value)) return;
            self.dropReverse(old_value);
            if (namedKey(new_value)) |named| {
                std.debug.assert(identity_hash.eql(named, k));
            } else {
                const new_words = identity_hash.words(new_value);
                if (self.reverse.fetchRemove(new_words)) |old| {
                    // The evicted pair's key is not `k`: `k` still pairs with
                    // `old_value`, which differs from `new_value`.
                    std.debug.assert(self.forward.remove(old.value));
                }
                self.reverse.putAssumeCapacity(new_words, k);
            }
            // The forward row is reached after any eviction above, since a
            // removal may move rows.
            (self.forward.getPtr(k) orelse unreachable).* = new_value;
        }
    };
}
