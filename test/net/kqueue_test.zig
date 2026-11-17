const std = @import("std");
const glowcap = @import("glowcap");
const pool_refusal = @import("../support/recv_pool_refusal.zig");

const kqueue = glowcap.net.kqueue_white_box;

test "kqueue failed registration leaves no pending operation" {
    try std.testing.expect(try kqueue.failedRegistrationLeavesNoPending(std.testing.allocator));
}

/// Armed operations. A completed one-shot read keeps its row with both
/// directions idle, so the row count alone would not say what is outstanding.
fn armedCount(backend: *const kqueue.TestBackend) usize {
    var armed: usize = 0;
    var rows = backend.pending.valueIterator();
    while (rows.next()) |row| {
        if (row.read != .idle or row.write != .idle) armed += 1;
    }
    return armed;
}

test "kqueue refused buffer growth fails the receive once and exhaustion still waits for a recycle" {
    try pool_refusal.expectRefusalThenSaturationRecovery(kqueue.TestBackend, armedCount);
}
