//! Owned connection and retry state for the completion-backed Noise adapter.
//!
//! The reactor drives transitions; this module keeps the per-leg footprint,
//! borrowed completion seats, ciphertext staging, retry links, and sealing
//! authority together as one lifetime subject.

const std = @import("std");

const foundation = @import("foundation");
const intrusive_queue = @import("../../completion/intrusive_queue.zig");

const crypto = foundation.crypto;
const sealed = foundation.sealed;

pub fn Types(comptime Inner: type) type {
    return struct {
        pub const SealedTarget = struct {
            inner: Inner.ConnectTarget,
            remote: crypto.PeerKey,
            transport: []const u8,
        };

        pub const ConnectTarget = union(enum) {
            plain: Inner.ConnectTarget,
            sealed: SealedTarget,
        };

        pub const ConnId = u32;
        pub const InternalOp = enum(u3) { connect, recv, send, close };
        pub const RetryLinks = intrusive_queue.Links(ConnId);

        pub const InternalPending = struct {
            connect: bool = false,
            recv: bool = false,
            send: bool = false,

            pub fn get(p: InternalPending, op: InternalOp) bool {
                return switch (op) {
                    .connect => p.connect,
                    .recv => p.recv,
                    .send => p.send,
                    .close => unreachable,
                };
            }

            pub fn arm(p: *InternalPending, op: InternalOp) void {
                std.debug.assert(!p.get(op));
                switch (op) {
                    .connect => p.connect = true,
                    .recv => p.recv = true,
                    .send => p.send = true,
                    .close => unreachable,
                }
            }

            pub fn retire(p: *InternalPending, op: InternalOp) void {
                std.debug.assert(p.get(op));
                switch (op) {
                    .connect => p.connect = false,
                    .recv => p.recv = false,
                    .send => p.send = false,
                    .close => unreachable,
                }
            }

            pub fn count(p: InternalPending) usize {
                return @intFromBool(p.connect) + @intFromBool(p.recv) + @intFromBool(p.send);
            }
        };

        pub const NoiseConn = struct {
            id: ConnId,
            inner_fd: Inner.Fd,
            state: enum { connecting, handshaking, open, closing } = .connecting,
            channel: sealed.SealedChannel,
            proven: ?[crypto.PEER_KEY_BYTES]u8 = null,
            external_connect_ud: ?u64,
            external_recv_ud: ?u64 = null,
            external_send_ud: ?u64 = null,
            external_send_len: i32 = 0,
            external_send_bytes: []const u8 = &.{},
            external_send_off: usize = 0,
            external_close_ud: ?u64 = null,
            inner_recv_bytes: []const u8 = &.{},
            inner_recv_off: u32 = 0,
            inner_recv_token: u32 = 0,
            pending: InternalPending = .{},
            inner_close: enum { open, in_flight, failed, closed } = .open,
            recv_starvation: RetryLinks = .{},
            submission_retry: RetryLinks = .{},
            submission_retry_mask: u8 = 0,
            ct_front: std.ArrayList(u8) = .empty,
            ct_front_off: usize = 0,
            ct_back: std.ArrayList(u8) = .empty,
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

            pub fn externalSeatCount(c: *const NoiseConn) usize {
                return @intFromBool(c.external_connect_ud != null) +
                    @intFromBool(c.external_recv_ud != null) +
                    @intFromBool(c.external_send_ud != null);
            }
        };

        pub const ConnMap = std.AutoHashMapUnmanaged(ConnId, *NoiseConn);

        fn recvStarvationLinks(c: *NoiseConn) *RetryLinks {
            return &c.recv_starvation;
        }

        fn submissionRetryLinks(c: *NoiseConn) *RetryLinks {
            return &c.submission_retry;
        }

        pub const RecvStarvationQueue = intrusive_queue.Queue(
            ConnId,
            NoiseConn,
            recvStarvationLinks,
        );
        pub const SubmissionRetryQueue = intrusive_queue.Queue(
            ConnId,
            NoiseConn,
            submissionRetryLinks,
        );

        pub const Sealing = struct {
            identity: crypto.SecretKey,
            rng: std.Random.DefaultCsprng,

            pub fn deinit(self: *Sealing) void {
                std.crypto.secureZero(u8, std.mem.asBytes(&self.identity));
                std.crypto.secureZero(u8, std.mem.asBytes(&self.rng));
            }
        };
    };
}
