//! The owner-thread token: a raw thread id becomes a token that is never the
//! unclaimed value, and an owner that does not track pays nothing.

const std = @import("std");
const foundation = @import("glowcap").foundation;

test "an owner thread token is never the unclaimed value" {
    const Tracked = foundation.thread_affinity.OwnerThread(true);
    try std.testing.expect(Tracked.token(0) != Tracked.unclaimed);
    try std.testing.expectEqual(Tracked.token(7), Tracked.token(7));
    try std.testing.expect(Tracked.token(7) != Tracked.token(8));
    try std.testing.expectEqual(Tracked.unclaimed, Tracked.initial);
}

test "an untracked owner's token is void" {
    const Untracked = foundation.thread_affinity.OwnerThread(false);
    try std.testing.expectEqual(void, Untracked.Id);
    Untracked.token(7);
}
