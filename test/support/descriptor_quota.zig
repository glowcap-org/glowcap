//! The process descriptor quota, lowered for a test so the kernel refuses a
//! descriptor past a chosen count, and restored after it.

const std = @import("std");

/// The quota as the test found it, which `end` restores.
pub const Lowered = struct {
    saved: std.posix.rlimit,

    /// Lower the soft quota so `spare` more descriptors fit and the one
    /// after them is over it.
    pub fn begin(spare: usize) !Lowered {
        const saved = try std.posix.getrlimit(.NOFILE);
        const rc = std.posix.system.dup(0);
        if (std.posix.errno(rc) != .SUCCESS) return error.DupFailed;
        const lowest_free: std.posix.fd_t = @intCast(rc);
        _ = std.posix.system.close(lowest_free);
        try std.posix.setrlimit(.NOFILE, .{ .cur = @as(std.posix.rlim_t, @intCast(lowest_free)) + spare, .max = saved.max });
        return .{ .saved = saved };
    }

    pub fn end(self: Lowered) void {
        std.posix.setrlimit(.NOFILE, self.saved) catch unreachable; // raising back to the saved soft limit stays under its own hard limit
    }
};
