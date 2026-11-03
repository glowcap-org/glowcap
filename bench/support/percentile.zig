//! The percentile every bench reports: nearest rank over samples already
//! sorted ascending, so a reported p99 is always a latency that was observed.
//! The rank is `ceil(p * len)` counted from one, clamped into the slice.

const std = @import("std");

/// Index of the nearest-rank percentile `p` (in 0..1) in a sorted slice of
/// `len` samples. An empty slice has no sample, so the index is 0 and a
/// caller reading it must check `len` first; `of` does.
pub fn index(len: usize, p: f64) usize {
    if (len == 0) return 0;
    const rank: usize = @intFromFloat(@ceil(p * @as(f64, @floatFromInt(len))));
    return @min(len - 1, @max(rank, 1) - 1);
}

/// The nearest-rank percentile `p` of `sorted`, or zero for an empty slice.
pub fn of(comptime T: type, sorted: []const T, p: f64) T {
    if (sorted.len == 0) return 0;
    return sorted[index(sorted.len, p)];
}
