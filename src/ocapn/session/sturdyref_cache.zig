//! The session's sturdyref-enliven dedup state (ADR-0012): the resolved-
//! enlivenment cache and the in-flight enliven set, as `*Session` helpers.
//!
//! Both are non-load-bearing dedup: a cache miss costs one extra bootstrap-fetch
//! round-trip, never correctness, so the cache evicts its oldest entry on
//! overflow rather than erroring, and the in-flight set only collapses
//! concurrent enlivens of the same swissnum onto one outstanding answer. The
//! engine driver of this seam is `engine.sturdyref`; the cache row type
//! (`SturdyrefCacheEntry`) and the storage fields it operates on
//! (`sturdyref_cache`, `sturdyref_cache_index`, `pending_enlivens`,
//! `pending_enliven_by_answer`) live on
//! `Session` in `mod.zig`. These functions are aliased back into the `Session`
//! namespace there, so a caller still writes `sess.cacheSturdyrefEnlivenment(...)`.

const std = @import("std");
const model = @import("model");
const session = @import("mod.zig");

const Session = session.Session;
const SturdyrefCacheEntry = session.SturdyrefCacheEntry;

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
/// resolved cache (no second dupe) and clear both in-flight indexes. When no
/// pending row exists, falls back to `cacheSturdyrefEnlivenment`. The cache is
/// non-load-bearing: insert failures keep the live reference and free the
/// transferred swissnum.
pub fn settlePendingEnlivenIntoCache(self: *Session, swissnum: []const u8, far: model.FarRef) void {
    const removed = self.pending_enlivens.fetchRemove(swissnum) orelse {
        cacheSturdyrefEnlivenment(self, swissnum, far) catch {};
        return;
    };
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
    appendSturdyrefCacheRow(self, owned, far) catch {
        self.allocator.free(owned);
    };
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
/// already outstanding (the caller checks `pendingEnlivenAnswer` first).
pub fn notePendingEnliven(self: *Session, swissnum: []const u8, answer_position: model.AnswerPosition) !void {
    const gop = try self.pending_enlivens.getOrPut(self.allocator, swissnum);
    if (gop.found_existing) return;
    // Rows are removed on completion, so the key is gpa-owned and freed then;
    // replace the borrowed key with an owned copy, undoing the slot on OOM.
    gop.key_ptr.* = try self.allocator.dupe(u8, swissnum);
    errdefer {
        self.allocator.free(gop.key_ptr.*);
        std.debug.assert(self.pending_enlivens.remove(swissnum));
    }
    gop.value_ptr.* = answer_position;
    // The reverse index borrows the same owned slice; one owner, two lookups.
    try self.pending_enliven_by_answer.put(self.allocator, answer_position, gop.key_ptr.*);
}

/// Clear the in-flight marker for `swissnum` once its enliven settles. A
/// no-op when none is outstanding.
pub fn finishPendingEnliven(self: *Session, swissnum: []const u8) void {
    if (self.pending_enlivens.fetchRemove(swissnum)) |kv| {
        std.debug.assert(self.pending_enliven_by_answer.remove(kv.value));
        self.allocator.free(kv.key);
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
    const evicted = self.sturdyref_cache.orderedRemove(0);
    std.debug.assert(self.sturdyref_cache_index.remove(evicted.swissnum));
    self.allocator.free(evicted.swissnum);
    for (self.sturdyref_cache.items, 0..) |entry, i| {
        self.sturdyref_cache_index.getPtr(entry.swissnum).?.* = i;
    }
}
