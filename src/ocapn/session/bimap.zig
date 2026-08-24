//! A bijective map: every key maps to exactly one value and vice versa, with
//! both directions kept in lockstep by construction rather than by comment.
//!
//! The V1.0 resolver links (ADR-0010) are two such bijections — an outbound
//! answer's resolver export and an inbound answer's resolver import — each of
//! which was a hand-rolled forward `HashMap` plus its inverse, with the "both
//! rows appear together and drop together" contract enforced only by prose and
//! scattered asserted removes. `BiMap` makes that lockstep the type's own
//! invariant: `put` maintains the bijection and the two removes take out a
//! whole pair by either side, so a half-installed link is unconstructible.

const std = @import("std");

/// A one-to-one map between `K` and `V`. `put` evicts any pair sharing the new
/// key or value so the bijection holds; a lookup or removal names either side.
pub fn BiMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        forward: std.AutoHashMapUnmanaged(K, V) = .empty,
        reverse: std.AutoHashMapUnmanaged(V, K) = .empty,

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.forward.deinit(allocator);
            self.reverse.deinit(allocator);
        }

        /// Install `k <-> v`, evicting any existing pair that shares `k` or `v`
        /// so the bijection stays one-to-one. All-or-none: the only fallible
        /// step is the up-front capacity reserve, so a failure leaves the map
        /// exactly as it was — no half-installed pair survives.
        pub fn put(self: *Self, allocator: std.mem.Allocator, k: K, v: V) !void {
            try self.ensureUnusedCapacity(allocator, 1);
            // Evict a stale pair sharing the new key or the new value, taking
            // its opposite row with it, before the infallible insert below.
            if (self.forward.fetchRemove(k)) |old| std.debug.assert(self.reverse.remove(old.value));
            if (self.reverse.fetchRemove(v)) |old| std.debug.assert(self.forward.remove(old.value));
            self.forward.putAssumeCapacity(k, v);
            self.reverse.putAssumeCapacity(v, k);
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
            std.debug.assert(!self.reverse.contains(v));
            self.forward.putAssumeCapacity(k, v);
            self.reverse.putAssumeCapacity(v, k);
        }

        pub fn getByKey(self: *const Self, k: K) ?V {
            return self.forward.get(k);
        }

        pub fn getByValue(self: *const Self, v: V) ?K {
            return self.reverse.get(v);
        }

        pub fn len(self: *const Self) usize {
            std.debug.assert(self.forward.count() == self.reverse.count());
            return self.forward.count();
        }

        /// Remove the pair keyed by `k` (both directions); returns whether one
        /// was present.
        pub fn removeByKey(self: *Self, k: K) bool {
            const old = self.forward.fetchRemove(k) orelse return false;
            std.debug.assert(self.reverse.remove(old.value));
            return true;
        }

        /// Replace the value paired with an existing key without growing either
        /// backing map. Used for resolver-purpose state transitions where the
        /// row identity stays live and only its phase changes.
        pub fn replaceValueForKey(self: *Self, k: K, new_value: V) void {
            const old_value = self.forward.get(k) orelse unreachable;
            if (std.meta.eql(old_value, new_value)) return;
            std.debug.assert(self.reverse.remove(old_value));
            if (self.reverse.fetchRemove(new_value)) |old| {
                std.debug.assert(self.forward.remove(old.value));
            }
            self.forward.putAssumeCapacity(k, new_value);
            self.reverse.putAssumeCapacity(new_value, k);
        }
    };
}
