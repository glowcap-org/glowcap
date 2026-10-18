const std = @import("std");
const glowcap = @import("glowcap");

const frame_support = @import("../support/frame.zig");
const foundation = glowcap.foundation;

test "frame owns a copy of caller bytes" {
    const allocator = std.testing.allocator;
    var caller_bytes = [_]u8{ 0x70, 0x6e, 0x63, 0x6b };

    var frame = try frame_support.copyFromBorrowed(allocator, caller_bytes[0..], .byte);
    defer frame.deinit();

    caller_bytes[0] = 0xff;

    try std.testing.expectEqual(foundation.FrameShape.byte, frame.shape);
    try std.testing.expectEqualSlices(u8, &.{ 0x70, 0x6e, 0x63, 0x6b }, frame.bytes());
}

test "owned frame adopts caller storage without copying" {
    const allocator = std.testing.allocator;
    const storage = try allocator.alloc(u8, 4);
    const payload = [_]u8{ 0x70, 0x6e, 0x63, 0x6b };
    @memcpy(storage, payload[0..]);
    const storage_ptr = @intFromPtr(storage.ptr);

    var frame = try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));
    defer frame.deinit();

    try std.testing.expectEqual(storage_ptr, @intFromPtr(frame.bytes().ptr));
    try std.testing.expectEqualSlices(u8, &.{ 0x70, 0x6e, 0x63, 0x6b }, frame.bytes());
}

test "owned byte frame frees with caller-provided allocation alignment" {
    const allocator = std.testing.allocator;
    const storage = try allocator.alignedAlloc(u8, .fromByteUnits(8), 8);
    @memcpy(storage, &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 });

    var frame = try foundation.Frame.initOwned(
        allocator,
        storage,
        .byte,
        .fromByteUnits(8),
    );
    defer frame.deinit();

    try std.testing.expectEqual(foundation.FrameShape.byte, frame.shape);
    try std.testing.expectEqual(@intFromPtr(storage.ptr), @intFromPtr(frame.bytes().ptr));
}

test "external frame owner releases without copying storage" {
    const Context = struct {
        released: bool = false,
    };
    const Release = struct {
        var calls: usize = 0;

        fn release(context: *anyopaque) void {
            const ctx: *Context = @ptrCast(@alignCast(context));
            calls += 1;
            ctx.released = true;
        }
    };

    var storage = [_]u8{ 1, 2, 3, 4 };
    var ctx = Context{};
    var frame = try foundation.Frame.initExternal(
        storage[0..],
        .byte,
        &ctx,
        Release.release,
    );

    try std.testing.expectEqual(@intFromPtr(storage[0..].ptr), @intFromPtr(frame.bytes().ptr));
    frame.deinit();
    try std.testing.expectEqual(@as(usize, 1), Release.calls);
    try std.testing.expect(ctx.released);
}

test "frame view borrows the same bytes without copying" {
    const allocator = std.testing.allocator;
    const storage = try allocator.dupe(u8, &.{ 1, 2, 3, 4 });
    var frame = try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));
    defer frame.deinit();

    const view = frame.view();

    try std.testing.expectEqual(foundation.FrameShape.byte, view.shape);
    try std.testing.expectEqual(@intFromPtr(frame.bytes().ptr), @intFromPtr(view.bytes.ptr));
    try std.testing.expectEqual(frame.bytes().len, view.bytes.len);
}

test "word frame shape is visible on owned frame and borrowed view" {
    const allocator = std.testing.allocator;
    const storage = try allocator.alignedAlloc(u8, .fromByteUnits(8), 8);
    const payload = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    @memcpy(storage, payload[0..]);
    var frame = try foundation.Frame.initOwned(allocator, storage, .word, .fromByteUnits(8));
    defer frame.deinit();

    const view = frame.view();

    try std.testing.expectEqual(foundation.FrameShape.word, frame.shape);
    try std.testing.expectEqual(foundation.FrameShape.word, view.shape);
    try std.testing.expectEqual(@as(usize, 8), view.bytes.len);
}

test "word frame rejects non-word-sized payloads" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        foundation.Frame.Error.InvalidFrameShape,
        frame_support.copyFromBorrowed(allocator, &.{ 1, 2, 3 }, .word),
    );
}

test "initOwned frees the storage when the shape is refused" {
    // Ownership transfer is unconditional: the testing allocator's leak check
    // proves the refused storage was freed here, not left with the caller.
    const allocator = std.testing.allocator;
    const storage = try allocator.alloc(u8, 3);

    try std.testing.expectError(
        foundation.Frame.Error.InvalidFrameShape,
        foundation.Frame.initOwned(allocator, storage, .word, .fromByteUnits(1)),
    );
}

test "initExternal releases the storage when the shape is refused" {
    const Context = struct {
        released: bool = false,
    };
    const Release = struct {
        var calls: usize = 0;

        fn release(context: *anyopaque) void {
            const ctx: *Context = @ptrCast(@alignCast(context));
            calls += 1;
            ctx.released = true;
        }
    };

    var storage = [_]u8{ 1, 2, 3 };
    var ctx = Context{};

    try std.testing.expectError(
        foundation.Frame.Error.InvalidFrameShape,
        foundation.Frame.initExternal(storage[0..], .word, &ctx, Release.release),
    );
    try std.testing.expectEqual(@as(usize, 1), Release.calls);
    try std.testing.expect(ctx.released);
}

test "empty frames are valid borrowed views" {
    const allocator = std.testing.allocator;
    const storage = try allocator.alloc(u8, 0);
    var frame = try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));
    defer frame.deinit();

    const view = frame.view();

    try std.testing.expectEqual(@as(usize, 0), frame.bytes().len);
    try std.testing.expectEqual(@as(usize, 0), view.bytes.len);
}

test "a headed frame keeps its head beside shape-aligned bytes in one block" {
    const allocator = std.testing.allocator;
    const Head = struct { words: [5]u64 };
    var frame = try foundation.Frame.initHeaded(allocator, Head, u64, 0, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }, .word);
    defer frame.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, frame.bytes());
    try std.testing.expect(std.mem.Alignment.fromByteUnits(8).check(@intFromPtr(frame.bytes().ptr)));
    const head = frame.head(Head).?;
    head.words = .{ 9, 9, 9, 9, 9 };
    try std.testing.expectEqual(@as(u64, 9), frame.head(Head).?.words[4]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, frame.bytes());
    try std.testing.expect(frame.head(u8) == null);
}

test "a headed frame refuses a shape its bytes do not fit and frees the block" {
    try std.testing.expectError(
        error.InvalidFrameShape,
        foundation.Frame.initHeaded(std.testing.allocator, u64, u64, 0, &[_]u8{ 1, 2, 3 }, .word),
    );
}

test "a plain owned frame carries no head" {
    const allocator = std.testing.allocator;
    const storage = try allocator.dupe(u8, "abc");
    var frame = try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));
    defer frame.deinit();
    try std.testing.expect(frame.head(u8) == null);
}

test "a headed frame hands its head only to the type it was built for" {
    const allocator = std.testing.allocator;
    const Built = struct { words: [2]u64 };
    const Other = struct { halves: [4]u32 };
    comptime std.debug.assert(@sizeOf(Built) == @sizeOf(Other));
    var frame = try foundation.Frame.initHeaded(allocator, Built, u64, 0, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }, .word);
    defer frame.deinit();
    try std.testing.expect(frame.head(Built) != null);
    try std.testing.expect(frame.head(Other) == null);
}

test "headed frame refuses an overflowing tail before allocation" {
    var refusing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    inline for (.{ foundation.FrameShape.byte, foundation.FrameShape.word }) |shape| {
        try std.testing.expectError(
            error.OutOfMemory,
            foundation.Frame.initHeaded(refusing.allocator(), u64, u64, std.math.maxInt(usize), "", shape),
        );
    }
    try std.testing.expect(!refusing.has_induced_failure);
}

test "headed frame sizing refuses addition overflow and unrepresentable metadata" {
    const Frame = foundation.Frame;
    inline for (.{ foundation.FrameShape.byte, foundation.FrameShape.word }) |shape| {
        // The tail product fits, but adding the head does not.
        try std.testing.expectError(error.OutOfMemory, Frame.headedBlockLen(u64, u8, std.math.maxInt(usize), 0, shape));
        // The head fits its metadata, but adding the wire bytes does not.
        try std.testing.expectError(error.OutOfMemory, Frame.headedBlockLen(u64, u64, 0, std.math.maxInt(usize), shape));
        try std.testing.expectError(error.OutOfMemory, Frame.headedBlockLen(u64, u8, std.math.maxInt(u16), 0, shape));
    }
    // Byte heads can fill all sixteen bits. Word heads must leave room for
    // alignment, including when only the padding would cross the limit.
    try std.testing.expectEqual(@as(usize, 65535), try Frame.headedBlockLen(u8, u8, 65534 - @sizeOf(usize), 0, .byte));
    try std.testing.expectEqual(@as(usize, 65528), try Frame.headedBlockLen(u8, u8, 65527 - @sizeOf(usize), 0, .word));
    try std.testing.expectError(error.OutOfMemory, Frame.headedBlockLen(u8, u8, 65528 - @sizeOf(usize), 0, .word));
}

test "headed frame sizing matches aligned storage and its writable tail" {
    const Head = struct { value: u8 };
    inline for (.{ foundation.FrameShape.byte, foundation.FrameShape.word }) |shape| {
        var counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var frame = try foundation.Frame.initHeaded(counter.allocator(), Head, u64, 3, "abcdefgh", shape);
        defer frame.deinit();
        frame.head(Head).?.value = 7;
        const tail = frame.headTail(Head, u64);
        try std.testing.expectEqual(@as(usize, 3), tail.len);
        @memset(tail, 9);
        try std.testing.expectEqual(try foundation.Frame.headedBlockLen(Head, u64, 3, 8, shape), counter.allocated_bytes);
        try std.testing.expectEqual(@as(u8, 7), frame.head(Head).?.value);
        try std.testing.expectEqualStrings("abcdefgh", frame.bytes());
    }
}

fn CollisionHead(comptime identity: usize) type {
    return struct {
        value: u64,
        const id = identity;
    };
}

test "headed frames distinguish types with colliding short name hashes" {
    const Built = CollisionHead(139);
    const Other = CollisionHead(2304);
    // Keep this fixture adversarial: equal truncated hashes must not make
    // these distinct types interchangeable.
    try std.testing.expectEqual(
        @as(u16, @truncate(std.hash.Fnv1a_32.hash(@typeName(Built)))),
        @as(u16, @truncate(std.hash.Fnv1a_32.hash(@typeName(Other)))),
    );
    var frame = try foundation.Frame.initHeaded(std.testing.allocator, Built, u64, 0, "", .byte);
    defer frame.deinit();
    try std.testing.expect(frame.head(Built) != null);
    try std.testing.expect(frame.head(Other) == null);
}

test "headed frames align an over-aligned head independently of wire shape" {
    const Head = struct { value: u8 align(32) };
    inline for (.{ foundation.FrameShape.byte, foundation.FrameShape.word }) |shape| {
        var frame = try foundation.Frame.initHeaded(std.testing.allocator, Head, u64, 1, "abcdefgh", shape);
        defer frame.deinit();
        const head = frame.head(Head).?;
        try std.testing.expect(std.mem.Alignment.of(Head).check(@intFromPtr(head)));
        head.value = 7;
        frame.headTail(Head, u64)[0] = 9;
        try std.testing.expectEqual(@as(u8, 7), head.value);
        try std.testing.expectEqualStrings("abcdefgh", frame.bytes());
    }
}

test "headed frames with zero-sized heads and empty wire retain type identity" {
    var frame = try foundation.Frame.initHeaded(std.testing.allocator, void, u64, 0, "", .byte);
    defer frame.deinit();
    try std.testing.expect(frame.head(void) != null);
    try std.testing.expect(frame.head(u8) == null);
    try std.testing.expectEqual(@as(usize, 0), frame.headTail(void, u64).len);
    try std.testing.expectEqual(@as(usize, 0), frame.bytes().len);
}

test "headed frames refuse a tail type other than the one allocated" {
    const Head = struct { value: u8 };
    var frame = try foundation.Frame.initHeaded(std.testing.allocator, Head, u64, 3, "", .byte);
    defer frame.deinit();
    try std.testing.expectEqual(@as(usize, 3), frame.headTail(Head, u64).len);
    try std.testing.expectEqual(@as(usize, 0), frame.headTail(Head, u128).len);
}

test "headed frames distinguish separate modules with equal type names" {
    const Built = @import("frame_identity_left").Head;
    const Other = @import("frame_identity_right").Head;
    try std.testing.expect(Built != Other);
    try std.testing.expectEqualStrings(@typeName(Built), @typeName(Other));
    var frame = try foundation.Frame.initHeaded(std.testing.allocator, Built, u64, 0, "", .byte);
    defer frame.deinit();
    try std.testing.expect(frame.head(Built) != null);
    try std.testing.expect(frame.head(Other) == null);
}
