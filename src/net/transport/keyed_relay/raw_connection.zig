//! One admitted relay byte channel, independent of CapTP framing and profile.

const std = @import("std");
const relay_stream = @import("stream.zig");

const foundation = @import("foundation");
const multiplexed_resident = @import("../../multiplexed_resident.zig");

const Io = std.Io;
const RelayStream = relay_stream.RelayStream;
pub const CloseProgress = relay_stream.CloseProgress;

pub const Connection = struct {
    stream: *RelayStream,

    pub fn read(self: *Connection, dest: []u8) Io.Reader.Error!usize {
        return self.stream.readSome(dest);
    }

    pub fn writeAll(self: *Connection, bytes: []const u8) Io.Writer.Error!void {
        try self.stream.writeFrame(.binary, bytes);
        try self.stream.flush();
    }

    pub fn tryRead(self: *Connection, dest: []u8) isize {
        const count = self.stream.tryReadSome(dest) catch |err| return switch (err) {
            error.WouldBlock => multiplexed_resident.would_block,
            error.EndOfStream => 0,
            error.ReadFailed => -1,
        };
        return @intCast(count);
    }

    /// Mask and adopt a bounded caller prefix before returning.
    pub fn tryWrite(self: *Connection, bytes: []const u8) isize {
        return self.stream.tryWriteSome(bytes);
    }

    pub fn flushPending(self: *Connection) isize {
        return self.stream.tryFlushPending();
    }

    pub fn hasPendingWrite(self: *const Connection) bool {
        return self.stream.hasPendingWrite();
    }

    pub fn readinessFd(self: *const Connection) i32 {
        return self.stream.readinessFd();
    }

    pub fn takeFailure(self: *Connection) ?foundation.FailureChain {
        return self.stream.takeFailure();
    }

    pub fn tryClose(self: *Connection) CloseProgress {
        return self.stream.tryClose();
    }

    pub fn close(self: *Connection) ?foundation.FailureChain {
        const failure = self.stream.destroy();
        self.* = undefined;
        return failure;
    }
};
