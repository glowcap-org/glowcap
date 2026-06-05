const std = @import("std");

const protocol_oracle = @import("protocol_oracle.zig");

test "protocol oracle enumerates every shipped message arm" {
    const expected = [_][]const u8{
        "Deliver",
        "Resolve",
        "GcExport",
        "GcAnswer",
        "Handoff",
        "StartSession",
        "Abort",
        "Listen",
        "Get",
        "Index",
    };

    try std.testing.expectEqual(expected.len, protocol_oracle.message_arms.len);
    for (expected, protocol_oracle.message_arms) |want, got| {
        try std.testing.expectEqualStrings(want, got.name);
    }
}

test "protocol oracle exposes checked-in Goblins Syrup fixtures" {
    try std.testing.expect(protocol_oracle.goblins_fixtures.len >= 34);

    const abort = protocol_oracle.fixtureByName("op_abort.bin").?;
    try std.testing.expectEqualStrings("op_abort.bin", abort.name);
    try std.testing.expect(abort.bytes().len > 0);

    const handoff = protocol_oracle.fixtureByName("op_handoff_give.bin").?;
    try std.testing.expect(handoff.bytes().len > 0);
}
