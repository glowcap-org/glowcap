//! Codec-neutral canonical ordering (ADR-0003).
//!
//! Syrup and Cap'n Proto both emit sets and structs in a single byte-key
//! order and refuse adjacent duplicates after that sort. The emit path that
//! produces each key stays codec-local. This module owns only the sort and the
//! symmetric duplicate refusal so the two codecs cannot drift.

const std = @import("std");

/// Whether `a` precedes `b` in canonical encoded-byte order.
pub fn byteSliceBefore(a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Byte-slice total order used as the canonical sort key comparator. `Key` is
/// `[]const u8` or `[]u8` (the Syrup set encoder sorts owned buffers in
/// place). One definition serves both so the two cannot drift.
pub fn lessByteSlice(comptime Key: type) fn (void, Key, Key) bool {
    return struct {
        fn less(_: void, a: Key, b: Key) bool {
            return byteSliceBefore(a, b);
        }
    }.less;
}

/// Refuse two equal adjacent keys. Callers pass keys already in sorted order
/// (or the sorted index order for `sortIndicesByKeys`). `Err` must include
/// `error.UnsupportedArgument`. `keys` is a slice of `[]const u8` or `[]u8`.
pub fn refuseAdjacentEqualKeys(comptime Err: type, keys: anytype) Err!void {
    if (keys.len < 2) return;
    for (keys[1..], 1..) |key, i| {
        if (std.mem.eql(u8, keys[i - 1], key)) return error.UnsupportedArgument;
    }
}

/// Sort `order` (indices into `keys`) by `keys[order[i]]`. When
/// `refuse_dupes`, refuse adjacent equal keys after the sort.
pub fn sortIndicesByKeys(
    comptime Err: type,
    order: []usize,
    keys: []const []const u8,
    comptime refuse_dupes: bool,
) Err!void {
    std.mem.sort(usize, order, keys, struct {
        fn less(ks: []const []const u8, a: usize, b: usize) bool {
            return std.mem.lessThan(u8, ks[a], ks[b]);
        }
    }.less);
    if (!refuse_dupes or order.len < 2) return;
    for (order[1..], 1..) |src, i| {
        if (std.mem.eql(u8, keys[order[i - 1]], keys[src])) return error.UnsupportedArgument;
    }
}

/// Allocate a copy of `items`, sort by `keyFn`, optionally refuse adjacent
/// equal keys. Caller owns the returned slice.
pub fn orderedCopyByKey(
    comptime T: type,
    comptime Err: type,
    allocator: std.mem.Allocator,
    items: []const T,
    comptime keyFn: *const fn (T) []const u8,
    comptime refuse_dupes: bool,
) Err![]T {
    const ordered = try allocator.alloc(T, items.len);
    errdefer allocator.free(ordered);
    for (items, 0..) |item, i| ordered[i] = item;
    std.mem.sort(T, ordered, {}, struct {
        fn less(_: void, a: T, b: T) bool {
            return std.mem.lessThan(u8, keyFn(a), keyFn(b));
        }
    }.less);
    if (refuse_dupes and ordered.len >= 2) {
        var i: usize = 1;
        while (i < ordered.len) : (i += 1) {
            if (std.mem.eql(u8, keyFn(ordered[i - 1]), keyFn(ordered[i])))
                return error.UnsupportedArgument;
        }
    }
    return ordered;
}
