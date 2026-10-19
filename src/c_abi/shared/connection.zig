//! Stream-shaped connection lifetime and frame operations at the C waist.

const std = @import("std");
const foundation = @import("foundation");
const frame = @import("frame.zig");
const result = @import("result.zig");
const last_error = @import("last_error.zig");

const GlowcapFrame = frame.GlowcapFrame;
const GlowcapManagedFrame = frame.GlowcapManagedFrame;
const GLOWCAP_OK = result.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = result.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = result.GLOWCAP_ERR_INVALID_ARGUMENT;
const GLOWCAP_ERR_INTERNAL = result.GLOWCAP_ERR_INTERNAL;
const GLOWCAP_ERR_CLOSED = result.GLOWCAP_ERR_CLOSED;
const GLOWCAP_ERR_IO = result.GLOWCAP_ERR_IO;
const GLOWCAP_ERR_MALFORMED = result.GLOWCAP_ERR_MALFORMED;
const GLOWCAP_ERR_FRAME_TOO_LARGE = result.GLOWCAP_ERR_FRAME_TOO_LARGE;
const setLastError = last_error.set;

/// Admission barrier for operations entered from foreign threads. Shutdown
/// seals admission and waits for every call that already crossed the barrier.
/// The foreign owner still prevents calls from racing final handle release.
pub const ForeignCallBarrier = struct {
    const closing_bit = @as(usize, 1) << (@bitSizeOf(usize) - 1);
    const active_mask = closing_bit - 1;

    gate: std.Io.Mutex = .init,
    drained: std.Io.Condition = .init,
    /// High bit seals admission. Low bits count calls that already crossed the
    /// C boundary. Admission and shutdown never wait on the release barrier.
    state: std.atomic.Value(usize) = .init(0),

    pub fn acquire(self: *ForeignCallBarrier, io: std.Io) bool {
        _ = io;
        var state = self.state.load(.acquire);
        while (true) {
            if (state & closing_bit != 0) return false;
            std.debug.assert(state & active_mask != active_mask);
            if (self.state.cmpxchgWeak(state, state + 1, .acquire, .monotonic)) |observed| {
                state = observed;
                continue;
            }
            return true;
        }
    }

    pub fn release(self: *ForeignCallBarrier, io: std.Io) void {
        const previous = self.state.fetchSub(1, .release);
        std.debug.assert(previous & active_mask != 0);
        if (previous & active_mask != 1) return;
        self.gate.lockUncancelable(io);
        self.drained.signal(io);
        self.gate.unlock(io);
    }

    /// Seal admission. True exactly once, so the caller that wins performs the
    /// transport's idempotent wake without every concurrent closer repeating it.
    pub fn beginShutdown(self: *ForeignCallBarrier, io: std.Io) bool {
        _ = io;
        return self.state.fetchOr(closing_bit, .acq_rel) & closing_bit == 0;
    }

    pub fn wait(self: *ForeignCallBarrier, io: std.Io) void {
        self.gate.lockUncancelable(io);
        defer self.gate.unlock(io);
        while (self.state.load(.acquire) & active_mask != 0)
            self.drained.waitUncancelable(io, &self.gate);
    }
};

/// Per-direction serialization for one stream-shaped foreign connection.
/// `ForeignCallBarrier` owns lifetime admission, not stream state: two reads
/// share decoder/spill state and two writes share encoder/buffer state, while
/// one read and one write are valid full-duplex operations. Keeping distinct
/// gates makes that contract structural at every transport archive.
pub const ConnDirectionGates = struct {
    read: std.Io.Mutex = .init,
    write: std.Io.Mutex = .init,
};

/// Modest caps on a stream-shaped transport connection's per-direction buffers.
/// Neither buffer needs to hold a whole frame: `writeFrame` streams a large
/// outbound frame straight through the write buffer, and an inbound frame
/// larger than the read buffer accumulates in the connection's bounded spill
/// (`net.Spill`) while it is in flight. Steady per-connection memory is
/// therefore these two buffers, not `max_frame_bytes`.
pub const connection_read_buf_bytes: usize = 16 * 1024;
pub const connection_write_buf_bytes: usize = 64 * 1024;
/// Default frame cap for direct blocking transport frame-shuttle APIs. Keeping
/// this below the Host protocol default preserves small per-connection buffers
/// unless the caller opts into larger frames.
pub const raw_transport_default_frame_cap: usize = 4096;

/// The buffer/payload lifecycle every stream-shaped transport archive's
/// connection handles share (tcp, inproc, and onion; iroh's loop connections
/// carry no buffers). `Payload` declares `stream` (with `shutdown`/`deinit`),
/// `operations`, `directions`, `read_buf`, `write_buf`, and `allocator`. A
/// comptime helper,
/// not an `export fn`, so each archive compiles its own copy and the shared leaf
/// stays symbol-free.
pub fn ConnLifecycle(comptime Payload: type) type {
    return struct {
        const Stream = @TypeOf(@as(Payload, undefined).stream);
        const ShutdownResult = @typeInfo(@TypeOf(Stream.shutdown)).@"fn".return_type.?;

        /// Allocate a connection payload and its buffers, leaving `.stream` for
        /// the caller to install once the connection is established. On any
        /// failure before install, release it with `abort`.
        pub fn begin(alloc: std.mem.Allocator, max_frame_bytes: usize) ?*Payload {
            const read_buf = alloc.alloc(u8, @min(max_frame_bytes, connection_read_buf_bytes)) catch return null;
            const write_buf = alloc.alloc(u8, @min(max_frame_bytes, connection_write_buf_bytes)) catch {
                alloc.free(read_buf);
                return null;
            };
            const payload = alloc.create(Payload) catch {
                alloc.free(read_buf);
                alloc.free(write_buf);
                return null;
            };
            payload.read_buf = read_buf;
            payload.write_buf = write_buf;
            payload.allocator = alloc;
            payload.operations = .{};
            payload.directions = .{};
            return payload;
        }

        /// Release a payload whose `.stream` was never installed.
        pub fn abort(payload: *Payload) void {
            const alloc = payload.allocator;
            alloc.free(payload.read_buf);
            alloc.free(payload.write_buf);
            alloc.destroy(payload);
        }

        /// Seal new operations and interrupt those already blocked in transport
        /// I/O without releasing storage.
        pub fn shutdown(payload: *Payload) ShutdownResult {
            if (payload.operations.beginShutdown(payload.stream.io)) {
                return payload.stream.shutdown();
            }
            return;
        }

        /// Release an established payload: interrupt I/O, join every admitted C
        /// call, then close the stream and free its buffers.
        pub fn destroy(payload: *Payload) ShutdownResult {
            const alloc = payload.allocator;
            // The release is a barrier even when shutdown refuses: admitted
            // calls still join and every owned byte is reclaimed before the
            // exact shutdown result reaches the caller.
            defer {
                payload.operations.wait(payload.stream.io);
                payload.stream.deinit();
                alloc.free(payload.read_buf);
                alloc.free(payload.write_buf);
                alloc.destroy(payload);
            }
            return shutdown(payload);
        }
    };
}

/// The one body behind every stream-shaped `glowcap_*_conn_{read,write}_frame`
/// (tcp and inproc). `Payload` declares `stream` (with `readFrame`/`writeFrame`)
/// and `allocator`. A comptime helper, not an `export fn`, so each archive
/// compiles its own copy and the shared leaf stays symbol-free. The archives
/// keep their own exports (ADR-0022). `onConnectionLost` / `onWriteErr`
/// parameterize the last-error message: tcp consults `lastReadError`/
/// `lastWriteError`, inproc records a static cause.
pub fn ConnFrameOps(comptime Payload: type) type {
    return struct {
        pub fn readFrame(
            payload: *Payload,
            out_frame: *GlowcapManagedFrame,
            comptime onConnectionLost: fn (*Payload) void,
        ) i32 {
            if (!payload.operations.acquire(payload.stream.io)) return GLOWCAP_ERR_CLOSED;
            defer payload.operations.release(payload.stream.io);
            payload.directions.read.lockUncancelable(payload.stream.io);
            defer payload.directions.read.unlock(payload.stream.io);
            const f = payload.stream.readFrame() catch |err| return frameReadErrorToCode(payload, err, onConnectionLost);
            out_frame.* = frame.managed(f);
            return GLOWCAP_OK;
        }

        pub fn writeFrame(
            payload: *Payload,
            frame_in: *const GlowcapFrame,
            comptime onWriteErr: fn (*Payload, anyerror) void,
        ) i32 {
            if (!payload.operations.acquire(payload.stream.io)) return GLOWCAP_ERR_CLOSED;
            defer payload.operations.release(payload.stream.io);
            const bytes_ptr = frame_in.bytes orelse return GLOWCAP_ERR_NULL_POINTER;
            payload.directions.write.lockUncancelable(payload.stream.io);
            defer payload.directions.write.unlock(payload.stream.io);

            payload.stream.writeFrame(bytes_ptr[0..frame_in.len]) catch |err| {
                onWriteErr(payload, err);
                return GLOWCAP_ERR_IO;
            };
            return GLOWCAP_OK;
        }

        fn frameReadErrorToCode(
            payload: *Payload,
            err: anytype,
            comptime onConnectionLost: fn (*Payload) void,
        ) i32 {
            return switch (err) {
                error.Closed => GLOWCAP_ERR_CLOSED,
                error.MalformedFrame => GLOWCAP_ERR_MALFORMED,
                error.FrameTooLarge => GLOWCAP_ERR_FRAME_TOO_LARGE,
                error.TruncatedFrame => blk: {
                    setLastError("read_frame: stream closed mid-frame", .{});
                    break :blk GLOWCAP_ERR_IO;
                },
                error.ConnectionLost => blk: {
                    onConnectionLost(payload);
                    break :blk GLOWCAP_ERR_IO;
                },
                error.OutOfMemory => GLOWCAP_ERR_INTERNAL,
            };
        }
    };
}
