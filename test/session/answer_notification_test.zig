//! Answer-notification ownership when `op:gc-answers` frees a pipelining name.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const session = pancake.ocapn.session;

test "gc-answers notification detachment is allocation atomic and retryable" {
    var reached_success = false;
    var fail_offset: usize = 0;
    while (fail_offset < 16) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        failing.fail_index = std.math.maxInt(usize);
        var s = session.Session.initWith(failing.allocator(), .{
            .captp_version = .v1_0,
            .features = model.FeatureSet.full(),
        });
        defer {
            failing.fail_index = std.math.maxInt(usize);
            s.deinit();
        }

        try s.registerExport(.from(1));
        const answer = model.AnswerName.fromWire(.from(99));
        try s.recordRecv(.{ .deliver = .{
            .target = .{ .near = model.NearRef.object(1) },
            .args = &.{},
            .answer = answer.wire,
        } });
        try s.installInboundResolver(answer, .from(3));
        const target = s.answerTargetNamed(answer).?;

        failing.fail_index = failing.alloc_index + fail_offset;
        if (s.recordRecv(.{ .gc_answer = .{ .positions = &.{99} } })) |_| {
            reached_success = true;
            try std.testing.expect(s.inboundAnswer(.from(99)) == null);
            try std.testing.expect(s.answerPayloadForTarget(target) != null);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(u64, 1), s.inboundAnswer(.from(99)).?.count);
            try std.testing.expectEqual(
                @as(?model.ImportPosition, .from(3)),
                s.resolverForInboundAnswer(answer),
            );
            try std.testing.expectEqual(target, s.answerTargetNamed(answer).?);

            // The refused turn adopted nothing. The identical message succeeds
            // once allocation is available and detaches the exact incarnation.
            failing.fail_index = std.math.maxInt(usize);
            try s.recordRecv(.{ .gc_answer = .{ .positions = &.{99} } });
            try std.testing.expect(s.inboundAnswer(.from(99)) == null);
            try std.testing.expect(s.answerPayloadForTarget(target) != null);
        }
    }
    try std.testing.expect(reached_success);
}

test "duplicate gc-answers positions refuse before decrementing" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = .v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();

    try s.registerExport(.from(1));
    const answer = model.AnswerName.fromWire(.from(99));
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = model.NearRef.object(1) },
        .args = &.{},
        .answer = answer.wire,
    } });
    try s.installInboundResolver(answer, .from(3));

    try std.testing.expectError(
        error.GcUnderflow,
        s.recordRecv(.{ .gc_answer = .{ .positions = &.{ 99, 99 } } }),
    );
    try std.testing.expectEqual(@as(u64, 1), s.inboundAnswer(.from(99)).?.count);
    try std.testing.expectEqual(
        @as(?model.ImportPosition, .from(3)),
        s.resolverForInboundAnswer(answer),
    );
}

test "detached answer cannot adopt reused position resolver" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = .v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();

    try s.registerExport(.from(1));
    const answer = model.AnswerName.fromWire(.from(99));
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = model.NearRef.object(1) },
        .args = &.{},
        .answer = answer.wire,
    } });
    const old_target = s.answerTargetNamed(answer).?;
    const old_settlement = try s.beginAnswerSettlement(old_target);
    defer s.releaseAnswerPayload(old_settlement.payload);

    try s.recordRecv(.{ .gc_answer = .{ .positions = &.{99} } });
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = model.NearRef.object(1) },
        .args = &.{},
        .answer = answer.wire,
    } });
    try s.installInboundResolver(answer, .from(3));
    try std.testing.expect(old_target.row_id != s.answerTargetNamed(answer).?.row_id);

    const old_again = try s.beginAnswerSettlement(old_target);
    defer s.releaseAnswerPayload(old_again.payload);
    try std.testing.expect(old_again.payload.resolver_import == null);
    try std.testing.expectEqual(
        @as(?model.ImportPosition, .from(3)),
        s.resolverForInboundAnswer(answer),
    );
}
