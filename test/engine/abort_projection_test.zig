const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const abort_projection = glowcap.ocapn.engine.abort_projection;

test "decode failures project to malformed-frame and close" {
    const a = abort_projection.abortForError(error.MalformedFrame).?;
    try std.testing.expectEqual(model.AbortKind.malformed_frame, a.kind);

    const b = abort_projection.abortForError(error.InvalidFrameShape).?;
    try std.testing.expectEqual(model.AbortKind.malformed_frame, b.kind);
}

test "unsupported wire shapes project to protocol-error and close" {
    const a = abort_projection.abortForError(error.UnsupportedReference).?;
    try std.testing.expectEqual(model.AbortKind.protocol_error, a.kind);
}

test "captp-version mismatch projects to terminal version-mismatch" {
    const a = abort_projection.abortForError(session.Error.CaptpVersionMismatch).?;
    try std.testing.expectEqual(model.AbortKind.version_mismatch, a.kind);
}

test "queue-cap and handoff-replay project to their typed kinds and close" {
    const q = abort_projection.abortForError(session.Error.QueueCapExceeded).?;
    try std.testing.expectEqual(model.AbortKind.queue_cap_exceeded, q.kind);

    const r = abort_projection.abortForError(session.Error.HandoffReplay).?;
    try std.testing.expectEqual(model.AbortKind.handoff_replay, r.kind);
}

test "table-cap exhaustion projects to resource-exhausted and close" {
    for ([_]anyerror{
        session.Error.InboundAnswerCapExceeded,
        session.Error.RetainedAnswerCapExceeded,
        session.Error.ListenerCapExceeded,
        session.Error.ImportCapExceeded,
        session.Error.DepositedGiftCapExceeded,
        session.Error.PendingWithdrawCapExceeded,
    }) |err| {
        const a = abort_projection.abortForError(err).?;
        try std.testing.expectEqual(model.AbortKind.resource_exhausted, a.kind);
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
        session.Error.HostMismatch,
    }) |err| {
        const a = abort_projection.abortForError(err).?;
        try std.testing.expectEqual(model.AbortKind.protocol_error, a.kind);
    }
}

test "already-closed and non-protocol errors do not project to an abort" {
    try std.testing.expect(abort_projection.abortForError(session.Error.SessionClosed) == null);
    try std.testing.expect(abort_projection.abortForError(error.OutOfMemory) == null);
}
