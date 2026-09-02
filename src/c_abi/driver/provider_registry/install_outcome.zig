//! One provider-package installation result and its rollback consequences.

const driver = @import("driver");
const driver_error = @import("../error.zig");
const shared = @import("c_abi_shared");

pub const Outcome = struct {
    result: i32 = shared.GLOWCAP_OK,
    failure: ?driver.OperationFailure = null,

    pub fn fromError(err: anyerror) Outcome {
        const failure = driver.OperationFailure.fromError(err);
        return .{ .result = driver_error.code(failure.kind), .failure = failure };
    }

    pub fn fromCode(result: i32, err: anyerror) Outcome {
        return .{ .result = result, .failure = driver.OperationFailure.fromError(err) };
    }

    pub fn note(self: *Outcome, later: driver.OperationFailure) void {
        if (self.failure) |*failure| {
            failure.noteFailure(later);
        } else {
            self.result = driver_error.code(later.kind);
            self.failure = later;
        }
    }
};
