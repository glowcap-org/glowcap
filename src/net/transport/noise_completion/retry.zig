//! Retry queue ownership for completion-backed Noise connections.
//!
//! The reactor decides when an inner recv/send/close should be retried. This
//! leaf owns only the intrusive queue memberships and recycle-progress latch
//! that make each owed retry appear at most once.

pub fn State(comptime Types: type) type {
    return struct {
        const Self = @This();
        const ConnMap = Types.ConnMap;
        const NoiseConn = Types.NoiseConn;
        const InternalOp = Types.InternalOp;

        pub const SubmissionDebt = struct {
            conn: *NoiseConn,
            mask: u8,

            pub fn includes(debt: SubmissionDebt, op: InternalOp) bool {
                return debt.mask & Types.submissionBit(op) != 0;
            }
        };

        recv_starvation: Types.RecvStarvationQueue = .{},
        submission_retries: Types.SubmissionRetryQueue = .{},
        recv_recycle_progress: bool = false,

        pub fn assertEmpty(self: *const Self) void {
            std.debug.assert(self.recv_starvation.count == 0);
            std.debug.assert(self.submission_retries.count == 0);
        }

        pub fn noteRecvRecycle(self: *Self) void {
            self.recv_recycle_progress = true;
        }

        pub fn takeRecvRecycleProgress(self: *Self) bool {
            if (!self.recv_recycle_progress) return false;
            self.recv_recycle_progress = false;
            return true;
        }

        pub fn oweRecvStarvation(self: *Self, conns: *ConnMap, c: *NoiseConn) void {
            if (!self.recv_starvation.contains(c)) self.recv_starvation.push(conns, c);
        }

        pub fn oweSubmission(self: *Self, conns: *ConnMap, c: *NoiseConn, op: InternalOp) void {
            const bit = Types.submissionBit(op);
            if (c.submission_retry_mask & bit != 0) return;
            c.submission_retry_mask |= bit;
            if (!self.submission_retries.contains(c)) self.submission_retries.push(conns, c);
        }

        pub fn clearOwedRetries(self: *Self, conns: *ConnMap, c: *NoiseConn) void {
            self.recv_starvation.removeIfQueued(conns, c);
            self.submission_retries.removeIfQueued(conns, c);
            c.submission_retry_mask = 0;
        }

        pub fn clearRecvRetry(self: *Self, conns: *ConnMap, c: *NoiseConn) void {
            self.recv_starvation.removeIfQueued(conns, c);
            c.submission_retry_mask &= ~Types.submissionBit(.recv);
            if (c.submission_retry_mask == 0)
                self.submission_retries.removeIfQueued(conns, c);
        }

        pub fn clearDataRetries(self: *Self, conns: *ConnMap, c: *NoiseConn) void {
            self.recv_starvation.removeIfQueued(conns, c);
            c.submission_retry_mask &= Types.submissionBit(.close);
            if (c.submission_retry_mask == 0)
                self.submission_retries.removeIfQueued(conns, c);
        }

        pub fn owesSubmission(_: *const Self, c: *const NoiseConn, op: InternalOp) bool {
            return Types.owesSubmission(c, op);
        }

        pub fn recvStarvationCount(self: *const Self) usize {
            return self.recv_starvation.count;
        }

        pub fn popRecvStarvation(self: *Self, conns: *ConnMap) ?*NoiseConn {
            return self.recv_starvation.pop(conns);
        }

        pub fn submissionRetryCount(self: *const Self) usize {
            return self.submission_retries.count;
        }

        pub fn popSubmissionRetry(self: *Self, conns: *ConnMap) ?SubmissionDebt {
            const c = self.submission_retries.pop(conns) orelse return null;
            const mask = c.submission_retry_mask;
            c.submission_retry_mask = 0;
            return .{ .conn = c, .mask = mask };
        }
    };
}

const std = @import("std");
