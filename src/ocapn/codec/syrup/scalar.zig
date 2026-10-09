//! Syrup scalar and delimiter writers shared by message and signing records.

const std = @import("std");

const model = @import("model");
const shared = @import("shared.zig");

const Error = shared.Error;
const WalkError = shared.WalkError;

pub fn beginRecord(sink: anytype) !void {
    try sink.append('<');
}

pub fn endRecord(sink: anytype) !void {
    try sink.append('>');
}

pub fn beginList(sink: anytype) !void {
    try sink.append('[');
}

pub fn endList(sink: anytype) !void {
    try sink.append(']');
}

pub fn writeSymbol(sink: anytype, symbol: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(symbol)) return Error.UnsupportedArgument;
    try writeUnsigned(sink, symbol.len);
    try sink.append('\'');
    try sink.appendSlice(symbol);
}

pub fn writeString(sink: anytype, string: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(string)) return Error.UnsupportedArgument;
    try writeUnsigned(sink, string.len);
    try sink.append('"');
    try sink.appendSlice(string);
}

pub fn writeAbortWireString(sink: anytype, abort: model.AbortReason) !void {
    if (abort.kind == .other) return writeString(sink, abort.message);
    if (!std.unicode.utf8ValidateSlice(abort.message)) return Error.UnsupportedArgument;
    const label = abort.kind.wireName();
    try writeUnsigned(sink, label.len + ": ".len + abort.message.len);
    try sink.append('"');
    try sink.appendSlice(label);
    try sink.appendSlice(": ");
    try sink.appendSlice(abort.message);
}

pub fn writeBytes(sink: anytype, bytes: []const u8) !void {
    try writeBytesPrefix(sink, bytes.len);
    try sink.appendSlice(bytes);
}

/// Length-only measurement shares the emitted prefix and never reads a payload.
pub fn byteStringSize(length: usize) error{Overflow}!usize {
    const prefix = @import("render.zig").measureRecord(writeBytesPrefix, .{length}) catch unreachable;
    return std.math.add(usize, prefix, length);
}

fn writeBytesPrefix(sink: anytype, length: usize) !void {
    try writeUnsigned(sink, length);
    try sink.append(':');
}

pub fn writeInteger(sink: anytype, value: i64) !void {
    if (value < 0) {
        try writeSignedMagnitude(sink, value);
        try sink.append('-');
    } else {
        try writePositiveInt(sink, @intCast(value));
    }
}

pub fn writePositiveInt(sink: anytype, value: u64) !void {
    try writeUnsigned(sink, value);
    try sink.append('+');
}

pub fn writeBool(sink: anytype, value: bool) !void {
    try sink.append(if (value) 't' else 'f');
}

/// Syrup binary64 is `D` followed by eight big-endian IEEE-754 bytes.
pub fn writeFloat64(sink: anytype, value: f64) !void {
    try sink.append('D');
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, @bitCast(value), .big);
    try sink.appendSlice(&buf);
}

pub fn writeUnsignedList(sink: anytype, values: []const u64) !void {
    try beginList(sink);
    for (values) |value| try writePositiveInt(sink, value);
    try endList(sink);
}

pub fn writeIntegerValue(sink: anytype, integer: model.Integer) WalkError!void {
    switch (integer) {
        .integer => |value| try writeInteger(sink, value),
        .big_integer => |big| try writeBigInteger(sink, big),
    }
}

pub fn writeBigInteger(sink: anytype, big: model.BigInteger) WalkError!void {
    if (!big.isCanonical()) return Error.UnsupportedArgument;
    try sink.appendSlice(big.digits);
    try sink.append(if (big.negative) '-' else '+');
}

pub fn writeError(sink: anytype, err: model.BreakReason) !void {
    try beginRecord(sink);
    try writeSymbol(sink, "error");
    try writeString(sink, err.message);
    try endRecord(sink);
}

fn writeUnsigned(sink: anytype, value: anytype) !void {
    var buf: [20]u8 = undefined;
    try sink.appendSlice(formatDecimal(&buf, value));
}

fn formatDecimal(buf: *[20]u8, value: anytype) []const u8 {
    var remaining: u64 = value;
    if (remaining == 0) {
        buf[19] = '0';
        return buf[19..20];
    }
    var i: usize = buf.len;
    while (remaining > 0) {
        i -= 1;
        buf[i] = @intCast((remaining % 10) + '0');
        remaining /= 10;
    }
    return buf[i..];
}

fn writeSignedMagnitude(sink: anytype, value: i64) !void {
    const magnitude: u64 = if (value == std.math.minInt(i64))
        @as(u64, 1) << 63
    else
        @intCast(-value);
    try writeUnsigned(sink, magnitude);
}
