const std = @import("std");
const pancake = @import("pancake");

const frame_support = @import("../support/frame.zig");
const foundation = pancake.foundation;

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
