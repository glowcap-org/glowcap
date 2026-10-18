//! Measure-then-fill storage for Syrup record writers.
//!
//! One generic writer drives both passes. The count pass allocates nothing
//! for a tree of owned or parsed values (a lazy codec hint list is the one
//! exception, named at `signing.writePeerLocatorRecord`), the fill pass owns
//! exactly one slice, and a short or long fill is a returned invariant failure
//! rather than uninitialized bytes or an out-of-bounds write.
//!
//! A caller that already measured the message's value tree, the session's
//! admission walk with this codec's meter (`meter.zig`), hands that measure
//! to `renderRecordExactSized`: the count pass then walks the envelope alone,
//! and the fill is the one pass that reads the tree.
//!
//! A sink takes a byte, a slice, or a decimal with its delimiter. The decimal is its own verb
//! because every length prefix and position is one: the count pass measures
//! its width without forming digits, and the fill pass writes them in place.

const std = @import("std");
const decimal = @import("foundation").decimal;
const WalkError = @import("shared.zig").WalkError;

const CountSink = struct {
    total: usize = 0,
    /// Bytes the caller measured for the message's value tree, which the
    /// message writer takes in place of walking that tree
    /// (`encode.writeDeliverArguments`, `encode.writeFulfillment`), and
    /// whether it took them: a message with no tree takes nothing.
    known_values: ?usize = null,
    took_values: bool = false,

    const counting = true;

    /// Take the bytes the caller measured for the value tree in place of
    /// walking it. False when this pass measures the tree itself.
    pub fn takeMeasured(self: *CountSink) bool {
        const values = self.known_values orelse return false;
        self.total += values;
        self.took_values = true;
        return true;
    }

    pub inline fn append(self: *CountSink, byte: u8) error{}!void {
        _ = byte;
        self.total += 1;
    }

    pub inline fn appendSlice(self: *CountSink, bytes: []const u8) error{}!void {
        self.total += bytes.len;
    }

    /// Reserve the digits and their Syrup delimiter together.
    pub inline fn appendTerminatedDecimal(self: *CountSink, value: u64, suffix: u8) error{}!void {
        _ = suffix;
        self.total += decimal.width(value) + 1;
    }
};

const SliceSink = struct {
    buf: []u8,
    cursor: usize = 0,

    const counting = false;

    pub inline fn append(self: *SliceSink, byte: u8) error{EncoderInvariantViolation}!void {
        if (self.cursor >= self.buf.len) return error.EncoderInvariantViolation;
        self.buf[self.cursor] = byte;
        self.cursor += 1;
    }

    pub inline fn appendSlice(self: *SliceSink, bytes: []const u8) error{EncoderInvariantViolation}!void {
        if (self.cursor > self.buf.len or self.buf.len - self.cursor < bytes.len)
            return error.EncoderInvariantViolation;
        @memcpy(self.buf[self.cursor..][0..bytes.len], bytes);
        self.cursor += bytes.len;
    }

    /// Reserve the digits and their Syrup delimiter together.
    pub inline fn appendTerminatedDecimal(self: *SliceSink, value: u64, suffix: u8) error{EncoderInvariantViolation}!void {
        const width = decimal.width(value);
        if (self.cursor > self.buf.len or self.buf.len - self.cursor < width + 1)
            return error.EncoderInvariantViolation;
        decimal.fill(self.buf[self.cursor..][0..width], value);
        self.buf[self.cursor + width] = suffix;
        self.cursor += width + 1;
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

    /// Reserve the digits and their Syrup delimiter together.
    pub fn appendTerminatedDecimal(self: *ListSink, value: u64, suffix: u8) std.mem.Allocator.Error!void {
        const width = decimal.width(value);
        const bytes = try self.list.addManyAsSlice(self.allocator, width + 1);
        decimal.fill(bytes[0..width], value);
        bytes[width] = suffix;
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

/// `renderRecordExact` for a message whose value tree the caller measured:
/// `values` is what that tree encodes to, and the count pass walks the
/// envelope alone. The fill pass holds the sum, and a message with no tree
/// holds `values` to zero: a measure that disagrees with the writer is a
/// returned `EncoderInvariantViolation`.
pub fn renderRecordExactSized(
    allocator: std.mem.Allocator,
    values: usize,
    comptime writeFn: anytype,
    args: anytype,
) WalkError![]u8 {
    var count: CountSink = .{ .known_values = values };
    try @call(.auto, writeFn, .{&count} ++ args);
    if (!count.took_values and values != 0) return error.EncoderInvariantViolation;
    const storage = try allocator.alloc(u8, count.total);
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
