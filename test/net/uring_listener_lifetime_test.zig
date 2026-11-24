//! A listener the io_uring backend serves must not outlive a process that dies
//! without closing it. A pending ring operation holds its own reference to the
//! file it waits on, so an accept armed on the listening socket kept the port
//! bound after the process had been reaped, for as long as the kernel took to
//! retire the ring. The restart in place then failed with "address in use".
//! A descriptor a caller polls as a listener is the same: the ring holds no
//! operation on it either.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const glowcap = @import("glowcap");
const net = glowcap.net;
const io_uring_gate = @import("../support/io_uring_gate.zig");

const Backend = net.uring_white_box.TestBackend;
const uring_probe = @import("../support/uring_probe.zig");
const external = net.external_completion;
const ExternalBackend = external.CompletionBackend(Backend);

const killed_child = @import("../support/killed_child.zig");
const process = killed_child.process;
const announce = killed_child.announce;
const bindListener = killed_child.bindLoopback;

/// Serve `port` through the real backend with an accept armed and submitted.
fn serve(ready: c_int, hold: c_int) noreturn {
    var backend = Backend.init(std.heap.page_allocator, 16, 4, 4096) catch process._exit(2);
    const fd = backend.openListener(0) catch process._exit(3);
    const port = childPort(&backend, fd);
    backend.submitAccept(1, fd) catch process._exit(4);
    backend.flush() catch process._exit(5);
    announce(port, ready, hold);
}

/// Poll a raw listening socket as a listener, as a provider's readiness
/// descriptor is.
fn pollRawListener(ready: c_int, hold: c_int) noreturn {
    var backend = Backend.init(std.heap.page_allocator, 16, 4, 4096) catch process._exit(2);
    const listener = bindListener(0) catch process._exit(3);
    backend.submitPoll(1, listener.fd, .listener) catch process._exit(4);
    backend.flush() catch process._exit(5);
    if (uring_probe.innerOperations(&backend) != 1 or !uring_probe.watchArmed(&backend)) process._exit(11);
    announce(listener.port, ready, hold);
}

fn childPort(backend: *Backend, fd: Backend.Fd) u16 {
    const address = backend.listenerAddress(fd) catch process._exit(12);
    return Backend.listenerPort(address) orelse process._exit(12);
}

/// Hold an accepted connection with a recv armed on it.
fn holdAcceptedRecv(ready: c_int, hold: c_int) noreturn {
    var backend = Backend.init(std.heap.page_allocator, 16, 4, 4096) catch process._exit(2);
    const fd = backend.openListener(0) catch process._exit(3);
    const port = childPort(&backend, fd);
    backend.submitAccept(1, fd) catch process._exit(4);
    _ = backend.startDial(2, .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } }) catch process._exit(5);
    var out: [4]net.completion.Completion = undefined;
    var accepted: ?Backend.Fd = null;
    var dialed = false;
    var turns: usize = 0;
    while (accepted == null or !dialed) : (turns += 1) {
        if (turns == 200) process._exit(6);
        const n = backend.poll(&out, 50) catch process._exit(7);
        for (out[0..n]) |comp| {
            if (comp.user_data == 1 and comp.result >= 0) accepted = @intCast(comp.result);
            if (comp.user_data == 2 and comp.result >= 0) dialed = true;
        }
    }
    backend.submitRecv(3, accepted.?) catch process._exit(8);
    backend.flush() catch process._exit(9);
    announce(port, ready, hold);
}

/// The external adapter over a provider whose listener readiness descriptor
/// is a real listening socket, as the TCP provider's is.
fn adapterOverListeningSocket(ready: c_int, hold: c_int) noreturn {
    const listener = bindListener(0) catch process._exit(2);
    const vtable: external.VTable = .{
        .start_connect = unreachableDial,
        .finish_connect = unreachableFinish,
        .cancel_connect = unreachableCancel,
        .listen = listenOn,
        .finish_listen = unreachableFinishListen,
        .cancel_listen = unreachableCancel,
        .listener_close = noopClose,
        .accept = unreachableAccept,
        .try_read = unreachableRead,
        .try_write = unreachableWrite,
        .conn_close = .{ .plain = noopClose },
    };
    var fd_slot: i32 = listener.fd;
    const providers = [_]external.Provider{.{ .transport = "raw-tcp", .ctx = &fd_slot, .vtable = &vtable }};
    const allocator = std.heap.page_allocator;
    const platform = Backend.init(allocator, 8, 2, 256) catch process._exit(3);
    var backend = ExternalBackend.initWithPlatform(allocator, .{ .providers = &providers }, platform, 2, 256) catch process._exit(4);
    const fd = backend.openListener(.{ .provider = .{ .transport = "raw-tcp", .designator = "x" } }) catch process._exit(5);
    backend.submitAccept(1, fd) catch process._exit(6);
    backend.flush() catch process._exit(7);
    if (uring_probe.innerOperations(&backend.platform) != 1) process._exit(11);
    announce(listener.port, ready, hold);
}

fn listenOn(ctx: *anyopaque, _: []const u8, _: ?glowcap.foundation.crypto.PeerKey) external.ListenStarted {
    const fd: *i32 = @ptrCast(@alignCast(ctx));
    return .{ .ready = .{ .ptr = ctx, .fd = fd.* } };
}
fn unreachableDial(_: *anyopaque, _: glowcap.ocapn.model.PeerLocator) external.Started {
    unreachable;
}
fn unreachableFinish(_: *anyopaque, _: *anyopaque) external.Finished {
    unreachable;
}
fn unreachableCancel(_: *anyopaque, _: *anyopaque) void {
    unreachable;
}
fn unreachableFinishListen(_: *anyopaque, _: *anyopaque) external.ListenFinished {
    unreachable;
}
fn noopClose(_: *anyopaque, _: *anyopaque) void {}
fn unreachableAccept(_: *anyopaque, _: *anyopaque) external.AcceptFinished {
    unreachable;
}
fn unreachableRead(_: *anyopaque, _: *anyopaque, _: []u8, _: *?net.carrier_failure.Report) net.completion.TryRead {
    unreachable;
}
fn unreachableWrite(_: *anyopaque, _: *anyopaque, _: []const u8, _: *?net.carrier_failure.Report) net.completion.TryWrite {
    unreachable;
}

fn killedChildLeavesPortFree(comptime child_fn: killed_child.Child) !void {
    var probe = Backend.init(std.testing.allocator, 16, 4, 4096) catch |err| return io_uring_gate.refused(err);
    probe.deinit();
    try killed_child.expectKilledChildFreesPort(child_fn, 50);
}

test "io_uring listener set: a killed process leaves its io_uring listener's port free at once" {
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;
    try killedChildLeavesPortFree(serve);
}

test "io_uring listener set: a killed process leaves a polled listening socket's port free at once" {
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;
    try killedChildLeavesPortFree(pollRawListener);
}

test "io_uring listener set: a killed process holding an accepted connection with a recv armed leaves the port free" {
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;
    try killedChildLeavesPortFree(holdAcceptedRecv);
}

test "io_uring listener set: a killed process whose external provider listens on a real socket leaves the port free" {
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;
    try killedChildLeavesPortFree(adapterOverListeningSocket);
}

/// Bind, hand the listener to a grandchild that outlives the child, and report.
fn bindAndLeaveHolder(ready: c_int, hold: c_int) noreturn {
    const listener = bindListener(0) catch process._exit(2);
    const holder = process.fork();
    if (holder < 0) process._exit(3);
    if (holder == 0) {
        // Holds the listener until every write end of `hold` closes.
        var byte: [1]u8 = undefined;
        _ = process.read(hold, &byte, 1);
        process._exit(0);
    }
    announce(listener.port, ready, hold);
}

test "io_uring listener set: the kill harness reports a port a surviving process still holds" {
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;
    try std.testing.expectError(
        error.AddressInUse,
        killed_child.expectKilledChildFreesPort(bindAndLeaveHolder, 1),
    );
}
