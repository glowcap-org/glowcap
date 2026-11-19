//! Receipt numbering and slot retention through the endpoint's retry window.
const std = @import("std");
const loam = @import("glowcap").loam;
const Window = loam.access.records.RetryWindow;

fn receipt(sequence: u64) loam.core.ObjectId {
    return .{ .store = @fromBackingInt(3), .incarnation = 1, .sequence = 100 + sequence * 3 };
}

test "loam receipt window keeps exact outcomes and never reopens expired sequences" {
    var window: Window = .{};
    try std.testing.expectError(error.OperationOutOfOrder, window.lookup(0));
    for (1..3 * Window.capacity + 1) |sequence| {
        try std.testing.expect((try window.lookup(sequence)) == null);
        try window.append(receipt(sequence));
        try std.testing.expectEqual(@as(u64, sequence + 1), window.next);
        const kept = @min(sequence, Window.capacity);
        try std.testing.expectEqual(kept, @as(usize, window.count));
        const first = sequence + 1 - kept;
        for (1..sequence + 1) |prior| {
            if (prior < first) {
                try std.testing.expectError(error.ReceiptExpired, window.lookup(prior));
            } else {
                try std.testing.expectEqualDeep(receipt(prior), (try window.lookup(prior)).?);
            }
        }
        try std.testing.expectError(error.OperationOutOfOrder, window.lookup(window.next + 1));
    }

    var exhausted: Window = .{ .next = std.math.maxInt(i64) };
    try std.testing.expectError(error.SequenceExhausted, exhausted.lookup(exhausted.next));
    try std.testing.expectError(error.SequenceExhausted, exhausted.append(receipt(1)));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(i64)), exhausted.next);
    try std.testing.expectEqual(@as(u8, 0), exhausted.count);
    try std.testing.expectError(error.ReceiptExpired, exhausted.lookup(1));
    try std.testing.expectError(error.InvalidRecord, (Window{ .next = 1, .count = 1 }).lookup(1));
}
