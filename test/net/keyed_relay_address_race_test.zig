//! Shared resolver-order and pollable descriptor-retirement evidence.

const std = @import("std");
const relay = @import("glowcap").net.relay;

test "relay address failures retain resolver order" {
    const Chain = struct {
        items: [4]u8 = undefined,
        len: usize = 0,

        fn init(value: u8) @This() {
            var chain: @This() = .{};
            chain.items[0] = value;
            chain.len = 1;
            return chain;
        }

        pub fn noteChain(self: *@This(), other: @This()) void {
            @memcpy(self.items[self.len..][0..other.len], other.items[0..other.len]);
            self.len += other.len;
        }
    };
    const Failure = struct { chain: Chain };
    var ledger: relay.white_box.FailureLedger(Failure) = .{};
    ledger.note(2, .{ .chain = .init(3) });
    ledger.note(0, .{ .chain = .init(1) });
    ledger.note(2, .{ .chain = .init(4) });
    ledger.note(1, .{ .chain = .init(2) });

    var ordered: ?Failure = null;
    ledger.appendTo(&ordered, 3);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, ordered.?.chain.items[0..4]);
}

test "pollable relay classifies descriptor retirement refusal" {
    const failure = relay.white_box.pollable_address_race.descriptorRetirementFailure(-1);
    try std.testing.expectEqual(error.InvalidSocketHandle, failure.chain.cause);
    try std.testing.expectEqualStrings("shutdown", @tagName(failure.carrier_phase.?));
}
