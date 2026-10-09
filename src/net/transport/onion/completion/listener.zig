//! Listeners for the completion-backed onion adapter.
//!
//! A plain listener is the inner backend's own and passes through untouched.
//! An onion listener binds an inner listener, then publishes that exact bound
//! endpoint as a Tor onion service through one control connection. The
//! control connection stays open for the listener's lifetime, which is Tor's
//! undetached-service lifetime rule, so closing the listener withdraws the
//! service. One backend publishes one service.

const std = @import("std");

const socks5 = @import("../socks5.zig");
const Published = @import("control.zig").Published;

pub fn Machine(comptime Backend: type, comptime Inner: type, comptime ControlTransaction: type) type {
    return struct {
        pub const ServiceId = [socks5.service_id_len]u8;

        /// `onion` names the inner listener the service forwards to.
        pub const Target = union(enum) {
            platform: Inner.ListenTarget,
            onion: Inner.ListenTarget,
        };

        pub const Address = union(enum) {
            platform: Inner.ListenerAddress,
            onion: ServiceId,
        };

        /// The published listener, set only once its service exists.
        pub const State = struct {
            fd: ?Inner.Fd = null,
            service: Published = undefined,
        };

        pub fn open(backend: *Backend, target: Target) !Inner.Fd {
            const inner_target = switch (target) {
                .platform => |platform_target| return backend.inner.openListener(platform_target),
                .onion => |onion_target| onion_target,
            };
            if (backend.listener.fd != null) return error.ListenerAlreadyOpen;
            const config = backend.config orelse return error.OnionControlNotConfigured;
            const control_target = config.control orelse return error.OnionControlNotConfigured;
            const fd = try backend.inner.openListener(inner_target);
            errdefer backend.inner.closeFd(fd);
            const bound = Inner.listenerPort(try backend.inner.listenerAddress(fd)) orelse
                return error.ListenerNotForwardable;
            const service = try ControlTransaction.publish(backend, control_target, bound, config);
            backend.listener = .{ .fd = fd, .service = service };
            return fd;
        }

        pub fn owns(backend: *const Backend, fd: Inner.Fd) bool {
            return backend.listener.fd == fd;
        }

        pub fn address(backend: *Backend, fd: Inner.Fd) !Address {
            if (owns(backend, fd)) return .{ .onion = backend.listener.service.service_id };
            return .{ .platform = try backend.inner.listenerAddress(fd) };
        }

        /// The key that restores the published service on `fd`; null for a
        /// platform listener.
        pub fn serviceKey(backend: *const Backend, fd: Inner.Fd) ?[]const u8 {
            if (!owns(backend, fd)) return null;
            return backend.listener.service.key[0..backend.listener.service.key_len];
        }

        pub fn port(value: Address) ?u16 {
            return switch (value) {
                .platform => |platform_address| Inner.listenerPort(platform_address),
                .onion => null,
            };
        }

        /// Close the published listener; the service goes with its control
        /// connection.
        pub fn submitClose(backend: *Backend, user_data: u64, fd: Inner.Fd) !void {
            std.debug.assert(owns(backend, fd));
            try backend.inner.submitClose(user_data, fd);
            withdraw(backend);
        }

        pub fn close(backend: *Backend, fd: Inner.Fd) void {
            std.debug.assert(owns(backend, fd));
            withdraw(backend);
            backend.inner.closeFd(fd);
        }

        fn withdraw(backend: *Backend) void {
            if (backend.control_fd) |control_fd| backend.inner.closeFd(control_fd);
            backend.control_fd = null;
            backend.listener = .{};
        }
    };
}
