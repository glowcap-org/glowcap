//! WebSocket receive progression for the completion-backed relay carrier.
//!
//! The owning backend supplies the small set of reactor effects through
//! `Access`. This module owns parsing and buffer-lifetime decisions; it does
//! not own connection admission, platform polling, or terminal teardown.

const std = @import("std");

const completion = @import("../../../completion/loop.zig");
const protocol = @import("../../../websocket.zig").client_protocol;

pub fn Machine(
    comptime Backend: type,
    comptime Types: type,
    comptime Access: type,
) type {
    return struct {
        const RelayConn = Types.RelayConn;
        const PlatformBufferDisposition = Types.PlatformBufferDisposition;
        const ControlEffect = Types.ControlEffect;

        const Input = union(enum) {
            retained,
            platform: struct {
                completion_record: completion.Completion,
                bytes: []const u8,
                at: usize = 0,
            },

            fn available(input: *Input, c: *RelayConn) []const u8 {
                return switch (input.*) {
                    .retained => Access.rawBytes(c),
                    .platform => |platform| platform.bytes[platform.at..],
                };
            }

            fn consume(input: *Input, backend: *Backend, c: *RelayConn, count: usize) void {
                switch (input.*) {
                    .retained => Access.dropRaw(backend, c, count),
                    .platform => |*platform| platform.at += count,
                }
            }

            /// Preserve every unconsumed platform byte before its pool buffer
            /// is recycled. Retained input already lives in `raw_in`.
            fn retainRemainder(input: *Input, backend: *Backend, c: *RelayConn) !void {
                switch (input.*) {
                    .retained => {},
                    .platform => |*platform| {
                        const remaining = platform.bytes[platform.at..];
                        if (remaining.len > 0) try Access.appendRaw(backend, c, remaining);
                        platform.at = platform.bytes.len;
                    },
                }
            }

            fn completionRecord(input: *Input) ?completion.Completion {
                return switch (input.*) {
                    .retained => null,
                    .platform => |platform| platform.completion_record,
                };
            }
        };

        pub fn tryEmit(backend: *Backend, c: *RelayConn) !void {
            var input: Input = .retained;
            _ = try drive(backend, c, &input);
        }

        /// Project one wrapped platform buffer directly into the caller's
        /// receive seat. The platform token crosses unchanged, so the outer
        /// Loop returns the buffer to its actual owner after consumption.
        pub fn tryEmitPlatform(
            backend: *Backend,
            c: *RelayConn,
            comp: completion.Completion,
            bytes: []const u8,
        ) !PlatformBufferDisposition {
            var input: Input = .{ .platform = .{
                .completion_record = comp,
                .bytes = bytes,
            } };
            return drive(backend, c, &input);
        }

        /// The one WebSocket receive state machine. `Input` owns the only
        /// source-dependent choices: retained bytes copy into the adapter
        /// pool, while a fresh platform payload is lent directly and preserves
        /// only its coalesced tail.
        fn drive(
            backend: *Backend,
            c: *RelayConn,
            input: *Input,
        ) !PlatformBufferDisposition {
            if (c.state != .open) return .recycle;
            // The Loop owns the receive seat for an open connection. A hidden
            // prefetch can outlive that seat under backpressure, leaving an
            // internal fault with no user_data to retire.
            const ud = c.external_recv_ud orelse return .recycle;
            if (c.close.wire.hasReceived()) {
                if (!c.pending.send and c.ws_out.items.len == 0) {
                    try backend.ready.ensureUnusedCapacity(backend.allocator, 1);
                    c.external_recv_ud = null;
                    backend.ready.appendAssumeCapacity(.{ .user_data = ud, .result = 0 });
                }
                return .recycle;
            }

            while (true) {
                const available = input.available(c);
                if (c.data_remaining > 0) {
                    if (available.len == 0) {
                        try Access.armPlatformRecv(backend, c);
                        return .recycle;
                    }
                    try backend.ready.ensureUnusedCapacity(backend.allocator, 1);
                    if (input.completionRecord()) |comp| {
                        const n: usize = @intCast(@min(
                            c.data_remaining,
                            @as(u64, @intCast(available.len)),
                        ));
                        input.consume(backend, c, n);
                        try input.retainRemainder(backend, c);
                        c.data_remaining -= n;
                        c.external_recv_ud = null;
                        backend.ready.appendAssumeCapacity(.{
                            .user_data = ud,
                            .result = @intCast(n),
                            .borrowed = .recv(available[0..n], comp.borrowed.token),
                        });
                        return .lent_to_caller;
                    }

                    const idx = backend.buffer_pool.acquire() orelse {
                        backend.ready.appendAssumeCapacity(.{
                            .user_data = ud,
                            .result = -1,
                            .recv_no_buffer = true,
                        });
                        c.external_recv_ud = null;
                        return .recycle;
                    };
                    const out = backend.buffer_pool.buffer(idx);
                    const remaining: usize = @intCast(@min(c.data_remaining, std.math.maxInt(usize)));
                    const n = @min(out.len, available.len, remaining);
                    @memcpy(out[0..n], available[0..n]);
                    input.consume(backend, c, n);
                    c.data_remaining -= n;
                    c.external_recv_ud = null;
                    backend.ready.appendAssumeCapacity(.{
                        .user_data = ud,
                        .result = @intCast(n),
                        .borrowed = .recv(out[0..n], Access.borrowToken(idx)),
                    });
                    return .recycle;
                }

                const frame = (protocol.parseFrameBytes(&c.fragmented, available) catch {
                    Access.failRelay(backend, c);
                    return .recycle;
                }) orelse {
                    try input.retainRemainder(backend, c);
                    try Access.armPlatformRecv(backend, c);
                    return .recycle;
                };
                const payload = frame.controlPayload(available);
                switch (frame.effect) {
                    .data => {
                        input.consume(backend, c, frame.consumed_len);
                        c.data_remaining = frame.header.len;
                        if (frame.header.len == 0) continue;
                    },
                    .ping, .close => {
                        // A send borrows ws_out. Preserve this frame until that
                        // borrow retires; its completion resumes this seat.
                        if (c.pending.send) {
                            try input.retainRemainder(backend, c);
                            return .recycle;
                        }
                        const effect = try handleControlFrame(backend, c, frame.effect, payload);
                        input.consume(backend, c, frame.consumed_len);
                        if (effect == .reply_queued) try input.retainRemainder(backend, c);
                        return .recycle;
                    },
                    .pong => {
                        _ = try handleControlFrame(backend, c, frame.effect, payload);
                        input.consume(backend, c, frame.consumed_len);
                    },
                }
            }
        }

        /// Inspect complete retained controls between application receive
        /// seats. Application headers and payload remain untouched until a
        /// caller owns their projection.
        fn drainRetainedControls(backend: *Backend, c: *RelayConn) !void {
            if (c.state != .open or c.pending.send or c.data_remaining != 0) return;
            while (Access.rawBytes(c).len != 0) {
                var fragmented = c.fragmented;
                const frame = (protocol.parseFrameBytes(&fragmented, Access.rawBytes(c)) catch {
                    Access.failRelay(backend, c);
                    return;
                }) orelse return;
                if (frame.effect == .data) return;

                c.fragmented = fragmented;
                const payload = frame.controlPayload(Access.rawBytes(c));
                const effect = try handleControlFrame(backend, c, frame.effect, payload);
                Access.dropRaw(backend, c, frame.consumed_len);
                if (effect == .reply_queued or effect == .closed) return;
            }
        }

        pub fn serviceBuffered(backend: *Backend, c: *RelayConn) !void {
            if (c.external_recv_ud != null) try tryEmit(backend, c);
            // A projected data payload can consume the caller's receive seat
            // and leave a complete control frame immediately behind it.
            if (c.external_recv_ud == null) try drainRetainedControls(backend, c);
        }

        fn handleControlFrame(
            backend: *Backend,
            c: *RelayConn,
            effect: protocol.FrameEffect,
            payload: []const u8,
        ) !ControlEffect {
            return switch (effect) {
                .pong => .consumed,
                .ping => blk: {
                    try Access.queueControlFrame(backend, c, .pong, payload);
                    break :blk .reply_queued;
                },
                .close => blk: {
                    c.close.wire.markReceived();
                    if (!c.close.wire.hasSent())
                        try Access.queueControlFrame(backend, c, .close, payload);
                    Access.refuseExternalSend(backend, c);
                    break :blk .closed;
                },
                .data => unreachable,
            };
        }
    };
}
