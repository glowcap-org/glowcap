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

/// Sort `ordered` in place by the key `keyFn` reads from each element, and
/// with `refuse_dupes` refuse two elements with one key as
/// `UnsupportedArgument`, which `Err` holds. The one sort both codecs use for
/// a set or a dictionary.
pub fn orderByKey(
    comptime T: type,
    comptime Err: type,
    ordered: []T,
    comptime keyFn: *const fn (T) []const u8,
    comptime refuse_dupes: bool,
) Err!void {
    std.mem.sort(T, ordered, {}, struct {
        fn less(_: void, a: T, b: T) bool {
            return byteSliceBefore(keyFn(a), keyFn(b));
        }
    }.less);
    if (!refuse_dupes or ordered.len < 2) return;
    for (ordered[1..], 1..) |element, i| {
        if (std.mem.eql(u8, keyFn(ordered[i - 1]), keyFn(element))) return error.UnsupportedArgument;
    }
}

/// The key of an element that is its own encoded bytes.
pub fn ownBytes(bytes: []u8) []const u8 {
    return bytes;
}
