//! The close vocabulary the byte-fed Host and the driver share: how long a
//! finish may wait before it escalates to cancellation, what an owning close
//! does with work admitted before its barrier, and the outcome it reports.

const std = @import("std");

/// How long finish may wait before it escalates to cancellation. Unlike a
/// general wait budget, grace cannot be negative.
pub const Grace = union(enum) {
    unbounded,
    ms: u32,
};

pub const max_finite_grace_ms: u32 = std.math.maxInt(u32);

/// What an owning close does with work admitted before its barrier.
pub const PendingWork = union(enum) {
    cancel,
    finish: Grace,
};

/// A representation-neutral close request before semantic validation. Adapter
/// layers map their own discriminants into this shape. The core alone decides
/// which pending/grace combinations are meaningful.
pub const PendingWorkInput = struct {
    pending: Pending,
    grace: GraceInput,

    pub const Pending = enum { cancel, finish };
    pub const GraceInput = union(enum) {
        unspecified,
        finite_ms: u32,
        unbounded,
    };

    pub const Error = error{
        CancelGraceSpecified,
        FinishGraceRequired,
    };

    pub fn resolve(self: PendingWorkInput) Error!PendingWork {
        return switch (self.pending) {
            .cancel => switch (self.grace) {
                .unspecified => .cancel,
                .finite_ms, .unbounded => error.CancelGraceSpecified,
            },
            .finish => .{ .finish = switch (self.grace) {
                .unspecified => return error.FinishGraceRequired,
                .finite_ms => |milliseconds| .{ .ms = milliseconds },
                .unbounded => .unbounded,
            } },
        };
    }
};

/// The observable close result. Timeout is reported only after cancellation
/// has reached the owner's completion barrier.
pub const CloseOutcome = enum {
    pending,
    closed,
    timed_out,
};

/// Convert a finish budget to one absolute monotonic deadline. Null is the
/// explicit unbounded case. Overflow saturates in the requested direction.
pub fn deadlineFor(grace: Grace, now_ms: i64) ?i64 {
    return switch (grace) {
        .unbounded => null,
        .ms => |milliseconds| std.math.add(i64, now_ms, milliseconds) catch std.math.maxInt(i64),
    };
}
