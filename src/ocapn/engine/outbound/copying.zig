//! Explicit borrowed-to-owned conveniences at the Peer boundary.
//!
//! The engine's internal send spine moves ownership. These are the named copy
//! points for static/test/FFI callers and application replies whose borrowed
//! values must survive queueing.

const model = @import("model");
const session = @import("session");
const outbound = @import("../outbound.zig");

pub fn send(self: anytype, message: model.Message) !void {
    const owned = try model.cloneMessage(self.allocator, message);
    return self.send(owned);
}

pub fn answer(
    self: anytype,
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
    self: anytype,
    target: session.AnswerTarget,
    resolution: model.Resolution,
) !void {
    return outbound.enqueueAnswerTargetResolutionOwned(
        self,
        target,
        try cloneResolution(self, resolution),
    );
}

fn cloneResolution(self: anytype, resolution: model.Resolution) !model.Resolution {
    return switch (resolution) {
        .fulfill => |value| .{ .fulfill = try model.cloneArgument(self.allocator, value) },
        .@"break" => |reason| .{ .@"break" = .{
            .message = try self.allocator.dupe(u8, reason.message),
        } },
    };
}
