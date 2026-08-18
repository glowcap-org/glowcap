//! Terminal ownership for completion-backed relay connections.
//!
//! The owning adapter delegates only the platform operations that are private
//! to its reactor. This module owns synthetic-handle shutdown, WebSocket close
//! progression, wrapped-descriptor retirement, and the single final removal.

const std = @import("std");
const carrier_failure = @import("../../../carrier_failure.zig");

pub fn Machine(
    comptime Backend: type,
    comptime Types: type,
    comptime Access: type,
    comptime max_frame_header_len: usize,
    comptime close_retry_batch: usize,
) type {
    return struct {
        const RelayConn = Types.RelayConn;

        pub fn closeFd(backend: *Backend, fd: anytype) void {
            if (Access.idFromFd(fd)) |id| {
                const c = backend.conns.get(id) orelse return;
                std.debug.assert(pendingExternalCount(c) == 0);
                if (c.close.platform != .closed) {
                    c.state = .closing;
                    c.close.graceful = false;
                    backend.platform.shutdownFd(c.os_fd);
                    if (c.close.platform == .open and c.pending.count() == 0) {
                        backend.close_retries.removeIfQueued(&backend.conns, c);
                        backend.platform.closeFd(c.os_fd);
                        c.close.platform = .closed;
                    } else if (c.close.platform == .open) {
                        beginPlatformClose(backend, c);
                    }
                }
                if (c.close.platform == .failed and c.pending.count() == 0) {
                    backend.platform.closeFd(c.os_fd);
                    c.close.platform = .closed;
                }
                if (c.pending.count() != 0 or
                    backend.close_retries.contains(c) or
                    c.close.platform == .in_flight)
                {
                    return;
                }
                destroy(backend, id);
                return;
            }
            backend.platform.closeFd(fd);
        }

        pub fn shutdownFd(backend: *Backend, fd: anytype) void {
            // The outer Loop calls shutdown immediately before submitClose. A
            // synthetic handle delays it until its WebSocket close can drain.
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
                if (c.external_close_ud != null) return error.AlreadyClosing;
                errdefer if (c.close.shutdown_requested) backend.platform.shutdownFd(c.os_fd);
                const cancelled = pendingExternalCount(c);
                try backend.ready.ensureUnusedCapacity(backend.allocator, cancelled + 1);
                const send_close = c.state == .open and !c.close.wire.hasSent();
                if (send_close and !c.pending.send)
                    try c.ws_out.ensureTotalCapacityPrecise(
                        backend.allocator,
                        try std.math.add(usize, c.ws_out.items.len, max_frame_header_len),
                    );
                c.close.graceful = send_close;
                c.state = .closing;
                c.external_close_ud = user_data;
                if (c.external_connect_ud) |ud| {
                    backend.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                    c.external_connect_ud = null;
                }
                if (c.external_recv_ud) |ud| {
                    backend.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                    c.external_recv_ud = null;
                }
                Access.refuseExternalSend(backend, c);
                if (!c.pending.send) {
                    advance(backend, c);
                    if (backend.conns.get(id)) |still_live| maybeFinish(backend, still_live);
                }
                return;
            }
            try backend.platform.submitClose(user_data, fd);
        }

        pub fn fail(backend: *Backend, c: *RelayConn) void {
            end(backend, c, -1);
        }

        pub fn failWith(
            backend: *Backend,
            c: *RelayConn,
            phase: carrier_failure.Phase,
            cause: anyerror,
        ) void {
            endWith(backend, c, -1, phase, cause);
        }

        /// Stop admitting work and publish every outstanding external result.
        /// `recv_result` preserves clean EOF (`0`) versus failure (`-1`).
        pub fn end(backend: *Backend, c: *RelayConn, recv_result: i32) void {
            endWith(backend, c, recv_result, .receive, null);
        }

        pub fn endWith(
            backend: *Backend,
            c: *RelayConn,
            recv_result: i32,
            phase: carrier_failure.Phase,
            cause: ?anyerror,
        ) void {
            std.debug.assert(recv_result == 0 or recv_result == -1);
            if (c.state == .closing) return;
            c.state = .closing;
            if (c.external_connect_ud) |ud| {
                var borrowed = Access.borrowCarrierFailure(backend, c);
                if (cause != null and borrowed.carrierPhase() == null)
                    borrowed = borrowed.withPhase(phase);
                backend.ready.appendAssumeCapacity(.{
                    .user_data = ud,
                    .result = -1,
                    .failure = cause,
                    .borrowed = borrowed,
                });
                c.external_connect_ud = null;
            }
            if (c.external_recv_ud) |ud| {
                var borrowed = if (recv_result < 0)
                    Access.borrowCarrierFailure(backend, c)
                else
                    @TypeOf(Access.borrowCarrierFailure(backend, c)){};
                if (cause != null and borrowed.carrierPhase() == null)
                    borrowed = borrowed.withPhase(phase);
                backend.ready.appendAssumeCapacity(.{
                    .user_data = ud,
                    .result = recv_result,
                    .failure = if (recv_result < 0) cause else null,
                    .borrowed = borrowed,
                });
                c.external_recv_ud = null;
            }
            Access.refuseExternalSendWith(backend, c, cause, phase);
            if (c.external_close_ud == null) backend.platform.shutdownFd(c.os_fd);
        }

        /// Finish the WebSocket half-close before retiring the wrapped socket.
        pub fn advance(backend: *Backend, c: *RelayConn) void {
            std.debug.assert(c.state == .closing and !c.pending.send);
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
            if (c.close.platform != .open or backend.close_retries.contains(c)) return;
            backend.platform.submitClose(Access.closeUserData(c.id), c.os_fd) catch {
                backend.platform.shutdownFd(c.os_fd);
                backend.close_retries.push(&backend.conns, c);
                return;
            };
            c.close.platform = .in_flight;
        }

        /// Retry only closes refused under transient queue or allocator
        /// pressure. Intrusive links keep recovery allocation-free.
        pub fn retryPendingCloses(backend: *Backend) void {
            const attempts = @min(backend.close_retries.count, close_retry_batch);
            for (0..attempts) |_| {
                const c = backend.close_retries.pop(&backend.conns) orelse unreachable;
                backend.platform.submitClose(Access.closeUserData(c.id), c.os_fd) catch {
                    backend.close_retries.push(&backend.conns, c);
                    continue;
                };
                c.close.platform = .in_flight;
            }
        }

        pub fn maybeFinish(backend: *Backend, c: *RelayConn) void {
            if (c.close.platform == .open or
                c.close.platform == .in_flight or
                c.pending.count() != 0) return;
            const platform_failed = c.close.platform == .failed;
            if (platform_failed) {
                backend.platform.closeFd(c.os_fd);
                c.close.platform = .closed;
            }
            const close_failed = Access.prepareCarrierClose(backend, c, platform_failed);
            if (c.external_close_ud) |ud| {
                const cause: ?anyerror = c.close.failure orelse
                    (if (close_failed) error.CloseFailed else null);
                var borrowed = if (close_failed)
                    Access.borrowCarrierFailure(backend, c)
                else
                    @TypeOf(Access.borrowCarrierFailure(backend, c)){};
                if (cause != null and borrowed.carrierPhase() == null)
                    borrowed = borrowed.withPhase(.shutdown);
                backend.ready.appendAssumeCapacity(.{
                    .user_data = ud,
                    .result = if (close_failed) -1 else 0,
                    .failure = cause,
                    .borrowed = borrowed,
                });
                c.external_close_ud = null;
            }
            if (Access.hasBorrowedCarrierFailure(backend, c)) return;
            destroy(backend, c.id);
        }

        pub fn pendingExternalCount(c: *const RelayConn) usize {
            return @as(usize, @intFromBool(c.external_connect_ud != null)) +
                @as(usize, @intFromBool(c.external_recv_ud != null)) +
                @as(usize, @intFromBool(c.external_send_ud != null));
        }

        fn destroy(backend: *Backend, id: Types.ConnId) void {
            const c = backend.conns.get(id) orelse unreachable;
            backend.recv_retries.removeIfQueued(&backend.conns, c);
            backend.close_retries.removeIfQueued(&backend.conns, c);
            const kv = backend.conns.fetchRemove(id) orelse unreachable;
            std.debug.assert(kv.value == c);
            Access.destroyCarrier(backend, c);
            c.deinit(backend.allocator);
            backend.allocator.destroy(c);
        }
    };
}
