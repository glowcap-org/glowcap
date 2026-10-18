//! Pinning for a two-thread measurement: a `--pin=A,B` row keeps the timed
//! thread on core A and its partner on core B, so a spinning side never
//! shares a core with the side it waits for, and a parked side pays the
//! same cross-core wake on every run. Without it the scheduler chooses, and
//! two runs of one recipe can differ by a scheduler tick.

const std = @import("std");

/// The two cores a `--pin=A,B` argument names.
pub const Pair = [2]u16;

/// Parse the value after `--pin=`: two decimal core numbers joined by a comma.
pub fn parsePair(text: []const u8) !Pair {
    const comma = std.mem.indexOfScalar(u8, text, ',') orelse return error.PinWantsTwoCores;
    return .{
        try std.fmt.parseInt(u16, text[0..comma], 10),
        try std.fmt.parseInt(u16, text[comma + 1 ..], 10),
    };
}

/// Pin the calling thread to `cpu`. Linux only, since the benches that use
/// it measure a Linux kernel's wakes and rings.
pub fn pinThread(cpu: u16) !void {
    try apply(try mask(&.{cpu}));
}

/// A thread's mask as the kernel holds it.
pub const Set = std.os.linux.cpu_set_t;

/// The mask that admits exactly `cpus`.
pub fn mask(cpus: []const u16) !Set {
    var set: Set = @splat(0);
    const bits = @bitSizeOf(usize);
    for (cpus) |cpu| {
        if (cpu / bits >= set.len) return error.CpuOutOfRange;
        set[cpu / bits] |= @as(usize, 1) << @intCast(cpu % bits);
    }
    return set;
}

/// Put `set` on the calling thread.
pub fn apply(set: Set) !void {
    try std.os.linux.sched_setaffinity(0, &set);
}

/// Read the calling thread's mask, so a pinned spawn can put it back: a child
/// inherits the mask it is spawned under, and the spawner keeps its own.
pub fn current() !Set {
    return std.posix.sched_getaffinity(0);
}
