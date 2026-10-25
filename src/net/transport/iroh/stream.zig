//! The stream over one iroh QUIC connection: the sidecar connection as a
//! `stream_shim` byte source, pinned as the shared `net.netlayer.PinnedStream`,
//! and the adoption of one owned sidecar connection into a netlayer
//! `Connection` with its verified channel key.

const std = @import("std");

const engine = @import("engine");
const net = @import("net");
const sidecar = @import("sidecar.zig");

const Io = std.Io;
const Connection = net.Connection;
const Buffers = net.netlayer.Buffers;
const CConn = sidecar.CConn;
const connRemoteKey = sidecar.connRemoteKey;

/// The sidecar connection as a `stream_shim` byte source. The sidecar write
/// is synchronous: it copies or sends the bytes before returning, so the caller
/// may free them as soon as the call returns, unlike the completion loop's
/// queued writes, which borrow until retire. QUIC sends written bytes eagerly,
/// so `flush` only surfaces a connection that died under the writes.
const ConnSource = struct {
    conn: *CConn,

    pub fn readSome(self: ConnSource, dest: []u8) Io.Reader.Error!usize {
        const n = sidecar.glowcap_iroh_sidecar_conn_read(self.conn, dest.ptr, dest.len);
        if (n == 0) return error.EndOfStream;
        // A negative count is a fault, and one past `dest` is the sidecar
        // breaking its contract.
        if (n < 0 or n > dest.len) return error.ReadFailed;
        return @intCast(n);
    }

    pub fn writeAll(self: ConnSource, bytes: []const u8) Io.Writer.Error!void {
        if (sidecar.glowcap_iroh_sidecar_conn_write(self.conn, bytes.ptr, bytes.len) < 0) return error.WriteFailed;
    }

    pub fn flush(self: ConnSource) Io.Writer.Error!void {
        if (sidecar.glowcap_iroh_sidecar_conn_flush(self.conn) != 0) return error.WriteFailed;
    }
};

/// One dialed/accepted QUIC stream, pinned so its reader/writer interfaces hold
/// a stable address for the `Connection`'s life. It is the shared
/// `net.netlayer.PinnedStream` over the sidecar's `ConnSource`. Closing it
/// finishes the QUIC stream (the partner reads a clean end of stream) and frees
/// the sidecar connection handle. Read and write ride the one `*CConn`, so both
/// Shim sources name it.
const IrohContext = struct {
    conn: *CConn,

    pub fn closeStream(self: IrohContext) void {
        sidecar.glowcap_iroh_sidecar_conn_free(self.conn);
    }
};

const IrohStream = net.netlayer.PinnedStream(ConnSource, IrohContext);

fn irohStreamCreate(allocator: std.mem.Allocator, conn: *CConn, bufs: Buffers) std.mem.Allocator.Error!*IrohStream {
    return IrohStream.create(allocator, .{ .conn = conn }, .{ .conn = conn }, bufs, .{ .conn = conn });
}

/// Adopt one sidecar connection into the netlayer stream. Ownership transfers
/// on entry, including every failure path. The authenticated identity becomes
/// durable only after the last fallible stream allocation, so a refused
/// connection cannot leave a phantom channel proof on `peer`.
pub fn adoptOwnedConn(io: Io, peer: *engine.Peer, conn: *CConn, bufs: Buffers) (error{ConnectionLost} || std.mem.Allocator.Error)!Connection {
    errdefer sidecar.glowcap_iroh_sidecar_conn_free(conn);
    const remote_key = connRemoteKey(conn) orelse return error.ConnectionLost;
    const stream = try irohStreamCreate(peer.allocator, conn, bufs);
    peer.bindVerifiedChannelKey(remote_key);
    return stream.intoConnection(io, peer);
}
