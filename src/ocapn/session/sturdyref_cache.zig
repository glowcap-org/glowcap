//! The session's sturdyref-enliven dedup state (ADR-0012): the resolved-
//! enlivenment cache and the in-flight enliven set, as `*Session` helpers.
//!
//! Both are non-load-bearing dedup: a cache miss costs one extra bootstrap-fetch
//! round-trip, never correctness, so the cache evicts its oldest entry on
//! overflow rather than erroring, and the in-flight set only collapses
//! concurrent enlivens of the same swissnum onto one outstanding answer. The
//! engine driver of this seam is `engine.sturdyref`; the cache row type
//! (`SturdyrefCacheEntry`) and the storage fields it operates on
//! (`sturdyref_cache`, `pending_enlivens`) live on `Session` in `mod.zig`. These
//! functions are aliased back into the `Session` namespace there, so a caller
//! still writes `sess.cacheSturdyrefEnlivenment(...)`.

const std = @import("std");
const model = @import("model");
const session = @import("mod.zig");

const Session = session.Session;
const SturdyrefCacheEntry = session.SturdyrefCacheEntry;

/// The cached enlivenment row for `swissnum`, by value, or null on a cache
/// miss (ADR-0012), one scan answering both halves of the cache-hit
/// short-circuit: the import id and the wire-kind, the latter preserved
/// verbatim per ADR-0010 § The far-kind is preserved across enliven. The
/// returned `swissnum` field borrows the cache row; read the POD fields,
/// do not retain the slice.
pub fn sturdyrefCacheLookup(self: *const Session, swissnum: []const u8) ?SturdyrefCacheEntry {
    for (self.sturdyref_cache.items) |entry| {
        if (std.mem.eql(u8, entry.swissnum, swissnum)) return entry;
    }
    return null;
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
        const evicted = self.sturdyref_cache.orderedRemove(0);
        self.allocator.free(evicted.swissnum);
    }
    const owned = try self.allocator.dupe(u8, swissnum);
    errdefer self.allocator.free(owned);
    try self.sturdyref_cache.append(self.allocator, .{
        .swissnum = owned,
        .far = far,
    });
}

/// The outstanding bootstrap-fetch answer for an in-flight enliven of
/// `swissnum`, or null when none is pending (ADR-0012 in-flight dedup).
pub fn pendingEnlivenAnswer(self: *Session, swissnum: []const u8) ?model.AnswerId {
    return self.pending_enlivens.get(swissnum);
}

/// Record an in-flight enliven so a concurrent enliven for the same
/// `swissnum` collapses onto `answer_position`. Idempotent: a no-op when one is
/// already outstanding (the caller checks `pendingEnlivenAnswer` first).
pub fn notePendingEnliven(self: *Session, swissnum: []const u8, answer_position: model.AnswerId) !void {
    const gop = try self.pending_enlivens.getOrPut(self.allocator, swissnum);
    if (gop.found_existing) return;
    // Rows are removed on completion, so the key is gpa-owned and freed then;
    // replace the borrowed key with an owned copy, undoing the slot on OOM.
    gop.key_ptr.* = self.allocator.dupe(u8, swissnum) catch |err| {
        _ = self.pending_enlivens.remove(swissnum);
        return err;
    };
    gop.value_ptr.* = answer_position;
}

/// Clear the in-flight marker for `swissnum` once its enliven settles. A
/// no-op when none is outstanding.
pub fn finishPendingEnliven(self: *Session, swissnum: []const u8) void {
    if (self.pending_enlivens.fetchRemove(swissnum)) |kv| {
        self.allocator.free(kv.key);
    }
}

fn findSturdyrefCache(self: *Session, swissnum: []const u8) ?*SturdyrefCacheEntry {
    for (self.sturdyref_cache.items) |*entry| {
        if (std.mem.eql(u8, entry.swissnum, swissnum)) return entry;
    }
    return null;
}
