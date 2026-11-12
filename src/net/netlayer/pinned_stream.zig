//! The two pinned connection shells a resident wraps its byte source in.
//! Each holds the reader and writer at a stable address for the
//! `Connection`'s life.

const std = @import("std");

const foundation = @import("foundation");
const engine = @import("engine");
const connection = @import("../connection.zig");
const operation = @import("operation.zig");
const stream_shim = @import("../stream_shim.zig");

const Buffers = operation.Buffers;

/// One pinned byte-source stream: a shim reader/writer pair plus the allocation
/// from which their concrete interfaces can be recovered by field offset.
pub fn PinnedStream(comptime Source: type, comptime Context: type) type {
    return struct {
        const Self = @This();
        const ShimT = stream_shim.Shim(Source);

        reader: ShimT.Reader,
        writer: ShimT.Writer,
        allocator: std.mem.Allocator,
        context: Context,

        /// Pin the two shim sources and the transport context on `allocator`.
        pub fn create(
            allocator: std.mem.Allocator,
            read_source: Source,
            write_source: Source,
            bufs: Buffers,
            context: Context,
        ) std.mem.Allocator.Error!*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .reader = ShimT.Reader.init(read_source, bufs.read),
                .writer = ShimT.Writer.init(write_source, bufs.write),
                .allocator = allocator,
                .context = context,
            };
            return self;
        }

        pub fn intoConnection(self: *Self, io: std.Io, peer: *engine.Peer) connection.Connection {
            return connection.Connection.init(io, peer, &self.reader.interface, &self.writer.interface, .{
                .ctx = self,
                .close_fn = close,
                .socket_handle_fn = socketHandle,
                .take_failure_fn = takeFailure,
            });
        }

        /// Release the transport handle before freeing its pinned allocation.
        pub fn close(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.context.closeStream();
            self.allocator.destroy(self);
        }

        fn socketHandle(ctx: *anyopaque) ?std.Io.net.Socket.Handle {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(Context, "socketHandle")) return self.context.socketHandle();
            return null;
        }

        fn takeFailure(ctx: *anyopaque) ?foundation.FailureChain {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(Context, "takeFailure")) return self.context.takeFailure();
            return null;
        }
    };
}

/// One pinned raw socket connection: a `Raw` that already carries
/// `std.Io.net.Stream`'s own reader and writer, held at a stable address for
/// the `Connection`'s life.
///
/// This is the second pinned shell beside `PinnedStream`, and the two exist
/// because their sources differ in kind. `PinnedStream` builds a shim reader
/// and writer over a byte `Source`, for transports that expose only read and
/// write calls (an in-process pipe, the iroh sidecar). A raw socket connection
/// already owns a `std.Io.Reader` and `std.Io.Writer` over its buffers, so
/// wrapping it in a shim would put a second buffer and a copy between the
/// socket and the frame parser (ADR-0019, ADR-0021). `Raw` supplies `reader`
/// and `writer` fields with an `interface`, an `io` field, `close`, and
/// `readinessFd`. Neither raw socket type carries a failure chain, so the
/// handle publishes none.
///
/// `std.Io.Reader`'s vtable recovers its concrete reader from `&interface` by
/// field offset, so the pair needs an address that outlives the call that made
/// it. Allocated from the peer's allocator at connect or accept and freed by
/// the connection's transport handle on `deinit`: one small per-connection
/// allocation on the blocking path, the price of keeping `Connection`
/// transport-neutral.
pub fn PinnedRawStream(comptime Raw: type) type {
    return struct {
        const Self = @This();

        raw: Raw,
        allocator: std.mem.Allocator,

        /// Pin `raw` on `peer.allocator` and weld it to `peer`. On allocation
        /// failure `raw` is still the caller's to close.
        pub fn adopt(peer: *engine.Peer, raw: Raw) std.mem.Allocator.Error!connection.Connection {
            const self = try peer.allocator.create(Self);
            self.* = .{ .raw = raw, .allocator = peer.allocator };
            return connection.Connection.init(self.raw.io, peer, &self.raw.reader.interface, &self.raw.writer.interface, .{
                .ctx = self,
                .close_fn = close,
                .socket_handle_fn = socketHandle,
            });
        }

        fn close(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.raw.close();
            self.allocator.destroy(self);
        }

        fn socketHandle(ctx: *anyopaque) ?std.Io.net.Socket.Handle {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.raw.readinessFd();
        }
    };
}
