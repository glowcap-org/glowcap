//! Explicit borrowed-to-owned conveniences at the Peer boundary.
//!
//! The engine's internal send spine moves ownership. These are the named copy
//! points for application replies whose borrowed resolution must survive
//! queueing in the answer store. A borrowed message goes through
//! `outbound.enqueueBorrowed`, which copies only the kinds the queue keeps.

const Peer = @import("../mod.zig").Peer;
const model = @import("model");
const session = @import("session");
const outbound = @import("../outbound.zig");

pub fn answer(
    self: *Peer,
    answer_name: model.AnswerName,
    resolution: model.Resolution,
) !void {
    return outbound.enqueueAnswerResolutionOwned(
        self,
        answer_name,
        try cloneResolution(self, resolution),
    );
}

pub fn answerTarget(
    self: *Peer,
    target: session.AnswerTarget,
    resolution: model.Resolution,
) !void {
    return outbound.enqueueAnswerTargetResolutionOwned(
        self,
        target,
        try cloneResolution(self, resolution),
    );
}

/// Copy a turn-borrowed resolution directly into the answer store's owner.
/// The views may borrow handler state or the inbound frame. Admission can
/// queue the answer past both lifetimes, so the retained tree owns its bytes.
pub fn answerTargetView(
    self: *Peer,
    target: session.AnswerTarget,
    resolution: model.view.Resolution,
) !void {
    return outbound.enqueueAnswerTargetResolutionOwned(
        self,
        target,
        try resolution.toOwned(self.allocator),
    );
}

pub fn cloneResolution(self: *Peer, resolution: model.Resolution) !model.Resolution {
    return switch (resolution) {
        .fulfill => |value| .{ .fulfill = try model.cloneArgument(self.allocator, value) },
        .@"break" => |reason| .{ .@"break" = .{
            .message = try self.allocator.dupe(u8, reason.message),
        } },
    };
}
