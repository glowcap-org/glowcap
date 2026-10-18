//! Cap'n Proto builder layout writes for the encoder.
//!
//! This leaf owns word allocation, pointer offsets, and list bounds. It does
//! not know CapTP message semantics or canonical ordering.

const std = @import("std");

const shared = @import("shared.zig");
const wire = shared.wire;

const Error = shared.Error;
const EncodeError = shared.EncodeError;
const StructLoc = shared.StructLoc;

pub const ListContent = struct { data_idx: usize, elem: wire.ElementSize, count: usize };

/// A composite list reserved as one run of words: its tag, then `count`
/// elements of one struct shape.
pub const Composite = struct {
    tag_idx: usize,
    data_words: u16,
    ptr_words: u16,
    count: usize,

    pub fn elem(self: Composite, index: usize) StructLoc {
        std.debug.assert(index < self.count);
        return .{ .data_idx = self.tag_idx + 1 + index * self.stride(), .data_words = self.data_words, .ptr_words = self.ptr_words };
    }

    pub fn content(self: Composite) ListContent {
        return .{ .data_idx = self.tag_idx, .elem = .composite, .count = self.count * self.stride() };
    }

    fn stride(self: Composite) usize {
        return @as(usize, self.data_words) + self.ptr_words;
    }
};

/// Reserve a composite list and write its tag. The tag counts elements in 30
/// bits, so a longer list has no wire form here and is refused whole.
pub fn allocComposite(b: *wire.Builder, allocator: std.mem.Allocator, count: usize, comptime data_words: u16, comptime ptr_words: u16) EncodeError!Composite {
    const element_count = std.math.cast(u30, count) orelse return Error.UnsupportedArgument;
    const body_words = std.math.mul(usize, count, @as(usize, data_words) + ptr_words) catch return Error.UnsupportedArgument;
    const tag_idx = try b.allocWords(allocator, 1 + body_words);
    b.set(tag_idx, wire.Builder.compositeTag(element_count, data_words, ptr_words));
    return .{ .tag_idx = tag_idx, .data_words = data_words, .ptr_words = ptr_words, .count = count };
}

/// Schema dimensions are fixed by the writer, never by the input value.
pub fn allocStruct(b: *wire.Builder, allocator: std.mem.Allocator, comptime data_words: u16, comptime ptr_words: u16) std.mem.Allocator.Error!StructLoc {
    const idx = try b.allocWords(allocator, @as(usize, data_words) + ptr_words);
    return .{ .data_idx = idx, .data_words = data_words, .ptr_words = ptr_words };
}

pub fn ptrIndex(loc: StructLoc, i: u16) usize {
    return loc.data_idx + loc.data_words + i;
}

pub fn setStructPtr(b: *wire.Builder, ptr_idx: usize, loc: StructLoc) void {
    b.set(ptr_idx, wire.encodeStructPointer(wire.Builder.offsetTo(ptr_idx, loc.data_idx), loc.data_words, loc.ptr_words));
}

/// A Cap'n Proto list pointer carries its element count in 29 bits. Longer
/// lists have no wire form in this codec, so refusal preserves the original
/// value instead of truncating the pointer in fast builds.
pub fn setListPtr(b: *wire.Builder, ptr_idx: usize, content: ListContent) EncodeError!void {
    if (content.count > wire.max_list_elements) return Error.UnsupportedArgument;
    b.set(ptr_idx, wire.encodeListPointer(wire.Builder.offsetTo(ptr_idx, content.data_idx), content.elem, @intCast(content.count)));
}

pub fn setData(b: *wire.Builder, allocator: std.mem.Allocator, loc: StructLoc, i: u16, bytes: []const u8) EncodeError!void {
    const start = try b.allocWords(allocator, wire.wordsForBytes(bytes.len));
    b.setBytes(start, bytes);
    try setListPtr(b, ptrIndex(loc, i), .{ .data_idx = start, .elem = .byte, .count = bytes.len });
}
