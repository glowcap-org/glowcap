//! Borrowed Syrup `desc:sig-envelope` projection and owned give materialization.

const std = @import("std");

const model = @import("model");

const shared = @import("../../shared.zig");
const syntax = @import("../syntax.zig");
const locators = @import("../locator.zig");

const Error = shared.Error;

fn readBorrowedSignedHandoff(bytes: []const u8, cursor: *usize) Error!model.view.Handoff {
    const envelope_start = cursor.*;
    try syntax.readByte(bytes, cursor, '<');
    const envelope_tag = try syntax.readLabel(bytes, cursor);
    if (!std.mem.eql(u8, envelope_tag, "desc:sig-envelope")) return Error.MalformedFrame;
    return finishSignedHandoff(bytes, cursor, envelope_start);
}

/// Project a `<desc:sig-envelope …>` the decoder framed structurally.
/// `Ctx.bytes` is the whole envelope, so a give's signed span is the region.
pub fn projectSignedHandoff(ctx: model.view.LazyHandoff.Ctx) model.view.ProjectError!model.view.Handoff {
    var cursor: usize = 0;
    const projected = readBorrowedSignedHandoff(ctx.bytes, &cursor) catch return error.MalformedView;
    if (cursor != ctx.bytes.len) return error.MalformedView;
    return projected;
}

/// Finish a `<desc:sig-envelope …>` whose opening `<` and label are already
/// consumed. `envelope_start` lets a give borrow its whole signed byte span.
fn finishSignedHandoff(bytes: []const u8, cursor: *usize, envelope_start: usize) Error!model.view.Handoff {
    try syntax.readByte(bytes, cursor, '<');
    const payload_tag = try syntax.readLabel(bytes, cursor);

    if (std.mem.eql(u8, payload_tag, "desc:handoff-give")) {
        var give = try readBorrowedGivePayload(bytes, cursor);
        try syntax.readByte(bytes, cursor, '>');
        const sig = try syntax.readSignatureView(bytes, cursor);
        give.signature = .{ .halves = .{ .r = sig.r, .s = sig.s } };
        try syntax.readByte(bytes, cursor, '>');
        give.raw_signed = bytes[envelope_start..cursor.*];
        return .{ .give = give };
    }

    if (std.mem.eql(u8, payload_tag, "desc:handoff-receive")) {
        var receive = try readBorrowedReceivePayload(bytes, cursor);
        try syntax.readByte(bytes, cursor, '>');
        const sig = try syntax.readSignatureView(bytes, cursor);
        receive.signature = .{ .halves = .{ .r = sig.r, .s = sig.s } };
        try syntax.readByte(bytes, cursor, '>');
        return .{ .receive = receive };
    }

    return Error.UnsupportedMessage;
}

fn readBorrowedGivePayload(bytes: []const u8, cursor: *usize) Error!model.view.HandoffGive {
    const recipient_key = try syntax.readPeerKeyQ(bytes, cursor);
    const locator = try locators.readPeerLocatorView(bytes, cursor);
    const gifter_exporter_session = try syntax.readBytes(bytes, cursor);
    const gifter_side = try syntax.readBytes(bytes, cursor);
    const gift_id = try syntax.readBytes(bytes, cursor);
    return .{
        .recipient_key = recipient_key,
        .exporter = locator,
        .gifter_exporter_session = gifter_exporter_session,
        .gifter_side = gifter_side,
        .gift_id = gift_id,
        .signature = .{ .raw = &.{} },
    };
}

fn readBorrowedReceivePayload(bytes: []const u8, cursor: *usize) Error!model.view.HandoffReceive {
    const receiving_session = try syntax.readBytes(bytes, cursor);
    const receiving_side = try syntax.readBytes(bytes, cursor);
    const handoff_count = try syntax.readPositiveInt(bytes, cursor);
    const signed = try readBorrowedSignedHandoff(bytes, cursor);
    const signed_give = switch (signed) {
        .give => |give| give,
        .receive => return Error.MalformedFrame,
    };
    return .{
        .receiving_session = receiving_session,
        .receiving_side = receiving_side,
        .handoff_count = handoff_count,
        .signed_give = signed_give,
        .signature = .{ .raw = &.{} },
    };
}

/// Decode a standalone signed handoff-give into an owned codec-neutral value.
/// `raw_signed` and typed fields are both populated, so either session codec can
/// render the result. Free it with `model.freeHandoffGive`.
pub fn decodeSignedHandoffGiveOwned(allocator: std.mem.Allocator, bytes: []const u8) shared.WalkError!model.HandoffGive {
    var cursor: usize = 0;
    const handoff = try readBorrowedSignedHandoff(bytes, &cursor);
    const give = switch (handoff) {
        .give => |g| g,
        .receive => return Error.MalformedFrame,
    };
    try syntax.expectEnd(bytes, cursor);
    return give.toOwned(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MalformedView => return Error.MalformedFrame,
    };
}
