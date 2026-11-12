//! Bounded terminal diagnostics shared by Host operations. This text survives
//! its producer without allocating at completion. It is not protocol data.
const std = @import("std");
const Failure = @This();
const engine = @import("engine");

bytes: [engine.Broken.diagnostic_capacity]u8 = undefined,
len: u16 = 0,
cause: engine.BreakCause,

comptime {
    // The cause occupies the existing alignment unit after the bounded length.
    std.debug.assert(@sizeOf(Failure) == 260);
}

pub fn init(reason: engine.Broken) Failure {
    const text = engine.Broken.truncate(reason.detail, engine.Broken.diagnostic_capacity);
    var failure: Failure = .{ .cause = reason.cause };
    @memcpy(failure.bytes[0..text.len], text);
    failure.len = @intCast(text.len);
    return failure;
}

pub fn message(self: *const Failure) []const u8 {
    return self.bytes[0..self.len];
}

pub fn broken(self: *const Failure) engine.Broken {
    return .{ .detail = self.message(), .cause = self.cause };
}
