//! Owned state and queue vocabulary for one completion-backed relay leg.
//!
//! The backend drives transitions; this module owns the data whose lifetimes
//! those transitions coordinate. Keeping the state together makes connection
//! footprint, retry links, buffer ownership, and teardown progress one subject
//! instead of declarations scattered through the reactor adapter.

const std = @import("std");

const address_race = @import("../address_race.zig");
const carrier_failure = @import("../../../carrier_failure.zig");
const adapter = @import("../../../completion/adapter.zig");
const intrusive_queue = @import("../../../completion/intrusive_queue.zig");
const tls_engine = @import("../../../tls/engine.zig");
const tls_runtime_owner = @import("../../../tls/runtime_owner.zig");
const tls_transform = @import("../../../tls/transform.zig");
const route = @import("../route.zig");
const resolver = @import("resolver.zig");

pub fn Types(comptime Platform: type, comptime Namespace: type) type {
    return struct {
        /// The wrapped platform backend, named so the shared leg lifecycle
        /// can borrow it per verb.
        pub const Inner = Platform;
        pub const ConnId = u32;
        pub const InternalOp = enum(u3) { connect, recv, send, close };
        pub const PendingOps = adapter.PendingOps(InternalOp, &.{ .connect, .recv, .send });
        pub const Identity = Namespace.RowIdentity(InternalOp);

        pub const State = enum {
            connecting,
            tls_handshake,
            sending_upgrade,
            reading_upgrade,
            open,
            closing,
        };

        pub const WsSendKind = enum(u2) {
            none,
            upgrade,
            application,
            control,
        };

        pub const ControlEffect = enum {
            consumed,
            reply_queued,
            closed,
        };

        pub const PlatformBufferDisposition = enum {
            recycle,
            lent_to_caller,
        };

        pub const CloseHandshake = enum {
            open,
            received,
            sent,
            exchanged,

            pub fn hasReceived(state: CloseHandshake) bool {
                return state == .received or state == .exchanged;
            }

            pub fn hasSent(state: CloseHandshake) bool {
                return state == .sent or state == .exchanged;
            }

            pub fn markReceived(state: *CloseHandshake) void {
                state.* = if (state.hasSent()) .exchanged else .received;
            }

            pub fn markSent(state: *CloseHandshake) void {
                state.* = if (state.hasReceived()) .exchanged else .sent;
            }
        };

        pub const RetryLinks = intrusive_queue.Links(ConnId);

        /// Progress of the WebSocket half of retiring one relay leg: `wire`
        /// tracks RFC 6455, `retry` links an owed platform close, and the
        /// rest records how the close was asked for. Descriptor ownership is
        /// `RelayConn.inner_close`, the shared leg vocabulary.
        pub const CloseProgress = struct {
            wire: CloseHandshake = .open,
            retry: RetryLinks = .{},
            failure: ?anyerror = null,
            graceful: bool = false,
            shutdown_requested: bool = false,
        };

        pub const RelayConn = struct {
            id: ConnId,
            inner_fd: Platform.Fd,
            state: State = .connecting,
            ws_send_kind: WsSendKind = .none,
            external_connect_ud: ?u64,
            external_recv_ud: ?u64 = null,
            external_send_ud: ?u64 = null,
            external_send_len: i32 = 0,
            /// Caller-owned tail not yet copied and masked into `ws_out`.
            external_send_remainder: []const u8 = &.{},
            external_close_ud: ?u64 = null,
            pending: PendingOps = .{},
            inner_close: adapter.InnerClose = .open,
            recv_retry: RetryLinks = .{},
            close: CloseProgress = .{},
            expected_accept: [28]u8,
            upgrade_buf: std.ArrayList(u8) = .empty,
            raw_in: std.ArrayList(u8) = .empty,
            raw_in_head: usize = 0,
            ws_out: std.ArrayList(u8) = .empty,
            ws_out_off: usize = 0,
            data_remaining: u64 = 0,
            fragmented: bool = false,

            pub fn deinit(c: *RelayConn, allocator: std.mem.Allocator) void {
                c.upgrade_buf.deinit(allocator);
                c.raw_in.deinit(allocator);
                c.ws_out.deinit(allocator);
            }
        };

        /// The row the shared leg lifecycle drives.
        pub const Conn = RelayConn;

        /// At most one normal DNS answer set races at a time per logical dial.
        /// More answers remain ordered behind these seats rather than growing
        /// transient descriptor pressure with resolver output size.
        pub const max_parallel_dials = address_race.max_parallel_attempts;

        pub const DialLeg = struct {
            fd: Platform.Fd = undefined,
            state: enum { idle, connecting, closing } = .idle,
            connect_pending: bool = false,
            close_pending: bool = false,
            closed: bool = false,
            address_index: u8 = 0,
        };

        /// State before one physical socket wins the relay dial. The synthetic
        /// connection handle names this row from admission onward, while every
        /// platform fd remains private until all losing legs have retired.
        pub const PendingDial = struct {
            id: ConnId,
            conn: *RelayConn,
            resolver_job: ?*resolver.Job = null,
            addresses: [resolver.max_addresses]std.Io.net.IpAddress = undefined,
            address_count: u8 = 0,
            next_address: u8 = 0,
            legs: [max_parallel_dials]DialLeg = @as([max_parallel_dials]DialLeg, @splat(.{})),
            winner: ?u3 = null,
            close_requested: bool = false,
            external_close_ud: ?u64 = null,
            failure: ?carrier_failure.Failure = null,
            /// One bounded slot per retained DNS answer preserves resolver
            /// ordering even when the eight live connect seats finish out of
            /// order. This is transient, admission-capped open state rather
            /// than per-connection scale cost.
            attempt_failures: address_race.FailureLedger(carrier_failure.Failure) = .{},
            cleanup_failure: ?carrier_failure.Failure = null,
            failure_borrowed: bool = false,
            terminal_published: bool = false,
            close_retry_next: ?*PendingDial = null,
            close_retry_queued: bool = false,
        };

        /// Secure-only state lives in a side table, not in `RelayConn`: the
        /// 500k clear-connection target pays zero bytes per connection for a
        /// feature it does not use.
        pub const TlsState = struct {
            id: ConnId,
            lifecycle: union(enum) {
                pending,
                active: tls_transform.Transform,
                retired,
            } = .pending,
            interest: tls_engine.Interest = .{},
            shutting_down: bool = false,
            /// The TLS state machine reached its clean terminal transition,
            /// but its final close-notify ciphertext may still be owned by a
            /// platform send. Retirement follows that send completion.
            shutdown_complete: bool = false,
            failure: ?carrier_failure.Failure = null,
            failure_borrows: u8 = 0,
            send_retry: RetryLinks = .{},

            pub fn activeTransform(state: *TlsState) *tls_transform.Transform {
                return switch (state.lifecycle) {
                    .active => |*transform| transform,
                    .pending, .retired => unreachable,
                };
            }

            pub fn deinit(state: *TlsState) ?carrier_failure.Failure {
                var failure = state.failure;
                switch (state.lifecycle) {
                    .pending, .retired => {},
                    .active => |*transform| {
                        if (transform.deinitOutcome()) |cleanup| {
                            const carrier_cleanup = fromTlsFailure(cleanup);
                            if (failure) |*primary|
                                primary.chain.noteChain(carrier_cleanup.chain)
                            else
                                failure = carrier_cleanup;
                        }
                    },
                }
                state.* = undefined;
                return failure;
            }

            /// Retire an active client after a non-TLS owner reports the
            /// primary failure. The operation cause is installed before
            /// engine destruction so teardown can only become a consequence.
            pub fn fail(
                state: *TlsState,
                phase: tls_engine.Phase,
                cause: anyerror,
            ) carrier_failure.Failure {
                std.debug.assert(state.lifecycle == .active);
                var transform = &state.lifecycle.active;
                var failure = transform.takeFailure() orelse
                    tls_engine.Failure.init(phase, cause);
                if (transform.deinitOutcome()) |cleanup|
                    failure.chain.noteChain(cleanup.chain);
                state.* = undefined;
                return fromTlsFailure(failure);
            }

            pub fn fromTlsFailure(failure_value: tls_engine.Failure) carrier_failure.Failure {
                return .{
                    .phase = switch (failure_value.phase) {
                        .handshake => .secure_handshake,
                        .receive => .receive,
                        .transmit => .transmit,
                        .shutdown => .shutdown,
                    },
                    .chain = failure_value.chain,
                    .detail = failure_value.detail,
                };
            }
        };

        pub const TlsMap = std.AutoHashMapUnmanaged(ConnId, *TlsState);

        pub const ConnMap = std.AutoHashMapUnmanaged(ConnId, *RelayConn);
        pub const PendingDialMap = std.AutoHashMapUnmanaged(ConnId, *PendingDial);

        fn recvRetryLinks(c: *RelayConn) *RetryLinks {
            return &c.recv_retry;
        }

        fn closeRetryLinks(c: *RelayConn) *RetryLinks {
            return &c.close.retry;
        }

        fn tlsSendRetryLinks(state: *TlsState) *RetryLinks {
            return &state.send_retry;
        }

        pub const RecvRetryQueue = intrusive_queue.Queue(
            ConnId,
            RelayConn,
            recvRetryLinks,
        );
        pub const CloseRetryQueue = intrusive_queue.Queue(
            ConnId,
            RelayConn,
            closeRetryLinks,
        );
        pub const TlsSendRetryQueue = intrusive_queue.Queue(
            ConnId,
            TlsState,
            tlsSendRetryLinks,
        );

        /// Retained deployment configuration. `bytes` owns every slice in
        /// `url`, so it is released only after all route users retire.
        pub const RelayConfig = struct {
            bytes: []u8,
            url: route.RelayUrl,
            tls: ?tls_runtime_owner.Lease = null,

            pub fn deinit(config: *RelayConfig, allocator: std.mem.Allocator) void {
                if (config.tls) |*lease| lease.release();
                allocator.free(config.bytes);
            }
        };
    };
}
