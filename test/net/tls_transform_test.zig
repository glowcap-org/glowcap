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

const record_bytes = glowcap.net.tls.transform.record_bytes;

const read_wanted: tls.RawOutcome = .{ .stepped = .{ .interest = .{ .read = true } } };

test "TLS transform admits a ciphertext window filled to its last byte and refuses the next record byte" {
    const scripted = [_]tls.RawOutcome{ read_wanted, read_wanted };
    var fake = Fake{ .outcomes = &scripted };
    var transform = Transform.init(fake.client());

    const window = try transform.ciphertextDestination(.handshake);
    try std.testing.expectEqual(@as(usize, record_bytes), window.len);
    @memset(window[0 .. record_bytes - 1], 'x');
    try transform.commitCiphertext(.handshake, record_bytes - 1);
    // The engine needs more bytes and consumes none, so nothing can be reclaimed.
    const first = try transform.step(.handshake, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 0), first.transfer.ciphertext_consumed);
    try std.testing.expectEqual(@as(usize, record_bytes - 1), transform.bufferedCiphertext());

    // One byte of room remains and is admitted.
    const last = try transform.ciphertextDestination(.handshake);
    try std.testing.expectEqual(@as(usize, 1), last.len);
    last[0] = 'x';
    try transform.commitCiphertext(.handshake, 1);
    _ = try transform.step(.handshake, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, record_bytes), transform.bufferedCiphertext());

    // The window is full from its first byte and the engine still wants more.
    try std.testing.expectError(error.TlsFailed, transform.ciphertextDestination(.handshake));
    const failure = transform.deinitOutcome().?;
    try std.testing.expectEqual(tls.Phase.handshake, failure.phase);
    try std.testing.expectEqualStrings("TlsCiphertextLimit", failure.chain.primaryName());
}

test "TLS transform refuses a record that still fills the window after the consumed prefix is reclaimed" {
    const consume_one: tls.RawOutcome = .{ .stepped = .{
        .interest = .{ .read = true },
        .transfer = .{ .ciphertext_consumed = 1 },
    } };
    const scripted = [_]tls.RawOutcome{ consume_one, read_wanted };
    var fake = Fake{ .outcomes = &scripted };
    var transform = Transform.init(fake.client());

    const window = try transform.ciphertextDestination(.handshake);
    @memset(window, 'x');
    try transform.commitCiphertext(.handshake, record_bytes);
    // The engine consumes one byte of a record that needs more than the window.
    _ = try transform.step(.handshake, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, record_bytes - 1), transform.bufferedCiphertext());

    // Reclaiming that byte makes room for exactly one more.
    const reclaimed = try transform.ciphertextDestination(.handshake);
    try std.testing.expectEqual(@as(usize, 1), reclaimed.len);
    reclaimed[0] = 'x';
    try transform.commitCiphertext(.handshake, 1);
    _ = try transform.step(.handshake, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, record_bytes), transform.bufferedCiphertext());

    // The prefix is spent, so there is nothing left to reclaim.
    try std.testing.expectError(error.TlsFailed, transform.ciphertextDestination(.handshake));
    const failure = transform.deinitOutcome().?;
    try std.testing.expectEqual(tls.Phase.handshake, failure.phase);
    try std.testing.expectEqualStrings("TlsCiphertextLimit", failure.chain.primaryName());
}
