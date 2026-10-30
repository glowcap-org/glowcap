//! A relay stream over a carrier whose write window a test controls.

const std = @import("std");
const glowcap = @import("glowcap");
const net = glowcap.net;
pub const Stream = net.relay.white_box.Stream;
const Carrier = net.relay.white_box.carrier.Stream;
const would_block = net.multiplexed_resident.would_block;

pub const Backpressure = struct {
    reader: std.Io.Reader = .fixed(&.{}),
    writer: std.Io.Writer,
    blocked: bool = true,
    sent: [64]u8 = undefined,
    sent_len: usize = 0,

    fn flush(ctx: *anyopaque) isize {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const bytes = self.writer.buffered();
        if (bytes.len == 0) return 0;
        if (self.blocked) return would_block;
        @memcpy(self.sent[self.sent_len..][0..bytes.len], bytes);
        self.sent_len += bytes.len;
        self.writer.end = 0;
        return @intCast(bytes.len);
    }

    fn handle(_: *anyopaque) std.Io.net.Socket.Handle {
        unreachable;
    }

    fn fill(_: *anyopaque) error{ReadFailed}!net.relay.white_box.carrier.Fill {
        return .would_block;
    }

    fn pending(ctx: *anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.writer.end != 0;
    }

    fn shutdown(_: *anyopaque) error{ ReadFailed, WriteFailed }!net.relay.white_box.carrier.Shutdown {
        unreachable;
    }

    fn failure(_: *anyopaque) ?glowcap.foundation.FailureChain {
        return null;
    }

    const vtable: Carrier.VTable = .{
        .socket_handle = handle,
        .try_fill = fill,
        .try_flush = flush,
        .has_pending_write = pending,
        .try_shutdown = shutdown,
        .take_failure = failure,
        .deinit_outcome = failure,
    };
};

pub fn initStream(stream: *Stream, carrier: *Backpressure) void {
    stream.* = .{
        .source = .{ .ctx = carrier, .reader = &carrier.reader, .writer = &carrier.writer, .vtable = &Backpressure.vtable },
        .ws_reader = undefined,
        .ws_writer = undefined,
        .carrier = undefined,
        .allocator = std.testing.allocator,
        .remaining = 0,
        .fragmented = false,
        .read_closed = false,
        .close_sent = false,
        .failure = null,
        .mask_rng = std.Random.DefaultCsprng.init(@splat(0x51)),
    };
}
