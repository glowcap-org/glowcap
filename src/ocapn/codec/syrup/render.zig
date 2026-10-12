//! Measure-then-fill storage for Syrup record writers.
//!
//! One generic writer drives both passes. The count pass cannot allocate, the
//! fill pass owns exactly one slice, and a short or long fill is a returned
//! invariant failure rather than uninitialized bytes or an out-of-bounds write.

const std = @import("std");
const WalkError = @import("shared.zig").WalkError;

const CountSink = struct {
    total: usize = 0,

    const counting = true;

    pub fn append(self: *CountSink, byte: u8) error{}!void {
        _ = byte;
        self.total += 1;
    }

    pub fn appendSlice(self: *CountSink, bytes: []const u8) error{}!void {
        self.total += bytes.len;
    }
};

const SliceSink = struct {
    buf: []u8,
    cursor: usize = 0,

    const counting = false;

    pub fn append(self: *SliceSink, byte: u8) error{EncoderInvariantViolation}!void {
        if (self.cursor >= self.buf.len) return error.EncoderInvariantViolation;
        self.buf[self.cursor] = byte;
        self.cursor += 1;
    }

    pub fn appendSlice(self: *SliceSink, bytes: []const u8) error{EncoderInvariantViolation}!void {
        if (self.cursor > self.buf.len or self.buf.len - self.cursor < bytes.len)
            return error.EncoderInvariantViolation;
        @memcpy(self.buf[self.cursor..][0..bytes.len], bytes);
        self.cursor += bytes.len;
    }
};

/// Growable sink used only for canonical-collection emit scratch.
pub const ListSink = struct {
    allocator: std.mem.Allocator,
    list: *std.ArrayList(u8),

    const counting = false;

    pub fn append(self: *ListSink, byte: u8) std.mem.Allocator.Error!void {
        try self.list.append(self.allocator, byte);
    }

    pub fn appendSlice(self: *ListSink, bytes: []const u8) std.mem.Allocator.Error!void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

pub fn sinkCounts(comptime SinkPtr: type) bool {
    return @typeInfo(SinkPtr).pointer.child.counting;
}

/// Render one record with one exact allocation. `writeFn` receives the sink as
/// its first argument and `args` supplies the remainder.
pub fn renderRecordExact(
    allocator: std.mem.Allocator,
    comptime writeFn: anytype,
    args: anytype,
) WalkError![]u8 {
    const storage = try allocator.alloc(u8, try measureRecord(writeFn, args));
    errdefer allocator.free(storage);
    try renderRecordInto(storage, writeFn, args);
    return storage;
}

/// Measure without allocating, so a caller can enforce a storage budget before
/// obtaining a buffer. The same writer must supply the subsequent fill pass.
pub fn measureRecord(comptime writeFn: anytype, args: anytype) WalkError!usize {
    var count: CountSink = .{};
    try @call(.auto, writeFn, .{&count} ++ args);
    return count.total;
}

/// Fill the exact measured buffer. The caller owns the buffer on every outcome.
/// Failed or incomplete output must not be published.
pub fn renderRecordInto(storage: []u8, comptime writeFn: anytype, args: anytype) WalkError!void {
    var fill: SliceSink = .{ .buf = storage };
    try @call(.auto, writeFn, .{&fill} ++ args);
    if (fill.cursor != storage.len) return error.EncoderInvariantViolation;
}
