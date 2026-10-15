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

/// Write a symbol the caller received as data, checking it as UTF-8 first.
pub fn writeSymbol(sink: anytype, symbol: []const u8) !void {
    if (!shared.textValid(symbol)) return Error.UnsupportedArgument;
    try sink.appendTerminatedDecimal(symbol.len, '\'');
    try sink.appendSlice(symbol);
}

/// Write a record label glowcap spells itself. The label is checked and its
/// length prefix is formed when the code compiles, so the wire path copies
/// one finished symbol and validates nothing.
pub fn writeLabel(sink: anytype, comptime label: []const u8) !void {
    try sink.appendSlice(comptime spelledLabel(label));
}

/// Open a record glowcap labels itself: the `<` and the finished label land
/// as one slice, the way the decoder matches them as one comparison.
pub fn openRecord(sink: anytype, comptime label: []const u8) !void {
    try sink.appendSlice(comptime "<" ++ spelledLabel(label));
}

/// A label's one canonical form, its width, a quote, and its bytes.
fn spelledLabel(comptime label: []const u8) []const u8 {
    comptime for (label) |byte| std.debug.assert(byte > ' ' and byte < 0x7f);
    return std.fmt.comptimePrint("{d}'{s}", .{ label.len, label });
}

pub fn writeString(sink: anytype, string: []const u8) !void {
    if (!shared.textValid(string)) return Error.UnsupportedArgument;
    try sink.appendTerminatedDecimal(string.len, '"');
    try sink.appendSlice(string);
}

pub fn writeAbortWireString(sink: anytype, abort: model.AbortReason) !void {
    if (abort.kind == .other) return writeString(sink, abort.message);
    if (!shared.textValid(abort.message)) return Error.UnsupportedArgument;
    const label = abort.kind.wireName();
    try sink.appendTerminatedDecimal(label.len + ": ".len + abort.message.len, '"');
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
    try sink.appendTerminatedDecimal(length, ':');
}

pub fn writeInteger(sink: anytype, value: i64) !void {
    try sink.appendTerminatedDecimal(@abs(value), if (value < 0) '-' else '+');
}

pub fn writePositiveInt(sink: anytype, value: u64) !void {
    try sink.appendTerminatedDecimal(value, '+');
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
    try openRecord(sink, "error");
    try writeString(sink, err.message);
    try endRecord(sink);
}
