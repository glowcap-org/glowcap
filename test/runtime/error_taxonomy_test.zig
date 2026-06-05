const std = @import("std");
const pancake = @import("pancake");

const abort = pancake.runtime.abort_projection;

test "every codec / session / projection error classifies to a non-foreign domain" {
    // `classify` is the single source of truth for what a dispatch error means.
    // A new codec/session/projection error variant that falls through to
    // `.foreign` (and thus the C ABI's INTERNAL code and no abort) fails the gate
    // here instead of silently mis-surfacing — this is the compile-checked seam
    // that replaced the hand-maintained per-surface error tables.
    inline for (.{
        pancake.session.Error,
        pancake.codec.syrup.Error,
        pancake.model.view.ProjectError,
    }) |ErrSet| {
        inline for (@typeInfo(ErrSet).error_set.?) |e| {
            const ev: anyerror = @field(ErrSet, e.name);
            try std.testing.expect(abort.classify(ev).domain != .foreign);
        }
    }
}

test "prior cross-surface drift now classifies consistently" {
    // NestingTooDeep used to reach the C ABI as INTERNAL (a host bug) while the
    // abort projection called it resource_exhausted. One classifier, one answer.
    const nesting = abort.classify(error.NestingTooDeep);
    try std.testing.expectEqual(abort.Domain.session, nesting.domain);
    try std.testing.expectEqual(pancake.model.AbortKind.resource_exhausted, nesting.abort.?.kind);

    // MalformedView fell through the abort projection's `else => null`, leaving
    // the partner with no op:abort. It is a codec decode failure.
    const view = abort.classify(error.MalformedView);
    try std.testing.expectEqual(abort.Domain.codec, view.domain);
    try std.testing.expectEqual(pancake.model.AbortKind.malformed_frame, view.abort.?.kind);

    // A handshake version mismatch is the one protocol error that does not close.
    const mismatch = abort.classify(error.CaptpVersionMismatch);
    try std.testing.expectEqual(abort.Domain.session, mismatch.domain);
    try std.testing.expect(!mismatch.abort.?.close);

    // Host-internal failures stay foreign with no abort.
    const oom = abort.classify(error.OutOfMemory);
    try std.testing.expectEqual(abort.Domain.foreign, oom.domain);
    try std.testing.expect(oom.abort == null);
}
