//! The io_uring backend's listeners run on an inner epoll backend the ring
//! watches. An accept completes from readiness on the listener, whenever the
//! connection arrived, and these orderings cannot strand a waiting one.

const std = @import("std");
const linux = std.os.linux;
const net = @import("glowcap").net;
const io_uring_gate = @import("../support/io_uring_gate.zig");

const completion = net.completion;
const Backend = net.uring_white_box.TestBackend;
const white_box = net.uring_white_box;
const probe = @import("../support/uring_probe.zig");
const tcp = net.tcp;
const fixtures = @import("../support/completion_loop_fixtures.zig");

const Fixture = struct {
    backend: Backend,
    listener: Backend.Fd,
    port: u16,
    dials: std.ArrayList(Backend.Fd) = .empty,
    accepted: std.ArrayList(Backend.Fd) = .empty,

    fn init() !*Fixture {
        const self = try std.testing.allocator.create(Fixture);
        errdefer std.testing.allocator.destroy(self);
        self.* = .{ .backend = Backend.init(std.testing.allocator, 32, 4, 4096) catch |err| return io_uring_gate.refused(err), .listener = undefined, .port = undefined };
        errdefer self.backend.deinit();
        self.listener = try self.backend.openListener(0);
        self.port = Backend.listenerPort(try self.backend.listenerAddress(self.listener)).?;
        return self;
    }

    fn deinit(self: *Fixture) void {
        for (self.accepted.items) |fd| self.backend.closeFd(fd);
        for (self.dials.items) |fd| self.backend.closeFd(fd);
        self.backend.closeFd(self.listener);
        self.accepted.deinit(std.testing.allocator);
        self.dials.deinit(std.testing.allocator);
        self.backend.deinit();
        std.testing.allocator.destroy(self);
    }

    fn dial(self: *Fixture) !void {
        const fd = try self.backend.startDial(20, .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = self.port } });
        try self.dials.append(std.testing.allocator, fd);
    }

    /// Poll until `count` dial completions arrive, collecting nothing else.
    fn connect(self: *Fixture, count: usize) !void {
        var connected: usize = 0;
        var turns: usize = 0;
        var out: [8]completion.Completion = undefined;
        while (connected < count) : (turns += 1) {
            if (turns == 200) return error.DialNeverConnected;
            const n = try self.backend.poll(&out, 50);
            for (out[0..n]) |comp| {
                try std.testing.expectEqual(@as(u64, 20), comp.user_data);
                try std.testing.expect(comp.result >= 0);
                connected += 1;
            }
        }
    }

    /// Arm one accept and expect its completion from `peek`, with no turn that
    /// waits for the kernel.
    fn acceptNow(self: *Fixture) !void {
        try self.backend.submitAccept(7, self.listener);
        try std.testing.expect(self.backend.readyPending());
        var out: [4]completion.Completion = undefined;
        const n = try self.backend.peek(&out);
        try std.testing.expectEqual(@as(usize, 1), n);
        try std.testing.expectEqual(@as(u64, 7), out[0].user_data);
        try std.testing.expect(out[0].result >= 0);
        try self.accepted.append(std.testing.allocator, out[0].result);
    }
};

fn pollUntil(f: *Fixture, out: []completion.Completion, user_data: u64) !completion.Completion {
    var turns: usize = 0;
    while (turns < 200) : (turns += 1) {
        const n = try f.backend.poll(out, 50);
        for (out[0..n]) |comp| if (comp.user_data == user_data) return comp;
    }
    return error.CompletionNeverArrived;
}

test "io_uring listener set: an accept armed after the connection arrived completes at the next peek" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.dial();
    try f.connect(1);
    // No accept is armed and nothing is held.
    try std.testing.expect(!f.backend.readyPending());
    try f.acceptNow();
}

test "io_uring listener set: a burst is accepted one re-arm at a time until the backlog drains" {
    const f = try Fixture.init();
    defer f.deinit();
    const burst = 40;
    for (0..burst) |_| try f.dial();
    try f.connect(burst);
    var out: [4]completion.Completion = undefined;
    for (0..burst) |_| {
        try f.backend.submitAccept(7, f.listener);
        const comp = try pollUntil(f, &out, 7);
        try std.testing.expect(comp.result >= 0);
        try f.accepted.append(std.testing.allocator, comp.result);
    }
    // The next accept finds the backlog empty and stays armed.
    try f.backend.submitAccept(7, f.listener);
    try std.testing.expectEqual(@as(usize, 0), try f.backend.poll(&out, 20));
    // A connection after the drain completes that accept.
    try f.dial();
    const comp = try pollUntil(f, &out, 7);
    try std.testing.expect(comp.result >= 0);
    try f.accepted.append(std.testing.allocator, comp.result);
}

test "io_uring listener set: a watch that ended is queued again and still reports connections" {
    const f = try Fixture.init();
    defer f.deinit();
    try std.testing.expect(probe.watchArmed(&f.backend));
    try f.backend.flush();
    try probe.cancelWatch(&f.backend);
    var out: [4]completion.Completion = undefined;
    // The watch ends with `ECANCELED` and no `IORING_CQE_F_MORE`, and the
    // CQE path queues it again, which a poll that parks submits first.
    try std.testing.expectEqual(@as(usize, 0), try f.backend.poll(&out, 20));
    try std.testing.expect(probe.watchArmed(&f.backend));
    try f.backend.submitAccept(7, f.listener);
    // Nothing is waiting, and this zero poll clears `dirty`, so the accept can
    // complete only from the re-armed watch reporting the dial.
    try std.testing.expectEqual(@as(usize, 0), try f.backend.poll(&out, 0));
    try std.testing.expect(!f.backend.readyPending());
    try f.dial();
    const comp = try pollUntil(f, &out, 7);
    try std.testing.expect(comp.result >= 0);
    try f.accepted.append(std.testing.allocator, comp.result);
}

test "io_uring listener set: closing a listener under an armed accept completes the accept, then the close" {
    const f = try Fixture.init();
    defer f.deinit();
    const listener = f.listener;
    try f.backend.submitAccept(7, listener);
    try f.backend.submitClose(8, listener);
    var out: [4]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 2), try f.backend.poll(&out, 0));
    try std.testing.expectEqual(@as(u64, 7), out[0].user_data);
    try std.testing.expect(out[0].result < 0);
    try std.testing.expectEqual(@as(?anyerror, null), out[0].failure);
    try std.testing.expectEqual(@as(u64, 8), out[1].user_data);
    try std.testing.expectEqual(@as(i32, 0), out[1].result);
    try std.testing.expectEqual(@as(usize, 0), try f.backend.poll(&out, 20));
    // The descriptor is closed: the fixture must not close it again.
    f.listener = try f.backend.openListener(0);
}

test "io_uring listener set: a completion left because out was full is delivered next and the loop does not park" {
    const f = try Fixture.init();
    defer f.deinit();
    const listener = f.listener;
    try f.backend.submitAccept(7, listener);
    try f.backend.submitClose(8, listener);
    var one: [1]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try f.backend.peek(&one));
    try std.testing.expectEqual(@as(u64, 7), one[0].user_data);
    try std.testing.expect(f.backend.readyPending());
    try std.testing.expectEqual(@as(usize, 1), try f.backend.peek(&one));
    try std.testing.expectEqual(@as(u64, 8), one[0].user_data);
    // Two peeks with nothing held settle it: a peek reaches the inner backend
    // only while something may be there.
    _ = try f.backend.peek(&one);
    try std.testing.expect(!f.backend.readyPending());
    f.listener = try f.backend.openListener(0);
}

/// A listening socket the backend did not open, as a provider hands one over.
const Raw = struct {
    fd: Backend.Fd,
    port: u16,

    fn open() !Raw {
        const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
        if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
        const fd: Backend.Fd = @intCast(rc);
        errdefer _ = linux.close(fd);
        var addr: linux.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return error.SocketFailed;
        if (linux.errno(linux.listen(fd, 16)) != .SUCCESS) return error.SocketFailed;
        var len: u32 = @sizeOf(linux.sockaddr.in);
        if (linux.errno(linux.getsockname(fd, @ptrCast(&addr), &len)) != .SUCCESS) return error.SocketFailed;
        return .{ .fd = fd, .port = std.mem.bigToNative(u16, addr.port) };
    }

    fn deinit(self: Raw) void {
        _ = linux.close(self.fd);
    }

    /// Accept one waiting connection and close it, reporting whether one was there.
    fn drainOne(self: Raw) bool {
        const rc = linux.accept4(self.fd, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return false;
        _ = linux.close(@intCast(rc));
        return true;
    }
};

test "io_uring listener set: a polled listening socket completes on a waiting backlog and again after a partial drain" {
    const f = try Fixture.init();
    defer f.deinit();
    const raw = try Raw.open();
    defer raw.deinit();
    for (0..2) |_| {
        const dial = try f.backend.startDial(20, .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = raw.port } });
        try f.dials.append(std.testing.allocator, dial);
    }
    try f.connect(2);
    var out: [4]completion.Completion = undefined;
    try f.backend.submitPoll(9, raw.fd, .listener);
    var comp = try pollUntil(f, &out, 9);
    try std.testing.expectEqual(@as(i32, 0), comp.result);
    // The poll was one-shot and nothing was consumed: it reports again when armed again.
    try std.testing.expectEqual(@as(usize, 0), try f.backend.poll(&out, 20));
    try std.testing.expect(raw.drainOne());
    try f.backend.submitPoll(10, raw.fd, .listener);
    comp = try pollUntil(f, &out, 10);
    try std.testing.expectEqual(@as(i32, 0), comp.result);
    try std.testing.expect(raw.drainOne());
    // Drained: the next poll waits.
    try f.backend.submitPoll(11, raw.fd, .listener);
    try std.testing.expectEqual(@as(usize, 0), try f.backend.poll(&out, 20));
    try f.backend.submitCancel(12, 11, raw.fd);
    try std.testing.expectEqual(@as(usize, 2), try f.backend.poll(&out, 0));
}

test "io_uring listener set: a second operation on a busy descriptor is refused and changes nothing" {
    const f = try Fixture.init();
    defer f.deinit();
    const raw = try Raw.open();
    defer raw.deinit();
    try f.backend.submitAccept(7, f.listener);
    try std.testing.expectError(error.DescriptorBusy, f.backend.submitPoll(9, f.listener, .listener));
    try f.backend.submitPoll(9, raw.fd, .listener);
    try std.testing.expectError(error.DescriptorBusy, f.backend.submitPoll(10, raw.fd, .listener));
    // The first poll still holds its seat, and cancel completes the target, then itself.
    try f.backend.submitCancel(11, 9, raw.fd);
    var out: [4]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 2), try f.backend.poll(&out, 0));
    try std.testing.expectEqual(@as(u64, 9), out[0].user_data);
    try std.testing.expect(out[0].result < 0);
    try std.testing.expectEqual(@as(u64, 11), out[1].user_data);
    try std.testing.expectEqual(@as(i32, 0), out[1].result);
    // A cancelled poll leaves the descriptor free to poll again.
    try f.backend.submitPoll(12, raw.fd, .listener);
    try f.backend.submitCancel(13, 12, raw.fd);
    try std.testing.expectEqual(@as(usize, 2), try f.backend.poll(&out, 0));
}

test "io_uring listener set: a descriptor closed under a poll leaves a number clean to reuse" {
    const f = try Fixture.init();
    defer f.deinit();
    const first = try Raw.open();
    const other = try Raw.open();
    defer other.deinit();
    try f.backend.submitPoll(9, first.fd, .listener);
    f.backend.closeFd(first.fd);
    // Put another listening socket on the closed number.
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(first.fd, linux.F.GETFD, 0)));
    try std.testing.expectEqual(@as(usize, @intCast(first.fd)), linux.dup3(other.fd, first.fd, @bitCast(linux.O{ .CLOEXEC = true })));
    try f.backend.submitPoll(10, first.fd, .listener);
    try f.backend.submitClose(11, first.fd);
    var out: [4]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 2), try f.backend.poll(&out, 0));
    try std.testing.expectEqual(@as(u64, 10), out[0].user_data);
    try std.testing.expect(out[0].result < 0);
    try std.testing.expectEqual(@as(u64, 11), out[1].user_data);
}

/// Wait until the kernel has posted `count` completions to the ring, so a test
/// can hold ring completions and listener completions at once.
fn awaitRing(f: *Fixture, count: u32) !void {
    var turns: usize = 0;
    while (f.backend.ring.cq_ready() < count) : (turns += 1) {
        if (turns == 2000) return error.RingNeverCompleted;
        _ = linux.nanosleep(&.{ .sec = 0, .nsec = std.time.ns_per_ms }, null);
    }
}

fn nomem() i32 {
    return -@as(i32, @backingInt(linux.E.NOMEM));
}

test "io_uring listener set: a watch that fails reports its cause once and closing still completes the armed accept" {
    const f = try Fixture.init();
    defer f.deinit();
    const raw = try Raw.open();
    defer raw.deinit();
    const listener = f.listener;
    try f.backend.submitAccept(7, listener);
    white_box.reportWatch(&f.backend, nomem());
    // The cause comes once, from the next call, before anything is reaped.
    var out: [4]completion.Completion = undefined;
    try std.testing.expect(f.backend.readyPending());
    try std.testing.expectError(error.OutOfMemory, f.backend.peek(&out));
    try std.testing.expectEqual(@as(usize, 0), try f.backend.poll(&out, 0));
    // New listener work refuses with the same cause.
    try std.testing.expectError(error.OutOfMemory, f.backend.submitAccept(8, listener));
    try std.testing.expectError(error.OutOfMemory, f.backend.submitPoll(10, raw.fd, .listener));
    try std.testing.expectError(error.OutOfMemory, f.backend.openListener(0));
    // The held accept can never wake, and closing is how its owner retires it.
    try std.testing.expectEqual(@as(usize, 1), probe.innerOperations(&f.backend));
    try f.backend.submitClose(9, listener);
    try std.testing.expectEqual(@as(usize, 2), try f.backend.poll(&out, 0));
    try std.testing.expectEqual(@as(u64, 7), out[0].user_data);
    try std.testing.expect(out[0].result < 0);
    try std.testing.expectEqual(@as(u64, 9), out[1].user_data);
    try std.testing.expectEqual(@as(usize, 0), probe.innerOperations(&f.backend));
    // The descriptor is closed: the fixture closes a duplicate instead.
    f.listener = @intCast(linux.dup(raw.fd));
}

test "io_uring listener set: an indefinite poll returns a terminal watch error before parking" {
    const f = try Fixture.init();
    defer f.deinit();
    // An invalid poll posts a terminal CQE with the watch's tag. No other
    // descriptor is ready to wake a backend that parks after reaping it.
    const sqe = try f.backend.ring.get_sqe();
    sqe.prep_poll_add(-1, linux.POLL.IN);
    sqe.user_data = white_box.watch_user_data;
    var out: [1]completion.Completion = undefined;
    try std.testing.expectError(error.InvalidFileDescriptor, f.backend.poll(&out, -1));
    try std.testing.expectEqual(@as(usize, 0), try f.backend.peek(&out));
}

test "io_uring listener set: the first listener fault stays, and a ring fault is a separate fact" {
    const f = try Fixture.init();
    defer f.deinit();
    f.backend.fault = error.Planted;
    white_box.reportWatch(&f.backend, nomem());
    white_box.reportWatch(&f.backend, -@as(i32, @backingInt(linux.E.NOSPC)));
    // Neither latch replaces the other, and the second failure replaces nothing.
    try std.testing.expectEqual(@as(?anyerror, error.Planted), f.backend.fault);
    try std.testing.expectEqual(@as(?anyerror, error.OutOfMemory), f.backend.listener_fault);
    try std.testing.expectError(error.Planted, f.backend.flush());
    f.backend.fault = null;
    var out: [4]completion.Completion = undefined;
    try std.testing.expectError(error.OutOfMemory, f.backend.peek(&out));
    // The second failure queued no second report.
    try std.testing.expectEqual(@as(usize, 0), try f.backend.peek(&out));
    try std.testing.expectEqual(@as(?anyerror, error.OutOfMemory), f.backend.listener_fault);
}

test "io_uring listener set: a refused re-arm is no fault, and the next flush arms the watch" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.backend.flush();
    // A refusal for lack of a submission slot cannot be produced on demand, so
    // a ring fault stands in for it: `getSqe` refuses, as it would.
    f.backend.fault = error.Planted;
    white_box.reportWatch(&f.backend, -@as(i32, @backingInt(linux.E.CANCELED)));
    f.backend.fault = null;
    try std.testing.expect(!probe.watchArmed(&f.backend));
    try std.testing.expectEqual(@as(?anyerror, null), f.backend.listener_fault);
    try std.testing.expectEqual(@as(?anyerror, null), f.backend.deferred_error);
    // `dirty` holds what arrived meanwhile.
    try std.testing.expect(f.backend.readyPending());
    try f.backend.flush();
    try std.testing.expect(probe.watchArmed(&f.backend));
    var out: [4]completion.Completion = undefined;
    try f.backend.submitAccept(7, f.listener);
    _ = try f.backend.poll(&out, 0);
    try f.dial();
    const comp = try pollUntil(f, &out, 7);
    try std.testing.expect(comp.result >= 0);
    try f.accepted.append(std.testing.allocator, comp.result);
}

test "io_uring listener set: an inner backend error surfaces once, with ring completions kept" {
    const f = try Fixture.init();
    defer f.deinit();
    const inner = f.backend.inner.?;
    try f.backend.submitAccept(7, f.listener);
    net.epoll_white_box.failNextControl(inner, .NOMEM);
    try f.dial();
    // The connect, and the watch reporting the waiting connection.
    try awaitRing(f, 2);
    var out: [4]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 2), try f.backend.peek(&out));
    try std.testing.expectEqual(@as(u64, 20), out[0].user_data);
    try std.testing.expectEqual(@as(u64, 7), out[1].user_data);
    try f.accepted.append(std.testing.allocator, out[1].result);
    // The accept's cleanup failed, so the inner backend holds that error. A
    // ring completion is waiting when it is met, and the batch keeps it.
    try f.dial();
    try awaitRing(f, 1);
    f.backend.listener_turn = false; // the ring goes first, so the error meets a batch
    try std.testing.expectEqual(@as(usize, 1), try f.backend.peek(&out));
    try std.testing.expectEqual(@as(u64, 20), out[0].user_data);
    try std.testing.expect(f.backend.readyPending());
    try std.testing.expectError(error.EpollControlFailed, f.backend.peek(&out));
    try std.testing.expectEqual(@as(usize, 0), try f.backend.peek(&out));
    try std.testing.expect(!f.backend.readyPending());
}

test "io_uring listener set: neither source starves the other behind a one-slot out" {
    const f = try Fixture.init();
    defer f.deinit();
    const second = try Raw.open();
    defer second.deinit();
    const third = try Raw.open();
    defer third.deinit();
    // Ring work: three connects. Listener work: two armed polls, each
    // cancelled, so the inner backend holds four completions.
    for (0..3) |_| try f.dial();
    try awaitRing(f, 3);
    try f.backend.submitPoll(31, second.fd, .listener);
    try f.backend.submitCancel(32, 31, second.fd);
    try f.backend.submitPoll(33, third.fd, .listener);
    try f.backend.submitCancel(34, 33, third.fd);
    var one: [1]completion.Completion = undefined;
    var from_ring: [8]bool = undefined;
    var turns: usize = 0;
    while (turns < 7) : (turns += 1) {
        try std.testing.expectEqual(@as(usize, 1), try f.backend.peek(&one));
        from_ring[turns] = one[0].user_data == 20;
    }
    // While both held work, no two turns in a row went to the same source.
    for (0..5) |i| try std.testing.expect(from_ring[i] != from_ring[i + 1]);
    try std.testing.expectEqual(@as(usize, 0), try f.backend.peek(&one));
    try std.testing.expect(!f.backend.readyPending());
}

test "io_uring listener set: a dial or connection poll on a descriptor a listener holds is refused" {
    const f = try Fixture.init();
    defer f.deinit();
    const raw = try Raw.open();
    defer raw.deinit();
    try f.backend.submitPoll(9, raw.fd, .listener);
    try std.testing.expectError(error.DescriptorBusy, f.backend.submitPoll(10, raw.fd, .readable));
    try std.testing.expectError(error.DescriptorBusy, f.backend.submitPoll(10, raw.fd, .writable));
    try f.backend.submitCancel(11, 9, raw.fd);
    var out: [4]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 2), try f.backend.poll(&out, 0));
}

test "io_uring listener set: a cancel names the operation it targets when one number holds both kinds" {
    const f = try Fixture.init();
    defer f.deinit();
    const raw = try Raw.open();
    defer raw.deinit();
    // The ring poll came first; a provider that shares the descriptor between
    // a connection and a listener breaks the contract, and the cancel still
    // reaches the ring operation instead of the listener one.
    try f.backend.submitPoll(9, raw.fd, .readable);
    try f.backend.submitPoll(10, raw.fd, .listener);
    try f.backend.submitCancel(11, 9, raw.fd);
    var out: [4]completion.Completion = undefined;
    var seen: [2]bool = .{ false, false };
    var turns: usize = 0;
    while (!(seen[0] and seen[1])) : (turns += 1) {
        if (turns == 100) return error.CancelNeverSettled;
        const n = try f.backend.poll(&out, 50);
        for (out[0..n]) |comp| switch (comp.user_data) {
            9 => {
                try std.testing.expect(comp.result < 0);
                seen[0] = true;
            },
            11 => seen[1] = true,
            else => return error.UnexpectedCompletion,
        };
    }
    try std.testing.expectEqual(@as(usize, 1), probe.innerOperations(&f.backend));
    try f.backend.submitCancel(12, 10, raw.fd);
    try std.testing.expectEqual(@as(usize, 2), try f.backend.poll(&out, 0));
}

const UringLoop = net.completion.Loop(Backend, tcp.DialResolver);

fn serveLoop() !UringLoop {
    const backend = Backend.init(std.testing.allocator, 32, 4, 4096) catch |err| return io_uring_gate.refused(err);
    return UringLoop.initWithBackend(std.testing.allocator, backend, fixtures.makeServerPeer, null, .{
        .max_conns = 4,
        .listen = 0,
    });
}

test "io_uring listener set: a loop under a failed watch reports its cause and closeAndDrain finishes" {
    var loop = try serveLoop();
    defer loop.deinit();
    var never = std.atomic.Value(bool).init(false);
    try std.testing.expectError(error.Timeout, loop.runUntil(&never, 20));
    try std.testing.expect(loop.accept_armed);
    white_box.reportWatch(&loop.backend, nomem());
    // The loop retires with the watch's cause, once.
    try std.testing.expectError(error.OutOfMemory, loop.runUntil(&never, 20));
    try loop.closeAndDrain();
    try std.testing.expect(!loop.accept_armed);
    try std.testing.expectEqual(@as(usize, 0), probe.innerOperations(&loop.backend));
}

test "io_uring listener set: closeAndDrain that meets the cause first is retried and finishes" {
    var loop = try serveLoop();
    defer loop.deinit();
    var never = std.atomic.Value(bool).init(false);
    try std.testing.expectError(error.Timeout, loop.runUntil(&never, 20));
    white_box.reportWatch(&loop.backend, nomem());
    try std.testing.expectError(error.OutOfMemory, loop.closeAndDrain());
    try loop.closeAndDrain();
    try std.testing.expect(!loop.accept_armed);
    try std.testing.expectEqual(@as(usize, 0), probe.innerOperations(&loop.backend));
}

/// A blocking loopback connect from outside the backend, so the ring posts no
/// completion of its own for it. Returns the connected descriptor.
fn connectOutside(port: u16) !i32 {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(rc);
    errdefer _ = linux.close(fd);
    var addr: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return error.ConnectFailed;
    return fd;
}

fn dialLater(port: u16) void {
    _ = linux.nanosleep(&.{ .sec = 0, .nsec = 150 * std.time.ns_per_ms }, null);
    // best-effort: a failed dial leaves the test's own wait to time out and fail.
    const fd = connectOutside(port) catch return;
    _ = linux.nanosleep(&.{ .sec = 0, .nsec = 50 * std.time.ns_per_ms }, null);
    _ = linux.close(fd);
}

test "io_uring listener set: a wait without a limit that reaps only the watch waits on" {
    const f = try Fixture.init();
    defer f.deinit();
    const second = try Raw.open();
    defer second.deinit();
    var one: [1]completion.Completion = undefined;
    try f.backend.submitAccept(7, f.listener);
    try std.testing.expectEqual(@as(usize, 0), try f.backend.poll(&one, 0));
    // A connection arrives, and the ring posts the watch's report of it. A
    // delegated submit then makes the listeners go first, so their turn
    // takes the accept and leaves that report unreaped.
    const client = try connectOutside(f.port);
    defer _ = linux.close(client);
    try awaitRing(f, 1);
    try f.backend.submitPoll(31, second.fd, .listener);
    try std.testing.expectEqual(@as(usize, 1), try f.backend.poll(&one, 0));
    try std.testing.expectEqual(@as(u64, 7), one[0].user_data);
    try f.accepted.append(std.testing.allocator, one[0].result);
    // The next wait reaps only that report, which is no completion, and waits
    // on for the one that follows.
    const dialer = try std.Thread.spawn(.{}, dialLater, .{second.port});
    defer dialer.join();
    try std.testing.expectEqual(@as(usize, 1), try f.backend.poll(&one, -1));
    try std.testing.expectEqual(@as(u64, 31), one[0].user_data);
}

test "io_uring listener set: a wait parks on a watch the turn before it queued again" {
    const f = try Fixture.init();
    defer f.deinit();
    var one: [1]completion.Completion = undefined;
    try f.backend.submitAccept(7, f.listener);
    try std.testing.expectEqual(@as(usize, 0), try f.backend.poll(&one, 0));
    try f.backend.flush();
    // The first turn reaps only the cancelled watch and queues it again. The
    // wait submits it before it parks, or no connection could end the wait.
    try probe.cancelWatch(&f.backend);
    const dialer = try std.Thread.spawn(.{}, dialLater, .{f.port});
    defer dialer.join();
    try std.testing.expectEqual(@as(usize, 1), try f.backend.poll(&one, -1));
    try std.testing.expectEqual(@as(u64, 7), one[0].user_data);
    try f.accepted.append(std.testing.allocator, one[0].result);
}
