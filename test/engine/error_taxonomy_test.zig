const std = @import("std");
const pancake = @import("pancake");

const abort = pancake.ocapn.engine.abort_projection;

test "every codec / session / engine / projection error classifies to a non-foreign domain" {
    // `classify` is the single source of truth for what a dispatch error means.
    // A new codec/session/engine/projection error variant that falls through to
    // `.foreign` (and thus the C ABI's INTERNAL code and no abort) fails the gate
    // here instead of silently mis-surfacing, this is the compile-checked boundary
    // that replaced the hand-maintained per-surface error tables.
    inline for (.{
        pancake.ocapn.session.Error,
        pancake.ocapn.codec.syrup.Error,
        pancake.ocapn.codec.capnp.Error,
        pancake.ocapn.model.view.ProjectError,
        pancake.ocapn.engine.EngineError,
    }) |ErrSet| {
        inline for (@typeInfo(ErrSet).error_set.error_names.?) |error_name| {
            // `OutOfMemory` is the one error a codec set carries (via
            // `std.mem.Allocator.Error`) that is legitimately host-internal:
            // it has no protocol meaning, so it stays `.foreign` with no abort.
            // Every *protocol* error must classify to codec/session.
            if (comptime std.mem.eql(u8, error_name, "OutOfMemory")) continue;
            const ev: anyerror = @field(ErrSet, error_name);
            try std.testing.expect(abort.classify(ev).domain != .foreign);
        }
    }
}

test "prior cross-surface drift now classifies consistently" {
    // NestingTooDeep used to reach the C ABI as INTERNAL (a host bug) while the
    // abort projection called it resource_exhausted. One classifier, one answer.
    const nesting = abort.classify(error.NestingTooDeep);
    try std.testing.expectEqual(abort.Domain.session, nesting.domain);
    try std.testing.expectEqual(pancake.ocapn.model.AbortKind.resource_exhausted, nesting.abort.?.kind);

    // MalformedView fell through the abort projection's `else => null`, leaving
    // the partner with no op:abort. It is a codec decode failure.
    const view = abort.classify(error.MalformedView);
    try std.testing.expectEqual(abort.Domain.codec, view.domain);
    try std.testing.expectEqual(pancake.ocapn.model.AbortKind.malformed_frame, view.abort.?.kind);

    // An outbound encoder invariant is contained to its operation and remains
    // codec-owned, but cannot blame a partner with an abort.
    const encoder = abort.classify(error.EncoderInvariantViolation);
    try std.testing.expectEqual(abort.Domain.codec, encoder.domain);
    try std.testing.expect(encoder.abort == null);

    // A handshake version mismatch is a session-domain terminal abort.
    const mismatch = abort.classify(error.CaptpVersionMismatch);
    try std.testing.expectEqual(abort.Domain.session, mismatch.domain);
    try std.testing.expectEqual(pancake.ocapn.model.AbortKind.version_mismatch, mismatch.abort.?.kind);

    // Host-internal failures stay foreign with no abort.
    const oom = abort.classify(error.OutOfMemory);
    try std.testing.expectEqual(abort.Domain.foreign, oom.domain);
    try std.testing.expect(oom.abort == null);

    // The engine's partner-drivable local-delivery bound is a resource cap,
    // not a host bug: it projects resource_exhausted and closes.
    const cap = abort.classify(error.LocalDeliveryCapExceeded);
    try std.testing.expectEqual(abort.Domain.session, cap.domain);
    try std.testing.expectEqual(pancake.ocapn.model.AbortKind.resource_exhausted, cap.abort.?.kind);
}
