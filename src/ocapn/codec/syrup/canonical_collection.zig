//! Canonical Syrup ordering for unordered encoded collections.
//!
//! A caller supplies the element writer. The count pass sums elements without
//! scratch because canonical ordering is a permutation. The fill pass encodes
//! each element once, sorts the encoded bytes, optionally refuses adjacent
//! duplicates, and emits the sorted byte strings.

const std = @import("std");

const codec_order = @import("codec_order");
const render = @import("render.zig");
const shared = @import("shared.zig");

const WalkError = shared.WalkError;

pub fn write(
    comptime Elem: type,
    allocator: std.mem.Allocator,
    sink: anytype,
    items: []const Elem,
    comptime refuse_adjacent_dupes: bool,
    comptime writeElem: anytype,
) WalkError!void {
    if (comptime render.sinkCounts(@TypeOf(sink))) {
        for (items) |item| try writeElem(allocator, sink, item);
        return;
    }

    const encoded = try allocator.alloc([]u8, items.len);
    var built: usize = 0;
    defer {
        for (encoded[0..built]) |element| allocator.free(element);
        allocator.free(encoded);
    }

    for (items) |item| {
        var element: std.ArrayList(u8) = .empty;
        errdefer element.deinit(allocator);
        var element_sink: render.ListSink = .{ .allocator = allocator, .list = &element };
        try writeElem(allocator, &element_sink, item);
        encoded[built] = try element.toOwnedSlice(allocator);
        built += 1;
    }

    std.mem.sort([]u8, encoded, {}, codec_order.lessByteSlice([]u8));
    if (comptime refuse_adjacent_dupes) {
        try codec_order.refuseAdjacentEqualKeys(WalkError, encoded);
    }
    for (encoded) |element| try sink.appendSlice(element);
}
