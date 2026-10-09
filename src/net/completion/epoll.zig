//! Linux epoll readiness backend for `completion.Loop`.
//!
//! This is the fallback when the kernel or host policy cannot provide the
//! io_uring facilities glowcap requires. It preserves the same completion and
//! shared-buffer-pool contract. epoll reports readiness, so `poll` performs
//! nonblocking socket operations and synthesizes their completions.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const completion = @import("loop.zig");
const model = @import("model");
const BufferPool = @import("buffer_pool.zig").BufferPool;
const socket_tcp = @import("socket_tcp.zig");
const tcp_keepalive = @import("tcp_keepalive.zig");

comptime {
    if (builtin.os.tag != .linux) @compileError("the epoll completion backend is Linux-only");
}

const tcp_os = socket_tcp.Os.linux;

const PendingSend = struct { ud: u64, bytes: []const u8 };

const Pending = struct {
    read: union(enum) {
        idle,
        recv: u64,
        accept: u64,
        poll: u64,
    } = .idle,
    write: union(enum) {
        idle,
        send: PendingSend,
        connect: u64,
        poll: u64,
    } = .idle,
};

pub const Backend = struct {
    pub const Fd = linux.fd_t;
    pub const adapter_depth = 0;
    pub const ConnectTarget = std.Io.net.IpAddress;
    pub const ListenerAddress = socket_tcp.Ip4;

    allocator: std.mem.Allocator,
    epoll_fd: Fd,
    /// One row per descriptor with an armed direction. The map grows only when
    /// concurrent armed descriptors reach a new peak, then retains capacity so
    /// steady re-arm is allocation-free. A readiness event names an fd, and
    /// one fd may carry both a read and a write operation, so the backend needs
    /// this join from kernel identity to the two exact completion identities.
    pending: std.AutoHashMap(Fd, Pending),
    ready: completion.ReadyQueue,
    /// A control failure discovered after an operation already completed.
    /// The completion is returned first so the loop can retire its borrow and
    /// accounting; the next poll reports this exact backend failure.
    deferred_error: ?anyerror = null,
    buffer_pool: BufferPool,
    listener_ip4: [4]u8,
    test_state: if (builtin.is_test) struct {
        fail_next_control: bool = false,
        defer_next_recv: bool = false,
    } else struct {} = .{},

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
        _ = queue_entries;
        const fd_result = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.errno(fd_result) != .SUCCESS) return error.EpollCreateFailed;
        const epoll_fd: Fd = @intCast(fd_result);
        errdefer _ = linux.close(epoll_fd);

        var buffer_pool = try BufferPool.init(allocator, read_buffers, read_buffer_bytes);
        errdefer buffer_pool.deinit();

        return .{
            .allocator = allocator,
            .epoll_fd = epoll_fd,
            .pending = std.AutoHashMap(Fd, Pending).init(allocator),
            .ready = .{},
            .buffer_pool = buffer_pool,
            .listener_ip4 = listener_ip4,
        };
    }

    pub fn deinit(self: *Backend) void {
        self.buffer_pool.deinit();
        self.pending.deinit();
        self.ready.deinit(self.allocator);
        _ = linux.close(self.epoll_fd);
    }

    pub fn verifiedChannelKey(_: *Backend, _: Fd) ?[32]u8 {
        return null;
    }

    pub fn applyKeepalive(_: *Backend, fd: Fd, keepalive: completion.Keepalive) tcp_keepalive.ApplyError!void {
        return tcp_keepalive.apply(fd, keepalive);
    }

    pub fn wireFraming(_: *Backend, _: Fd) model.transport.WireFraming {
        return .byte_stream;
    }

    pub fn recycleBorrowed(self: *Backend, comp: completion.Completion) void {
        std.debug.assert(comp.borrowed.kind == .recv);
        self.buffer_pool.release(@intCast(comp.borrowed.token));
    }

    const ReservedSlot = struct {
        pending: *Pending,
        inserted: bool,
    };

    fn reserveSlot(self: *Backend, fd: Fd) !ReservedSlot {
        const gop = try self.pending.getOrPut(fd);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return .{ .pending = gop.value_ptr, .inserted = !gop.found_existing };
    }

    fn rollbackSlot(self: *Backend, fd: Fd, reserved: ReservedSlot) void {
        if (!reserved.inserted) return;
        std.debug.assert(reserved.pending.read == .idle and reserved.pending.write == .idle);
        std.debug.assert(self.pending.remove(fd));
    }

    fn interests(pending: Pending) u32 {
        var events: u32 = 0;
        if (pending.read != .idle) events |= linux.EPOLL.IN;
        if (pending.write != .idle) events |= linux.EPOLL.OUT;
        return events;
    }

    fn control(self: *Backend, operation: u32, fd: Fd, events: u32) !void {
        if (comptime builtin.is_test) {
            if (self.test_state.fail_next_control) {
                self.test_state.fail_next_control = false;
                return error.EpollControlFailed;
            }
        }
        var event: linux.epoll_event = .{
            .events = events,
            .data = .{ .fd = fd },
        };
        const result = linux.epoll_ctl(
            self.epoll_fd,
            operation,
            fd,
            if (operation == linux.EPOLL.CTL_DEL) null else &event,
        );
        if (linux.errno(result) != .SUCCESS) return error.EpollControlFailed;
    }

    fn register(self: *Backend, fd: Fd, pending: Pending, inserted: bool) !void {
        try self.control(
            if (inserted) linux.EPOLL.CTL_ADD else linux.EPOLL.CTL_MOD,
            fd,
            interests(pending),
        );
    }

    /// Reflect a completed operation in the kernel interest set. The old mask
    /// is a superset of the remaining directions, so a failed update leaves
    /// pending work observable. Keep the row in that case: removing it would
    /// make the next submission use ADD against a possibly live kernel entry.
    fn syncAfterCompletion(self: *Backend, fd: Fd, pending: Pending) void {
        const events = interests(pending);
        self.control(
            if (events == 0) linux.EPOLL.CTL_DEL else linux.EPOLL.CTL_MOD,
            fd,
            events,
        ) catch |err| {
            if (self.deferred_error == null) self.deferred_error = err;
            return;
        };
        if (events == 0) std.debug.assert(self.pending.remove(fd));
    }

    /// Submissions register with epoll as they are made; nothing waits.
    pub fn flush(_: *Backend) !void {}

    /// Nothing here waits on a timer: every completion arrives through the
    /// descriptor.
    pub fn waitBoundMs(_: *const Backend, requested_ms: i32) i32 {
        return requested_ms;
    }

    /// The descriptor that turns readable when `poll` has completions to
    /// return, once `flush` has run after the last submission. A resident
    /// that hands the loop's readiness to another waiter polls on it
    /// (`net.completion_resident`).
    pub fn readinessFd(self: *const Backend) Fd {
        return self.epoll_fd;
    }

    pub fn submitAccept(self: *Backend, user_data: u64, listen_fd: Fd) !void {
        const reserved = try self.reserveSlot(listen_fd);
        errdefer self.rollbackSlot(listen_fd, reserved);
        var next = reserved.pending.*;
        std.debug.assert(next.read == .idle);
        next.read = .{ .accept = user_data };
        try self.register(listen_fd, next, reserved.inserted);
        reserved.pending.* = next;
    }

    pub fn startDial(self: *Backend, user_data: u64, target: ConnectTarget) !Fd {
        const fd = try openSocket();
        errdefer self.closeFd(fd);
        if (!socket_tcp.setNodelay(tcp_os, fd)) return error.SocketConfigurationFailed;
        try self.submitConnect(user_data, fd, target);
        return fd;
    }

    fn submitConnect(self: *Backend, user_data: u64, fd: Fd, target: ConnectTarget) !void {
        const ip4 = try socket_tcp.ip4FromTarget(target);
        var address = socket_tcp.sockaddrIn4(tcp_os, ip4);
        const result = linux.connect(fd, @ptrCast(&address), @sizeOf(@TypeOf(address)));
        switch (linux.errno(result)) {
            .SUCCESS => {
                try self.ready.append(self.allocator, .{ .user_data = user_data, .result = 0 });
                return;
            },
            .INPROGRESS, .ALREADY => {},
            else => |err| {
                try self.ready.append(self.allocator, .{
                    .user_data = user_data,
                    .result = -1,
                    .failure = completion.failureFromErrno(err),
                });
                return;
            },
        }

        const reserved = try self.reserveSlot(fd);
        errdefer self.rollbackSlot(fd, reserved);
        var next = reserved.pending.*;
        std.debug.assert(next.write == .idle);
        next.write = .{ .connect = user_data };
        try self.register(fd, next, reserved.inserted);
        reserved.pending.* = next;
    }

    pub fn submitRecv(self: *Backend, user_data: u64, fd: Fd) !void {
        const reserved = try self.reserveSlot(fd);
        errdefer self.rollbackSlot(fd, reserved);
        var next = reserved.pending.*;
        std.debug.assert(next.read == .idle);
        next.read = .{ .recv = user_data };
        try self.register(fd, next, reserved.inserted);
        reserved.pending.* = next;
    }

    pub fn submitPoll(self: *Backend, user_data: u64, fd: Fd, interest: completion.Interest) !void {
        const reserved = try self.reserveSlot(fd);
        errdefer self.rollbackSlot(fd, reserved);
        var next = reserved.pending.*;
        switch (interest) {
            .readable => {
                std.debug.assert(next.read == .idle);
                next.read = .{ .poll = user_data };
            },
            .writable => {
                std.debug.assert(next.write == .idle);
                next.write = .{ .poll = user_data };
            },
        }
        try self.register(fd, next, reserved.inserted);
        reserved.pending.* = next;
    }

    pub fn submitSend(self: *Backend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        const reserved = try self.reserveSlot(fd);
        errdefer self.rollbackSlot(fd, reserved);
        var next = reserved.pending.*;
        std.debug.assert(next.write == .idle);
        next.write = .{ .send = .{ .ud = user_data, .bytes = bytes } };
        try self.register(fd, next, reserved.inserted);
        reserved.pending.* = next;
    }

    pub fn submitCancel(
        self: *Backend,
        cancel_user_data: u64,
        target_user_data: u64,
        fd: Fd,
    ) !void {
        const pending = self.pending.getPtr(fd) orelse return error.InvalidCancelTarget;
        var next = pending.*;
        const read_target = switch (pending.read) {
            .recv, .poll => |ud| ud == target_user_data,
            .idle, .accept => false,
        };
        const write_target = switch (pending.write) {
            .poll => |ud| ud == target_user_data,
            .idle, .send, .connect => false,
        };
        if (read_target) next.read = .idle else if (write_target) next.write = .idle else return error.InvalidCancelTarget;
        try self.ready.ensureUnusedCapacity(self.allocator, 2);
        const events = interests(next);
        try self.control(
            if (events == 0) linux.EPOLL.CTL_DEL else linux.EPOLL.CTL_MOD,
            fd,
            events,
        );
        pending.* = next;
        self.ready.appendAssumeCapacity(.{ .user_data = target_user_data, .result = -1 });
        self.ready.appendAssumeCapacity(.{ .user_data = cancel_user_data, .result = 0 });
        if (events == 0) std.debug.assert(self.pending.remove(fd));
    }

    pub fn submitClose(self: *Backend, user_data: u64, fd: Fd) !void {
        try self.ready.ensureUnusedCapacity(self.allocator, 3);
        if (self.pending.get(fd)) |pending| {
            switch (pending.read) {
                .idle => {},
                .recv, .accept, .poll => |ud| self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 }),
            }
            switch (pending.write) {
                .idle => {},
                .send => |send| self.ready.appendAssumeCapacity(.{ .user_data = send.ud, .result = -1 }),
                .connect, .poll => |ud| self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 }),
            }
        }
        _ = self.pending.remove(fd); // tolerant: an idle fd has no submitted operation and therefore no row
        self.control(linux.EPOLL.CTL_DEL, fd, 0) catch {}; // best-effort: close below removes the kernel registration
        _ = linux.close(fd);
        self.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
    }

    pub fn poll(self: *Backend, out: []completion.Completion, timeout_ms: i32) !usize {
        if (self.ready.len() > 0) return self.ready.drain(out);
        if (self.deferred_error) |err| {
            self.deferred_error = null;
            return err;
        }
        if (out.len == 0) return 0;

        var events: [256]linux.epoll_event = undefined;
        const wanted: u32 = @intCast(@min(out.len, events.len));
        const received = while (true) {
            const result = linux.epoll_wait(self.epoll_fd, &events, wanted, timeout_ms);
            switch (linux.errno(result)) {
                .SUCCESS => break result,
                // End this turn instead of restarting the full wait. The loop
                // owns the deadline and recomputes its remaining time before
                // polling again. Reusing `timeout_ms` here could extend a
                // finite deadline after every signal.
                .INTR => return 0,
                else => return error.EpollWaitFailed,
            }
        };

        var produced: usize = 0;
        for (events[0..received]) |event| {
            const fd = event.data.fd;
            const pending = self.pending.getPtr(fd) orelse continue;
            const read_ready = event.events & (linux.EPOLL.IN | linux.EPOLL.ERR | linux.EPOLL.HUP | linux.EPOLL.RDHUP) != 0;
            const write_ready = event.events & (linux.EPOLL.OUT | linux.EPOLL.ERR | linux.EPOLL.HUP) != 0;
            var completed = false;

            if (read_ready and produced < out.len) {
                switch (pending.read) {
                    .idle => {},
                    .recv => |ud| if (self.completeRecv(fd, ud)) |comp| {
                        pending.read = .idle;
                        out[produced] = comp;
                        produced += 1;
                        completed = true;
                    },
                    .accept => |ud| if (completeAccept(fd, ud)) |comp| {
                        pending.read = .idle;
                        out[produced] = comp;
                        produced += 1;
                        completed = true;
                    },
                    .poll => |ud| {
                        pending.read = .idle;
                        out[produced] = .{ .user_data = ud, .result = 0 };
                        produced += 1;
                        completed = true;
                    },
                }
            }
            if (write_ready and produced < out.len) {
                switch (pending.write) {
                    .idle => {},
                    .connect => |ud| {
                        pending.write = .idle;
                        const failure = connectFailure(fd);
                        out[produced] = .{
                            .user_data = ud,
                            .result = if (failure == null) 0 else -1,
                            .failure = failure,
                        };
                        produced += 1;
                        completed = true;
                    },
                    .send => |send| if (completeSend(fd, send)) |comp| {
                        pending.write = .idle;
                        out[produced] = comp;
                        produced += 1;
                        completed = true;
                    },
                    .poll => |ud| {
                        pending.write = .idle;
                        out[produced] = .{ .user_data = ud, .result = 0 };
                        produced += 1;
                        completed = true;
                    },
                }
            }

            if (completed) {
                // `pending` remains stable until both directions above finish.
                // Updating or removing the map row only after both avoids using
                // a pointer invalidated by the first completion.
                self.syncAfterCompletion(fd, pending.*);
            }
        }
        return produced;
    }

    fn completeRecv(self: *Backend, fd: Fd, user_data: u64) ?completion.Completion {
        if (comptime builtin.is_test) {
            if (self.test_state.defer_next_recv) {
                self.test_state.defer_next_recv = false;
                return null;
            }
        }
        const index = self.buffer_pool.acquire() orelse return .{
            .user_data = user_data,
            .result = -1,
            .recv_no_buffer = true,
        };
        const buffer = self.buffer_pool.buffer(index);
        const result = linux.recvfrom(fd, buffer.ptr, buffer.len, linux.MSG.DONTWAIT, null, null);
        switch (linux.errno(result)) {
            .SUCCESS => {
                const count: usize = @intCast(result);
                if (count == 0) {
                    self.buffer_pool.release(index);
                    return .{ .user_data = user_data, .result = 0 };
                }
                return .{
                    .user_data = user_data,
                    .result = @intCast(count),
                    .borrowed = .recv(buffer[0..count], index),
                };
            },
            .AGAIN, .INTR => {
                self.buffer_pool.release(index);
                return null;
            },
            else => |err| {
                self.buffer_pool.release(index);
                return .{
                    .user_data = user_data,
                    .result = -1,
                    .failure = completion.failureFromErrno(err),
                };
            },
        }
    }

    fn completeAccept(fd: Fd, user_data: u64) ?completion.Completion {
        const result = linux.accept4(fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
        switch (linux.errno(result)) {
            .SUCCESS => {
                const accepted: Fd = @intCast(result);
                if (!socket_tcp.setNodelay(tcp_os, accepted)) {
                    _ = linux.close(accepted);
                    return .{
                        .user_data = user_data,
                        .result = -1,
                        .failure = error.SocketConfigurationFailed,
                    };
                }
                return .{ .user_data = user_data, .result = accepted };
            },
            .AGAIN, .INTR => return null,
            else => |err| return .{
                .user_data = user_data,
                .result = -1,
                .failure = completion.failureFromErrno(err),
            },
        }
    }

    fn completeSend(fd: Fd, pending: PendingSend) ?completion.Completion {
        const result = linux.sendto(
            fd,
            pending.bytes.ptr,
            pending.bytes.len,
            linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL,
            null,
            0,
        );
        return switch (linux.errno(result)) {
            .SUCCESS => .{ .user_data = pending.ud, .result = @intCast(result) },
            .AGAIN, .INTR => null,
            else => |err| .{
                .user_data = pending.ud,
                .result = -1,
                .failure = completion.failureFromErrno(err),
            },
        };
    }

    /// The interface every listener binds; `openListener` chooses only the
    /// port.
    pub fn listenerIp4(self: *const Backend) [4]u8 {
        return self.listener_ip4;
    }

    /// The port a listener binds on the construction-time interface.
    pub const ListenTarget = u16;

    pub fn loopListenTarget(port: u16) ListenTarget {
        return port;
    }

    pub fn openListener(self: *Backend, port: u16) !Fd {
        const fd = try socket_tcp.openListener(tcp_os, .{
            .bytes = self.listener_ip4,
            .port = port,
        });
        errdefer _ = linux.close(fd);
        if (!socket_tcp.setNonblocking(fd)) return error.SocketConfigurationFailed;
        return fd;
    }

    pub fn openSocket() !Fd {
        const fd = try socket_tcp.openSocket(tcp_os);
        errdefer _ = linux.close(fd);
        if (!socket_tcp.setNonblocking(fd)) return error.SocketConfigurationFailed;
        return fd;
    }

    pub fn listenerAddress(_: *Backend, fd: Fd) !ListenerAddress {
        return socket_tcp.boundIp4(tcp_os, fd);
    }

    pub fn listenerPort(address: ListenerAddress) ?u16 {
        return address.port;
    }

    pub fn closeFd(_: *Backend, fd: Fd) void {
        _ = linux.close(fd);
    }

    pub fn shutdownFd(_: *Backend, fd: Fd) void {
        _ = linux.shutdown(fd, linux.SHUT.RDWR);
    }
};

pub const white_box = if (builtin.is_test) struct {
    pub const TestBackend = Backend;

    pub fn pendingCount(backend: *const Backend) usize {
        return backend.pending.count();
    }

    pub fn failNextControl(backend: *Backend) void {
        backend.test_state.fail_next_control = true;
    }

    pub fn deferNextRecv(backend: *Backend) void {
        backend.test_state.defer_next_recv = true;
    }
} else struct {};

fn connectFailure(fd: linux.fd_t) ?anyerror {
    var socket_error: i32 = 0;
    var length: u32 = @sizeOf(i32);
    const result = linux.getsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.ERROR,
        std.mem.asBytes(&socket_error),
        &length,
    );
    if (linux.errno(result) != .SUCCESS) return error.GetsockoptFailed;
    return if (socket_error == 0)
        null
    else
        completion.failureFromErrno(@fromBackingInt(@intCast(socket_error)));
}
