//! Process-wide OS snapshots, peaks and fault counts cover the process lifetime.
const std = @import("std");
const report = @import("report.zig");
extern fn glowcap_bench_memory(*u64, *u64, *u64, *u64, *u64) c_int;

pub fn emit(gpa: std.mem.Allocator, output: *std.ArrayList(u8), phase: []const u8, count: usize, shape: usize) !void {
    var resident: u64 = 0;
    var virtual_bytes: u64 = 0;
    var peak: u64 = 0;
    var minor: u64 = 0;
    var major: u64 = 0;
    if (glowcap_bench_memory(&resident, &virtual_bytes, &peak, &minor, &major) != 0) return error.ProcessMemoryUnavailable;
    if (resident == 0 or virtual_bytes < resident or peak == 0) return error.InvalidProcessMemory;
    try report.emit(gpa, output, "process_memory phase={s} population={d} shape={d} rss_bytes={d} virtual_bytes={d} lifetime_peak_rss_bytes={d} lifetime_minor_faults={d} lifetime_major_faults={d}\n", .{ phase, count, shape, resident, virtual_bytes, peak, minor, major });
}
