//! Syrup sizes of an outbound tree's values, measured where the session
//! walks it.
//!
//! An encode measures its record before it fills the one exact buffer
//! (`render.zig`). The session already walks every outbound tree once at
//! admission (`session/inventory.zig`), so that walk takes this meter and
//! the encode's count pass walks the envelope alone. The meter sizes each
//! value with the writer that fills it and checks nothing: the fill pass
//! refuses an invalid text or digit string before any byte is published,
//! and a drift between meter and writer is a returned
//! `EncoderInvariantViolation`, never a short or long frame.

const std = @import("std");

const model = @import("model");

const encode = @import("encode.zig");
const render = @import("render.zig");
const scalar = @import("scalar.zig");

const WalkError = @import("shared.zig").WalkError;

/// The bytes a value encodes to outside its children, its struct keys, and
/// the reference or handoff it may be. `argument` is an owned
/// `model.Argument` or a borrowed `view.Argument`: the arms the two share
/// are sized alike.
pub inline fn shallow(argument: anytype) usize {
    return switch (argument) {
        inline else => |*payload, tag| shallowOf(tag, payload),
    };
}

/// `shallow` for one kind known at compile time, with the payload read where
/// it lies: the walk dispatches on the tag once for every measure. The tag
/// is the owned tree's or the borrowed one's (`model.view.Argument`), which
/// name the same kinds.
pub inline fn shallowOf(comptime tag: anytype, payload: anytype) usize {
    return switch (tag) {
        .bytes => size(scalar.writeBytes, .{payload.*}),
        .symbol => size(scalar.writeText, .{ payload.*, '\'' }),
        .string => size(scalar.writeText, .{ payload.*, '"' }),
        .keyword => size(scalar.openRecord, .{"kw"}) + size(scalar.writeText, .{ payload.*, '\'' }) + 1,
        .integer => size(scalar.writeInteger, .{payload.*}),
        .big_integer => size(scalar.writeDigits, .{payload.*}),
        .float64 => size(scalar.writeFloat64, .{payload.*}),
        .boolean => size(scalar.writeBool, .{payload.*}),
        .void => size(scalar.openRecord, .{"void"}) + 1,
        .@"error" => size(scalar.openRecord, .{"error"}) + size(scalar.writeText, .{ payload.message, '"' }) + 1,
        .tagged => size(scalar.openRecord, .{"user-record"}) + size(scalar.writeText, .{ payload.tag, '\'' }) + "[]>".len,
        // Two delimiters each; a struct's keys are `key`, between its values.
        .list, .set, .@"struct" => 2,
        // Lowered after the walk and sized by `mention` at encode.
        .reference, .handoff => 0,
    };
}

/// A struct key's bytes, which sit between the entries' values.
pub inline fn key(text: []const u8) usize {
    return size(scalar.writeText, .{ text, '"' });
}

/// The bytes a listed slot's mention encodes to: a reference or handoff as
/// `encode.writeArgument` writes it, and nothing for a set, whose delimiters
/// `shallow` sized. Measured at encode, after lowering fixed the positions
/// whose decimal widths the walk could not know.
pub fn mention(allocator: std.mem.Allocator, argument: *const model.Argument) WalkError!usize {
    return switch (argument.*) {
        .reference => |*reference| render.measureRecord(writeReference, .{ allocator, reference }),
        .handoff => |handoff| render.measureRecord(writeHandoff, .{ allocator, try model.view.borrowHandoff(handoff) }),
        else => 0,
    };
}

/// The mention writers take the sink after the allocator; `render` hands
/// the sink first.
fn writeReference(sink: anytype, allocator: std.mem.Allocator, reference: *const model.Reference) WalkError!void {
    try encode.writePayloadReference(allocator, sink, reference);
}

fn writeHandoff(sink: anytype, allocator: std.mem.Allocator, handoff: model.view.Handoff) WalkError!void {
    try encode.writeHandoff(allocator, sink, handoff);
}

/// The width a scalar writer gives the count sink. These writers take a
/// text, digits, or a number and refuse nothing.
inline fn size(comptime writeFn: anytype, args: anytype) usize {
    return render.measureRecord(writeFn, args) catch unreachable;
}
