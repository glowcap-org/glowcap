//! The OS thread identity reader shared by adapters and completion loops.
const std = @import("std");
const foundation = @import("foundation");

pub const reader: foundation.thread_affinity.Reader = .{ .read = read };

fn read(_: ?*anyopaque) u64 {
    return std.Thread.getCurrentId();
}
