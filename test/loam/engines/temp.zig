//! A temporary store directory and its real path, which every disk engine
//! fixture opens its stores in. Its own module, so an engine fixture never
//! pulls the shared record fixture into a process probe that imports it by path.
const std = @import("std");

pub const Temp = struct {
    dir: std.testing.TmpDir,
    path: [:0]u8,

    pub fn init() !Temp {
        var dir = std.testing.tmpDir(.{});
        errdefer dir.cleanup();
        const path = try std.Io.Dir.realPathFileAlloc(dir.dir, std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(path);
        return .{ .dir = dir, .path = try std.testing.allocator.dupeSentinel(u8, path, 0) };
    }

    pub fn deinit(self: *Temp) void {
        std.testing.allocator.free(self.path);
        self.dir.cleanup();
    }
};
