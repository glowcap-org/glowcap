//! Provider-owned pending dial and listen operations.

const std = @import("std");
const net = @import("net");
const runtime = @import("../runtime/state.zig");

pub const Dial = struct {
    owner: *runtime.Netlayer,
    designator: []u8,
    completion: net.TransportOperationCompletion,
    operation: net.CancelableOperation = undefined,
    result: Result = .pending,

    pub const Result = union(enum) {
        pending,
        stream: std.Io.net.Stream,
        failure: net.netlayer.DialError,
    };

    pub fn run(self: *Dial) std.Io.Cancelable!void {
        self.result = if (net.onion.resident.dialRawStream(
            self.owner.io(),
            self.owner.resident.config.socks,
            self.designator,
        )) |stream|
            .{ .stream = stream }
        else |err|
            .{ .failure = err };
        _ = self.completion.publish();
    }

    pub fn retire(raw: *anyopaque) void {
        const self: *Dial = @ptrCast(@alignCast(raw));
        self.destroy();
    }

    pub fn destroy(self: *Dial) void {
        switch (self.result) {
            .stream => |stream| stream.close(self.owner.io()),
            .pending, .failure => {},
        }
        self.completion.deinit();
        const allocator = self.owner.allocator;
        allocator.free(self.designator);
        allocator.destroy(self);
    }
};

pub const Listen = struct {
    owner: *runtime.Netlayer,
    requested_designator: []u8,
    completion: net.TransportOperationCompletion,
    operation: net.CancelableOperation = undefined,
    result: Result = .pending,

    pub const Result = union(enum) {
        pending,
        listener: *net.onion.Listener,
        failure: net.netlayer.ListenFailure,
    };

    pub fn run(self: *Listen) std.Io.Cancelable!void {
        self.result = switch (net.onion.Listener.create(
            self.owner.allocator,
            self.owner.io(),
            self.owner.resident.config,
        )) {
            .ready => |listener| blk: {
                if (self.requested_designator.len != 0 and
                    !std.mem.eql(u8, self.requested_designator, listener.designator()))
                {
                    var failure = net.netlayer.ListenFailure.init(error.InvalidAddress);
                    if (listener.deinit()) |cleanup| failure.noteChain(cleanup);
                    break :blk .{ .failure = failure };
                }
                break :blk .{ .listener = listener };
            },
            .failed => |failure| .{ .failure = failure },
        };
        _ = self.completion.publish();
    }

    pub fn retire(raw: *anyopaque) void {
        const self: *Listen = @ptrCast(@alignCast(raw));
        self.destroy();
    }

    pub fn destroy(self: *Listen) void {
        switch (self.result) {
            .listener => |listener| if (listener.deinit()) |failure|
                self.owner.noteFailure(failure),
            .pending, .failure => {},
        }
        self.completion.deinit();
        const allocator = self.owner.allocator;
        allocator.free(self.requested_designator);
        allocator.destroy(self);
    }
};
