//! One public representation for failure provenance, reason, and context.
const std = @import("std");
const core = @import("foundation").break_cause;

pub const GlowcapBreakCause = extern struct {
    origin: u32,
    reason: u32,
    context: u32,

    pub fn fromCore(value: core.BreakCause) GlowcapBreakCause {
        return .{
            .origin = @backingInt(value.origin),
            .reason = @backingInt(value.reason),
            .context = @as(u3, @bitCast(value.context)),
        };
    }

    /// Reject unknown fields and provenance/reason combinations no owner emits.
    /// Context only describes the caller's operation, never a peer's assertion.
    pub fn toCore(self: GlowcapBreakCause) error{InvalidArgument}!core.BreakCause {
        const origin = std.enums.fromInt(core.Origin, self.origin) orelse return error.InvalidArgument;
        const reason = std.enums.fromInt(core.Reason, self.reason) orelse return error.InvalidArgument;
        const context = std.math.cast(u3, self.context) orelse return error.InvalidArgument;
        switch (origin) {
            .unspecified => if (reason != .unspecified) return error.InvalidArgument,
            .partner => if (reason != .application) return error.InvalidArgument,
            .local => {},
        }
        return .{ .origin = origin, .reason = reason, .context = @bitCast(context) };
    }
};
