//! Bounded RFC 6455 client upgrade over an already-open carrier byte stream.

const std = @import("std");
const protocol = @import("../../websocket.zig").client_protocol;
const route = @import("route.zig");
const upgrade_request = @import("upgrade_request.zig");

const clock = @import("../../clock.zig");
const poll = @import("../../poll.zig");

pub const Error = error{ UpgradeRefused, ConnectionLost, UpgradeTimedOut };

const timeout_ms: i64 = 10_000;
const poll_slice_ms: i32 = 50;

/// Render, send, and verify one upgrade. `RelayStream` supplies the bounded
/// byte transport and failure owner without moving relay route policy into the
/// generic WebSocket protocol parser.
pub fn run(
    stream: anytype,
    request: route.OpenRequest,
    stop_requested: ?*const std.atomic.Value(bool),
) Error!void {
    var key_bytes: [16]u8 = undefined;
    stream.mask_rng.random().bytes(&key_bytes);
    var key_b64: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key_b64, &key_bytes);

    const writer = stream.source.writer;
    writer.print("{f}", .{upgrade_request.formatter(request, &key_b64)}) catch |err| {
        stream.noteSourceFailure(err);
        return error.ConnectionLost;
    };
    writer.flush() catch |err| {
        stream.noteSourceFailure(err);
        return error.ConnectionLost;
    };

    var expected: [28]u8 = undefined;
    protocol.acceptKey(&expected, &key_b64);
    const deadline_ms = clock.nowMs(stream.carrier.io()) + timeout_ms;
    try readResponse(stream, &expected, deadline_ms, stop_requested);
}

fn readResponse(
    stream: anytype,
    expected_accept: *const [28]u8,
    deadline_ms: i64,
    stop_requested: ?*const std.atomic.Value(bool),
) Error!void {
    var total: usize = 0;
    var line: [protocol.max_upgrade_response_bytes]u8 = undefined;
    var line_len: usize = 0;
    var first_line = true;
    var response = protocol.UpgradeResponseValidator{};
    while (true) {
        if (total >= protocol.max_upgrade_response_bytes) return error.UpgradeRefused;
        while (stream.source.reader.bufferedLen() == 0) {
            if (stop_requested) |flag| if (flag.load(.acquire)) return error.ConnectionLost;
            std.Io.checkCancel(stream.carrier.io()) catch |err| {
                stream.noteFailure(err);
                return error.ConnectionLost;
            };
            const remaining = deadline_ms - clock.nowMs(stream.carrier.io());
            if (remaining <= 0) return error.UpgradeTimedOut;
            var fds = [_]std.posix.pollfd{.{
                .fd = stream.source.socketHandle(),
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const wait_ms: i32 = @intCast(@min(remaining, @as(i64, poll_slice_ms)));
            const ready = poll.wait(&fds, wait_ms) catch |err| {
                stream.noteFailure(err);
                return error.ConnectionLost;
            };
            if (ready == 0) continue;
            if (fds[0].revents & std.posix.POLL.NVAL != 0) return error.ConnectionLost;
            if (fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP) != 0 and
                fds[0].revents & std.posix.POLL.IN == 0)
                return error.ConnectionLost;
            // Readiness is the socket's, not the reader's: over TLS a record
            // can be half here. Fill without blocking and poll again for the
            // rest, so the deadline above still bounds the wait.
            switch (stream.source.tryFill() catch |err| {
                stream.noteSourceFailure(err);
                return error.ConnectionLost;
            }) {
                .progress, .would_block => {},
                .closed => return error.ConnectionLost,
            }
        }
        const byte = stream.source.reader.takeByte() catch |err| {
            stream.noteSourceFailure(err);
            return error.ConnectionLost;
        };
        total += 1;
        if (byte != '\n') {
            line[line_len] = byte;
            line_len += 1;
            continue;
        }
        if (line_len == 0 or line[line_len - 1] != '\r') return error.UpgradeRefused;
        const complete = line[0 .. line_len - 1];
        if (first_line) {
            if (!protocol.validUpgradeStatus(complete)) return error.UpgradeRefused;
            first_line = false;
        } else if (complete.len == 0) {
            if (!response.valid()) return error.UpgradeRefused;
            return;
        } else {
            response.observe(complete, expected_accept);
        }
        line_len = 0;
    }
}
