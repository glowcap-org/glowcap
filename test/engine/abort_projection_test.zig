const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const session = pancake.ocapn.session;
const abort_projection = pancake.ocapn.engine.abort_projection;

test "decode failures project to malformed-frame and close" {
    const a = abort_projection.abortForError(error.MalformedFrame).?;
    try std.testing.expectEqual(model.AbortKind.malformed_frame, a.kind);
    try std.testing.expect(a.close);

    const b = abort_projection.abortForError(error.InvalidFrameShape).?;
    try std.testing.expectEqual(model.AbortKind.malformed_frame, b.kind);
    try std.testing.expect(b.close);
}

test "unsupported wire shapes project to protocol-error and close" {
    const a = abort_projection.abortForError(error.UnsupportedReference).?;
    try std.testing.expectEqual(model.AbortKind.protocol_error, a.kind);
    try std.testing.expect(a.close);
}

test "captp-version mismatch projects to version-mismatch without closing" {
    const a = abort_projection.abortForError(session.Error.CaptpVersionMismatch).?;
    try std.testing.expectEqual(model.AbortKind.version_mismatch, a.kind);
    try std.testing.expect(!a.close);
}

test "queue-cap and handoff-replay project to their typed kinds and close" {
    const q = abort_projection.abortForError(session.Error.QueueCapExceeded).?;
    try std.testing.expectEqual(model.AbortKind.queue_cap_exceeded, q.kind);
    try std.testing.expect(q.close);

    const r = abort_projection.abortForError(session.Error.HandoffReplay).?;
    try std.testing.expectEqual(model.AbortKind.handoff_replay, r.kind);
    try std.testing.expect(r.close);
}

test "table-cap exhaustion projects to resource-exhausted and close" {
    for ([_]anyerror{
        session.Error.InboundAnswerCapExceeded,
        session.Error.ListenerCapExceeded,
        session.Error.ImportCapExceeded,
        session.Error.HandoffCountCapExceeded,
        session.Error.DepositedGiftCapExceeded,
    }) |err| {
        const a = abort_projection.abortForError(err).?;
        try std.testing.expectEqual(model.AbortKind.resource_exhausted, a.kind);
        try std.testing.expect(a.close);
    }
}

test "generic protocol violations project to protocol-error and close" {
    for ([_]anyerror{
        session.Error.MalformedMessage,
        session.Error.InvalidReference,
        session.Error.FeatureNotNegotiated,
        session.Error.InvalidGift,
        session.Error.GcUnderflow,
        session.Error.UnexpectedMessage,
        session.Error.DuplicateStartSession,
        session.Error.ResolutionCycle,
        session.Error.HostMismatch,
    }) |err| {
        const a = abort_projection.abortForError(err).?;
        try std.testing.expectEqual(model.AbortKind.protocol_error, a.kind);
        try std.testing.expect(a.close);
    }
}

test "already-closed and non-protocol errors do not project to an abort" {
    try std.testing.expect(abort_projection.abortForError(session.Error.SessionClosed) == null);
    try std.testing.expect(abort_projection.abortForError(error.OutOfMemory) == null);
}
