//! Process-wide OS snapshots, lifetime peaks and fault counts, and CPU placement for Tasks comparisons.
const std = @import("std");
const report = @import("report.zig");
extern fn glowcap_bench_memory(*u64, *u64, *u64, *u64, *u64) c_int;

pub const Snapshot = struct { resident: u64, virtual_bytes: u64, peak: u64, minor: u64, major: u64 };

pub fn snapshot() !Snapshot {
    var value: Snapshot = undefined;
    if (glowcap_bench_memory(&value.resident, &value.virtual_bytes, &value.peak, &value.minor, &value.major) != 0) return error.ProcessMemoryUnavailable;
    if (value.resident == 0 or value.virtual_bytes < value.resident or value.peak == 0) return error.InvalidProcessMemory;
    return value;
}

pub fn emit(gpa: std.mem.Allocator, output: *std.ArrayList(u8), phase: []const u8, count: usize, shape: usize) !void {
    try emitSnapshot(gpa, output, phase, count, shape, try snapshot());
}

/// Report a snapshot the caller also keeps, so a line and the figures a phase
/// derives from it agree.
pub fn emitSnapshot(gpa: std.mem.Allocator, output: *std.ArrayList(u8), phase: []const u8, count: usize, shape: usize, now: Snapshot) !void {
    try report.emit(gpa, output, "process_memory phase={s} population={d} shape={d} rss_bytes={d} virtual_bytes={d} lifetime_peak_rss_bytes={d} lifetime_minor_faults={d} lifetime_major_faults={d}\n", .{ phase, count, shape, now.resident, now.virtual_bytes, now.peak, now.minor, now.major });
}

/// Keep both Tasks engine runs on one logical CPU, so migration between
/// different CPU types cannot masquerade as an engine cost. Linux only.
pub fn pinCpu(cpu: u32) !void {
    if (@import("builtin").os.tag != .linux) return error.CpuAffinityUnsupported;
    if (glowcap_bench_pin_cpu(cpu) != 0) return error.CpuAffinityUnavailable;
}

extern fn glowcap_bench_pin_cpu(c_uint) c_int;
