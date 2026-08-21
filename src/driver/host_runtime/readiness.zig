//! Aggregate readiness ownership and runtime event observers.

const std = @import("std");

const net = @import("net");

const lifecycle = @import("lifecycle.zig");
const pending_state = @import("pending.zig");
const runtime = @import("../host_runtime.zig");
const wire_state = @import("wire.zig");

const HostRuntime = runtime.HostRuntime;
const Internal = runtime.Internal;

/// One source selected from the aggregate readiness wait.
pub const Source = union(enum) {
    wire: *wire_state.Wire,
    resident: usize,
    stream_dial: *pending_state.Open,
    stream_listen: *pending_state.Listener,
    stream_accept: *lifecycle.TransportListener,
};

/// Arm the aggregate readiness set and return its one pollable descriptor.
pub fn readinessDescriptor(self: *HostRuntime) !i32 {
    try Internal.admitApplicationOperation(self);
    if (self.ready_set) |*ready_set| return ready_set.descriptor();
    var ready_set = try net.ReadySet.init();
    errdefer ready_set.deinit();
    var wires = self.wires.valueIterator();
    while (wires.next()) |wire| switch (wire.*.link) {
        .stream => |*stream| if (stream.conn.socketHandle()) |fd| {
            if (!wire.*.closed)
                try ready_set.add(fd)
            else if (!wire.*.carrierClosed()) switch (wire.*.carrier_close) {
                .wait_read => try ready_set.setInterest(fd, .read),
                .wait_write => try ready_set.setInterest(fd, .write),
                .open, .wait_resident, .complete => {},
            };
        },
        .resident => {},
    };
    var retiring = self.retiring_wires;
    while (retiring) |wire| : (retiring = wire.retiring_next) switch (wire.link) {
        .stream => |*stream| if (stream.conn.socketHandle()) |fd| switch (wire.carrier_close) {
            .wait_read => try ready_set.setInterest(fd, .read),
            .wait_write => try ready_set.setInterest(fd, .write),
            .open, .wait_resident, .complete => {},
        },
        .resident => {},
    };
    for (self.residents.items) |registered| try ready_set.add(registered.readiness_fd);
    for (self.listener_fds.items) |fd| try ready_set.add(fd);
    for (self.pending_opens.items) |row| switch (row.stage) {
        .stream_dial => |attempt| try ready_set.add(attempt.readinessFd()),
        .resident_dial, .handshake => {},
    };
    for (self.pending_listeners.items) |row| switch (row.stage) {
        .stream => |attempt| try ready_set.add(attempt.readinessFd()),
        .resident => {},
    };
    if (self.mailbox) |mailbox| try ready_set.add(mailbox.wakeFd());
    self.ready_set = ready_set;
    return ready_set.descriptor();
}

pub fn watchFd(self: *HostRuntime, fd: i32) !void {
    if (fd < 0) return error.ReadinessUnavailable;
    if (descriptorInUse(self, fd)) return error.ReadinessDescriptorConflict;
    try self.listener_fds.ensureUnusedCapacity(self.allocator, 1);
    if (self.ready_set) |*ready_set| try ready_set.add(fd);
    self.listener_fds.appendAssumeCapacity(fd);
}

pub fn unwatchFd(self: *HostRuntime, fd: i32) void {
    removeReadyFd(self, fd);
    for (self.listener_fds.items, 0..) |existing, index| if (existing == fd) {
        std.debug.assert(self.listener_fds.swapRemove(index) == fd);
        return;
    };
}

pub fn removeReadyFd(self: *HostRuntime, fd: i32) void {
    if (self.ready_set) |*ready_set|
        ready_set.remove(fd) catch |err| self.noteTerminalFailure(err);
}

/// Descriptor integer aliasing is never identity: duplicate rows make poll
/// routing ambiguous and removing either owner would silence the other.
pub fn descriptorInUse(self: *const HostRuntime, fd: i32) bool {
    for (self.residents.items) |registered| if (registered.readiness_fd == fd) return true;
    for (self.listener_fds.items) |listener_fd| if (listener_fd == fd) return true;
    var wires = self.wires.valueIterator();
    while (wires.next()) |wire| switch (wire.*.link) {
        .stream => |*stream| if (stream.conn.socketHandle() == fd) return true,
        .resident => {},
    };
    for (self.pending_opens.items) |row| switch (row.stage) {
        .stream_dial => |attempt| if (attempt.readinessFd() == fd) return true,
        .resident_dial, .handshake => {},
    };
    for (self.pending_listeners.items) |row| switch (row.stage) {
        .stream => |attempt| if (attempt.readinessFd() == fd) return true,
        .resident => {},
    };
    if (self.mailbox) |mailbox| if (mailbox.wakeFd() == fd) return true;
    if (self.ready_set) |*ready_set|
        if (ready_set.descriptor() == fd or ready_set.wakeFd() == fd) return true;
    return false;
}

/// Cross-thread wake touches only the readiness channel.
pub fn wakeReadiness(self: *HostRuntime) net.wake_channel.Failure!void {
    if (self.ready_set) |*ready_set| try ready_set.postWake();
}

pub fn setCompletionSink(self: *HostRuntime, sink: ?HostRuntime.CompletionSink) void {
    self.completion_sink = sink;
}

/// Installing a close observer reserves every wire publication atomically.
pub fn setCloseObserver(self: *HostRuntime, observer: ?HostRuntime.CloseObserver) !void {
    if (observer == null) {
        clearCloseObserver(self);
        return;
    } else if (self.close_observer == null) {
        const installing = observer.?;
        var wires = self.wires.valueIterator();
        errdefer {
            var rollback = self.wires.valueIterator();
            while (rollback.next()) |wire| if (wire.*.close_event_reserved) {
                installing.release(installing.ctx);
                wire.*.close_event_reserved = false;
            };
        }
        while (wires.next()) |wire| {
            try installing.reserve(installing.ctx);
            wire.*.close_event_reserved = true;
        }
    } else return error.CloseObserverAlreadyInstalled;
    self.close_observer = observer;
}

pub fn clearCloseObserver(self: *HostRuntime) void {
    if (self.close_observer) |installed| {
        var wires = self.wires.valueIterator();
        while (wires.next()) |wire| if (wire.*.close_event_reserved) {
            installed.release(installed.ctx);
            wire.*.close_event_reserved = false;
        };
    }
    self.close_observer = null;
}
