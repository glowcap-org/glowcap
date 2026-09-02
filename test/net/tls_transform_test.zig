//! Completion-neutral TLS storage and failure ownership.

const std = @import("std");
const glowcap = @import("glowcap");

const tls = glowcap.net.tls.engine;
const Transform = glowcap.net.tls.transform.Transform;

const Fake = struct {
    outcomes: []const tls.RawOutcome,
    at: usize = 0,
    cleanup: ?glowcap.foundation.FailureChain = null,

    fn client(self: *Fake) tls.Client {
        return .init(self, &vtable);
    }

    fn step(raw: *anyopaque, _: tls.Phase, _: tls.Exchange) tls.RawOutcome {
        const self: *Fake = @ptrCast(@alignCast(raw));
        const outcome = self.outcomes[self.at];
        self.at += 1;
        return outcome;
    }

    fn deinit(raw: *anyopaque) ?glowcap.foundation.FailureChain {
        const self: *Fake = @ptrCast(@alignCast(raw));
        return self.cleanup;
    }

    const vtable: tls.VTable = .{ .step = step, .deinit = deinit };
};

test "TLS transform preserves the exact engine primary through transport cleanup" {
    const scripted = [_]tls.RawOutcome{.{ .failed = .{
        .failure = .init(.handshake, error.InjectedHandshakeFailure),
        .transfer = .{ .ciphertext_produced = 2 },
    } }};
    var fake = Fake{
        .outcomes = &scripted,
        .cleanup = .init(error.InjectedEngineCleanupFailure),
    };
    var transform = Transform.init(fake.client());

    try std.testing.expectError(error.TlsFailed, transform.step(.handshake, &.{}, &.{}));
    const failure = transform.deinitOutcome().?;
    try std.testing.expectEqualStrings("InjectedHandshakeFailure", failure.chain.primaryName());
    try std.testing.expectEqualStrings("TlsCiphertextAbandoned", failure.chain.secondaryName().?);
    try std.testing.expectEqual(@as(u16, 2), failure.chain.secondary_count);
}

test "TLS transform makes transport truncation authoritative before engine cleanup" {
    var fake = Fake{
        .outcomes = &.{},
        .cleanup = .init(error.InjectedEngineCleanupFailure),
    };
    var transform = Transform.init(fake.client());
    transform.noteTransportEof(.receive);

    const failure = transform.deinitOutcome().?;
    try std.testing.expectEqual(tls.Phase.receive, failure.phase);
    try std.testing.expectEqualStrings("TlsTruncated", failure.chain.primaryName());
    try std.testing.expectEqualStrings("InjectedEngineCleanupFailure", failure.chain.secondaryName().?);
    try std.testing.expectEqual(@as(u16, 1), failure.chain.secondary_count);
}
