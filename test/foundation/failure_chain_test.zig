const std = @import("std");
const FailureChain = @import("glowcap").foundation.FailureChain;

test "failure chain retains first cause and bounded consequences" {
    var failure = FailureChain.init(error.Primary);
    failure.note(error.FirstCleanup);
    failure.note(error.LaterCleanup);
    try std.testing.expectEqual(error.Primary, failure.cause);
    try std.testing.expectEqual(error.FirstCleanup, failure.secondary_cause.?);
    try std.testing.expectEqual(@as(u16, 2), failure.secondary_count);

    var later = FailureChain.init(error.NestedPrimary);
    later.note(error.NestedCleanup);
    failure.noteChain(later);
    try std.testing.expectEqual(error.FirstCleanup, failure.secondary_cause.?);
    try std.testing.expectEqual(@as(u16, 4), failure.secondary_count);

    failure.secondary_count = std.math.maxInt(u16);
    failure.note(error.Saturated);
    try std.testing.expectEqual(std.math.maxInt(u16), failure.secondary_count);
}
