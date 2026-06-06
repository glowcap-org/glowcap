//! An in-memory frame endpoint for tests: a FIFO of owned frames, no real I/O.
//!
//! It exercises the owned-transfer half of the transport contract — the same
//! seam `net_adapter` fills over a real `std.Io` stream — without needing a
//! socket. The `std.Io` parameters match that transport shape but go unused;
//! moving a frame needs no I/O. This is test support, not a production layer.

const std = @import("std");
const pancake = @import("pancake");

const frame_support = @import("frame.zig");
const foundation = pancake.foundation;

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

/// Copy a borrowed frame into the endpoint (the test-only boundary copy).
pub fn writeFrameCopy(
    endpoint: *MemoryEndpoint,
    io: std.Io,
    frame: foundation.FrameView,
) !void {
    var owned = try frame_support.copyFromBorrowed(endpoint.allocator, frame.bytes, frame.shape);
    errdefer owned.deinit();
    try endpoint.writeFrameOwned(io, owned);
}
