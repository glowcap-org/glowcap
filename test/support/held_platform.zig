//! The platform completion backend with a gate on delivery. While `held`,
//! `poll` and `peek` deliver nothing, `readyPending` reports none, and the
//! platform keeps every completion it has queued, so a test decides when a
//! physical cancel or close is seen instead of inheriting the host's timing.
//! Epoll and kqueue queue a cancel's completions before the cancel call
//! returns, and io_uring may complete it later. The other verbs the external adapter calls forward unchanged.

const std = @import("std");
const glowcap = @import("glowcap");

const net = glowcap.net;
const completion = net.completion;

/// The platform backend the gate wraps.
const Inner = net.Backend;

pub const HeldPlatform = struct {
    pub const Fd = Inner.Fd;
    pub const adapter_depth = Inner.adapter_depth;
    pub const ConnectTarget = Inner.ConnectTarget;
    pub const ListenTarget = Inner.ListenTarget;
    pub const ListenerAddress = Inner.ListenerAddress;

    inner: Inner,
    /// Deliver nothing until cleared.
    held: bool = false,

    pub fn init(allocator: std.mem.Allocator) !HeldPlatform {
        return .{ .inner = try Inner.init(allocator, 64, 16, 256) };
    }

    pub fn deinit(self: *HeldPlatform) void {
        self.inner.deinit();
    }

    pub const loopListenTarget = Inner.loopListenTarget;
    pub const listenerPort = Inner.listenerPort;

    pub fn readyPending(self: *const HeldPlatform) bool {
        return !self.held and self.inner.readyPending();
    }

    pub fn submitPoll(self: *HeldPlatform, user_data: u64, fd: Fd, interest: completion.Interest) !void {
        return self.inner.submitPoll(user_data, fd, interest);
    }

    pub fn startDial(self: *HeldPlatform, user_data: u64, target: ConnectTarget) !Fd {
        return self.inner.startDial(user_data, target);
    }

    pub fn submitRecv(self: *HeldPlatform, user_data: u64, fd: Fd) !void {
        return self.inner.submitRecv(user_data, fd);
    }

    pub fn shutdownFd(self: *HeldPlatform, fd: Fd) void {
        self.inner.shutdownFd(fd);
    }

    pub fn submitClose(self: *HeldPlatform, user_data: u64, fd: Fd) !void {
        return self.inner.submitClose(user_data, fd);
    }

    pub fn readinessFd(self: *const HeldPlatform) Fd {
        return self.inner.readinessFd();
    }

    pub fn flush(self: *HeldPlatform) !void {
        return self.inner.flush();
    }

    pub fn waitBoundMs(self: *const HeldPlatform, requested_ms: i32) i32 {
        return self.inner.waitBoundMs(requested_ms);
    }

    pub fn openListener(self: *HeldPlatform, target: ListenTarget) !Fd {
        return self.inner.openListener(target);
    }

    pub fn listenerAddress(self: *HeldPlatform, fd: Fd) !ListenerAddress {
        return self.inner.listenerAddress(fd);
    }

    pub fn wireFraming(self: *HeldPlatform, fd: Fd) glowcap.ocapn.model.transport.WireFraming {
        return self.inner.wireFraming(fd);
    }

    pub fn verifiedChannelKey(self: *HeldPlatform, fd: Fd) ?[32]u8 {
        return self.inner.verifiedChannelKey(fd);
    }

    pub fn submitAccept(self: *HeldPlatform, user_data: u64, fd: Fd) !void {
        return self.inner.submitAccept(user_data, fd);
    }

    pub fn submitSend(self: *HeldPlatform, user_data: u64, fd: Fd, bytes: []const u8) !void {
        return self.inner.submitSend(user_data, fd, bytes);
    }

    pub fn closeFd(self: *HeldPlatform, fd: Fd) void {
        self.inner.closeFd(fd);
    }

    pub fn recycleBorrowed(self: *HeldPlatform, comp: completion.Completion) void {
        self.inner.recycleBorrowed(comp);
    }

    pub fn submitCancel(self: *HeldPlatform, cancel_user_data: u64, target_user_data: u64, fd: Fd) !void {
        return self.inner.submitCancel(cancel_user_data, target_user_data, fd);
    }

    pub fn listenerPending(self: *const HeldPlatform, fd: Fd) bool {
        return self.inner.listenerPending(fd);
    }

    pub fn peek(self: *HeldPlatform, out: []completion.Completion) !usize {
        if (self.held) return 0;
        return self.inner.peek(out);
    }

    pub fn poll(self: *HeldPlatform, out: []completion.Completion, timeout_ms: i32) !usize {
        if (self.held) return 0;
        return self.inner.poll(out, timeout_ms);
    }
};
