//! A connection transport over a stream the test owns and closes itself.

const std = @import("std");
const glowcap = @import("glowcap");

/// A transport handle over `reader`'s stream whose close does nothing.
pub fn borrowedHandle(reader: *std.Io.net.Stream.Reader) glowcap.net.Connection.Transport {
    return .{
        .ctx = reader,
        .close_fn = struct {
            fn noop(_: *anyopaque) void {}
        }.noop,
        .socket_handle_fn = struct {
            fn handle(ctx: *anyopaque) ?std.Io.net.Socket.Handle {
                const r: *std.Io.net.Stream.Reader = @ptrCast(@alignCast(ctx));
                return r.stream.socket.handle;
            }
        }.handle,
    };
}
