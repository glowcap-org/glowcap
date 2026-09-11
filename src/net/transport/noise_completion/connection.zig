//! One-leg storage and local invariants for completion-backed Noise.
//!
//! The reactor owns the table and every lifecycle transition. This leaf keeps
//! only the row representation: borrowed completion seats, ciphertext staging,
//! pending inner operations, and intrusive retry memberships.

const std = @import("std");

const foundation = @import("foundation");
const adapter = @import("../../completion/adapter.zig");
const intrusive_queue = @import("../../completion/intrusive_queue.zig");

const crypto = foundation.crypto;
const sealed = foundation.sealed;

pub fn Types(comptime Inner: type, comptime Namespace: type) type {
    return struct {
        pub const steady_ciphertext_bytes: usize = 4096;
        pub const ConnId = u32;
        pub const InternalOp = enum(u3) { connect, recv, send, close };
        pub const RetryLinks = intrusive_queue.Links(ConnId);
        pub const PendingOps = adapter.PendingOps(InternalOp, &.{ .connect, .recv, .send });
        pub const Identity = Namespace.RowIdentity(InternalOp);

        pub const NoiseConn = struct {
            id: ConnId,
            inner_fd: Inner.Fd,
            state: enum { connecting, handshaking, open, closing } = .connecting,
            /// The sole cryptographic/record machine. `proven` publishes only
            /// after its initiator handshake completes.
            channel: sealed.SealedChannel,
            proven: ?[crypto.PEER_KEY_BYTES]u8 = null,
            external_connect_ud: ?u64,
            external_recv_ud: ?u64 = null,
            external_send_ud: ?u64 = null,
            external_send_len: i32 = 0,
            /// Borrowed from the completion caller until its send completion.
            external_send_bytes: []const u8 = &.{},
            external_send_off: usize = 0,
            external_close_ud: ?u64 = null,
            /// Retained inner receive loan. Coalesced ciphertext stays here
            /// until every complete record in the loan has been consumed.
            inner_recv_bytes: []const u8 = &.{},
            inner_recv_off: u32 = 0,
            inner_recv_token: u32 = 0,
            pending: PendingOps = .{},
            inner_close: adapter.InnerClose = .open,
            /// Intrusive memberships: recycle-gated starvation and actionable
            /// submission debt. A row can occupy each queue at most once.
            recv_starvation: RetryLinks = .{},
            submission_retry: RetryLinks = .{},
            submission_retry_mask: u8 = 0,
            /// Front is frozen while `Inner` borrows it; new records append to
            /// back. A drained oversized front releases its capacity.
            ct_front: std.ArrayList(u8) = .empty,
            ct_front_off: usize = 0,
            ct_back: std.ArrayList(u8) = .empty,
            /// The channel's plaintext scratch is lent until public recycle.
            lend_active: bool = false,

            pub fn deinit(c: *NoiseConn, allocator: std.mem.Allocator) void {
                std.debug.assert(c.inner_recv_bytes.len == 0);
                c.channel.deinit(allocator);
                c.ct_front.deinit(allocator);
                c.ct_back.deinit(allocator);
            }

            pub fn pendingCiphertext(c: *const NoiseConn) usize {
                return (c.ct_front.items.len - c.ct_front_off) + c.ct_back.items.len;
            }

            pub fn clearCiphertextFront(c: *NoiseConn, allocator: std.mem.Allocator) void {
                if (c.ct_front.capacity > steady_ciphertext_bytes) {
                    c.ct_front.deinit(allocator);
                    c.ct_front = .empty;
                } else {
                    c.ct_front.clearRetainingCapacity();
                }
                c.ct_front_off = 0;
            }
        };

        /// The row the shared leg lifecycle and submission debt drive.
        pub const Conn = NoiseConn;

        pub const ConnMap = std.AutoHashMapUnmanaged(ConnId, *NoiseConn);
    };
}
