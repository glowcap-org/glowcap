//! Sender-side next subscription uniqueness, tied to the promise incarnation.
//! No side table outlives an answer or import. Prepared engine maintenance
//! records claims at the same commit boundary as ordinary sent listens.
const std = @import("std");
const model = @import("model");
const session = @import("mod.zig");
const Session = session.Session;

fn modes(owner: *Session, target: model.Reference) ?*u2 {
    return switch (target) {
        .promise => |promise| if (owner.outbound_answers.getPtr(promise.answer_position)) |cell| &cell.sent_listen_modes else null,
        .far => |far| if (owner.findImportedPromise(far.import_position)) |promise| &promise.sent_listen_modes else null,
        else => null,
    };
}

pub fn validate(owner: *Session, listen: model.Listen) session.Error!void {
    if (owner.captp_version != .next) return;
    const sent = modes(owner, listen.target) orelse return error.InvalidReference;
    const requested = @backingInt(listen.mode);
    if (sent.* & requested != 0 or (sent.* == 0 and listen.mode == .settling_only))
        return error.UnexpectedMessage;
}

pub fn record(owner: *Session, listen: model.Listen) void {
    if (owner.captp_version != .next) return;
    const sent = modes(owner, listen.target) orelse unreachable;
    std.debug.assert(sent.* & @backingInt(listen.mode) == 0);
    std.debug.assert(sent.* != 0 or listen.mode != .settling_only);
    sent.* |= @backingInt(listen.mode);
}

/// A withdrawn queue entry never crossed the wire. Return precisely its
/// modes, preserving any other subscription already sent for this promise.
pub fn retract(owner: *Session, listen: model.Listen) void {
    if (owner.captp_version != .next) return;
    const sent = modes(owner, listen.target) orelse unreachable;
    const requested = @backingInt(listen.mode);
    std.debug.assert(sent.* & requested == requested);
    sent.* &= ~requested;
}
