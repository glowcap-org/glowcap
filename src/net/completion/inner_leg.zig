//! Terminal lifecycle for one wrapped leg, shared by every completion
//! adapter that runs a synthetic handle over an inner connection.
//!
//! Once a relay or onion leg has finished its protocol work, its
//! close is the same choreography: refuse every external seat exactly once,
//! carry the inner descriptor through close submission, retry, or direct
//! release, and retire the row only when nothing borrowed remains. This
//! module owns that choreography. Each adapter keeps its own row type and
//! supplies, through `Access`, the steps that differ by transport: what a
//! refused send carries, how a requested close starts on the wire, and which
//! retry memberships to clear.
//!
//! A row is any struct with these fields: `id`, `inner_fd`, `state` (an
//! enum with a `closing` member), `pending` (a `PendingOps`), `inner_close`
//! (an `InnerClose`), and the seats `external_connect_ud`,
//! `external_recv_ud`, `external_send_ud`, and `external_close_ud`. The
//! backend keeps `allocator`, `ready`, and `conns`. The inner backend is
//! passed to every verb because one adapter borrows it per operation rather
//! than owning it.
//!
//! `Access` supplies:
//!
//!   * `closeUserData(id) u64`, the internal user data a close submits under.
//!   * `onClosing(backend, inner, c, how) void`, run once as the row enters
//!     `closing`, before its state changes and before any seat is refused;
//!   * `prepareClose(backend, inner, c) !void` and `closeRefused(backend,
//!     inner, c) void`, the fallible preparation a requested close needs and
//!     its undo when a later step refuses;
//!   * `refuseExternalSend(backend, c, cause, phase) void`, which publishes
//!     and clears the send seat in the adapter's own shape;
//!   * `startClose(backend, inner, c) void`, how a requested close proceeds
//!     once every seat is refused;
//!   * `owesClose`, `oweClose`, and `clearOwedClose`, the close-submission
//!     debt;
//!   * `lendActive(c) bool`, whether the row still lends bytes to the loop.
//!   * `borrowFailure(backend, c) Borrowed`, `prepareFinish(backend, c,
//!     inner_failed) bool`, `closeCause(c) ?anyerror`, and
//!     `hasBorrowedFailure(backend, c) bool`, the failure a close result
//!     carries and whether it is still lent;
//!   * `retireRow(backend, c) void` and `deinitRow(backend, inner, c) void`,
//!     the adapter's side of destruction.

const std = @import("std");

const contract = @import("contract.zig");
const carrier_failure = @import("../carrier_failure.zig");

/// Why a leg is entering `closing`.
pub const Closing = enum {
    /// The wire or the inner connection ended it.
    ended,
    /// The loop submitted a close.
    requested,
    /// The loop released the handle with nothing pending.
    abandoned,
};

pub fn Lifecycle(
    comptime Backend: type,
    comptime Inner: type,
    comptime Types: type,
    comptime Access: type,
) type {
    return struct {
        const Conn = Types.Conn;
        const ConnId = Types.ConnId;

        /// Release a synthetic handle the loop no longer waits on. Every status-allow: lifecycle transition
        /// external seat has settled, so nothing is published here. The inner
        /// descriptor is driven to closed and the row retires once no inner
        /// operation or lent buffer remains.
        pub fn closeRow(backend: *Backend, inner: *Inner, c: *Conn) void {
            std.debug.assert(externalSeatCount(c) == 0);
            if (c.inner_close != .closed) {
                if (c.state != .closing) Access.onClosing(backend, inner, c, .abandoned);
                c.state = .closing;
                inner.shutdownFd(c.inner_fd);
                if (c.inner_close == .open and c.pending.count() == 0) {
                    Access.clearOwedClose(backend, c);
                    inner.closeFd(c.inner_fd);
                    c.inner_close = .closed;
                } else if (c.inner_close == .open) {
                    beginInnerClose(backend, inner, c);
                }
            }
            if (c.inner_close == .failed and c.pending.count() == 0) {
                inner.closeFd(c.inner_fd);
                c.inner_close = .closed;
            }
            maybeFinish(backend, inner, c);
        }

        /// Submit a close the loop will wait on. Every external seat owes a
        /// record and the close owes one more. All are reserved before any
        /// state changes, so the publications below cannot fail.
        pub fn submitCloseRow(backend: *Backend, inner: *Inner, c: *Conn, user_data: u64) !void {
            if (c.external_close_ud != null) return error.AlreadyClosing;
            errdefer Access.closeRefused(backend, inner, c);
            try backend.ready.ensureUnusedCapacity(backend.allocator, externalSeatCount(c) + 1);
            try Access.prepareClose(backend, inner, c);
            Access.onClosing(backend, inner, c, .requested);
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
            Access.refuseExternalSend(backend, c, null, .transmit);
            Access.startClose(backend, inner, c);
            if (backend.conns.get(c.id)) |live| maybeFinish(backend, inner, live);
        }

        pub fn fail(backend: *Backend, inner: *Inner, c: *Conn) void {
            end(backend, inner, c, -1);
        }

        pub fn failWith(
            backend: *Backend,
            inner: *Inner,
            c: *Conn,
            phase: carrier_failure.Phase,
            cause: anyerror,
        ) void {
            endWith(backend, inner, c, -1, phase, cause);
        }

        /// Stop admitting work and publish every outstanding external result.
        /// `recv_result` preserves clean EOF (`0`) versus failure (`-1`).
        pub fn end(backend: *Backend, inner: *Inner, c: *Conn, recv_result: i32) void {
            endWith(backend, inner, c, recv_result, .receive, null);
        }

        pub fn endWith(
            backend: *Backend,
            inner: *Inner,
            c: *Conn,
            recv_result: i32,
            phase: carrier_failure.Phase,
            cause: ?anyerror,
        ) void {
            std.debug.assert(recv_result == 0 or recv_result == -1);
            if (c.state == .closing) return;
            Access.onClosing(backend, inner, c, .ended);
            c.state = .closing;
            if (c.external_connect_ud) |ud| {
                var borrowed = Access.borrowFailure(backend, c);
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
                var borrowed: contract.Borrowed = if (recv_result < 0)
                    Access.borrowFailure(backend, c)
                else
                    .{};
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
            Access.refuseExternalSend(backend, c, cause, phase);
            if (c.external_close_ud == null) inner.shutdownFd(c.inner_fd);
        }

        /// Submit the inner close, or owe it when the inner backend refuses
        /// the submission under transient pressure.
        pub fn beginInnerClose(backend: *Backend, inner: *Inner, c: *Conn) void {
            if (c.inner_close != .open or Access.owesClose(backend, c)) return;
            inner.submitClose(Access.closeUserData(c.id), c.inner_fd) catch {
                inner.shutdownFd(c.inner_fd);
                Access.oweClose(backend, c);
                return;
            };
            c.inner_close = .in_flight;
        }

        /// Publish the close result and retire the row once the inner close
        /// has settled and nothing pending or lent remains.
        pub fn maybeFinish(backend: *Backend, inner: *Inner, c: *Conn) void {
            if (c.state != .closing) return;
            if (c.inner_close == .open or
                c.inner_close == .in_flight or
                Access.owesClose(backend, c)) return;
            if (c.pending.count() != 0 or Access.lendActive(c)) return;
            const inner_failed = c.inner_close == .failed;
            if (inner_failed) {
                inner.closeFd(c.inner_fd);
                c.inner_close = .closed;
            }
            const close_failed = Access.prepareFinish(backend, c, inner_failed);
            if (c.external_close_ud) |ud| {
                const cause: ?anyerror = Access.closeCause(c) orelse
                    (if (close_failed) error.CloseFailed else null);
                var borrowed: contract.Borrowed = if (close_failed)
                    Access.borrowFailure(backend, c)
                else
                    .{};
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
            if (Access.hasBorrowedFailure(backend, c)) return;
            destroy(backend, inner, c.id);
        }

        pub fn externalSeatCount(c: *const Conn) usize {
            return @as(usize, @intFromBool(c.external_connect_ud != null)) +
                @as(usize, @intFromBool(c.external_recv_ud != null)) +
                @as(usize, @intFromBool(c.external_send_ud != null));
        }

        fn destroy(backend: *Backend, inner: *Inner, id: ConnId) void {
            const c = backend.conns.get(id) orelse unreachable;
            Access.retireRow(backend, c);
            const kv = backend.conns.fetchRemove(id) orelse unreachable;
            std.debug.assert(kv.value == c);
            Access.deinitRow(backend, inner, c);
            backend.allocator.destroy(c);
        }
    };
}
