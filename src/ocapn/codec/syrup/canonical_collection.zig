//! Canonical Syrup ordering for unordered encoded collections.
//!
//! A caller supplies the element writer and a sequence with the lazy
//! sequence contract (`len` and a forward `iterator`), so a borrowed set,
//! struct, or hint dictionary is walked where it lies. The count pass sums
//! elements without scratch because canonical ordering is a permutation. The
//! fill pass sorts encoded set elements or borrowed dictionary keys, refuses
//! duplicates where required, and emits the canonical order.

const std = @import("std");

const codec_order = @import("codec_order");
const render = @import("render.zig");
const shared = @import("shared.zig");

const WalkError = shared.WalkError;

pub fn write(
    allocator: std.mem.Allocator,
    sink: anytype,
    sequence: anytype,
    comptime refuse_adjacent_dupes: bool,
    comptime writeElem: anytype,
) WalkError!void {
    if (comptime render.sinkCounts(@TypeOf(sink))) {
        return countElements(allocator, sink, sequence, writeElem);
    }

    const encoded = try allocator.alloc([]u8, try sequence.len());
    var built: usize = 0;
    defer {
        for (encoded[0..built]) |element| allocator.free(element);
        allocator.free(encoded);
    }

    var it = sequence.iterator();
    while (try it.nextRef()) |item| {
        // A sequence whose walk and `len` disagree is malformed, and the
        // check stays live in every build mode because the alternative is
        // an out-of-bounds write.
        if (built == encoded.len) return error.MalformedView;
        var element: std.ArrayList(u8) = .empty;
        errdefer element.deinit(allocator);
        var element_sink: render.ListSink = .{ .allocator = allocator, .list = &element };
        try writeElem(allocator, &element_sink, item);
        encoded[built] = try element.toOwnedSlice(allocator);
        built += 1;
    }
    if (built != encoded.len) return error.MalformedView;

    try codec_order.orderByKey([]u8, WalkError, encoded, codec_order.ownBytes, refuse_adjacent_dupes);
    for (encoded) |element| try sink.appendSlice(element);
}

/// Order a dictionary by its encoded String keys. Keys are self-delimiting,
/// so no value bytes participate in ordering. Keep eight borrowed keys and
/// iterator checkpoints in place, spilling only the index for larger maps.
/// Scratch dies before return. Sorting full entry encodings would allocate
/// and copy every value even when the final output already has exact storage.
pub fn writeKeyed(
    allocator: std.mem.Allocator,
    sink: anytype,
    sequence: anytype,
    comptime refuse_dupes: bool,
    comptime keyOf: anytype,
    comptime writeElem: anytype,
) WalkError!void {
    if (comptime render.sinkCounts(@TypeOf(sink))) {
        return countElements(allocator, sink, sequence, writeElem);
    }
    const Row = struct {
        key: []const u8,
        position: @TypeOf(sequence).Checkpoint,
        fn less(_: void, a: @This(), b: @This()) bool {
            return stringKeyBefore(a.key, b.key);
        }
    };
    const count = try sequence.len();
    var room: [8]Row = undefined;
    const ordered = if (count <= room.len) room[0..count] else try allocator.alloc(Row, count);
    defer if (count > room.len) allocator.free(ordered);
    var it = sequence.iterator();
    var filled: usize = 0;
    while (true) {
        const position = it.checkpoint();
        const item = try it.nextRef() orelse break;
        if (filled == count) return error.MalformedView;
        ordered[filled] = .{ .key = keyOf(item), .position = position };
        filled += 1;
    }
    if (filled != count) return error.MalformedView;
    std.mem.sort(Row, ordered, {}, Row.less);
    for (ordered, 0..) |row, i| {
        if (refuse_dupes and i != 0 and std.mem.eql(u8, ordered[i - 1].key, row.key))
            return error.UnsupportedArgument;
        const item = try sequence.atCheckpoint(row.position);
        try writeElem(allocator, sink, &item);
    }
}

/// Compare the exact decimal-length prefixes, then the text. A String's
/// quote sorts before every digit, so prefix exhaustion has the same order
/// as the quote that follows it. Equal prefixes mean equal byte lengths.
fn stringKeyBefore(a: []const u8, b: []const u8) bool {
    const decimal = @import("foundation").decimal;
    var a_prefix: [20]u8 = undefined;
    var b_prefix: [20]u8 = undefined;
    const a_digits = a_prefix[0..decimal.width(a.len)];
    const b_digits = b_prefix[0..decimal.width(b.len)];
    decimal.fill(a_digits, a.len);
    decimal.fill(b_digits, b.len);
    return switch (std.mem.order(u8, a_digits, b_digits)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.lessThan(u8, a, b),
    };
}

/// The size pass checks the same sequence cardinality as the fill pass,
/// including a claimed empty collection whose iterator yields an element.
fn countElements(
    allocator: std.mem.Allocator,
    sink: anytype,
    sequence: anytype,
    comptime writeElem: anytype,
) WalkError!void {
    const count = try sequence.len();
    var visited: usize = 0;
    var it = sequence.iterator();
    while (try it.nextRef()) |item| : (visited += 1) {
        if (visited == count) return error.MalformedView;
        try writeElem(allocator, sink, item);
    }
    if (visited != count) return error.MalformedView;
}
