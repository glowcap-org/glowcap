const std = @import("std");

const foundation = @import("../foundation/mod.zig");

pub const MemoryEndpoint = struct {
    allocator: std.mem.Allocator,
    inbound: std.ArrayList(foundation.Frame),
    inbound_head: usize,

    pub fn init(allocator: std.mem.Allocator) MemoryEndpoint {
        return .{
            .allocator = allocator,
            .inbound = .empty,
            .inbound_head = 0,
        };
    }

    pub fn deinit(self: *MemoryEndpoint) void {
        for (self.inbound.items[self.inbound_head..]) |*frame| {
            frame.deinit();
        }
        self.inbound.deinit(self.allocator);
    }

    /// Transfer an owned frame into the endpoint without copying bytes.
    ///
    /// On success the endpoint owns `frame`; on error the caller remains
    /// responsible for releasing it.
    pub fn writeFrameOwned(self: *MemoryEndpoint, io: std.Io, frame: foundation.Frame) !void {
        _ = io;
        try self.inbound.append(self.allocator, frame);
    }

    /// Take the next queued inbound frame, transferring ownership to the caller:
    /// the endpoint advances past it and stops tracking it, so the caller must
    /// `deinit` the returned frame. Returns null once the queue is drained. `io`
    /// and `allocator` are unused — the frame was allocated by its writer and is
    /// moved, not copied.
    pub fn readFrame(
        self: *MemoryEndpoint,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) !?foundation.Frame {
        _ = io;
        _ = allocator;

        if (self.inbound_head == self.inbound.items.len) {
            return null;
        }
        const frame = self.inbound.items[self.inbound_head];
        self.inbound_head += 1;
        return frame;
    }
};
