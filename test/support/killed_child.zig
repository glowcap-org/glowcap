//! A process that listens must not outlive its listener's port. Run a child
//! that binds a port of its own and reports it, kill it with SIGKILL, reap
//! it, and rebind that port at once. A port the kernel still holds refuses
//! the rebind.

const std = @import("std");
const linux = std.os.linux;

pub const process = struct {
    pub extern "c" fn fork() c_int;
    pub extern "c" fn pipe(*[2]c_int) c_int;
    pub extern "c" fn read(c_int, [*]u8, usize) isize;
    pub extern "c" fn write(c_int, [*]const u8, usize) isize;
    pub extern "c" fn close(c_int) c_int;
    pub extern "c" fn waitpid(c_int, *c_int, c_int) c_int;
    pub extern "c" fn kill(c_int, c_int) c_int;
    pub extern "c" fn _exit(c_int) noreturn;
};

/// The child's body: bind, then `announce` the port and never return.
pub const Child = fn (ready: c_int, hold: c_int) noreturn;

/// Report `port` to the parent, then wait to be killed.
pub fn announce(port: u16, ready: c_int, hold: c_int) noreturn {
    _ = process.write(ready, std.mem.asBytes(&port), 2);
    var byte: [1]u8 = undefined;
    _ = process.read(hold, &byte, 1);
    process._exit(0);
}

/// Bind and listen on 127.0.0.1:`port` with `SO_REUSEADDR`, as the backends
/// do, with no backend involved.
pub fn bindLoopback(port: u16) !struct { fd: i32, port: u16 } {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(rc);
    errdefer _ = linux.close(fd);
    const one: u32 = 1;
    if (linux.errno(linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), 4)) != .SUCCESS)
        return error.SocketFailed;
    var addr: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    switch (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        else => return error.SocketFailed,
    }
    if (linux.errno(linux.listen(fd, 16)) != .SUCCESS) return error.SocketFailed;
    var len: u32 = @sizeOf(linux.sockaddr.in);
    if (linux.errno(linux.getsockname(fd, @ptrCast(&addr), &len)) != .SUCCESS) return error.SocketFailed;
    return .{ .fd = fd, .port = std.mem.bigToNative(u16, addr.port) };
}

/// Close `fd` unless a path already did, and mark it closed.
fn closeOnce(fd: *c_int) void {
    if (fd.* < 0) return;
    _ = process.close(fd.*);
    fd.* = -1;
}

/// How long the parent waits for the child to announce its port.
const announce_deadline_ms = 10_000;

/// Run `child_fn` in a forked process `iterations` times. The parent always
/// reaps the child and names its exit code when it died before it announced.
/// Every descriptor closes once on every path: `closeOnce` marks each end as
/// it goes, and the iteration's one `defer` closes what is left.
pub fn expectKilledChildFreesPort(comptime child_fn: Child, iterations: usize) !void {
    for (0..iterations) |_| {
        var ready: [2]c_int = .{ -1, -1 };
        var hold: [2]c_int = .{ -1, -1 };
        defer {
            closeOnce(&ready[0]);
            closeOnce(&ready[1]);
            closeOnce(&hold[0]);
            closeOnce(&hold[1]);
        }
        try std.testing.expectEqual(@as(c_int, 0), process.pipe(&ready));
        try std.testing.expectEqual(@as(c_int, 0), process.pipe(&hold));
        const child = process.fork();
        try std.testing.expect(child >= 0);
        if (child == 0) {
            // The child keeps only its own ends: a copy of the parent's would
            // hold the pipes open past the parent's close.
            closeOnce(&ready[0]);
            closeOnce(&hold[1]);
            child_fn(ready[1], hold[0]);
        }
        closeOnce(&ready[1]);
        closeOnce(&hold[0]);
        var reaped = false;
        defer if (!reaped) {
            _ = process.kill(child, 9);
            var status: c_int = 0;
            _ = process.waitpid(child, &status, 0);
        };

        var wait: [1]linux.pollfd = .{.{ .fd = ready[0], .events = linux.POLL.IN, .revents = 0 }};
        const waited = linux.poll(&wait, wait.len, announce_deadline_ms);
        var port: u16 = 0;
        if (linux.errno(waited) != .SUCCESS or waited == 0 or process.read(ready[0], std.mem.asBytes(&port), 2) != 2) {
            // The child died, or never spoke: its exit code says where.
            if (waited == 0) _ = process.kill(child, 9);
            var status: c_int = 0;
            _ = process.waitpid(child, &status, 0);
            reaped = true;
            std.debug.print("child exited with code {d} (signal {d}) before it reported a port\n", .{ (status >> 8) & 0xff, status & 0x7f });
            return error.ChildNeverAnnounced;
        }
        try std.testing.expectEqual(@as(c_int, 0), process.kill(child, 9));
        var status: c_int = 0;
        try std.testing.expectEqual(child, process.waitpid(child, &status, 0));
        reaped = true;
        try std.testing.expectEqual(@as(c_int, 9), status & 0x7f);

        const rebound = try bindLoopback(port);
        _ = linux.close(rebound.fd);
    }
}
