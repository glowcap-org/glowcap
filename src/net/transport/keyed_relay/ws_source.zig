//! CapTP-facing byte-source shim over a keyed-relay WebSocket stream.

const std = @import("std");

pub fn Source(comptime RelayStream: type) type {
    return struct {
        rs: *RelayStream,

        pub fn readSome(self: @This(), dest: []u8) std.Io.Reader.Error!usize {
            return self.rs.readSome(dest);
        }

        pub fn writeAll(self: @This(), bytes: []const u8) std.Io.Writer.Error!void {
            // RFC 6455 section 5.5.1 forbids data frames after either half has
            // started the close handshake. Control replies bypass this shim.
            if (self.rs.read_closed or self.rs.close_sent) {
                self.rs.noteFailure(error.Closed);
                return error.WriteFailed;
            }
            return self.rs.writeFrame(.binary, bytes);
        }

        pub fn flush(self: @This()) std.Io.Writer.Error!void {
            self.rs.source.writer.flush() catch |err| {
                self.rs.noteSourceFailure(err);
                return error.WriteFailed;
            };
        }
    };
}
