//! Release ownership and failure are independent facts in one C return word.
//! Negative values retain ownership and preserve the ordinary failure code.
//! Nonnegative values consume ownership, with positive values naming the
//! negated failure code. Zero is consumed success.
const std = @import("std");
pub const ReleaseResult = struct {
    const Self = @This();
    pub const contract = "signed-release-result-v1";
    pub const Ownership = enum { consumed, retained };

    failure: i32,
    ownership: Ownership,

    /// Whether a reflected public function returns the release contract.
    pub fn isFunction(comptime name: []const u8, comptime Fn: type) bool {
        return std.mem.endsWith(u8, name, "_release") and @typeInfo(Fn).@"fn".return_type.? == i32;
    }

    pub fn consumed(result: i32) Self {
        return init(result, .consumed);
    }

    pub fn retained(result: i32) Self {
        std.debug.assert(result != 0);
        return init(result, .retained);
    }

    /// The return word of a release whose every refusal precedes its commit:
    /// a failure code retains the handle, and success consumes it.
    pub fn refusingBeforeCommit(result: i32) i32 {
        return (if (result == 0) consumed(0) else retained(result)).raw();
    }

    fn init(result: i32, ownership: Ownership) Self {
        std.debug.assert(result <= 0 and result != std.math.minInt(i32));
        return .{ .failure = result, .ownership = ownership };
    }

    pub fn code(self: Self) i32 {
        return self.failure;
    }

    pub fn raw(self: Self) i32 {
        return if (self.ownership == .consumed) -self.failure else self.failure;
    }

    pub fn fromRaw(value: i32) Self {
        return .{
            .failure = if (value > 0) -value else value,
            .ownership = if (value >= 0) .consumed else .retained,
        };
    }
};
