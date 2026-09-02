//! The word-aligned plumbing the Cap'n Proto codec sits on.
//!
//! A Cap'n Proto message is a run of 8-byte little-endian words, grouped into
//! segments. You reach structured data by following pointers, struct or list,
//! each of which packs a signed word offset to whatever it points at.
//!
//! Nothing in this file knows about glowcap's messages. It's purely mechanical:
//! framing segments, packing and unpacking pointer bits, a small single-segment
//! builder, and bounds-checked word reads. Mapping all of that onto the model is
//! `decode.zig` and `encode.zig`'s job.
//!
//! Every read names its endianness (`std.mem.readInt(..., .little)`), so decoding
//! comes out right on any host, and the builder writes the same way, so encoding
//! does too.

const std = @import("std");

const foundation = @import("foundation");

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
    /// Element count (or, for composite lists, the word count, not used here).
    count: u29,
};

pub fn pointerKind(word: u64) PointerKind {
    return @fromBackingInt(@intCast(@as(u2, @truncate(word))));
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

/// The widest element count a list pointer can carry: the wire field is 29 bits.
pub const max_list_elements: usize = std.math.maxInt(u29);

pub fn encodeListPointer(offset: i32, elem: ElementSize, count: u29) u64 {
    return @backingInt(PointerKind.list) |
        offsetBits(offset) |
        (@as(u64, @backingInt(elem)) << 32) |
        (@as(u64, count) << 35);
}

pub fn decodeListPointer(word: u64) ListPtr {
    return .{
        .offset = signExtend30(@truncate(word >> 2)),
        .elem = @fromBackingInt(@intCast(@as(u3, @truncate(word >> 32)))),
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
/// The backing list begins with the one-word segment table, followed by words
/// appended in segment order. Pointers are back-patched with an offset computed
/// from their physical index; the leading table shifts every segment index by
/// the same amount, so those relative offsets remain the Cap'n Proto offsets.
///
/// Capacity precondition: the builder encodes a message that fits the wire
/// format's structural limits — a segment under 2^32 words, list word-counts
/// under 2^29, and composite element-counts under 2^30. Those bounds are what the
/// pointer fields can express, and the length casts in `offsetTo`,
/// `compositeTag`, `setListPtr`, and the two finish methods assume them. A
/// `model.Message` reaching those limits is on the order of tens of gigabytes — not constructible
/// in practice (it would exhaust memory first) and never produced by decode,
/// which bounds an inbound frame to `max_frame_bytes`. The casts therefore name a
/// precondition the local caller is responsible for, not an attacker-reachable
/// path; the inbound side is bounds-checked separately in the decoder.
pub const Builder = struct {
    /// The segment table sits in the backing list rather than in a second
    /// buffer, so `finishOwned` hands the whole allocation to the frame.
    pub const frame_header_words: usize = 1;

    /// Words reserved when a builder is created, the header plus room for an
    /// ordinary control message's segment. Encoding every arm the cross-codec
    /// equivalence corpus carries measured at most 37 words for a message with
    /// no bulk payload, so this clears them with headroom and `encodeMessage`
    /// costs one allocation, the count `test/codec/encode_budget_test.zig`
    /// holds. The two larger arms carry payloads and grow whatever the
    /// reservation is.
    ///
    /// Reserving here is also what keeps that first allocation a decision.
    /// `std.ArrayList` sizes its own first growth from a false-sharing
    /// cache-line constant, which varies by target and landed one word under
    /// this framing's small-message size. Falling one word short is expensive
    /// rather than neutral: the growth realloc and its copy cost the encoder
    /// about 40% on `zig build bench-codec`, so raising this constant is a
    /// cheaper mistake than lowering it.
    pub const initial_words: usize = 48;

    /// No default, so a builder cannot be created without its header word.
    words: std.ArrayList(u64),

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Builder {
        var words: std.ArrayList(u64) = .empty;
        errdefer words.deinit(allocator);
        try words.ensureTotalCapacityPrecise(allocator, initial_words);
        words.appendNTimesAssumeCapacity(0, frame_header_words);
        return .{ .words = words };
    }

    pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        self.words.deinit(allocator);
    }

    /// Append `n` zeroed words; return the segment index of the first.
    pub fn allocWords(self: *Builder, allocator: std.mem.Allocator, n: usize) !usize {
        std.debug.assert(self.words.items.len >= frame_header_words);
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

    /// Hand the builder's own allocation to the frame. The segment table is
    /// already word zero, so there is no second buffer and no copy of the
    /// encoded bytes. Ownership transfers before the framing is written, so a
    /// refusal leaves the builder exactly as it was.
    ///
    /// `toOwnedSlice` trims the growable buffer's spare capacity, which the
    /// allocators glowcap ships against do in place. One that cannot falls back
    /// to `std`'s allocate-and-copy, the same cost this method replaced.
    pub fn finishOwned(self: *Builder, allocator: std.mem.Allocator) !foundation.Frame {
        std.debug.assert(self.words.items.len >= frame_header_words);
        const frame_words = try self.words.toOwnedSlice(allocator);
        errdefer allocator.free(frame_words);
        return frameFromOwnedWords(allocator, frame_words);
    }

    /// Copy a framed snapshot while leaving the builder live. Canonical set
    /// ordering needs both halves: the snapshot bytes are the sort key, and the
    /// live builder still holds the encoded subgraph that is grafted afterward.
    pub fn finishCopying(self: *const Builder, allocator: std.mem.Allocator) !foundation.Frame {
        std.debug.assert(self.words.items.len >= frame_header_words);
        const frame_words = try allocator.alloc(u64, self.words.items.len);
        errdefer allocator.free(frame_words);
        @memcpy(frame_words[frame_header_words..], self.words.items[frame_header_words..]);
        return frameFromOwnedWords(allocator, frame_words);
    }

    /// Write the single-segment table into word zero and render the segment
    /// little-endian in place, then adopt the words as a word-shaped frame. The
    /// storage is 8-byte aligned because it was allocated as words, which is
    /// what `FrameShape.word` requires.
    fn frameFromOwnedWords(allocator: std.mem.Allocator, frame_words: []u64) !foundation.Frame {
        const segment_words = frame_words.len - frame_header_words;
        // Single segment: count - 1 = 0 in the low u32, segment size in the high.
        frame_words[0] = std.mem.nativeToLittle(u64, @as(u64, @intCast(segment_words)) << 32);
        for (frame_words[frame_header_words..]) |*word| {
            word.* = std.mem.nativeToLittle(u64, word.*);
        }
        const storage = std.mem.sliceAsBytes(frame_words);
        return foundation.Frame.initOwned(allocator, storage, .word, .fromByteUnits(WORD_BYTES));
    }
};
