//! The hermetic runtime every in-process CLI case runs on: an empty
//! environment map and a threaded `std.Io`, released together.

const std = @import("std");

pub const Runtime = struct {
    environ: std.process.Environ.Map,
    threaded: std.Io.Threaded,

    /// Fills `self` in place, because the `Io` it hands out points at
    /// `self.threaded`.
    pub fn init(self: *Runtime, gpa: std.mem.Allocator) void {
        self.environ = std.process.Environ.Map.init(gpa);
        self.threaded = std.Io.Threaded.init(gpa, .{});
    }

    pub fn deinit(self: *Runtime) void {
        self.threaded.deinit();
        self.environ.deinit();
    }

    pub fn io(self: *Runtime) std.Io {
        return self.threaded.io();
    }
};
