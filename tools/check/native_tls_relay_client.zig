//! Live refusal and WebSocket-upgrade proof for the native relay carrier.

const std = @import("std");

const allocation_probe = @import("allocation_probe");
const foundation = @import("foundation");
const native_relay = @import("native_relay");
const native_tls = @import("native_tls");
const net = @import("net");

const BackendKind = enum { pollable, completion };
const Expectation = enum {
    success,
    certificate_untrusted,
    certificate_expired,
    certificate_name_mismatch,
    sni_alert,
    peer_alert,
    malformed_tls,
    truncated,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len != 5) return error.ExpectedBackendExpectationTrustAndUrl;

    const backend = std.meta.stringToEnum(BackendKind, args[1]) orelse
        return error.UnknownBackend;
    const expectation = std.meta.stringToEnum(Expectation, args[2]) orelse
        return error.UnknownExpectation;
    const trust = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[3],
        allocator,
        .limited(8 << 20),
    );
    defer allocator.free(trust);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    allocation_probe.resetWindow();
    switch (backend) {
        .pollable => try expectPollable(threaded.io(), allocator, args[4], trust, expectation),
        .completion => try expectCompletion(threaded.io(), allocator, args[4], trust, expectation),
    }
}

fn expectPollable(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    trust: []const u8,
    expectation: Expectation,
) !void {
    var provider: native_relay.Provider = undefined;
    switch (provider.init(io, allocator, url, null, .{ .copied_pem = trust })) {
        .ready => {},
        .failed => |failure| {
            std.debug.print("native TLS relay initialization failed: {s}\n", .{
                failure.chain().primaryName(),
            });
            return error.UnexpectedInitializationFailure;
        },
    }
    const shared = allocation_probe.snapshot();
    allocation_probe.resetWindow();

    const identity = foundation.crypto.SecretKey.fromSeed(
        @as([foundation.crypto.SEED_BYTES]u8, @splat(0x6b)),
    );
    const designator = identity.publicKey().toDesignator();
    var stop = std.atomic.Value(bool).init(false);
    const outcome = provider.resident(.keyed).dialRawOutcomeCancelable(.{
        .transport = net.relay.transport_name,
        .designator = &designator,
    }, &stop);
    const result = checkPollableOutcome(outcome, expectation);
    const operation_probe = allocation_probe.snapshot();
    const budget_result = validateAllocationBudget(
        "pollable",
        expectation,
        shared,
        operation_probe,
    );
    const release_failure = provider.deinit();
    if (result) |err| {
        if (release_failure) |failure| {
            std.debug.print("native relay release also failed: {s}\n", .{
                failure.primaryName(),
            });
        }
        return err;
    }
    if (release_failure) |failure| {
        std.debug.print("native relay release failed: {s}\n", .{failure.primaryName()});
        return failure.cause;
    }
    if (budget_result) |err| return err;
    if (allocation_probe.snapshot().current_bytes != 0)
        return error.TlsRuntimeAllocationLeak;
}

fn checkPollableOutcome(outcome: anytype, expectation: Expectation) ?anyerror {
    return switch (expectation) {
        .success => expectConnected(outcome, false),
        .truncated => expectConnected(outcome, true),
        .certificate_untrusted => expectPollableRefusal(outcome, "CertificateUntrusted", null),
        .certificate_expired => expectPollableRefusal(outcome, "CertificateExpired", null),
        .certificate_name_mismatch => expectPollableRefusal(outcome, "CertificateNameMismatch", null),
        .sni_alert => expectPollableRefusal(outcome, "TlsPeerAlert", 112),
        .peer_alert => expectPollableRefusal(outcome, "TlsPeerAlert", 49),
        .malformed_tls => expectPollableRefusal(outcome, "TlsHandshakeFailed", null),
    };
}

fn expectConnected(outcome: anytype, expect_truncation: bool) ?anyerror {
    var connected = switch (outcome) {
        .connected => |value| value,
        .failed => |failure| {
            std.debug.print("native WSS dial failed: {s}\n", .{failure.chain.primaryName()});
            return failure.classification;
        },
    };
    if (expect_truncation) {
        var byte: [1]u8 = undefined;
        if (connected.read(&byte)) |_| {
            return error.TruncatedTlsProducedPlaintext;
        } else |err| if (err != error.ReadFailed) {
            return error.WrongTruncationReadResult;
        }
        const failure = connected.takeFailure() orelse return error.MissingTruncationFailure;
        if (!std.mem.eql(u8, failure.primaryName(), "TlsTruncated")) {
            std.debug.print("truncated TLS refusal was {s}\n", .{failure.primaryName()});
            return error.WrongTruncationFailure;
        }
    }
    if (connected.close()) |failure| {
        std.debug.print("native WSS close failed: {s}\n", .{failure.primaryName()});
        return failure.cause;
    }
    return null;
}

fn expectPollableRefusal(outcome: anytype, expected: []const u8, expected_alert: ?u8) ?anyerror {
    const failure = switch (outcome) {
        .connected => |value| {
            var connected = value;
            if (connected.close()) |close_failure| {
                std.debug.print("unexpected connection close also failed: {s}\n", .{
                    close_failure.primaryName(),
                });
            }
            return error.TlsRefusalWasAccepted;
        },
        .failed => |failure| failure,
    };
    return validateRefusal(
        failure.chain,
        failure.carrier_phase,
        failure.carrier_detail,
        expected,
        expected_alert,
    );
}

fn validateRefusal(
    chain: foundation.FailureChain,
    phase: ?net.carrier_failure.Phase,
    detail: net.carrier_failure.Detail,
    expected: []const u8,
    expected_alert: ?u8,
) ?anyerror {
    if (!std.mem.eql(u8, chain.primaryName(), expected)) {
        std.debug.print("TLS refusal was {s}, expected {s}\n", .{
            chain.primaryName(),
            expected,
        });
        return error.WrongTlsRefusal;
    }
    if (phase != .secure_handshake)
        return error.WrongCarrierFailurePhase;
    if (detail.engine_code == null)
        return error.MissingTlsEngineCode;
    if (expected_alert) |alert| {
        if (detail.peer_alert != alert) {
            std.debug.print("TLS peer alert was {?}, expected {}\n", .{
                detail.peer_alert,
                alert,
            });
            return error.WrongTlsPeerAlert;
        }
    } else if (std.mem.startsWith(u8, expected, "Certificate") and
        detail.verification_flags == 0)
    {
        return error.MissingCertificateVerificationFlags;
    }
    return null;
}

fn expectCompletion(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    trust: []const u8,
    expectation: Expectation,
) !void {
    const ready = switch (native_tls.init(io, allocator, .{ .copied_pem = trust })) {
        .ready => |value| value,
        .failed => |failure| {
            std.debug.print("completion TLS initialization failed: {s}\n", .{
                failure.chain.primaryName(),
            });
            return error.UnexpectedInitializationFailure;
        },
    };
    const shared = allocation_probe.snapshot();
    allocation_probe.resetWindow();
    var runtime = ready.runtime;
    var owner = try net.tls.runtime_owner.Owner.init(allocator, &runtime);
    var owner_live = true;
    defer if (owner_live) releaseTlsOwner(&owner) catch unreachable;

    var backend = try net.KeyedRelayBackend.initWithRelay(allocator, 64, 16, 4096, .{
        .url = url,
        .entropy_seed = @as([std.Random.DefaultCsprng.secret_seed_length]u8, @splat(0x93)),
        .tls_owner = owner,
        .resolver_io = io,
    });
    var backend_live = true;
    defer if (backend_live) {
        for (1..backend.next_id) |id| backend.closeFd(syntheticFd(@intCast(id)));
        drainRetirement(&backend) catch unreachable;
        backend.deinit();
    };

    const designator = foundation.crypto.SecretKey.fromSeed(
        @as([foundation.crypto.SEED_BYTES]u8, @splat(0x6b)),
    ).publicKey().toDesignator();
    const fd = try backend.startDial(1, .{ .keyed_relay = .{
        .designator = &designator,
        .relay = null,
    } });
    const dial = try waitCompletion(&backend, 1);
    const result = checkCompletionDial(dial, expectation);
    if (dial.borrowed.active()) backend.recycleBorrowed(dial);
    if (result) |err| {
        backend.closeFd(fd);
        try drainRetirement(&backend);
        backend.deinit();
        backend_live = false;
        try releaseTlsOwner(&owner);
        owner_live = false;
        return err;
    }

    if (expectation == .success or expectation == .truncated) {
        if (expectation == .truncated) {
            try backend.submitRecv(2, fd);
            const received = try waitCompletion(&backend, 2);
            const receive_result = validateCompletionTruncation(received);
            if (received.borrowed.active()) backend.recycleBorrowed(received);
            if (receive_result) |err| return err;
        }
        try backend.submitClose(3, fd);
        const closed = try waitCompletionWithin(&backend, 3, close_poll_budget);
        const close_result = validateCompletionClose(closed, expectation);
        if (closed.borrowed.active()) backend.recycleBorrowed(closed);
        if (close_result) |err| return err;
    } else {
        // A terminal dial completion settles the operation, not ownership of
        // the synthetic descriptor returned at admission. Recycle the exact
        // failure first, then retire that caller-owned handle explicitly.
        backend.closeFd(fd);
    }
    try drainRetirement(&backend);
    backend.deinit();
    backend_live = false;
    const operation_probe = allocation_probe.snapshot();
    if (validateAllocationBudget(
        "completion",
        expectation,
        shared,
        operation_probe,
    )) |err| return err;
    try releaseTlsOwner(&owner);
    owner_live = false;
    if (allocation_probe.snapshot().current_bytes != 0)
        return error.TlsRuntimeAllocationLeak;
}

// Requested payload measured inside Mbed TLS. Allocator metadata is platform
// owned and excluded. These are ceilings across the complete real local
// success/refusal matrix; structural record windows remain exact Zig sizes.
const shared_peak_ceiling: usize = 4 * 1024;
const connection_peak_ceiling: usize = 64 * 1024;
const connection_allocation_ceiling: usize = 8 * 1024;

fn validateAllocationBudget(
    backend: []const u8,
    expectation: Expectation,
    shared: allocation_probe.Snapshot,
    operation: allocation_probe.Snapshot,
) ?anyerror {
    if (operation.current_bytes != shared.current_bytes)
        return error.TlsConnectionAllocationLeak;
    if (shared.peak_bytes > shared_peak_ceiling)
        return error.TlsSharedAllocationBudgetExceeded;
    const connection_peak = operation.peak_bytes -| shared.current_bytes;
    if (connection_peak > connection_peak_ceiling)
        return error.TlsConnectionAllocationBudgetExceeded;
    if (operation.allocation_count > connection_allocation_ceiling)
        return error.TlsConnectionAllocationCountExceeded;
    if (expectation == .success) std.debug.print(
        "native TLS allocation budget: {s} shared={}/{} peak, connection={} peak/{} allocs\n",
        .{
            backend,
            shared.current_bytes,
            shared.peak_bytes,
            connection_peak,
            operation.allocation_count,
        },
    );
    return null;
}

fn validateCompletionClose(
    completion: net.completion.Completion,
    expectation: Expectation,
) ?anyerror {
    if (expectation == .success)
        return if (completion.result == 0) null else error.CompletionCloseFailed;
    std.debug.assert(expectation == .truncated);
    if (completion.result >= 0) return error.TruncatedTlsCloseReportedSuccess;
    const chain = completion.borrowed.failureChain() orelse
        return error.MissingTruncationCloseFailure;
    if (!std.mem.eql(u8, chain.primaryName(), "TlsTruncated")) {
        std.debug.print("completion WSS close retained {s}, expected TlsTruncated\n", .{
            chain.primaryName(),
        });
        return error.WrongTruncationCloseFailure;
    }
    return null;
}

fn checkCompletionDial(
    dial: net.completion.Completion,
    expectation: Expectation,
) ?anyerror {
    if (expectation == .success or expectation == .truncated) {
        if (dial.result == 0) return null;
        if (dial.borrowed.failureChain()) |chain| {
            std.debug.print("completion WSS dial failed: {s}\n", .{chain.primaryName()});
        } else if (dial.failure) |failure| {
            std.debug.print("completion WSS dial failed: {s}\n", .{@errorName(failure)});
        }
        return dial.failure orelse error.CompletionDialFailed;
    }
    if (dial.result >= 0) return error.TlsRefusalWasAccepted;
    const failure = dial.borrowed.carrierFailureValue() orelse
        return error.MissingCompletionCarrierFailure;
    const expected = switch (expectation) {
        .certificate_untrusted => "CertificateUntrusted",
        .certificate_expired => "CertificateExpired",
        .certificate_name_mismatch => "CertificateNameMismatch",
        .sni_alert, .peer_alert => "TlsPeerAlert",
        .malformed_tls => "TlsHandshakeFailed",
        .success, .truncated => unreachable,
    };
    const alert: ?u8 = switch (expectation) {
        .sni_alert => 112,
        .peer_alert => 49,
        else => null,
    };
    return validateRefusal(failure.chain, failure.phase, failure.detail, expected, alert);
}

fn validateCompletionTruncation(completion: net.completion.Completion) ?anyerror {
    if (completion.result >= 0) return error.TruncatedTlsProducedPlaintext;
    const failure = completion.borrowed.carrierFailureValue() orelse
        return error.MissingTruncationFailure;
    if (failure.phase != .receive or
        !std.mem.eql(u8, failure.chain.primaryName(), "TlsTruncated"))
    {
        std.debug.print("completion truncation was {s} in {s}\n", .{
            failure.chain.primaryName(),
            @tagName(failure.phase),
        });
        return error.WrongTruncationFailure;
    }
    return null;
}

fn waitCompletion(
    backend: *net.KeyedRelayBackend,
    expected_user_data: u64,
) !net.completion.Completion {
    return waitCompletionWithin(backend, expected_user_data, 30);
}

const close_poll_budget: usize = 10;

fn waitCompletionWithin(
    backend: *net.KeyedRelayBackend,
    expected_user_data: u64,
    poll_budget: usize,
) !net.completion.Completion {
    var completions: [8]net.completion.Completion = undefined;
    for (0..poll_budget) |_| {
        const count = try backend.poll(&completions, 1_000);
        for (completions[0..count]) |completion| {
            if (completion.user_data == expected_user_data) return completion;
            if (completion.borrowed.active()) backend.recycleBorrowed(completion);
            return error.UnexpectedCompletion;
        }
    }
    return error.CompletionTimedOut;
}

fn drainRetirement(backend: *net.KeyedRelayBackend) !void {
    var completions: [8]net.completion.Completion = undefined;
    for (0..30) |_| {
        if (backend.conns.count() == 0) return;
        const count = try backend.poll(&completions, 1_000);
        for (completions[0..count]) |completion| {
            if (completion.borrowed.active()) backend.recycleBorrowed(completion);
            return error.UnexpectedCompletion;
        }
    }
    return error.CompletionRetirementTimedOut;
}

fn releaseTlsOwner(owner: *net.tls.runtime_owner.Owner) !void {
    return switch (owner.release()) {
        .released => {},
        .busy => error.TlsRuntimeBusy,
        .failed => |failure| failure.cause,
    };
}

fn syntheticFd(id: u32) net.KeyedRelayBackend.Fd {
    return @bitCast(@as(u32, 0x8000_0000) | id);
}
