//! Sturdyref-enliven dedup state for one Session (ADR-0012).
//!
//! Both are non-load-bearing dedup: a cache miss costs one extra bootstrap-fetch
//! round-trip, never correctness, so the cache evicts its oldest entry on
//! overflow rather than erroring, and the in-flight set only collapses
//! concurrent enlivens of the same swissnum onto one outstanding answer. The
//! The row type lives here with the cache transitions. Storage remains on
//! `Session`; these helpers are aliased back into its method index.

const std = @import("std");
const model = @import("model");
const session = @import("mod.zig");

const Session = session.Session;
const SturdyrefCacheEntry = Entry;

/// One resolved sturdyref enlivenment. `swissnum` is owned by the cache row;
/// `far` is stored whole so the far-kind survives cache hits.
pub const Entry = struct {
    swissnum: []u8,
    far: model.FarRef,
};

/// The cached enlivenment row for `swissnum`, by value, or null on a cache
/// miss (ADR-0012), one O(1) index lookup answering both halves of the
/// cache-hit short-circuit: the import position and the wire-kind, the latter
/// preserved verbatim per ADR-0010 § The far-kind is preserved across enliven.
/// The returned `swissnum` field borrows the cache row; read the POD fields,
/// do not retain the slice.
pub fn sturdyrefCacheLookup(self: *const Session, swissnum: []const u8) ?SturdyrefCacheEntry {
    const i = findSturdyrefCacheIndex(self, swissnum) orelse return null;
    return self.sturdyref_cache.items[i];
}

/// Cache a resolved enlivenment for future repeat-enlivens (ADR-0012). Bounded
/// by `SessionLimits.max_sturdyref_cache_entries`; idempotent on `swissnum`
/// (last-wins overwrite, no extra allocation); on overflow it evicts the
/// oldest entry (the cache is non-load-bearing). A cap of 0 disables caching.
/// `far` is stored whole so its kind is preserved (ADR-0010).
pub fn cacheSturdyrefEnlivenment(
    self: *Session,
    swissnum: []const u8,
    far: model.FarRef,
) !void {
    if (self.limits.max_sturdyref_cache_entries == 0) return;
    if (findSturdyrefCache(self, swissnum)) |entry| {
        entry.far = far;
        return;
    }
    if (self.sturdyref_cache.items.len >= self.limits.max_sturdyref_cache_entries) {
        evictOldest(self);
    }
    const owned = try self.allocator.dupe(u8, swissnum);
    errdefer self.allocator.free(owned);
    try appendSturdyrefCacheRow(self, owned, far);
}

/// Settle a fulfilled enliven: move the pending row's owned swissnum into the
/// resolved cache (no second dupe) and clear both in-flight indexes. The fresh
/// enliven reservation preallocated every cache row this commit can need, so
/// settlement is infallible and a missing pending row is an engine ownership
/// defect rather than permission to silently skip dedup state.
pub fn settlePendingEnlivenIntoCache(self: *Session, swissnum: []const u8, far: model.FarRef) void {
    const removed = self.pending_enlivens.fetchRemove(swissnum) orelse unreachable;
    std.debug.assert(self.pending_enliven_by_answer.remove(removed.value));
    // Pending map keys are owned `[]u8` stored as `[]const u8`; reclaim mutability
    // for the cache row (sole remaining owner).
    const owned: []u8 = @constCast(removed.key);

    if (self.limits.max_sturdyref_cache_entries == 0) {
        self.allocator.free(owned);
        return;
    }
    if (findSturdyrefCache(self, owned)) |entry| {
        entry.far = far;
        self.allocator.free(owned);
        return;
    }
    if (self.sturdyref_cache.items.len >= self.limits.max_sturdyref_cache_entries) {
        evictOldest(self);
    }
    appendReservedSturdyrefCacheRow(self, owned, far);
}

/// The outstanding bootstrap-fetch answer for an in-flight enliven of
/// `swissnum`, or null when none is pending (ADR-0012 in-flight dedup).
pub fn pendingEnlivenAnswer(self: *Session, swissnum: []const u8) ?model.AnswerPosition {
    return self.pending_enlivens.get(swissnum);
}

/// The session-owned swissnum for an in-flight enliven on `answer_position`, or
/// null when none is pending. The slice borrows the pending row; do not retain
/// it past `finishPendingEnliven` / session teardown.
pub fn pendingEnlivenSwissnum(self: *const Session, answer_position: model.AnswerPosition) ?[]const u8 {
    return self.pending_enliven_by_answer.get(answer_position);
}

/// Record an in-flight enliven so a concurrent enliven for the same
/// `swissnum` collapses onto `answer_position`. Idempotent: a no-op when one is
/// already outstanding. An answer position may identify only one pending row;
/// rejecting a collision keeps the two indexes one-to-one.
pub fn notePendingEnliven(
    self: *Session,
    swissnum: []const u8,
    answer_position: model.AnswerPosition,
) error{ OutOfMemory, AnswerAlreadyPending }!void {
    if (self.pending_enlivens.contains(swissnum)) return;
    if (self.pending_enliven_by_answer.contains(answer_position))
        return error.AnswerAlreadyPending;
    // Settlement moves this pending row into the cache after the fetch has
    // committed. Reserve both cache structures now, while allocation failure
    // still leaves the caller's enliven operation untouched. A full cache
    // needs no growth: settlement evicts one row before inserting its own.
    if (self.limits.max_sturdyref_cache_entries > 0 and
        self.sturdyref_cache.items.len < self.limits.max_sturdyref_cache_entries)
    {
        try self.sturdyref_cache.ensureUnusedCapacity(self.allocator, 1);
        try self.sturdyref_cache_index.ensureUnusedCapacity(self.allocator, 1);
    }
    // Own the key before either index can observe it. The errdefers are ordered
    // so a reverse-index failure removes the forward row before freeing the
    // slice both maps compare through.
    const owned = try self.allocator.dupe(u8, swissnum);
    errdefer self.allocator.free(owned);
    const gop = try self.pending_enlivens.getOrPut(self.allocator, owned);
    std.debug.assert(!gop.found_existing); // Session mutation is single-owner.
    errdefer std.debug.assert(self.pending_enlivens.remove(owned));
    gop.value_ptr.* = answer_position;
    // The reverse index borrows the same owned slice; one owner, two lookups.
    try self.pending_enliven_by_answer.put(self.allocator, answer_position, owned);
}

/// Clear the in-flight marker for `swissnum` once its enliven settles. A
/// no-op when none is outstanding.
pub fn finishPendingEnliven(self: *Session, swissnum: []const u8) void {
    if (self.pending_enlivens.fetchRemove(swissnum)) |kv| {
        std.debug.assert(self.pending_enliven_by_answer.remove(kv.value));
        self.allocator.free(kv.key);
    }
}

/// Forget every resolved sturdyref cache row that names `position`.
///
/// Once the import's wire count reaches zero the partner may reuse its
/// position for another object. A cached swissnum must miss after that point
/// and enliven again, rather than returning the old position under its new
/// meaning. The cache is bounded and FIFO-ordered, so the removal is a small
/// linear sweep that preserves the surviving order.
pub fn forgetSturdyrefEnlivenmentsAt(self: *Session, position: model.ImportPosition) void {
    var i: usize = 0;
    while (i < self.sturdyref_cache.items.len) {
        if (self.sturdyref_cache.items[i].far.import_position == position) {
            removeAt(self, i);
        } else {
            i += 1;
        }
    }
}

fn appendSturdyrefCacheRow(self: *Session, owned: []u8, far: model.FarRef) !void {
    const index = self.sturdyref_cache.items.len;
    try self.sturdyref_cache.append(self.allocator, .{
        .swissnum = owned,
        .far = far,
    });
    errdefer _ = self.sturdyref_cache.pop();
    // The map key is the same owned slice the ArrayList row holds — one owner.
    try self.sturdyref_cache_index.put(self.allocator, owned, index);
}

/// Commit a cache row whose list and index capacity were reserved by
/// `notePendingEnliven`, or made available by evicting a full cache.
fn appendReservedSturdyrefCacheRow(self: *Session, owned: []u8, far: model.FarRef) void {
    const index = self.sturdyref_cache.items.len;
    self.sturdyref_cache.appendAssumeCapacity(.{
        .swissnum = owned,
        .far = far,
    });
    self.sturdyref_cache_index.putAssumeCapacity(owned, index);
}

fn findSturdyrefCache(self: *Session, swissnum: []const u8) ?*SturdyrefCacheEntry {
    const i = findSturdyrefCacheIndex(self, swissnum) orelse return null;
    return &self.sturdyref_cache.items[i];
}

/// O(1) swissnum to row index via the side map kept in sync with the FIFO list.
fn findSturdyrefCacheIndex(self: *const Session, swissnum: []const u8) ?usize {
    return self.sturdyref_cache_index.get(swissnum);
}

/// Drop the oldest FIFO row and repair every surviving index in the side map
/// so lookups stay consistent with `orderedRemove(0)`'s shift.
fn evictOldest(self: *Session) void {
    removeAt(self, 0);
}

fn removeAt(self: *Session, index: usize) void {
    const evicted = self.sturdyref_cache.orderedRemove(index);
    std.debug.assert(self.sturdyref_cache_index.remove(evicted.swissnum));
    self.allocator.free(evicted.swissnum);
    for (self.sturdyref_cache.items[index..], index..) |entry, i| {
        self.sturdyref_cache_index.getPtr(entry.swissnum).?.* = i;
    }
}
