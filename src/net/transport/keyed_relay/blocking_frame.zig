//! Blocking-reader adapter for the shared pure WebSocket frame grammar.

const std = @import("std");
const protocol = @import("../../websocket/client_protocol.zig");

pub const FrameError = protocol.ParseError || error{ Truncated, ReadFailed };

/// Read one complete frame header. The resident is the only tier allowed to
/// wait; completion code calls `protocol.parseHeaderBytes` on delivered bytes.
pub fn readFrameHeader(reader: *std.Io.Reader) FrameError!protocol.FrameHeader {
    var header: [10]u8 = undefined;
    header[0] = try takeHeaderByte(reader);
    header[1] = try takeHeaderByte(reader);
    const need = protocol.headerLenOf(header[0..2]).?;
    try readHeaderBytes(reader, header[2..need]);
    return (try protocol.parseHeaderBytes(header[0..need])).?.frame;
}

fn takeHeaderByte(reader: *std.Io.Reader) FrameError!u8 {
    return reader.takeByte() catch |err| switch (err) {
        error.EndOfStream => FrameError.Truncated,
        error.ReadFailed => FrameError.ReadFailed,
    };
}

pub fn readHeaderBytes(reader: *std.Io.Reader, dest: []u8) FrameError!void {
    reader.readSliceAll(dest) catch |err| switch (err) {
        error.EndOfStream => return FrameError.Truncated,
        error.ReadFailed => return FrameError.ReadFailed,
    };
}
