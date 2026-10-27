//! Fail-closed refusal: a protocol violation emits a typed op:abort and
//! closes, an app-queued abort commits before closing, allocation failure
//! cannot lose the close, and a promise-cycle consequence stays local.

const std = @import("std");
const glowcap = @import("glowcap");

const codec = glowcap.ocapn.codec;
const foundation = glowcap.foundation;
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const session = glowcap.ocapn.session;
const peer_fixture = @import("../../support/peer_fixture.zig");

const harness = @import("harness.zig");
const FailAfterAllocator = harness.FailAfterAllocator;
const CountingAllocator = harness.CountingAllocator;

test "failure-chain projection keeps boundary identity and saturates consequences" {
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    var chain = foundation.FailureChain.initNamed(error.ProviderContract, "tls.verify.hostname");
    var count: usize = 0;
    while (count < 300) : (count += 1) chain.note(error.SocketCloseFailed);
    peer.recordFailureChain(chain);

    const retained = peer.lastAbort().?;
    try std.testing.expectEqualStrings("tls.verify.hostname", retained.error_name);
    try std.testing.expectEqual(error.SocketCloseFailed, retained.secondary_error.?);
    try std.testing.expectEqual(std.math.maxInt(u8), retained.secondary_error_count);
}

test "an inbound protocol violation emits a typed op:abort and closes the session" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.pairedV1_0Syrup(allocator);
    defer pair.deinit();

    // An inbound `op:deliver` to `<desc:export 7>`, an export this open peer
    // never installed (only the bootstrap export 0 exists), is a protocol
    // violation (`InvalidReference`). The runtime must emit a typed abort and
    // close rather than silently bubbling the error.
    const deliver_to_unknown_export = "<10'op:deliver<11'desc:export7+>[]11+f>";
    try std.testing.expectError(
        session.Error.InvalidReference,
        pair.p2.recvBorrowed(.{ .bytes = deliver_to_unknown_export, .shape = .byte }),
    );

    // The session closed and no application event surfaced for the rejected frame.
    try std.testing.expectEqual(session.State.closed, pair.p2.session_state.state);
    try std.testing.expect(pair.p2.pollEvent() == null);

    // A typed `op:abort` (ProtocolError) is queued outbound for the partner.
    var abort_frame = pair.p2.takeOutbound().?;
    defer abort_frame.deinit();
    const decoded = try codec.syrup.decodeBody(abort_frame.view());
    try std.testing.expect(decoded == .abort);
    try std.testing.expectEqual(model.AbortKind.protocol_error, decoded.abort.kind);
    // Exactly one outbound frame, the abort.
    try std.testing.expect(pair.p2.takeOutbound() == null);
}

test "an app-queued op:abort commits outbound then closes the CapTP session" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.pairedV1_0Syrup(allocator);
    defer pair.deinit();

    try std.testing.expectEqual(session.State.open, pair.p1.session_state.state);
    // recordSend must not close, the partner still needs to take the frame
    // after step encodes it.
    try pair.p1.sendBorrowed(.{ .abort = .{ .kind = .graceful_shutdown, .message = "done" } });
    try std.testing.expectEqual(session.State.open, pair.p1.session_state.state);

    _ = try pair.p1.step();
    try std.testing.expectEqual(session.State.closed, pair.p1.session_state.state);

    var abort_frame = pair.p1.takeOutbound().?;
    defer abort_frame.deinit();
    const decoded = try codec.syrup.decodeBody(abort_frame.view());
    try std.testing.expect(decoded == .abort);
    try std.testing.expectEqual(model.AbortKind.graceful_shutdown, decoded.abort.kind);
    try std.testing.expectEqualStrings("done", decoded.abort.message);

    try std.testing.expectError(
        session.Error.SessionClosed,
        pair.p1.sendBorrowed(.{ .deliver = .{
            .target = .{ .far = .{ .import_position = .from(0) } },
            .args = &.{},
        } }),
    );
}

test "a closing projected abort still closes when the abort frame cannot allocate" {
    var failing = FailAfterAllocator{
        .backing = std.testing.allocator,
        .fail_after = std.math.maxInt(usize),
    };
    var peer = engine.Peer.init(failing.allocator());
    defer peer.deinit();
    try std.testing.expectEqual(session.State.open, peer.session_state.state);

    // Own the garbage with the real testing allocator so feed does not touch
    // the failing peer allocator; the next peer alloc is abort encode/push.
    const storage = try std.testing.allocator.dupe(u8, "this is not a syrup frame");
    const frame = try foundation.Frame.initOwned(
        std.testing.allocator,
        storage,
        .byte,
        .fromByteUnits(1),
    );
    try peer.feedOwned(frame);
    failing.fail_after = failing.allocation_count;
    try std.testing.expectError(error.MalformedFrame, peer.step());

    try std.testing.expectEqual(session.State.closed, peer.session_state.state);
    try std.testing.expect(peer.takeOutbound() == null);
    const cause = peer.lastAbort().?;
    try std.testing.expectEqual(model.AbortKind.malformed_frame, cause.kind.?);
    try std.testing.expectEqual(error.OutOfMemory, cause.abort_delivery_error.?);
}

test "a malformed inbound frame emits a malformed-frame abort and closes" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.pairedV1_0Syrup(allocator);
    defer pair.deinit();

    // Garbage that is not a decodable Syrup frame.
    const garbage = "this is not a syrup frame";
    try std.testing.expectEqual(@as(?engine.AbortInfo, null), pair.p1.lastAbort());
    try std.testing.expectError(
        error.MalformedFrame,
        pair.p1.recvBorrowed(.{ .bytes = garbage, .shape = .byte }),
    );

    try std.testing.expectEqual(session.State.closed, pair.p1.session_state.state);

    // The typed cause stays readable on the peer after the error propagated.
    const cause = pair.p1.lastAbort().?;
    try std.testing.expectEqual(engine.abort_projection.Domain.codec, cause.domain);
    try std.testing.expectEqual(model.AbortKind.malformed_frame, cause.kind.?);
    try std.testing.expectEqualStrings("MalformedFrame", cause.error_name);
    try std.testing.expect(cause.abort_delivery_error == null);

    var abort_frame = pair.p1.takeOutbound().?;
    defer abort_frame.deinit();
    const decoded = try codec.syrup.decodeBody(abort_frame.view());
    try std.testing.expect(decoded == .abort);
    try std.testing.expectEqual(model.AbortKind.malformed_frame, decoded.abort.kind);
}

test "a promise cycle breaks dependent work without emitting a session abort" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(.from(7));
    try p2.session_state.registerExport(.from(7));

    // p1 calls p2's export, allocating answer 42 (pending on p2), then
    // pipelines a call against it so the resolve below has a queue to drain.
    try p1.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{},
        .answer = .from(42),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }
    try p1.sendBorrowed(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = .from(43),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());

    // p2 resolves answer 42 to a local promise whose own answer resolves back
    // to that promise. The stored-resolution walker terminates both the
    // listener and dependent answer 43 without treating one promise graph as
    // a peer-wide protocol failure.
    const loop = try p2.session_state.allocateLocalPromiseProjection();
    const loop_ref: model.Reference = .{ .near = model.NearRef.promise(loop.export_position.int()) };
    try p2.sendBorrowed(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .reference = loop_ref } },
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    try p2.sendAnswerResolutionCopying(loop.answer_name, .{ .fulfill = .{ .reference = loop_ref } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    const wire = try peer_fixture.drainOutbound(&p2, allocator);
    defer allocator.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "promise resolution cycle") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "op:abort") == null);
    try std.testing.expectEqual(session.AnswerStatus.broken, p2.session_state.inboundAnswer(.from(43)).?.status);
    try std.testing.expectEqual(session.State.open, p2.session_state.state);
}

test "a malformed sturdyref argument is refused at validation as a malformed frame" {
    // The decoder frames the record and the session projects it while
    // validating the argument, so the refusal keeps the codec's verdict and
    // closes the session like any other malformed frame.
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.pairedV1_0Syrup(allocator);
    defer pair.deinit();
    pair.p1.session_state.features.sturdyref = true;

    const trailing = "<10'op:deliver<11'desc:export0+>[<15'ocapn-sturdyref<10'ocapn-peer3'tcp11\"127.0.0.1:0{}>5:swiss3:xyz>]ff>";
    try std.testing.expectError(
        error.MalformedView,
        pair.p1.recvBorrowed(.{ .bytes = trailing, .shape = .byte }),
    );
    try std.testing.expectEqual(session.State.closed, pair.p1.session_state.state);
    const cause = pair.p1.lastAbort().?;
    try std.testing.expectEqual(engine.abort_projection.Domain.codec, cause.domain);
    try std.testing.expectEqual(model.AbortKind.malformed_frame, cause.kind.?);
}
