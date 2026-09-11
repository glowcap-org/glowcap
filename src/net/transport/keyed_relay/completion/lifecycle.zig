//! Terminal ownership for completion-backed relay connections.
//!
//! The shared leg lifecycle in `completion/inner_leg.zig` owns seat refusal,
//! inner close progression, and the single final removal. This module
//! composes it for the relay carrier and keeps what the WebSocket adds: a
//! platform shutdown deferred until the close frame drains, the graceful
//! close handshake, the carrier failure a refused seat can borrow, and the
//! bounded retry of platform closes the wrapped backend refused.

const std = @import("std");
const carrier_failure = @import("../../../carrier_failure.zig");
const contract = @import("../../../completion/contract.zig");
const inner_leg = @import("../../../completion/inner_leg.zig");

pub fn Machine(
    comptime Backend: type,
    comptime Types: type,
    comptime Access: type,
    comptime max_frame_header_len: usize,
    comptime close_retry_batch: usize,
) type {
    return struct {
        const Platform = Types.Inner;
        const RelayConn = Types.RelayConn;

        const LegAccess = struct {
            pub fn closeUserData(id: Types.ConnId) u64 {
                return Access.closeUserData(id);
            }

            /// A requested close is graceful only while the wire is still open
            /// and no close frame has gone out; every other entry into
            /// `closing` retires the socket without the handshake.
            pub fn onClosing(_: *Backend, _: *Platform, c: *RelayConn, how: inner_leg.Closing) void {
                c.close.graceful = switch (how) {
                    .requested => c.state == .open and !c.close.wire.hasSent(),
                    .ended, .abandoned => false,
                };
            }

            /// Reserve the close frame's staging before any seat is refused,
            /// so a graceful close cannot fail between refusal and the frame.
            pub fn prepareClose(backend: *Backend, _: *Platform, c: *RelayConn) !void {
                const send_close = c.state == .open and !c.close.wire.hasSent();
                if (send_close and !c.pending.get(.send))
                    try c.ws_out.ensureTotalCapacityPrecise(
                        backend.allocator,
                        try std.math.add(usize, c.ws_out.items.len, max_frame_header_len),
                    );
            }

            pub fn closeRefused(backend: *Backend, _: *Platform, c: *RelayConn) void {
                if (c.close.shutdown_requested) backend.platform.shutdownFd(c.inner_fd);
            }

            pub fn refuseExternalSend(
                backend: *Backend,
                c: *RelayConn,
                cause: ?anyerror,
                phase: carrier_failure.Phase,
            ) void {
                Access.refuseExternalSendWith(backend, c, cause, phase);
            }

            /// A send in flight borrows `ws_out`; its completion resumes the
            /// close through `advance` once that borrow retires.
            pub fn startClose(backend: *Backend, _: *Platform, c: *RelayConn) void {
                if (!c.pending.get(.send)) advance(backend, c);
            }

            pub fn owesClose(backend: *Backend, c: *RelayConn) bool {
                return backend.close_retries.contains(c);
            }

            pub fn oweClose(backend: *Backend, c: *RelayConn) void {
                backend.close_retries.push(&backend.conns, c);
            }

            pub fn clearOwedClose(backend: *Backend, c: *RelayConn) void {
                backend.close_retries.removeIfQueued(&backend.conns, c);
            }

            pub fn lendActive(_: *const RelayConn) bool {
                return false;
            }

            pub fn borrowFailure(backend: *Backend, c: *RelayConn) contract.Borrowed {
                return Access.borrowCarrierFailure(backend, c);
            }

            pub fn prepareFinish(backend: *Backend, c: *RelayConn, inner_failed: bool) bool {
                return Access.prepareCarrierClose(backend, c, inner_failed);
            }

            pub fn closeCause(c: *const RelayConn) ?anyerror {
                return c.close.failure;
            }

            pub fn hasBorrowedFailure(backend: *const Backend, c: *const RelayConn) bool {
                return Access.hasBorrowedCarrierFailure(backend, c);
            }

            pub fn retireRow(backend: *Backend, c: *RelayConn) void {
                backend.recv_retries.removeIfQueued(&backend.conns, c);
                backend.close_retries.removeIfQueued(&backend.conns, c);
            }

            pub fn deinitRow(backend: *Backend, _: *Platform, c: *RelayConn) void {
                Access.destroyCarrier(backend, c);
                c.deinit(backend.allocator);
            }
        };
        const Leg = inner_leg.Lifecycle(Backend, Platform, Types, LegAccess);

        pub const pendingExternalCount = Leg.externalSeatCount;

        pub fn closeFd(backend: *Backend, fd: anytype) void {
            if (Access.idFromFd(fd)) |id| {
                const c = backend.conns.get(id) orelse return;
                Leg.closeRow(backend, &backend.platform, c);
                return;
            }
            backend.platform.closeFd(fd);
        }

        pub fn shutdownFd(backend: *Backend, fd: anytype) void {
            // The outer Loop calls shutdown immediately before submitClose. A
            // synthetic handle delays it until its WebSocket close can drain.
            // The sealing and onion legs shut their inner descriptor down at
            // once instead, because neither carries a close handshake on the
            // wire that a premature shutdown could cut short.
            if (Access.idFromFd(fd)) |id| {
                if (backend.conns.get(id)) |c| c.close.shutdown_requested = true;
                return;
            }
            backend.platform.shutdownFd(fd);
        }

        pub fn submitClose(backend: *Backend, user_data: u64, fd: anytype) !void {
            if (Access.idFromFd(fd)) |id| {
                const c = backend.conns.get(id) orelse {
                    try backend.ready.ensureUnusedCapacity(backend.allocator, 1);
                    backend.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
                    return;
                };
                return Leg.submitCloseRow(backend, &backend.platform, c, user_data);
            }
            try backend.platform.submitClose(user_data, fd);
        }

        pub fn fail(backend: *Backend, c: *RelayConn) void {
            Leg.fail(backend, &backend.platform, c);
        }

        pub fn failWith(
            backend: *Backend,
            c: *RelayConn,
            phase: carrier_failure.Phase,
            cause: anyerror,
        ) void {
            Leg.failWith(backend, &backend.platform, c, phase, cause);
        }

        /// Stop admitting work and publish every outstanding external result.
        /// `recv_result` preserves clean EOF (`0`) versus failure (`-1`).
        pub fn end(backend: *Backend, c: *RelayConn, recv_result: i32) void {
            Leg.end(backend, &backend.platform, c, recv_result);
        }

        pub fn endWith(
            backend: *Backend,
            c: *RelayConn,
            recv_result: i32,
            phase: carrier_failure.Phase,
            cause: ?anyerror,
        ) void {
            Leg.endWith(backend, &backend.platform, c, recv_result, phase, cause);
        }

        /// Finish the WebSocket half-close before retiring the wrapped socket.
        pub fn advance(backend: *Backend, c: *RelayConn) void {
            std.debug.assert(c.state == .closing and !c.pending.get(.send));
            if (!c.close.graceful) {
                Access.clearWsOut(backend, c);
                return beginPlatformClose(backend, c);
            }
            if (!c.close.wire.hasSent()) {
                Access.clearWsOut(backend, c);
                Access.queueCloseFrame(backend, c) catch return beginPlatformClose(backend, c);
                Access.driveRelaySend(backend, c) catch return beginPlatformClose(backend, c);
                return;
            }
            if (c.ws_out_off != c.ws_out.items.len) {
                Access.driveRelaySend(backend, c) catch return beginPlatformClose(backend, c);
                return;
            }
            Access.beginCarrierClose(backend, c);
        }

        pub fn beginPlatformClose(backend: *Backend, c: *RelayConn) void {
            Leg.beginInnerClose(backend, &backend.platform, c);
        }

        /// Retry only closes refused under transient queue or allocator
        /// pressure. Intrusive links keep recovery allocation-free.
        pub fn retryPendingCloses(backend: *Backend) void {
            const attempts = @min(backend.close_retries.count, close_retry_batch);
            for (0..attempts) |_| {
                const c = backend.close_retries.pop(&backend.conns) orelse unreachable;
                backend.platform.submitClose(Access.closeUserData(c.id), c.inner_fd) catch {
                    backend.close_retries.push(&backend.conns, c);
                    continue;
                };
                c.inner_close = .in_flight;
            }
        }

        pub fn maybeFinish(backend: *Backend, c: *RelayConn) void {
            Leg.maybeFinish(backend, &backend.platform, c);
        }
    };
}
