//! The platform backends serve several listeners at once: each accepts on its
//! own user_data, and each closes while its accept is armed with one close
//! completion and no stray record.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");

const net = glowcap.net;
const completion = net.completion;

/// `host_optional` marks io_uring, which a host kernel or policy may refuse.
/// Only a refusal the Linux selector would fall back from skips.
fn exercise(comptime Backend: type, host_optional: bool) !void {
    var backend = Backend.init(std.testing.allocator, 32, 4, 64) catch |err| {
        if (host_optional and builtin.os.tag == .linux and
            net.linux_completion_white_box.fallbackReasonFor(err) != null) return error.SkipZigTest;
        return err;
    };
    defer backend.deinit();
    var out: [8]completion.Completion = undefined;

    var listeners: [2]Backend.Fd = undefined;
    var dials: [2]Backend.Fd = undefined;
    var accepted: [2]?Backend.Fd = .{ null, null };
    defer for (accepted) |fd| if (fd) |open| backend.closeFd(open);
    for (&listeners, 0..) |*fd, i| {
        fd.* = try backend.openListener(0);
        try backend.submitAccept(10 + i, fd.*);
    }
    for (&dials, listeners) |*fd, listener| {
        const port = Backend.listenerPort(try backend.listenerAddress(listener)).?;
        fd.* = try backend.startDial(20, .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } });
    }
    defer for (dials) |fd| backend.closeFd(fd);

    var connected: usize = 0;
    var turns: usize = 0;
    while (connected < 2 or accepted[0] == null or accepted[1] == null) : (turns += 1) {
        if (turns == 100) return error.AcceptNeverArrived;
        const n = try backend.poll(&out, 100);
        for (out[0..n]) |comp| switch (comp.user_data) {
            10, 11 => {
                try std.testing.expect(comp.result >= 0);
                const slot = &accepted[comp.user_data - 10];
                try std.testing.expect(slot.* == null);
                slot.* = comp.accepted_fd orelse comp.result;
            },
            20 => {
                try std.testing.expect(comp.result >= 0);
                connected += 1;
            },
            else => return error.UnexpectedCompletion,
        };
    }

    // Re-arm both accepts, then close both listeners beneath them.
    for (listeners, 0..) |fd, i| try backend.submitAccept(10 + i, fd);
    for (listeners, 0..) |fd, i| try backend.submitClose(30 + i, fd);
    var closed: [2]bool = .{ false, false };
    turns = 0;
    while (!(closed[0] and closed[1])) : (turns += 1) {
        if (turns == 100) return error.CloseNeverSettled;
        const n = try backend.poll(&out, 100);
        for (out[0..n]) |comp| switch (comp.user_data) {
            // A canceled accept may surface on backends that report it.
            10, 11 => try std.testing.expect(comp.result < 0),
            30, 31 => {
                try std.testing.expect(!closed[comp.user_data - 30]);
                closed[comp.user_data - 30] = true;
            },
            else => return error.UnexpectedCompletion,
        };
    }
}

test "completion backends accept and close on several listeners at once" {
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
