//! The dial subject of the multiplexed-resident contract: the attempt a
//! runtime holds between admission and connection claim, and the outcomes a
//! resident's dial operations report. The attempt owns cancellation, so a
//! runtime that drops it cancels the dial it admitted.

const foundation = @import("foundation");
const netlayer = @import("../netlayer.zig");
const resident = @import("../multiplexed_resident.zig");

/// A resident dial request between admission and connection claim. The value
/// owns cancellation. `finish` consumes the request on both success and
/// refusal and returns the next ownership state only on success.
pub const DialAttempt = struct {
    dialer: resident.MultiplexedResident.Dialer,
    request_id: ?usize,

    pub fn deinit(self: *DialAttempt) ?foundation.FailureChain {
        const request_id = self.request_id orelse return null;
        self.request_id = null;
        return self.dialer.cancelDial(request_id);
    }

    pub fn id(self: DialAttempt) ?usize {
        return self.request_id;
    }

    pub fn take(self: *DialAttempt) DialAttempt {
        const owned = self.*;
        self.request_id = null;
        return owned;
    }

    pub fn finish(self: *DialAttempt) DialFinishOutcome {
        const request_id = self.request_id orelse
            return .{ .failed = .init(error.InvalidOptions) };
        self.request_id = null;
        return switch (self.dialer.finishDial(request_id)) {
            .connected => |conn| .{ .connected = .{ .resident = self.dialer.resident, .id = conn } },
            .failed => |failure| .{ .failed = failure },
        };
    }
};

pub const DialStartOutcome = union(enum) {
    admitted: DialAttempt,
    failed: netlayer.DialFailure,
};

pub const DialFinishOutcome = union(enum) {
    connected: resident.ClaimedConnection,
    failed: netlayer.DialFailure,
};

pub const RawDialStartOutcome = union(enum) {
    admitted,
    failed: netlayer.DialFailure,
};

pub const RawDialFinishOutcome = union(enum) {
    connected: usize,
    failed: netlayer.DialFailure,
};
