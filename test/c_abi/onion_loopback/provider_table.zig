//! Drive the onion provider's C stream table from a test: nonblocking reads
//! and writes retried within a finite budget, and the staged connect and
//! listen calls each scenario starts from.

const std = @import("std");

const c = @import("c_abi");
const cdrv = @import("c_abi_driver");

/// The table's I/O never blocks. These helpers retry a refusal within a
/// finite budget of short sleeps.
const io_retry_budget = 10_000;

pub fn providerReadAll(
    table: *const cdrv.GlowcapStreamTransport,
    conn: *anyopaque,
    out: []u8,
) !void {
    var offset: usize = 0;
    var retries: usize = 0;
    while (offset < out.len) {
        const got = table.try_read.?(table.ctx, conn, out[offset..].ptr, out.len - offset);
        if (got == cdrv.GLOWCAP_TRANSPORT_WOULD_BLOCK) {
            retries += 1;
            if (retries == io_retry_budget) return error.ReadTimedOut;
            retrySleep();
            continue;
        }
        try std.testing.expect(got > 0);
        offset += @intCast(got);
    }
}

pub fn providerWriteAll(
    table: *const cdrv.GlowcapStreamTransport,
    conn: *anyopaque,
    bytes: []const u8,
) i32 {
    var rest = bytes;
    var retries: usize = 0;
    while (rest.len != 0) {
        const wrote = table.try_write.?(table.ctx, conn, rest.ptr, rest.len);
        if (wrote == cdrv.GLOWCAP_TRANSPORT_WOULD_BLOCK) {
            retries += 1;
            if (retries == io_retry_budget) return c.GLOWCAP_ERR_IO;
            retrySleep();
            continue;
        }
        if (wrote <= 0) return c.GLOWCAP_ERR_IO;
        rest = rest[@intCast(wrote)..];
    }
    return c.GLOWCAP_OK;
}

fn retrySleep() void {
    var none = [_]std.posix.pollfd{};
    _ = std.posix.poll(&none, 1) catch {}; // best-effort: an early wake only retries sooner
}

pub fn providerConnect(
    table: *const cdrv.GlowcapStreamTransport,
    locator: *const cdrv.GlowcapLocatorView,
    out_conn: *?*anyopaque,
    out_readiness_fd: *i32,
) !i32 {
    var attempt: ?*anyopaque = null;
    var attempt_fd: i32 = -1;
    const start = table.start_connect.?(table.ctx, locator, null, &attempt, &attempt_fd, null);
    if (start != c.GLOWCAP_OK) return start;
    errdefer _ = table.cancel_connect.?(attempt.?, null);
    var fds = [_]std.posix.pollfd{.{
        .fd = attempt_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&fds, 10_000));
    return table.finish_connect.?(attempt.?, out_conn, out_readiness_fd, null);
}

pub fn providerListen(
    table: *const cdrv.GlowcapStreamTransport,
    requested_designator: []const u8,
    out_listener: *?*anyopaque,
) !i32 {
    var result: cdrv.GlowcapListenResult = undefined;
    const start = table.listen.?(
        table.ctx,
        requested_designator.ptr,
        requested_designator.len,
        null,
        0,
        null,
        &result,
        null,
    );
    if (start != c.GLOWCAP_OK) return start;
    if (result.state == cdrv.GLOWCAP_LISTEN_READY) {
        out_listener.* = result.listener;
        return c.GLOWCAP_OK;
    }
    try std.testing.expectEqual(cdrv.GLOWCAP_LISTEN_PENDING, result.state);
    const attempt = result.attempt orelse return error.MissingListenAttempt;
    errdefer _ = table.cancel_listen.?(attempt, null);
    var fds = [_]std.posix.pollfd{.{
        .fd = result.readiness_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&fds, 10_000));
    return table.finish_listen.?(attempt, out_listener, null);
}
