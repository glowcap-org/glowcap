//! Runtime selection for glowcap's Linux completion backend.
//!
//! io_uring remains preferred. epoll is selected when the kernel or host policy
//! cannot provide the facilities required by glowcap's io_uring ownership
//! model. The selected backend and exact fallback reason remain queryable. This
//! layer does not print from a reusable library.

const std = @import("std");
const builtin = @import("builtin");

const completion = @import("loop.zig");
const epoll = @import("epoll.zig");
const uring = @import("uring.zig");

comptime {
    if (builtin.os.tag != .linux) @compileError("the Linux completion selector is Linux-only");
}

pub const Implementation = enum {
    io_uring,
    epoll,
};

pub const FallbackReason = enum {
    io_uring_system_outdated,
    io_uring_permission_denied,
    provided_buffer_ring_unsupported,

    pub fn message(reason: FallbackReason) []const u8 {
        return switch (reason) {
            .io_uring_system_outdated => "the kernel does not provide the io_uring features glowcap requires",
            .io_uring_permission_denied => "host policy denied io_uring initialization",
            .provided_buffer_ring_unsupported => "the kernel rejected io_uring provided-buffer registration",
        };
    }
};

pub const Status = struct {
    implementation: Implementation,
    fallback_reason: ?FallbackReason,
};

fn fallbackReason(err: anyerror) ?FallbackReason {
    return switch (err) {
        error.IoUringSystemOutdated => .io_uring_system_outdated,
        error.IoUringInitDenied => .io_uring_permission_denied,
        error.ProvidedBufferRingUnsupported => .provided_buffer_ring_unsupported,
        else => null,
    };
}

const Selection = enum {
    io_uring,
    epoll_system_outdated,
    epoll_permission_denied,
    epoll_provided_buffer_ring_unsupported,
};

pub const Backend = union(Selection) {
    pub const Fd = uring.Backend.Fd;
    pub const adapter_depth = 0;
    pub const ConnectTarget = uring.Backend.ConnectTarget;
    pub const ListenerAddress = uring.Backend.ListenerAddress;

    io_uring: uring.Backend,
    epoll_system_outdated: epoll.Backend,
    epoll_permission_denied: epoll.Backend,
    epoll_provided_buffer_ring_unsupported: epoll.Backend,

    pub fn init(
        allocator: std.mem.Allocator,
        queue_entries: u16,
        read_buffers: u16,
        read_buffer_bytes: u32,
    ) !Backend {
        return initWithListenerIp4(
            allocator,
            queue_entries,
            read_buffers,
            read_buffer_bytes,
            .{ 127, 0, 0, 1 },
        );
    }

    pub fn initWithListenerIp4(
        allocator: std.mem.Allocator,
        queue_entries: u16,
        read_buffers: u16,
        read_buffer_bytes: u32,
        listener_ip4: [4]u8,
    ) !Backend {
        const preferred = uring.Backend.initWithListenerIp4(
            allocator,
            queue_entries,
            read_buffers,
            read_buffer_bytes,
            listener_ip4,
        ) catch |err| {
            const reason = fallbackReason(err) orelse return err;
            const fallback = try epoll.Backend.initWithListenerIp4(
                allocator,
                queue_entries,
                read_buffers,
                read_buffer_bytes,
                listener_ip4,
            );
            return switch (reason) {
                .io_uring_system_outdated => .{ .epoll_system_outdated = fallback },
                .io_uring_permission_denied => .{ .epoll_permission_denied = fallback },
                .provided_buffer_ring_unsupported => .{ .epoll_provided_buffer_ring_unsupported = fallback },
            };
        };
        return .{ .io_uring = preferred };
    }

    pub fn tcpBackendStatus(self: *const Backend) Status {
        return switch (self.*) {
            .io_uring => .{ .implementation = .io_uring, .fallback_reason = null },
            .epoll_system_outdated => .{
                .implementation = .epoll,
                .fallback_reason = .io_uring_system_outdated,
            },
            .epoll_permission_denied => .{
                .implementation = .epoll,
                .fallback_reason = .io_uring_permission_denied,
            },
            .epoll_provided_buffer_ring_unsupported => .{
                .implementation = .epoll,
                .fallback_reason = .provided_buffer_ring_unsupported,
            },
        };
    }

    pub fn deinit(self: *Backend) void {
        switch (self.*) {
            inline else => |*backend| backend.deinit(),
        }
    }

    pub fn listenerIp4(self: *const Backend) [4]u8 {
        return switch (self.*) {
            inline else => |*backend| backend.listenerIp4(),
        };
    }

    pub const ListenTarget = u16;

    pub fn loopListenTarget(port: u16) ListenTarget {
        return port;
    }

    pub fn openListener(self: *Backend, port: u16) !Fd {
        return switch (self.*) {
            inline else => |*backend| backend.openListener(port),
        };
    }

    pub fn listenerAddress(self: *Backend, fd: Fd) !ListenerAddress {
        return switch (self.*) {
            inline else => |*backend| backend.listenerAddress(fd),
        };
    }

    pub fn listenerPort(address: ListenerAddress) ?u16 {
        return uring.Backend.listenerPort(address);
    }

    pub fn closeFd(self: *Backend, fd: Fd) void {
        switch (self.*) {
            inline else => |*backend| backend.closeFd(fd),
        }
    }

    pub fn startDial(self: *Backend, user_data: u64, target: ConnectTarget) !Fd {
        return switch (self.*) {
            inline else => |*backend| backend.startDial(user_data, target),
        };
    }

    pub fn shutdownFd(self: *Backend, fd: Fd) void {
        switch (self.*) {
            inline else => |*backend| backend.shutdownFd(fd),
        }
    }

    pub fn wireFraming(self: *Backend, fd: Fd) @import("model").transport.WireFraming {
        return switch (self.*) {
            inline else => |*backend| backend.wireFraming(fd),
        };
    }

    pub fn flush(self: *Backend) !void {
        return switch (self.*) {
            inline else => |*backend| backend.flush(),
        };
    }

    /// A platform listener is bound when `openListener` returns; nothing
    /// pends.
    pub fn listenerPending(_: *const Backend, _: Fd) bool {
        return false;
    }

    pub fn waitBoundMs(self: *const Backend, requested_ms: i32) i32 {
        return switch (self.*) {
            inline else => |*backend| backend.waitBoundMs(requested_ms),
        };
    }

    pub fn readinessFd(self: *const Backend) Fd {
        return switch (self.*) {
            inline else => |*backend| backend.readinessFd(),
        };
    }

    pub fn submitAccept(self: *Backend, user_data: u64, fd: Fd) !void {
        return switch (self.*) {
            inline else => |*backend| backend.submitAccept(user_data, fd),
        };
    }

    pub fn submitRecv(self: *Backend, user_data: u64, fd: Fd) !void {
        return switch (self.*) {
            inline else => |*backend| backend.submitRecv(user_data, fd),
        };
    }

    pub fn submitSend(self: *Backend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        return switch (self.*) {
            inline else => |*backend| backend.submitSend(user_data, fd, bytes),
        };
    }

    pub fn submitPoll(self: *Backend, user_data: u64, fd: Fd, interest: completion.Interest) !void {
        return switch (self.*) {
            inline else => |*backend| backend.submitPoll(user_data, fd, interest),
        };
    }

    pub fn submitCancel(self: *Backend, cancel_ud: u64, target_ud: u64, fd: Fd) !void {
        return switch (self.*) {
            inline else => |*backend| backend.submitCancel(cancel_ud, target_ud, fd),
        };
    }

    pub fn submitClose(self: *Backend, user_data: u64, fd: Fd) !void {
        return switch (self.*) {
            inline else => |*backend| backend.submitClose(user_data, fd),
        };
    }

    pub fn recycleBorrowed(self: *Backend, comp: completion.Completion) void {
        switch (self.*) {
            inline else => |*backend| backend.recycleBorrowed(comp),
        }
    }

    pub fn poll(self: *Backend, out: []completion.Completion, timeout_ms: i32) !usize {
        return switch (self.*) {
            inline else => |*backend| backend.poll(out, timeout_ms),
        };
    }

    pub fn verifiedChannelKey(self: *Backend, fd: Fd) ?[32]u8 {
        return switch (self.*) {
            inline else => |*backend| backend.verifiedChannelKey(fd),
        };
    }

    pub fn applyKeepalive(self: *Backend, fd: Fd, keepalive: completion.Keepalive) !void {
        return switch (self.*) {
            inline else => |*backend| backend.applyKeepalive(fd, keepalive),
        };
    }
};

pub const white_box = if (builtin.is_test) struct {
    pub fn fallbackReasonFor(err: anyerror) ?FallbackReason {
        return fallbackReason(err);
    }
} else struct {};
