//! The cross-session agreement on pairs whose state is known: a fresh pair
//! agrees, in-flight and closed pairs are refused, and a pair where one side
//! holds an import the other never granted is named with its holder.

const std = @import("std");
const glowcap = @import("glowcap");
const agreement = @import("oracle").agreement;

const engine = glowcap.ocapn.engine;

test "a fresh pair agrees" {
    var pair = try engine.pairing.paired(std.testing.allocator);
    defer pair.deinit();
    try agreement.check(&pair.p1, &pair.p2);
}

test "pair agreement refuses in-flight traffic instead of claiming quiescence" {
    var pair = try engine.pairing.paired(std.testing.allocator);
    defer pair.deinit();
    try pair.p1.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = glowcap.ocapn.model.FarRef.object(0) },
        .args = &.{},
        .answer = .from(1),
    } });
    try std.testing.expectError(error.PairNotAtRest, agreement.check(&pair.p1, &pair.p2));
    try std.testing.expectError(error.PairNotAtRest, agreement.check(&pair.p2, &pair.p1));
    try std.testing.expectEqual(.quiescent, try engine.pairing.shuttleUntilQuiescent(&pair.p1, &pair.p2));
    try agreement.check(&pair.p1, &pair.p2);
}

test "pair agreement refuses a closed peer instead of checking retired tables" {
    var pair = try engine.pairing.paired(std.testing.allocator);
    defer pair.deinit();
    pair.p1.closeSession();
    try std.testing.expectError(error.PairNotOpen, agreement.check(&pair.p1, &pair.p2));
    try std.testing.expectError(error.PairNotOpen, agreement.check(&pair.p2, &pair.p1));
}

test "an import the partner never granted is named with its holder" {
    var pair = try engine.pairing.paired(std.testing.allocator);
    defer pair.deinit();
    try pair.p2.session_state.registerImport(.from(5));
    const finding = agreement.find(&pair.p1, &pair.p2) orelse return error.TestExpectedFinding;
    try std.testing.expectEqual(error.ImportWithoutExport, finding.kind);
    try std.testing.expectEqual(@as(u64, 5), finding.position);
    try std.testing.expect(!finding.holder_is_p1);
    try std.testing.expectError(error.ImportWithoutExport, agreement.check(&pair.p1, &pair.p2));
}
