//! Terminal close ownership for the completion-backed relay carrier.
//!
//! These scenarios pin the distinction between retiring the wrapped
//! descriptor and truthfully settling the synthetic close barrier.

const std = @import("std");
const glowcap = @import("glowcap");
const admission = @import("../../support/keyed_relay_admission.zig");

const net = glowcap.net;
const keyed_relay = net.relay;
const admissionBackend = admission.admissionBackend;
const deinitAdmissionBackend = admission.deinitAdmissionBackend;
const openAdmissionRelay = admission.openAdmissionRelay;

const FakeReader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn buffered(self: *FakeReader) []const u8 {
        return self.bytes[self.pos..];
    }

    pub fn bufferedLen(self: *FakeReader) usize {
        return self.bytes.len - self.pos;
    }

    pub fn toss(self: *FakeReader, len: usize) void {
        self.pos += len;
    }
};

const FakeSource = struct {
    reader: *FakeReader,
    pending_write: bool = false,
    flush_result: isize = 0,

    const Fill = enum { progress, would_block, closed };

    pub fn tryFill(_: *FakeSource) error{ReadFailed}!Fill {
        return .would_block;
    }

    pub fn hasPendingWrite(self: *const FakeSource) bool {
        return self.pending_write;
    }
};

const FakeStream = struct {
    source: FakeSource,
    remaining: u64 = 0,
    read_closed: bool = false,
    failure: ?anyerror = null,

    const Step = enum { data, handled, closed };

    pub fn noteFailure(self: *FakeStream, err: anyerror) void {
        self.failure = self.failure orelse err;
    }

    pub fn noteSourceFailure(self: *FakeStream, err: anyerror) void {
        self.noteFailure(err);
    }

    pub fn noteFrameFailure(self: *FakeStream, err: anyerror) void {
        self.noteFailure(err);
    }

    pub fn applyFrame(self: *FakeStream, header: keyed_relay.FrameHeader, _: []const u8, _: anytype) error{WriteFailed}!Step {
        return switch (header.opcode) {
            .binary, .continuation => data: {
                self.remaining = header.len;
                break :data if (header.len == 0) .handled else .data;
            },
            .ping => control: {
                self.source.pending_write = true;
                break :control .handled;
            },
            .pong => .handled,
            .close => closed: {
                self.read_closed = true;
                break :closed .closed;
            },
            else => unreachable,
        };
    }

    pub fn tryFlushPending(self: *FakeStream) isize {
        return self.source.flush_result;
    }
};

test "keyed-relay close discards in-flight data before the peer close" {
    const wire = [_]u8{ 0x82, 3, 'o', 'l', 'd', 0x88, 0 };
    var reader: FakeReader = .{ .bytes = &wire };
    var stream: FakeStream = .{ .source = .{ .reader = &reader } };

    try std.testing.expectEqual(.closed, keyed_relay.white_box.drainAfterLocalClose(&stream));
    try std.testing.expectEqual(wire.len, reader.pos);
    try std.testing.expectEqual(@as(u64, 0), stream.remaining);
    try std.testing.expectEqual(@as(?anyerror, null), stream.failure);
}

test "keyed-relay close requests write readiness for a blocked pong" {
    const wire = [_]u8{ 0x89, 0 };
    var reader: FakeReader = .{ .bytes = &wire };
    var stream: FakeStream = .{
        .source = .{
            .reader = &reader,
            .flush_result = net.multiplexed_resident.would_block,
        },
    };

    try std.testing.expectEqual(.wait_write, keyed_relay.white_box.drainAfterLocalClose(&stream));
    try std.testing.expect(stream.source.pending_write);
    try std.testing.expectEqual(@as(?anyerror, null), stream.failure);
}

test "keyed-relay partial application send gives way to one close frame" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);

    try backend.submitSend(9, fd, "payload");
    backend.platform.pending_send.?.result = 1;
    try backend.submitClose(10, fd);

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 9), completions[0].user_data);
    try std.testing.expectEqual(@as(usize, 2), backend.platform.send_submits);
    try std.testing.expect(backend.platform.pending_send != null);
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expect(backend.platform.pending_close != null);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 10), completions[0].user_data);
}

test "keyed-relay defers Loop shutdown until its WebSocket close drains" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);

    backend.shutdownFd(fd);
    try std.testing.expectEqual(@as(usize, 0), backend.platform.shutdown_calls);
    try backend.submitClose(11, fd);

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 0), backend.platform.shutdown_calls);
    try std.testing.expect(backend.platform.pending_close != null);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 11), completions[0].user_data);
}

test "keyed-relay reports a wrapped fd close failure after retiring it" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    backend.platform.close_result = -1;

    try backend.submitClose(10, fd);
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 10), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, -1), completions[0].result);
    try std.testing.expectEqual(error.CloseFailed, completions[0].failure.?);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.close_calls);
    try std.testing.expectEqual(@as(usize, 0), backend.conns.count());
}

test "keyed-relay reports failed close only after receive retires" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    try backend.submitRecv(53, fd);
    backend.platform.close_result = -1;
    backend.platform.close_before_recv = true;
    try backend.submitClose(54, fd);

    var completions: [2]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 53), completions[0].user_data);
    try std.testing.expect(conn.pending.recv);
    try std.testing.expectEqual(.in_flight, conn.close.platform);

    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 0), backend.platform.close_calls);
    try std.testing.expectEqual(.failed, conn.close.platform);

    backend.closeFd(fd);
    try std.testing.expectEqual(@as(usize, 0), backend.platform.close_calls);
    try std.testing.expectEqual(@as(usize, 1), backend.conns.count());

    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 1), backend.platform.close_calls);
    try std.testing.expectEqual(@as(u64, 54), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, -1), completions[0].result);
    try std.testing.expectEqual(error.CloseFailed, completions[0].failure.?);
}
