const std = @import("std");
const kqueue = @import("glowcap").net.kqueue_white_box;

test "kqueue failed registration leaves no pending operation" {
    try std.testing.expect(try kqueue.failedRegistrationLeavesNoPending(std.testing.allocator));
}
