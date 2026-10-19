//! Caller-owned out-of-band wake lifecycle (ADR-0014).
//!
//! The loop borrows the wake descriptor, owns one recv/cancel seat at a time,
//! and never closes the caller's handle. Refused rearm and cancellation remain
//! explicit owed work for the driver to retry before sleeping.

const std = @import("std");
const state = @import("state.zig");
const affinity = @import("affinity.zig");

pub fn Machine(comptime Self: type, comptime Types: type) type {
    return struct {
        const Fd = Types.Fd;

        /// Arm an ordinary recv on the caller-owned wake descriptor. Its
        /// completion runs `handler` on the loop thread and re-arms. The
        /// descriptor must outlive the loop's borrowed use (ADR-0014).
        pub fn armWake(
            self: *Self,
            fd: Fd,
            ctx: ?*anyopaque,
            handler: *const fn (?*anyopaque) void,
        ) !void {
            affinity.assertOwnerOrUnclaimed(self);
            if (self.shutting_down or self.tearing_down) return error.ShuttingDown;
            std.debug.assert(self.wake == null); // one wake channel per loop
            // Setup is transactional: a refused first submission leaves no
            // borrowed descriptor or callback behind and reaches the caller
            // through this fallible API.
            try self.backend.submitRecv(state.userData(.wake, 0), fd);
            self.wake = .{ .fd = fd, .ctx = ctx, .handler = handler };
            self.wake_armed = true;
        }

        /// A wake recv completed: run the handler and re-arm. A closed or
        /// faulted channel (teardown pulled the mailbox) stays disarmed. A
        /// re-arm the backend cannot admit right now is retried before the
        /// next wait, bounded like an owed close.
        pub fn onWakeCompletion(self: *Self, result: i32) !void {
            const wake = self.wake orelse return;
            if (result <= 0) {
                self.wake = null;
                return;
            }
            wake.handler(wake.ctx);
            self.backend.submitRecv(state.userData(.wake, 0), wake.fd) catch |err| {
                self.wake_rearm_pending = true;
                return err;
            };
            self.wake_armed = true;
        }

        pub fn retryWakeRearm(self: *Self) !void {
            if (!self.wake_rearm_pending) return;
            const wake = self.wake orelse {
                self.wake_rearm_pending = false;
                return;
            };
            try self.backend.submitRecv(state.userData(.wake, 0), wake.fd);
            self.wake_rearm_pending = false;
            self.wake_armed = true;
        }

        /// Retire the caller-owned wake recv without touching its descriptor.
        /// A refused cancel submission mints no completion and is retried on a
        /// bounded poll. An admitted one owns a distinct completion in addition
        /// to the target recv completion.
        pub fn retryWakeCancel(self: *Self) !void {
            if (!self.wake_cancel_submit_pending) return;
            std.debug.assert(self.wake_armed);
            std.debug.assert(!self.wake_cancel_pending);
            const wake = self.wake orelse unreachable;
            try self.backend.submitCancel(
                state.userData(.wake_cancel, 0),
                state.userData(.wake, 0),
                wake.fd,
            );
            self.wake_cancel_submit_pending = false;
            self.wake_cancel_pending = true;
        }
    };
}
