//! Completion-WSS evidence over the neutral TLS transform.
//!
//! The fake engine is byte-transparent so these tests reuse the WebSocket
//! fixture while pinning TLS progression, exact failure ownership, sparse
//! storage, and deterministic runtime retirement.

const std = @import("std");
const glowcap = @import("glowcap");
const admission = @import("../support/keyed_relay_admission.zig");
const fake_tls = @import("../support/fake_tls_runtime.zig");

const net = glowcap.net;
const AdmissionBackend = admission.AdmissionBackend;
const designator = @as([64]u8, @splat('a'));

/// Transform, two fixed 18 KiB TLS record windows, and the retained exact
/// failure/borrow state. Hash-map buckets and WebSocket buffers are separate.
const secure_connection_state_bytes: usize = 37_216;

test "completion WSS keeps clear state lean and pins secure state" {
    if (!std.debug.runtime_safety) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 272), AdmissionBackend.connection_state_bytes);
    try std.testing.expectEqual(
        secure_connection_state_bytes,
        AdmissionBackend.secure_connection_state_bytes,
    );
}

test "completion WSS drives TLS below the existing WebSocket machine" {
    var fake = fake_tls.FakeRuntime{ .shutdown_ciphertext = "close-notify" };
    var runtime = fake.erased();
    var owner = try net.tls.runtime_owner.Owner.init(std.testing.allocator, &runtime);
    defer std.debug.assert(owner.release() == .released);
    var backend = try secureBackend(&owner);
    defer admission.deinitAdmissionBackend(&backend);

    const fd = try startSecureRelay(&backend);
    const conn = backend.conns.get(1).?;
    try std.testing.expectEqual(.reading_upgrade, conn.state);
    try std.testing.expectEqual(@as(usize, 1), fake.opens);
    var completions: [2]net.completion.Completion = undefined;
    try completeSecureUpgrade(&backend, 71, &completions);
    try std.testing.expectEqual(.open, conn.state);

    const sends_before_close = backend.platform.send_submits;
    try backend.submitClose(72, fd);
    var close_seen = false;
    for (0..8) |_| {
        const count = try backend.poll(&completions, 0);
        for (completions[0..count]) |completion| {
            if (completion.user_data == 72) {
                try std.testing.expectEqual(@as(i32, 0), completion.result);
                close_seen = true;
            }
            if (completion.borrowed.active()) backend.recycleBorrowed(completion);
        }
        if (close_seen) break;
    }
    try std.testing.expect(close_seen);
    // One encrypted WebSocket close frame and one terminal TLS close-notify
    // are both admitted before the platform descriptor is retired.
    try std.testing.expectEqual(sends_before_close + 2, backend.platform.send_submits);
    try std.testing.expectEqual(@as(usize, 1), fake.shutdown_steps);
    try std.testing.expectEqual(@as(usize, 1), fake.client_closes);
}

test "completion WSS retains TLS primary and cleanup until recycle" {
    var fake = fake_tls.FakeRuntime{
        .fail_phase = .handshake,
        .client_cleanup = .init(error.InjectedTlsCleanupFailure),
    };
    var runtime = fake.erased();
    var owner = try net.tls.runtime_owner.Owner.init(std.testing.allocator, &runtime);
    defer std.debug.assert(owner.release() == .released);
    var backend = try secureBackend(&owner);
    defer admission.deinitAdmissionBackend(&backend);

    _ = try backend.startDial(81, relayTarget());
    var completions: [2]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    const failed = completions[0];
    try std.testing.expectEqual(@as(u64, 81), failed.user_data);
    try std.testing.expectEqual(@as(i32, -1), failed.result);
    const chain = failed.borrowed.failureChain().?;
    try std.testing.expectEqual(
        net.carrier_failure.Phase.secure_handshake,
        failed.borrowed.carrierFailureValue().?.phase,
    );
    try std.testing.expectEqualStrings("InjectedTlsHandshakeFailure", chain.primaryName());
    try std.testing.expectEqualStrings("InjectedTlsCleanupFailure", chain.secondaryName().?);
    try std.testing.expectEqual(@as(u16, 1), chain.secondary_count);
    try std.testing.expectEqual(@as(usize, 1), fake.client_closes);

    backend.recycleBorrowed(failed);
    try std.testing.expectEqual(@as(usize, 0), backend.secure.get(1).?.failure_borrows);
}

test "completion WSS runtime-open refusal settles through the admitted dial" {
    var open_failure = net.tls.engine.Failure.init(
        .handshake,
        error.InjectedTlsConfigurationFailure,
    );
    open_failure.chain.note(error.InjectedTlsConfigurationCleanupFailure);
    var fake = fake_tls.FakeRuntime{ .open_failure = open_failure };
    var runtime = fake.erased();
    var owner = try net.tls.runtime_owner.Owner.init(std.testing.allocator, &runtime);
    defer std.debug.assert(owner.release() == .released);
    var backend = try secureBackend(&owner);
    defer admission.deinitAdmissionBackend(&backend);

    // Engine construction happens only after the platform operation and its
    // terminal completion seat are owned. Refusal is therefore asynchronous,
    // correlated, and can retain the complete structured failure.
    _ = try backend.startDial(91, relayTarget());
    var completions: [2]net.completion.Completion = undefined;
    var count: usize = 0;
    for (0..4) |_| {
        count = try backend.poll(&completions, 0);
        if (count != 0) break;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    const failed = completions[0];
    try std.testing.expectEqual(@as(u64, 91), failed.user_data);
    try std.testing.expectEqual(@as(i32, -1), failed.result);
    const chain = failed.borrowed.failureChain().?;
    try std.testing.expectEqual(
        net.carrier_failure.Phase.secure_handshake,
        failed.borrowed.carrierFailureValue().?.phase,
    );
    try std.testing.expectEqualStrings("InjectedTlsConfigurationFailure", chain.primaryName());
    try std.testing.expectEqualStrings(
        "InjectedTlsConfigurationCleanupFailure",
        chain.secondaryName().?,
    );
    try std.testing.expectEqual(@as(u16, 1), chain.secondary_count);
    try std.testing.expectEqual(@as(usize, 0), fake.client_closes);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.close_submits);
    backend.recycleBorrowed(failed);
}

test "completion WSS platform refusal never opens a TLS client" {
    var fake = fake_tls.FakeRuntime{};
    var runtime = fake.erased();
    var owner = try net.tls.runtime_owner.Owner.init(std.testing.allocator, &runtime);
    defer std.debug.assert(owner.release() == .released);
    var backend = try secureBackend(&owner);
    defer admission.deinitAdmissionBackend(&backend);
    backend.platform.fail_dial = true;

    try std.testing.expectError(error.SubmitFailed, backend.startDial(101, relayTarget()));
    try std.testing.expectEqual(@as(usize, 0), fake.opens);
    try std.testing.expectEqual(@as(usize, 0), fake.client_closes);
    try std.testing.expectEqual(@as(usize, 0), backend.conns.count());
    try std.testing.expectEqual(@as(usize, 0), backend.secure.count());
}

test "completion WSS close cancels an admitted handshake and joins TLS retirement" {
    var fake = fake_tls.FakeRuntime{};
    var runtime = fake.erased();
    var owner = try net.tls.runtime_owner.Owner.init(std.testing.allocator, &runtime);
    defer std.debug.assert(owner.release() == .released);
    var backend = try secureBackend(&owner);
    defer admission.deinitAdmissionBackend(&backend);

    const fd = try backend.startDial(102, relayTarget());
    backend.shutdownFd(fd);
    try backend.submitClose(103, fd);

    var dial_seen = false;
    var close_seen = false;
    var completions: [4]net.completion.Completion = undefined;
    for (0..12) |_| {
        const count = try backend.poll(&completions, 0);
        for (completions[0..count]) |completion| {
            switch (completion.user_data) {
                102 => {
                    try std.testing.expect(completion.result < 0);
                    dial_seen = true;
                },
                103 => {
                    try std.testing.expectEqual(@as(i32, 0), completion.result);
                    close_seen = true;
                },
                else => {},
            }
            if (completion.borrowed.active()) backend.recycleBorrowed(completion);
        }
        if (dial_seen and close_seen) break;
    }
    try std.testing.expect(dial_seen);
    try std.testing.expect(close_seen);
    try std.testing.expectEqual(@as(usize, 1), fake.opens);
    try std.testing.expectEqual(@as(usize, 1), fake.client_closes);
    try std.testing.expectEqual(@as(usize, 0), backend.conns.count());
    try std.testing.expectEqual(@as(usize, 0), backend.secure.count());
}

test "completion WSS keeps platform connect primary ahead of TLS cleanup" {
    var fake = fake_tls.FakeRuntime{
        .client_cleanup = .init(error.InjectedTlsCleanupFailure),
    };
    var runtime = fake.erased();
    var owner = try net.tls.runtime_owner.Owner.init(std.testing.allocator, &runtime);
    defer std.debug.assert(owner.release() == .released);
    var backend = try secureBackend(&owner);
    defer admission.deinitAdmissionBackend(&backend);

    _ = try backend.startDial(106, relayTarget());
    const internal_ud = backend.platform.pending_connect.?.user_data;
    var platform_chain = glowcap.foundation.FailureChain.init(error.NetworkUnreachable);
    platform_chain.note(error.ResolverCleanupFailed);
    backend.platform.pending_connect = .{
        .user_data = internal_ud,
        .result = -1,
        .failure = error.ConnectFailed,
        .borrowed = .failure(&platform_chain, 41),
    };

    var completions: [2]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    const failed = completions[0];
    try std.testing.expectEqual(@as(i32, -1), failed.result);
    try std.testing.expectEqual(net.carrier_failure.Phase.connect, failed.borrowed.carrierPhase().?);
    const chain = failed.borrowed.failureChain().?;
    try std.testing.expectEqualStrings("NetworkUnreachable", chain.primaryName());
    try std.testing.expectEqualStrings("ResolverCleanupFailed", chain.secondaryName().?);
    try std.testing.expectEqual(@as(u16, 2), chain.secondary_count);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.recycle_calls);
    try std.testing.expectEqual(@as(u32, 41), backend.platform.last_recycled_token);
    backend.recycleBorrowed(failed);
}

test "completion WSS retries refused ciphertext submission without rollback" {
    var fake = fake_tls.FakeRuntime{};
    var runtime = fake.erased();
    var owner = try net.tls.runtime_owner.Owner.init(std.testing.allocator, &runtime);
    defer std.debug.assert(owner.release() == .released);
    var backend = try secureBackend(&owner);
    defer admission.deinitAdmissionBackend(&backend);
    backend.platform.fail_send = true;

    _ = try backend.startDial(111, relayTarget());
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 1), backend.tls_send_retries.count);
    try std.testing.expectEqual(@as(?u64, 111), backend.conns.get(1).?.external_connect_ud);

    backend.platform.fail_send = false;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 0), backend.tls_send_retries.count);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.send_submits);
    try std.testing.expectEqual(.reading_upgrade, backend.conns.get(1).?.state);
}

test "completion WSS keeps platform send primary ahead of TLS cleanup" {
    var fake = fake_tls.FakeRuntime{
        .client_cleanup = .init(error.InjectedTlsCleanupFailure),
    };
    var runtime = fake.erased();
    var owner = try net.tls.runtime_owner.Owner.init(std.testing.allocator, &runtime);
    defer std.debug.assert(owner.release() == .released);
    var backend = try secureBackend(&owner);
    defer admission.deinitAdmissionBackend(&backend);

    const fd = try startSecureRelay(&backend);
    var completions: [2]net.completion.Completion = undefined;
    try completeSecureUpgrade(&backend, 71, &completions);
    try backend.submitSend(116, fd, "payload");
    const internal_ud = backend.platform.pending_send.?.user_data;
    backend.platform.pending_send = .{
        .user_data = internal_ud,
        .result = -1,
        .failure = error.BrokenPipe,
    };

    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    const failed = completions[0];
    try std.testing.expectEqual(@as(u64, 116), failed.user_data);
    try std.testing.expectEqual(net.carrier_failure.Phase.transmit, failed.borrowed.carrierPhase().?);
    const chain = failed.borrowed.failureChain().?;
    try std.testing.expectEqualStrings("BrokenPipe", chain.primaryName());
    // The failed platform write strands the TLS-owned ciphertext before the
    // engine destructor runs. Observation order is therefore the abandoned
    // output first, followed by the injected destructor refusal; the bounded
    // chain retains the first name and the truthful total.
    try std.testing.expectEqualStrings("TlsCiphertextAbandoned", chain.secondaryName().?);
    try std.testing.expectEqual(@as(u16, 2), chain.secondary_count);
    backend.recycleBorrowed(failed);
}

test "completion WSS shutdown failure settles the close barrier exactly" {
    var fake = fake_tls.FakeRuntime{
        .fail_phase = .shutdown,
        .client_cleanup = .init(error.InjectedTlsShutdownCleanupFailure),
    };
    var runtime = fake.erased();
    var owner = try net.tls.runtime_owner.Owner.init(std.testing.allocator, &runtime);
    defer std.debug.assert(owner.release() == .released);
    var backend = try secureBackend(&owner);
    defer admission.deinitAdmissionBackend(&backend);

    const fd = try startSecureRelay(&backend);
    var completions: [2]net.completion.Completion = undefined;
    try completeSecureUpgrade(&backend, 71, &completions);
    try backend.submitClose(121, fd);

    var close_failure: ?net.completion.Completion = null;
    for (0..8) |_| {
        const count = try backend.poll(&completions, 0);
        for (completions[0..count]) |completion| {
            if (completion.user_data == 121) close_failure = completion else if (completion.borrowed.active())
                backend.recycleBorrowed(completion);
        }
        if (close_failure != null) break;
    }
    const failed = close_failure.?;
    try std.testing.expectEqual(@as(i32, -1), failed.result);
    try std.testing.expectEqual(
        net.carrier_failure.Phase.shutdown,
        failed.borrowed.carrierFailureValue().?.phase,
    );
    const chain = failed.borrowed.failureChain().?;
    try std.testing.expectEqualStrings("InjectedTlsShutdownFailure", chain.primaryName());
    try std.testing.expectEqualStrings(
        "InjectedTlsShutdownCleanupFailure",
        chain.secondaryName().?,
    );
    try std.testing.expectEqual(@as(u16, 1), chain.secondary_count);
    backend.recycleBorrowed(failed);
}

fn secureBackend(owner: *net.tls.runtime_owner.Owner) !AdmissionBackend {
    return AdmissionBackend.initWithRelay(
        std.testing.allocator,
        8,
        1,
        64,
        .{
            .url = "wss://127.0.0.1:1/relay",
            .entropy_seed = @as([std.Random.DefaultCsprng.secret_seed_length]u8, @splat(0x91)),
            .tls_owner = owner.*,
            .send_staging_bytes = admission.frame_cap,
        },
    );
}

fn relayTarget() AdmissionBackend.ConnectTarget {
    return .{ .keyed_relay = .{ .designator = &designator, .relay = null } };
}

fn startSecureRelay(backend: *AdmissionBackend) !AdmissionBackend.Fd {
    const fd = try backend.startDial(71, relayTarget());
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    return fd;
}

fn completeSecureUpgrade(
    backend: *AdmissionBackend,
    expected_user_data: u64,
    completions: []net.completion.Completion,
) !void {
    const conn = backend.conns.get(1).?;
    var response_buf: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(
        &response_buf,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n",
        .{conn.expected_accept[0..]},
    );
    try backend.platform.completeRecv(response);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(completions, 0));
    try std.testing.expectEqual(expected_user_data, completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), completions[0].result);
}
