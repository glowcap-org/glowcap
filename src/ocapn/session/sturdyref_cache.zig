//! Sturdyref-enliven dedup state for one Session (ADR-0012).
//!
//! Both are optional dedup: a cache miss costs one extra bootstrap-fetch
//! round-trip, never correctness, so the cache evicts its oldest entry on
//! overflow rather than erroring, and the in-flight set only collapses
//! concurrent enlivens of the same swissnum onto one outstanding answer.
//! The row type lives here with the cache transitions. Storage remains on
//! `Session`. These helpers are aliased back into its method index.

const std = @import("std");
const model = @import("model");
const session = @import("mod.zig");

const Session = session.Session;
const SturdyrefCacheEntry = Entry;

/// One resolved sturdyref enlivenment. `swissnum` is owned by the cache row,
/// `far` is stored whole so the far-kind survives cache hits. Two inline row
/// indexes maintain a circular FIFO through dense swap removal: eviction must
/// not rehash every surviving swissnum during a large foreign-graph restore.
/// Their retained cost is two words per admitted cache row, bounded by the
/// session's cache cap, with no additional allocation or idle Session field.
/// Row zero is always oldest. Its older neighbor is newest.
pub const Entry = struct {
    swissnum: []u8,
    far: model.FarRef,
    older: usize,
    newer: usize,
};

/// The cached enlivenment row for `swissnum`, by value, or null on a cache
/// miss (ADR-0012), one O(1) index lookup answering both halves of the
/// cache-hit short-circuit: the import position and the wire-kind, the latter
/// preserved verbatim per ADR-0010 § The far-kind is preserved across enliven.
/// The returned `swissnum` field borrows the cache row. Read the POD fields,
/// do not retain the slice.
pub fn sturdyrefCacheLookup(self: *const Session, swissnum: []const u8) ?SturdyrefCacheEntry {
    const i = findSturdyrefCacheIndex(self, swissnum) orelse return null;
    return self.sturdyref_cache.items[i];
}

/// Cache a resolved enlivenment for future repeat-enlivens (ADR-0012). Bounded
/// by `SessionLimits.max_sturdyref_cache_entries`. Idempotent on `swissnum`
/// (last-wins overwrite, no extra allocation). On overflow it evicts the
/// oldest entry (a miss costs only a refetch). A cap of 0 disables caching.
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
    try reserveCacheRow(self);
    const owned = try self.allocator.dupe(u8, swissnum);
    if (self.sturdyref_cache.items.len >= self.limits.max_sturdyref_cache_entries) {
        evictOldest(self);
    }
    appendReservedSturdyrefCacheRow(self, owned, far);
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
/// null when none is pending. The slice borrows the pending row. Do not retain
/// it past `finishPendingEnliven` / session teardown.
pub fn pendingEnlivenSwissnum(self: *const Session, answer_position: model.AnswerPosition) ?[]const u8 {
    return self.pending_enliven_by_answer.get(answer_position);
}

/// Record an in-flight enliven so a concurrent enliven for the same
/// `swissnum` collapses onto `answer_position`. Idempotent: a no-op when one is
/// already outstanding. An answer position may identify only one pending row.
/// Rejecting a collision keeps the two indexes one-to-one.
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
    // still leaves the caller's enliven operation untouched.
    try reserveCacheRow(self);
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
/// meaning. A bounded sweep finds matching positions. Unlinking each match
/// preserves FIFO order without moving or rehashing the surviving population.
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

/// Reserve one new row without consuming capacity promised to pending replies.
/// Every pending row may settle before another allocation is possible. Reserve
/// their combined demand, bounded by the cache cap. Once full, eviction makes
/// room without growth. Direct cache insertions obey the same reservation.
fn reserveCacheRow(self: *Session) !void {
    const room = self.limits.max_sturdyref_cache_entries - self.sturdyref_cache.items.len;
    const demand = @as(usize, self.pending_enlivens.count()) +| 1;
    const additional = @min(room, demand);
    const index_additional = std.math.cast(u32, additional) orelse return error.OutOfMemory;
    try self.sturdyref_cache.ensureUnusedCapacity(self.allocator, additional);
    try self.sturdyref_cache_index.ensureUnusedCapacity(self.allocator, index_additional);
}

/// Commit a cache row whose list and index capacity were reserved by
/// `reserveCacheRow`, or made available by evicting a full cache.
fn appendReservedSturdyrefCacheRow(self: *Session, owned: []u8, far: model.FarRef) void {
    const index = self.sturdyref_cache.items.len;
    const newest = if (index == 0) 0 else self.sturdyref_cache.items[0].older;
    if (index != 0) {
        self.sturdyref_cache.items[newest].newer = index;
        self.sturdyref_cache.items[0].older = index;
    }
    self.sturdyref_cache.appendAssumeCapacity(.{
        .swissnum = owned,
        .far = far,
        .older = newest,
        .newer = 0,
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

/// Row zero is the FIFO anchor even after arbitrary import invalidation.
fn evictOldest(self: *Session) void {
    removeAt(self, 0);
}

fn removeAt(self: *Session, index: usize) void {
    const evicted = self.sturdyref_cache.items[index];
    const last = self.sturdyref_cache.items.len - 1;
    std.debug.assert(self.sturdyref_cache_index.remove(evicted.swissnum));
    self.allocator.free(evicted.swissnum);
    if (last == 0) {
        _ = self.sturdyref_cache.pop();
        return;
    }
    self.sturdyref_cache.items[evicted.older].newer = evicted.newer;
    self.sturdyref_cache.items[evicted.newer].older = evicted.older;
    const removed = self.sturdyref_cache.swapRemove(index);
    std.debug.assert(removed.swissnum.ptr == evicted.swissnum.ptr);
    if (index != last) repairRow(self, index);
    if (index == 0) {
        const oldest = if (evicted.newer == last) 0 else evicted.newer;
        if (oldest != 0) swapRows(self, 0, oldest);
    }
}

/// Repair the one row relocated from the dense list's former last slot.
fn repairRow(self: *Session, index: usize) void {
    const entry = self.sturdyref_cache.items[index];
    // A singleton's neighbors named its former slot before relocation.
    if (self.sturdyref_cache.items.len == 1) {
        self.sturdyref_cache.items[index].older = index;
        self.sturdyref_cache.items[index].newer = index;
    } else {
        self.sturdyref_cache.items[entry.older].newer = index;
        self.sturdyref_cache.items[entry.newer].older = index;
    }
    self.sturdyref_cache_index.getPtr(entry.swissnum).?.* = index;
}

fn swapRows(self: *Session, a: usize, b: usize) void {
    const entries = self.sturdyref_cache.items;
    std.mem.swap(Entry, &entries[a], &entries[b]);
    for ([_]usize{ a, b }) |index| {
        entries[index].older = swapped(entries[index].older, a, b);
        entries[index].newer = swapped(entries[index].newer, a, b);
    }
    repairRow(self, a);
    repairRow(self, b);
}

fn swapped(index: usize, a: usize, b: usize) usize {
    return if (index == a) b else if (index == b) a else index;
}
