//! What the io_uring backend's tests read and drive that its test seam
//! (`net.uring_white_box`) does not carry: only public fields and verbs.

const std = @import("std");
const linux = std.os.linux;
const glowcap = @import("glowcap");
const net = glowcap.net;

const Backend = net.uring_white_box.TestBackend;
const socket_tcp = net.socket;
const completion = net.completion;

/// End the ring's multishot watch on the inner backend's epoll set, as the
/// kernel may. The cancel posts nothing on success, and the watch posts
/// `ECANCELED` without `IORING_CQE_F_MORE`, so the CQE path queues it again.
pub fn cancelWatch(backend: *Backend) !void {
    const sqe = try backend.ring.get_sqe();
    sqe.prep_cancel(net.uring_white_box.watch_user_data, 0);
    sqe.flags |= linux.IOSQE_CQE_SKIP_SUCCESS;
    sqe.user_data = 0;
    _ = try backend.ring.submit();
}

/// How many descriptors the inner listener backend holds an operation on.
pub fn innerOperations(backend: *const Backend) usize {
    const inner = backend.inner orelse return 0;
    return inner.pending.count();
}

/// Whether the watch is queued or live.
pub fn watchArmed(backend: *const Backend) bool {
    return backend.watch_armed;
}

/// Drive one real loopback dial-and-accept through the backend and report
/// whether both resulting sockets carry `TCP_NODELAY`. Pinned by
/// `test/net/uring_test.zig`: with Nagle left on, a pipelined CapTP
/// conversation stalls one delayed-ACK (~40ms) per round.
pub fn dialAndAcceptSetNodelay(allocator: std.mem.Allocator) !bool {
    var backend = try Backend.init(allocator, 16, 4, 4096);
    defer backend.deinit();

    const listen_fd = try backend.openListener(0);
    defer backend.closeFd(listen_fd);
    const port = (try socket_tcp.boundIp4(.linux, listen_fd)).port;
    try backend.submitAccept(1, listen_fd);

    const dial_fd = try backend.startDial(2, .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } });
    defer backend.closeFd(dial_fd);

    var accepted: ?Backend.Fd = null;
    defer if (accepted) |fd| backend.closeFd(fd);
    var connected = false;
    var rounds: usize = 0;
    while ((accepted == null or !connected) and rounds < 100) : (rounds += 1) {
        var out: [8]completion.Completion = undefined;
        const n = try backend.poll(&out, 100);
        for (out[0..n]) |comp| switch (comp.user_data) {
            1 => {
                if (comp.result < 0) return error.AcceptFailed;
                accepted = comp.result;
            },
            2 => {
                if (comp.result < 0) return error.ConnectFailed;
                connected = true;
            },
            else => {},
        };
    }
    if (accepted == null or !connected) return error.HandshakeIncomplete;
    const nodelay = net.uring_white_box.nodelayEnabled;
    return nodelay(dial_fd) and nodelay(accepted.?);
}
