//! Cap'n Proto wire primitives: the word-aligned substrate the capnp codec
//! builds on. A Cap'n Proto message is a sequence of 8-byte little-endian
//! words grouped into segments; structured data is reached by following
//! pointers (struct / list) that encode a signed word offset to their target.
//!
//! This module knows nothing about pancake's message model — it is the
//! mechanical layer (segment framing, pointer bit-packing, a single-segment
//! builder, bounds-checked word reads). The model mapping lives in `mod.zig`.
//!
//! Reads are endian-explicit (`std.mem.readInt(..., .little)`), so decoding is
//! correct on any host. The builder writes the same way, so encoding is too.

const std = @import("std");

const foundation = @import("../../foundation/mod.zig");

pub const WORD_BYTES: usize = 8;

/// Pointer kind, taken from the low two bits of a pointer word.
pub const PointerKind = enum(u2) {
    @"struct" = 0,
    list = 1,
    far = 2,
    capability = 3,
};

/// List element size, taken from bits 32-34 of a list pointer.
pub const ElementSize = enum(u3) {
    void = 0,
    bit = 1,
    byte = 2,
    two_bytes = 3,
    four_bytes = 4,
    eight_bytes = 5,
    pointer = 6,
    composite = 7,
};

pub const StructPtr = struct {
    /// Signed word offset from the word after the pointer to the struct's data.
    offset: i32,
    data_words: u16,
    ptr_words: u16,
};

pub const ListPtr = struct {
    /// Signed word offset from the word after the pointer to the list content.
    offset: i32,
    elem: ElementSize,
    /// Element count (or, for composite lists, the word count — not used here).
    count: u29,
};

pub fn pointerKind(word: u64) PointerKind {
    return @enumFromInt(@as(u2, @truncate(word)));
}

/// Number of words needed to hold `len` bytes (text/data lists).
pub fn wordsForBytes(len: usize) usize {
    return (len + WORD_BYTES - 1) / WORD_BYTES;
}

pub const CompositeTag = struct {
    element_count: u30,
    data_words: u16,
    ptr_words: u16,
};

/// Decode a composite-list tag word (the first word of a composite list's
/// content): a struct-pointer-shaped word carrying the element count in the
/// offset field plus the per-element section sizes.
pub fn decodeCompositeTag(word: u64) CompositeTag {
    return .{
        .element_count = @truncate(word >> 2),
        .data_words = @truncate(word >> 32),
        .ptr_words = @truncate(word >> 48),
    };
}

pub fn encodeStructPointer(offset: i32, data_words: u16, ptr_words: u16) u64 {
    return offsetBits(offset) |
        (@as(u64, data_words) << 32) |
        (@as(u64, ptr_words) << 48);
}

pub fn decodeStructPointer(word: u64) StructPtr {
    return .{
        .offset = signExtend30(@truncate(word >> 2)),
        .data_words = @truncate(word >> 32),
        .ptr_words = @truncate(word >> 48),
    };
}

pub fn encodeListPointer(offset: i32, elem: ElementSize, count: u29) u64 {
    return @intFromEnum(PointerKind.list) |
        offsetBits(offset) |
        (@as(u64, @intFromEnum(elem)) << 32) |
        (@as(u64, count) << 35);
}

pub fn decodeListPointer(word: u64) ListPtr {
    return .{
        .offset = signExtend30(@truncate(word >> 2)),
        .elem = @enumFromInt(@as(u3, @truncate(word >> 32))),
        .count = @truncate(word >> 35),
    };
}

/// Pack a signed word offset into bits 2-31 (the position shared by struct and
/// list pointers). The low two type bits are left zero for the caller to set.
fn offsetBits(offset: i32) u64 {
    const low30: u30 = @truncate(@as(u32, @bitCast(offset)));
    return @as(u64, low30) << 2;
}

/// Sign-extend a 30-bit two's-complement value to `i32`.
fn signExtend30(value: u30) i32 {
    return @as(i30, @bitCast(value));
}

/// Single-segment Cap'n Proto message builder.
///
/// Words are appended in segment order; pointers are back-patched with an
/// offset computed from their own index. `finish` emits the framed bytes
/// (segment table + segment) as a word-shaped [`foundation.Frame`].
pub const Builder = struct {
    words: std.ArrayList(u64) = .empty,

    pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        self.words.deinit(allocator);
    }

    /// Append `n` zeroed words; return the segment index of the first.
    pub fn allocWords(self: *Builder, allocator: std.mem.Allocator, n: usize) !usize {
        const start = self.words.items.len;
        try self.words.appendNTimes(allocator, 0, n);
        return start;
    }

    pub fn set(self: *Builder, idx: usize, word: u64) void {
        self.words.items[idx] = word;
    }

    /// Signed word offset for a pointer at `ptr_idx` aiming at `target_idx`.
    pub fn offsetTo(ptr_idx: usize, target_idx: usize) i32 {
        return @as(i32, @intCast(target_idx)) - @as(i32, @intCast(ptr_idx)) - 1;
    }

    /// Pack `bytes` little-endian into the words starting at `start_idx`. The
    /// caller must have allocated `wordsForBytes(bytes.len)` words there.
    pub fn setBytes(self: *Builder, start_idx: usize, bytes: []const u8) void {
        for (bytes, 0..) |byte, i| {
            const word = &self.words.items[start_idx + i / WORD_BYTES];
            word.* |= @as(u64, byte) << @intCast((i % WORD_BYTES) * 8);
        }
    }

    /// Tag word for a composite-list element type: a struct-pointer-shaped word
    /// whose "offset" field instead carries the element count.
    pub fn compositeTag(element_count: u30, data_words: u16, ptr_words: u16) u64 {
        return encodeStructPointer(@bitCast(@as(u32, element_count)), data_words, ptr_words);
    }

    /// Emit `segment-count − 1` (u32) ‖ `segment-0 size in words` (u32) ‖
    /// segment words, as a word-shaped owned frame. The frame storage is
    /// 8-byte aligned (allocated as words), satisfying `FrameShape.word`.
    pub fn finish(self: *Builder, allocator: std.mem.Allocator) !foundation.Frame {
        const seg = self.words.items;
        const total = 1 + seg.len;
        const frame_words = try allocator.alloc(u64, total);
        errdefer allocator.free(frame_words);
        const storage = std.mem.sliceAsBytes(frame_words);
        // Single segment: count − 1 = 0 in the low u32, segment size in the high.
        std.mem.writeInt(u64, storage[0..WORD_BYTES], @as(u64, @intCast(seg.len)) << 32, .little);
        for (seg, 0..) |word, i| {
            std.mem.writeInt(u64, storage[(i + 1) * WORD_BYTES ..][0..WORD_BYTES], word, .little);
        }
        return foundation.Frame.initOwned(allocator, storage, .word, .fromByteUnits(WORD_BYTES));
    }
};
