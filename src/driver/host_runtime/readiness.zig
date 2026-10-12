//! Aggregate readiness ownership on the stepped face.

const std = @import("std");

const net = @import("net");

const runtime = @import("../host_runtime.zig");

const HostRuntime = runtime.HostRuntime;
const Internal = runtime.Internal;

/// The one pollable descriptor of a stepped runtime. It has existed since
/// construction, so this only reads. The blocking face has no descriptor to
/// hand out and refuses.
pub fn readinessDescriptor(self: *HostRuntime) !i32 {
    try Internal.admitApplicationOperation(self);
    return switch (self.drive) {
        .blocking => error.ReadinessUnavailable,
        .stepped => |*stepped| stepped.ready_set.descriptor(),
    };
}

pub fn watchFd(self: *HostRuntime, fd: i32) !void {
    if (fd < 0) return error.ReadinessUnavailable;
    if (descriptorInUse(self, fd)) return error.ReadinessDescriptorConflict;
    try self.listener_fds.ensureUnusedCapacity(self.allocator, 1);
    switch (self.drive) {
        .blocking => {},
        .stepped => |*stepped| try stepped.ready_set.add(fd),
    }
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
    switch (self.drive) {
        .blocking => {},
        .stepped => |*stepped| stepped.ready_set.remove(fd) catch |err| self.noteTerminalFailure(err),
    }
}

/// Descriptor integer aliasing is never identity: duplicate rows make poll
/// routing ambiguous and removing either owner would silence the other.
pub fn descriptorInUse(self: *const HostRuntime, fd: i32) bool {
    for (self.residents.items) |registered| if (registered.readiness_fd == fd) return true;
    for (self.listener_fds.items) |listener_fd| if (listener_fd == fd) return true;
    if (self.mailbox) |mailbox| if (mailbox.wakeFd() == fd) return true;
    switch (self.drive) {
        .blocking => {},
        .stepped => |*stepped| {
            if (stepped.ready_set.descriptor() == fd or stepped.ready_set.wakeFd() == fd) return true;
        },
    }
    return false;
}

/// Cross-thread wake touches only the readiness channel.
pub fn wakeReadiness(self: *HostRuntime) net.wake_channel.Failure!void {
    switch (self.drive) {
        .blocking => {},
        .stepped => |*stepped| try stepped.ready_set.postWake(),
    }
}
