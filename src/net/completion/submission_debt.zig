//! Owed inner submissions for a wrapped completion adapter.
//!
//! An inner backend can refuse a recv, send, or close submission under
//! transient queue pressure, and a recv can complete buffer-starved. The
//! adapter decides when each is retried. This leaf owns only the intrusive
//! memberships and the recycle-progress latch that make every owed retry
//! appear at most once and cost no allocation. A row carries its own links
//! (`recv_starvation`, `submission_retry`) and a `submission_retry_mask`.
//!
//! Starvation is retried only on a recycle edge, because polling creates no
//! pool capacity. A refused submission is retried on the next poll turn,
//! which the adapter bounds with a short timeout while any debt is owed.

const std = @import("std");

const intrusive_queue = @import("intrusive_queue.zig");

pub fn State(comptime Types: type) type {
    return struct {
        const Self = @This();
        const Conn = Types.Conn;
        const ConnId = Types.ConnId;
        const ConnMap = Types.ConnMap;
        const InternalOp = Types.InternalOp;
        const Links = intrusive_queue.Links(ConnId);

        fn recvStarvationLinks(c: *Conn) *Links {
            return &c.recv_starvation;
        }

        fn submissionRetryLinks(c: *Conn) *Links {
            return &c.submission_retry;
        }

        const RecvStarvationQueue = intrusive_queue.Queue(ConnId, Conn, recvStarvationLinks);
        const SubmissionRetryQueue = intrusive_queue.Queue(ConnId, Conn, submissionRetryLinks);

        pub const SubmissionDebt = struct {
            conn: *Conn,
            mask: u8,

            pub fn includes(debt: SubmissionDebt, op: InternalOp) bool {
                return debt.mask & bit(op) != 0;
            }
        };

        recv_starvation: RecvStarvationQueue = .{},
        submission_retries: SubmissionRetryQueue = .{},
        recv_recycle_progress: bool = false,

        fn bit(op: InternalOp) u8 {
            std.debug.assert(op != .connect);
            return @as(u8, 1) << @backingInt(op);
        }

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

        pub fn oweRecvStarvation(self: *Self, conns: *ConnMap, c: *Conn) void {
            if (!self.recv_starvation.contains(c)) self.recv_starvation.push(conns, c);
        }

        pub fn oweSubmission(self: *Self, conns: *ConnMap, c: *Conn, op: InternalOp) void {
            const owed = bit(op);
            if (c.submission_retry_mask & owed != 0) return;
            c.submission_retry_mask |= owed;
            if (!self.submission_retries.contains(c)) self.submission_retries.push(conns, c);
        }

        pub fn clearOwedRetries(self: *Self, conns: *ConnMap, c: *Conn) void {
            self.recv_starvation.removeIfQueued(conns, c);
            self.submission_retries.removeIfQueued(conns, c);
            c.submission_retry_mask = 0;
        }

        pub fn clearRecvRetry(self: *Self, conns: *ConnMap, c: *Conn) void {
            self.recv_starvation.removeIfQueued(conns, c);
            c.submission_retry_mask &= ~bit(.recv);
            if (c.submission_retry_mask == 0)
                self.submission_retries.removeIfQueued(conns, c);
        }

        pub fn clearDataRetries(self: *Self, conns: *ConnMap, c: *Conn) void {
            self.recv_starvation.removeIfQueued(conns, c);
            c.submission_retry_mask &= bit(.close);
            if (c.submission_retry_mask == 0)
                self.submission_retries.removeIfQueued(conns, c);
        }

        pub fn owesSubmission(_: *const Self, c: *const Conn, op: InternalOp) bool {
            return c.submission_retry_mask & bit(op) != 0;
        }

        pub fn recvStarvationCount(self: *const Self) usize {
            return self.recv_starvation.count;
        }

        pub fn popRecvStarvation(self: *Self, conns: *ConnMap) ?*Conn {
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
