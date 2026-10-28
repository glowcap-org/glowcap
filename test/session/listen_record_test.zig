//! A local listen record can receive a resolver notification, but cannot name
//! a question on the partner: neither a descriptor nor a wire release.
const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;

test "a listen record accepts resolver settlement but refuses wire resolve" {
    for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| {
        var state = session.Session.initWith(std.testing.allocator, .{
            .captp_version = profile,
            .features = model.FeatureSet.full().forCaptpVersion(profile),
        });
        defer state.deinit();
        const nomination = try state.nominateResolverExport();
        const message: model.Message = .{ .resolve = .{
            .answer = nomination.answer,
            .resolution = .{ .fulfill = .{ .void = {} } },
        } };
        const refusal = if (profile == .v1_0) error.UnexpectedMessage else error.InvalidReference;
        try std.testing.expectError(refusal, state.recordRecvView(model.view.Body.fromOwned(&message)));
        try std.testing.expectEqual(.pending, state.outbound_answers.getPtr(nomination.answer).?.status());
        try std.testing.expectEqual(nomination.answer, state.answerForResolverExport(nomination.resolver_export).?);
        try std.testing.expect(state.hasExport(nomination.resolver_export));

        try state.recordResolverCallbackResolve(model.view.Body.fromOwned(&message).resolve);
        try std.testing.expectEqual(.fulfilled, state.outbound_answers.getPtr(nomination.answer).?.status());
        try state.releaseOutboundAnswer(nomination.answer);
    }
}

test "a listen record cannot escape as an answer descriptor or release" {
    for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| {
        var state = session.Session.initWith(std.testing.allocator, .{
            .captp_version = profile,
            .features = model.FeatureSet.full().forCaptpVersion(profile),
        });
        defer state.deinit();
        const nomination = try state.nominateResolverExport();
        const local: model.Reference = .{ .promise = .{ .answer_position = nomination.answer } };
        try std.testing.expectError(error.InvalidReference, state.recordSend(.{ .deliver = .{
            .target = local,
            .args = &.{},
            .answer = null,
        } }));
        try std.testing.expectError(error.InvalidReference, state.recordSend(.{ .deliver = .{
            .target = .{ .far = model.FarRef.object(0) },
            .args = &.{.{ .reference = local }},
            .answer = null,
        } }));
        try std.testing.expectError(error.InvalidReference, state.recordSend(.{ .listen = .{
            .target = local,
            .listener = .{ .far = model.FarRef.object(0) },
            .mode = .settling_only,
        } }));

        // Refusing a mixed release must not retire its preceding wire question.
        try state.recordSend(.{ .deliver = .{
            .target = .{ .far = model.FarRef.object(0) },
            .args = &.{},
            .answer = .from(42),
        } });
        try std.testing.expectError(error.GcUnderflow, state.recordSend(.{ .gc_answer = .{
            .positions = &.{ 42, nomination.answer.int() },
        } }));
        try std.testing.expect(state.outbound_answers.isQuestion(.from(42)));
        try std.testing.expect(state.outbound_answers.contains(nomination.answer));
        try state.recordSend(.{ .gc_answer = .{ .positions = &.{42} } });
        try state.releaseOutboundAnswer(nomination.answer);
        try std.testing.expect(!state.hasExport(nomination.resolver_export));
    }
}
