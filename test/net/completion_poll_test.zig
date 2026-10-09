//! The platform backends' readiness verb: `submitPoll` completes when a
//! descriptor becomes readable or writable without consuming its bytes, and
//! `submitCancel` retires it.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");

const net = glowcap.net;
const completion = net.completion;

const Pipe = struct {
    read: i32,
    write: i32,

    fn open() !Pipe {
        var fds: [2]i32 = undefined;
        if (builtin.os.tag == .linux) {
            const linux = std.os.linux;
            if (linux.errno(linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
        } else {
            if (std.c.pipe(&fds) != 0) return error.PipeFailed;
        }
        return .{ .read = fds[0], .write = fds[1] };
    }

    fn close(self: Pipe) void {
        _ = std.c.close(self.read);
        _ = std.c.close(self.write);
    }
};

fn pollAll(backend: anytype, out: []completion.Completion, timeout_ms: i32) !usize {
    return backend.poll(out, timeout_ms);
}

/// `host_optional` marks io_uring, which a host kernel or policy may refuse.
fn exercise(comptime Backend: type, host_optional: bool) !void {
    var backend = Backend.init(std.testing.allocator, 32, 4, 64) catch |err| {
        if (host_optional) return error.SkipZigTest;
        return err;
    };
    defer backend.deinit();
    const pipe = try Pipe.open();
    defer pipe.close();
    var out: [4]completion.Completion = undefined;

    // Readable waits for bytes and leaves them in place.
    try backend.submitPoll(1, pipe.read, .readable);
    try std.testing.expectEqual(@as(usize, 0), try pollAll(&backend, &out, 0));
    try std.testing.expectEqual(@as(isize, 3), std.c.write(pipe.write, "abc", 3));
    try std.testing.expectEqual(@as(usize, 1), try pollAll(&backend, &out, 1000));
    try std.testing.expectEqual(@as(u64, 1), out[0].user_data);
    try std.testing.expect(out[0].result >= 0);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 3), std.c.read(pipe.read, &buf, buf.len));

    // An empty pipe's write end is writable at once.
    try backend.submitPoll(2, pipe.write, .writable);
    try std.testing.expectEqual(@as(usize, 1), try pollAll(&backend, &out, 1000));
    try std.testing.expectEqual(@as(u64, 2), out[0].user_data);
    try std.testing.expect(out[0].result >= 0);

    // A cancel retires a waiting poll; both records arrive in either order.
    try backend.submitPoll(3, pipe.read, .readable);
    try backend.submitCancel(4, 3, pipe.read);
    var seen_target = false;
    var seen_cancel = false;
    var turns: usize = 0;
    while (!(seen_target and seen_cancel)) : (turns += 1) {
        if (turns == 50) return error.CancelNeverSettled;
        const n = try pollAll(&backend, &out, 100);
        for (out[0..n]) |comp| switch (comp.user_data) {
            3 => {
                try std.testing.expect(comp.result < 0);
                seen_target = true;
            },
            4 => seen_cancel = true,
            else => return error.UnexpectedCompletion,
        };
    }
}

test "completion backends report readiness without consuming and cancel a poll" {
    switch (builtin.os.tag) {
        .linux => {
            try exercise(net.epoll_white_box.TestBackend, false);
            exercise(net.uring_white_box.TestBackend, true) catch |err| switch (err) {
                error.SkipZigTest => {},
                else => return err,
            };
        },
        else => if (builtin.os.tag.isDarwin()) try exercise(net.kqueue_white_box.TestBackend, false) else return error.SkipZigTest,
    }
}
