//! Deterministic TLS-engine contract and failure ownership.

const std = @import("std");
const glowcap = @import("glowcap");

const tls = glowcap.net.tls.engine;

const Fake = struct {
    outcomes: []const tls.RawOutcome,
    at: usize = 0,
    cleanup: ?glowcap.foundation.FailureChain = null,
    deinit_count: usize = 0,

    fn client(self: *Fake) tls.Client {
        return .init(self, &vtable);
    }

    fn step(ctx: *anyopaque, _: tls.Phase, _: tls.Exchange) tls.RawOutcome {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        const outcome = self.outcomes[self.at];
        self.at += 1;
        return outcome;
    }

    fn deinit(ctx: *anyopaque) ?glowcap.foundation.FailureChain {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.deinit_count += 1;
        return self.cleanup;
    }

    const vtable: tls.VTable = .{ .step = step, .deinit = deinit };
};

test "TLS output is drained before the engine may reuse its buffer" {
    const scripted = [_]tls.RawOutcome{
        .{ .stepped = .{
            .interest = .{ .read = true },
            .transfer = .{ .ciphertext_produced = 4 },
        } },
        .{ .stepped = .{ .status = .established } },
    };
    var fake = Fake{ .outcomes = &scripted };
    var client = fake.client();
    var out: [8]u8 = undefined;
    _ = try client.step(.handshake, .{ .ciphertext_out = &out });
    try std.testing.expectEqual(@as(usize, 4), client.pendingCiphertext().len);
    try std.testing.expectError(error.OutputPending, client.step(.handshake, .{}));
    try client.consumeCiphertext(2);
    try std.testing.expectEqual(out[2..4].ptr, client.pendingCiphertext().ptr);
    try client.consumeCiphertext(2);
    const established = try client.step(.handshake, .{});
    try std.testing.expectEqual(tls.Status.established, established.stepped.status);
    try std.testing.expectEqual(@as(?tls.Failure, null), client.deinitOutcome());
    try std.testing.expectEqual(@as(usize, 1), fake.deinit_count);
}

test "TLS retries require the exact unconsumed plaintext tail" {
    const scripted = [_]tls.RawOutcome{
        .{ .stepped = .{ .status = .established } },
        .{ .stepped = .{
            .interest = .{ .write = true },
            .transfer = .{ .plaintext_consumed = 2 },
        } },
    };
    var fake = Fake{ .outcomes = &scripted };
    var client = fake.client();
    _ = try client.step(.handshake, .{});
    const plaintext = "hello";
    _ = try client.step(.transmit, .{ .plaintext_in = plaintext });
    try std.testing.expectError(
        error.EngineContractViolation,
        client.step(.transmit, .{ .plaintext_in = plaintext[0..3] }),
    );
    const failure = client.deinitOutcome().?;
    try std.testing.expectEqualStrings("EngineContractViolation", failure.chain.primaryName());
}

test "TLS driver may relocate an exact unconsumed ciphertext tail" {
    const scripted = [_]tls.RawOutcome{
        .{ .stepped = .{
            .interest = .{ .read = true },
            .transfer = .{ .ciphertext_consumed = 2 },
        } },
        .{ .stepped = .{ .status = .established } },
    };
    var fake = Fake{ .outcomes = &scripted };
    var client = fake.client();
    const original = "prefix-tail";
    _ = try client.step(.handshake, .{ .ciphertext_in = original });
    var moved: [10]u8 = undefined;
    const retained = try client.relocateCiphertext(.handshake, &moved);
    moved[retained] = '!';
    try client.extendCiphertext(.handshake, &moved);
    const established = try client.step(.handshake, .{ .ciphertext_in = &moved });
    try std.testing.expectEqual(tls.Status.established, established.stepped.status);
    try std.testing.expectEqual(@as(?tls.Failure, null), client.deinitOutcome());
}

test "TLS rejects impossible engine counts and preserves cleanup as secondary" {
    const scripted = [_]tls.RawOutcome{
        .{ .stepped = .{
            .interest = .{ .read = true },
            .transfer = .{ .ciphertext_consumed = 2 },
        } },
    };
    var fake = Fake{
        .outcomes = &scripted,
        .cleanup = .init(error.InjectedTlsCleanupFailure),
    };
    var client = fake.client();
    try std.testing.expectError(
        error.EngineContractViolation,
        client.step(.handshake, .{ .ciphertext_in = "x" }),
    );
    const failure = client.deinitOutcome().?;
    try std.testing.expectEqualStrings("EngineContractViolation", failure.chain.primaryName());
    try std.testing.expectEqualStrings("InjectedTlsCleanupFailure", failure.chain.secondaryName().?);
    try std.testing.expectEqual(@as(u16, 1), failure.chain.secondary_count);
}

test "TLS fatal alerts remain drainable beside the exact primary" {
    const scripted = [_]tls.RawOutcome{
        .{ .failed = .{
            .failure = .{
                .phase = .handshake,
                .chain = .init(error.CertificateNameMismatch),
                .detail = .{ .verification_flags = 0x04 },
            },
            .transfer = .{ .ciphertext_produced = 3 },
        } },
    };
    var fake = Fake{ .outcomes = &scripted };
    var client = fake.client();
    var alert: [8]u8 = undefined;
    const outcome = try client.step(.handshake, .{ .ciphertext_out = &alert });
    try std.testing.expectEqualStrings(
        "CertificateNameMismatch",
        outcome.failed.failure.chain.primaryName(),
    );
    try std.testing.expectEqual(@as(usize, 3), client.pendingCiphertext().len);
    try client.consumeCiphertext(3);
    const failure = client.deinitOutcome().?;
    try std.testing.expectEqual(tls.Phase.handshake, failure.phase);
    try std.testing.expectEqual(@as(u32, 0x04), failure.detail.verification_flags);
}

test "TLS preserves the terminal primary and reports abandoned output" {
    const scripted = [_]tls.RawOutcome{
        .{ .failed = .{
            .failure = .init(.handshake, error.InjectedTlsHandshakeFailure),
            .transfer = .{ .ciphertext_produced = 2 },
        } },
    };
    var fake = Fake{ .outcomes = &scripted };
    var client = fake.client();
    var alert: [4]u8 = undefined;
    _ = try client.step(.handshake, .{ .ciphertext_out = &alert });
    try std.testing.expectError(error.OutputPending, client.step(.handshake, .{}));
    const failure = client.deinitOutcome().?;
    try std.testing.expectEqualStrings("InjectedTlsHandshakeFailure", failure.chain.primaryName());
    try std.testing.expectEqualStrings("TlsCiphertextAbandoned", failure.chain.secondaryName().?);
    try std.testing.expectEqual(@as(u16, 1), failure.chain.secondary_count);
}

test "TLS implicit destruction failure has a shutdown recipient" {
    var fake = Fake{
        .outcomes = &.{},
        .cleanup = .init(error.InjectedTlsDestroyFailure),
    };
    var client = fake.client();
    const failure = client.deinitOutcome().?;
    try std.testing.expectEqual(tls.Phase.shutdown, failure.phase);
    try std.testing.expectEqualStrings("InjectedTlsDestroyFailure", failure.chain.primaryName());
}
