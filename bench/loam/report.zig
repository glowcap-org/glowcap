//! Shared latency samples and report rendering for the Loam workloads.
const std = @import("std");

pub const Samples = struct {
    values: [4096]u64 = undefined,
    count: usize = 0,
    pub fn add(self: *Samples, ns: u64) void {
        self.values[self.count] = ns;
        self.count += 1;
    }
    pub fn summarize(self: *Samples) Distribution {
        std.mem.sort(u64, self.values[0..self.count], {}, std.sort.asc(u64));
        return .{ .p50_ns = self.values[self.count / 2], .p95_ns = self.values[@min(self.count - 1, self.count * 95 / 100)], .p99_ns = self.values[@min(self.count - 1, self.count * 99 / 100)] };
    }
};
pub const Distribution = struct { p50_ns: u64, p95_ns: u64, p99_ns: u64 };
pub const Row = struct {
    phase: []const u8,
    conversations: usize,
    message_bytes: usize,
    operations: usize,
    reads: u64,
    writes: u64,
    elapsed_ns: u64,
    latency: Distribution,
};

pub fn now(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}
pub fn elapsed(io: std.Io, start: i128) u64 {
    return @intCast(@max(0, now(io) - start));
}
pub fn emit(gpa: std.mem.Allocator, report: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const line = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(line);
    std.debug.print("{s}", .{line});
    try report.appendSlice(gpa, line);
}
pub fn row(gpa: std.mem.Allocator, report: *std.ArrayList(u8), value: Row) !void {
    try emit(gpa, report, "{s} conversations={d} message_bytes={d} ops={d} reads={d} writes={d} elapsed_ns={d} p50_ns={d} p99_ns={d}\n", .{
        value.phase, value.conversations, value.message_bytes, value.operations, value.reads, value.writes, value.elapsed_ns, value.latency.p50_ns, value.latency.p99_ns,
    });
}
