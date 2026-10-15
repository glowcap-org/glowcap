//! In-process byte pipes and their pinned stream projection.
//!
//! This module owns byte movement and duplex lifetime. The switchboard in
//! `../inproc.zig` only matches dialers to listeners and transfers one shared
//! `Duplex`. It does not know how the bytes are buffered or framed.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const frame_stream = @import("../../frame_stream.zig");
const netlayer = @import("../../netlayer.zig");

const Io = std.Io;
const Buffers = netlayer.Buffers;

/// A one-directional in-process byte FIFO. One endpoint writes, the other
/// reads. A read blocks until bytes arrive or the writer closes.
pub const Channel = struct {
    allocator: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    not_empty: Io.Condition = .init,
    data: std.ArrayList(u8) = .empty,
    pos: usize = 0,
    closed: bool = false,

    fn write(self: *Channel, bytes: []const u8) (std.mem.Allocator.Error || error{Closed})!void {
        if (bytes.len == 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
        try self.data.appendSlice(self.allocator, bytes);
        self.not_empty.signal(self.io);
    }

    fn read(self: *Channel, dest: []u8) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.pos == self.data.items.len and !self.closed)
            self.not_empty.waitUncancelable(self.io, &self.mutex);
        const available = self.data.items.len - self.pos;
        if (available == 0) return 0;
        const n = @min(available, dest.len);
        @memcpy(dest[0..n], self.data.items[self.pos..][0..n]);
        self.pos += n;
        if (self.pos == self.data.items.len) {
            self.data.clearRetainingCapacity();
            self.pos = 0;
        }
        return n;
    }

    pub fn close(self: *Channel) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closed = true;
        self.not_empty.broadcast(self.io);
    }

    pub fn deinit(self: *Channel) void {
        self.data.deinit(self.allocator);
    }
};

/// The two pipes of one connection plus one reference per endpoint. A peer may
/// drain buffered bytes after its partner closes. Storage retires only after
/// both endpoint owners release it.
pub const Duplex = struct {
    allocator: std.mem.Allocator,
    io: Io,
    dial_to_listen: Channel,
    listen_to_dial: Channel,
    refs_lock: Io.Mutex = .init,
    refs: usize = 2,

    pub fn create(allocator: std.mem.Allocator, io: Io) std.mem.Allocator.Error!*Duplex {
        const self = try allocator.create(Duplex);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .dial_to_listen = .{ .allocator = allocator, .io = io },
            .listen_to_dial = .{ .allocator = allocator, .io = io },
        };
        return self;
    }

    pub fn release(self: *Duplex) void {
        self.refs_lock.lockUncancelable(self.io);
        self.refs -= 1;
        const remaining = self.refs;
        self.refs_lock.unlock(self.io);
        if (remaining == 0) {
            self.dial_to_listen.deinit();
            self.listen_to_dial.deinit();
            self.allocator.destroy(self);
        }
    }
};

const ChannelSource = struct {
    chan: *Channel,

    pub fn readSome(self: ChannelSource, dest: []u8) Io.Reader.Error!usize {
        const n = self.chan.read(dest);
        if (n == 0) return error.EndOfStream;
        return n;
    }

    pub fn writeAll(self: ChannelSource, bytes: []const u8) Io.Writer.Error!void {
        self.chan.write(bytes) catch return error.WriteFailed;
    }

    pub fn flush(self: ChannelSource) Io.Writer.Error!void {
        _ = self;
    }
};

const Context = struct {
    duplex: *Duplex,
    write_chan: *Channel,

    pub fn closeStream(self: Context) void {
        self.write_chan.close();
        self.duplex.release();
    }

    fn shutdown(self: Context) void {
        self.duplex.dial_to_listen.close();
        self.duplex.listen_to_dial.close();
    }
};

pub const Endpoint = netlayer.PinnedStream(ChannelSource, Context);

pub fn endpointCreate(
    allocator: std.mem.Allocator,
    duplex: *Duplex,
    read_chan: *Channel,
    write_chan: *Channel,
    bufs: Buffers,
) std.mem.Allocator.Error!*Endpoint {
    return Endpoint.create(
        allocator,
        .{ .chan = read_chan },
        .{ .chan = write_chan },
        bufs,
        .{ .duplex = duplex, .write_chan = write_chan },
    );
}

pub fn frameStream(
    endpoint: *Endpoint,
    io: Io,
    allocator: std.mem.Allocator,
    codec_id: model.CodecId,
    max_frame_bytes: usize,
) FrameStream {
    return .{
        .endpoint = endpoint,
        .io = io,
        .codec_id = codec_id,
        .max_frame_bytes = max_frame_bytes,
        .allocator = allocator,
    };
}

/// A peer-less frame stream over one pinned in-process endpoint. Framing and
/// spill ownership are the same shared machinery used by socket transports.
pub const FrameStream = struct {
    endpoint: *Endpoint,
    io: Io,
    codec_id: model.CodecId,
    max_frame_bytes: usize,
    allocator: std.mem.Allocator,
    spill: frame_stream.Spill = .{},

    pub fn readFrame(self: *FrameStream) frame_stream.FrameError!foundation.Frame {
        return frame_stream.readFrameFrom(
            &self.endpoint.reader.interface,
            self.allocator,
            self.codec_id,
            self.max_frame_bytes,
            &self.spill,
        );
    }

    pub fn writeFrame(self: *FrameStream, bytes: []const u8) frame_stream.FrameError!void {
        return frame_stream.writeFrameTo(&self.endpoint.writer.interface, bytes);
    }

    pub fn deinit(self: *FrameStream) void {
        self.spill.deinit(self.allocator);
        Endpoint.close(self.endpoint);
    }

    pub fn shutdown(self: *FrameStream) void {
        self.endpoint.context.shutdown();
    }
};
