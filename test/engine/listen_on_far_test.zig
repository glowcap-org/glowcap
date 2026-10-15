//! `listenOnFar`: nominating a fresh export bound to the answer it
//! returns, each profile's own op:listen shape, the partner's fulfill or
//! break surfacing on that answer, refusals for anything but a held far,
//! install-before-encode ordering, and whole-nomination rollback under
//! every allocation failure.

const std = @import("std");
const glowcap = @import("glowcap");

const codec = glowcap.ocapn.codec;
const foundation = glowcap.foundation;
const engine = glowcap.ocapn.engine;
const model = glowcap.ocapn.model;
const peer_fixture = @import("../support/peer_fixture.zig");

/// A paired session on `version` over Syrup, so a wire-shape assertion reads
/// one codec's bytes rather than whichever the glowcap offer preferred.
// ── The recipient half: waiting on a promise the partner handed us ──────────
//
// Everything above is what a holder does with a relayed resolution once it has
// one. `engine.listen.listenOnFar` is how a peer asks for one (ADR-0095):
// it nominates a fresh export as the listener and binds it to an outbound
// answer, so the partner's notification comes back as a resolve the caller
// observes exactly like a call's reply. Both negotiated profiles are exercised
// below, because `op:listen` and its notification are common CapTP, not a V1.0
// arrangement.

/// The profiles a session can negotiate. Both carry `op:listen`, and both
/// notification shapes must surface identically on the answer.
const profiles = [_]model.CaptpVersion{ .v1_0, .next };

fn syrupPair(allocator: std.mem.Allocator, version: model.CaptpVersion) !engine.pairing.Pair {
    return engine.pairing.pairedNegotiated(allocator, .{
        .captp_version = version,
        .codec = .syrup,
        .features = model.FeatureSet.full(),
    });
}

/// What `listenOnFar` left behind: the answer it returned, the listener
/// export read back off the emitted frame, and that frame's bytes.
const Listening = struct {
    answer: model.AnswerPosition,
    listener: u64,
    frame: foundation.Frame,

    fn deinit(self: *Listening) void {
        self.frame.deinit();
    }
};

fn installRemotePromise(peer: *engine.Peer, position: model.ImportPosition) !void {
    try peer.session_state.registerImport(position);
    if (peer.session_state.captp_version != .next) return;
    try engine.listen.ensureShorteningListener(peer, position);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var private = peer.takeOutbound().?;
    private.deinit();
}

/// Hold import 5 as a promise the partner handed us, listen on it, and drain
/// the one frame that produced. Own-outbound decode flips near export to far
/// import, so the listener position read back is the export the sender minted.
fn listenOnImportFive(peer: *engine.Peer) !Listening {
    try installRemotePromise(peer, .from(5));
    const answer = try engine.listen.listenOnFar(peer, .{ .far = model.FarRef.promise(5) });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    const frame = peer.takeOutbound().?;
    const view = try codec.syrup.decodeBodyForProfile(peer.session_state.captp_version, frame.view());
    try std.testing.expect(view == .listen);
    return .{ .answer = answer, .listener = view.listen.listener.far.import_position.int(), .frame = frame };
}

/// Notify `peer`'s listener export the way CapTP says a listener is told: an
/// `op:deliver` carrying `['fulfill|'break, payload]`, with no answer of its own.
fn notify(partner: *engine.Peer, peer: *engine.Peer, listener: u64, args: []const model.Argument) !void {
    try partner.session_state.registerImport(.from(listener));
    try partner.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(listener) },
        .args = args,
        .answer = null,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try partner.step());
    try peer.feedOwned(partner.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
}

test "listenOnFar nominates a fresh export and binds it to the answer it returns" {
    const allocator = std.testing.allocator;
    for (profiles) |version| {
        var pair = try syrupPair(allocator, version);
        defer pair.deinit();

        var listening = try listenOnImportFive(&pair.p1);
        defer listening.deinit();

        // The listener export is bound to the answer, so the partner's
        // notification reads as a settlement of that answer.
        try std.testing.expectEqual(
            listening.answer,
            pair.p1.session_state.answerForResolverExport(.from(listening.listener)).?,
        );
        // And the answer is installed before the send, so the notification is
        // not refused as a resolve on an answer we do not hold.
        try std.testing.expect(pair.p1.session_state.outbound_answers.contains(listening.answer));
    }
}

test "listenOnFar emits each profile's own op:listen, not one profile's shape on both" {
    const allocator = std.testing.allocator;

    var v1_0_pair = try syrupPair(allocator, .v1_0);
    defer v1_0_pair.deinit();
    var v1_0 = try listenOnImportFive(&v1_0_pair.p1);
    defer v1_0.deinit();

    var next_pair = try syrupPair(allocator, .next);
    defer next_pair.deinit();
    var next = try listenOnImportFive(&next_pair.p1);
    defer next.deinit();

    // Both nominate the same target and listener. The application asks only
    // for final settlement; next's mandatory shortening subscription was sent
    // when the remote promise first arrived.
    for ([_]struct { listening: *const Listening, profile: model.CaptpVersion }{
        .{ .listening = &v1_0, .profile = .v1_0 },
        .{ .listening = &next, .profile = .next },
    }) |item| {
        const listening = item.listening;
        const view = try codec.syrup.decodeBodyForProfile(item.profile, listening.frame.view());
        try std.testing.expectEqual(@as(u64, 5), view.listen.target.near.export_position.int());
        try std.testing.expectEqual(listening.listener, view.listen.listener.far.import_position.int());
        try std.testing.expectEqual(model.ListenMode.settling_only, view.listen.mode);
    }

    // V1.0 carries one Boolean byte; next carries the two-byte integer `2+`.
    // Next already spent one export on its private shortening listener, but
    // both positions remain one-byte integers, so the length difference is
    // still solely the mode encoding.
    try std.testing.expectEqual(v1_0.frame.bytes().len + 1, next.frame.bytes().len);
}

test "the partner's fulfill on the listener export surfaces as a resolve on the listen's answer" {
    const allocator = std.testing.allocator;
    for (profiles) |version| {
        var pair = try syrupPair(allocator, version);
        defer pair.deinit();
        var listening = try listenOnImportFive(&pair.p1);
        defer listening.deinit();

        try notify(&pair.p2, &pair.p1, listening.listener, &.{
            .{ .symbol = "fulfill" },
            .{ .bytes = "settled elsewhere" },
        });

        var event = pair.p1.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.resolve, event.kind());
        const view = event.view();
        try std.testing.expectEqual(listening.answer, view.resolve.answer);
        try std.testing.expectEqualStrings("settled elsewhere", view.resolve.resolution.fulfill.bytes);
    }
}

test "a V1.0 notification naming our own export surfaces for the local promise to follow" {
    // A V1.0 exporter whose answer resolved to a promise we host tells our
    // settling listener so; the resolve carries our own export, which the
    // application layer follows locally.
    const allocator = std.testing.allocator;
    var pair = try syrupPair(allocator, .v1_0);
    defer pair.deinit();
    try pair.p1.session_state.registerExport(.from(7));
    var listening = try listenOnImportFive(&pair.p1);
    defer listening.deinit();

    try pair.p2.session_state.registerImport(.from(7));
    try notify(&pair.p2, &pair.p1, listening.listener, &.{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .far = model.FarRef.promise(7) } },
    });

    var event = pair.p1.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.resolve, event.kind());
    const view = event.view();
    try std.testing.expectEqual(listening.answer, view.resolve.answer);
    try std.testing.expectEqual(@as(u64, 7), view.resolve.resolution.fulfill.reference.near.export_position.int());
}

test "the partner's break on the listener export surfaces as a broken resolve" {
    const allocator = std.testing.allocator;
    for (profiles) |version| {
        var pair = try syrupPair(allocator, version);
        defer pair.deinit();
        var listening = try listenOnImportFive(&pair.p1);
        defer listening.deinit();

        // A break rides as a bare Symbol, the same payload shape glowcap's own
        // listener fire emits.
        try notify(&pair.p2, &pair.p1, listening.listener, &.{
            .{ .symbol = "break" },
            .{ .symbol = "exporter vanished" },
        });

        var event = pair.p1.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.resolve, event.kind());
        const view = event.view();
        try std.testing.expectEqual(listening.answer, view.resolve.answer);
        try std.testing.expectEqualStrings("exporter vanished", view.resolve.resolution.@"break".message);
    }
}

test "listenOnFar refuses anything but a far this session holds" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    // A near names an export of ours, whose settlement is ours to decide; a
    // promise, sturdy, or broken names nothing a partner could notify us about.
    try peer.session_state.registerExport(.from(3));
    const sturdy = model.SturdyRef{
        .peer = .{ .transport = "tcp", .designator = "127.0.0.1:1", .hints = model.Hints.emptyFalse() },
        .swissnum = "swiss",
    };
    const refused = [_]model.Reference{
        .{ .near = model.NearRef.object(3) },
        .{ .promise = .{ .answer_position = .from(1) } },
        .{ .sturdy = &sturdy },
        .{ .broken = .{ .message = "gone" } },
        // A far this session does not hold names a capability that does not
        // exist here, refused like any unheld target.
        .{ .far = model.FarRef.promise(77) },
    };
    for (refused) |target| {
        try std.testing.expectError(
            error.InvalidReference,
            engine.listen.listenOnFar(&peer, target),
        );
    }
    // A refusal leaves nothing behind: no queued frame, and no listener export
    // bound to an answer nobody asked for.
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
    try std.testing.expect(peer.takeOutbound() == null);
}

test "next admits one settling listener per remote promise and refuses object targets" {
    const allocator = std.testing.allocator;
    var pair = try syrupPair(allocator, .next);
    defer pair.deinit();
    try installRemotePromise(&pair.p1, .from(5));

    _ = try engine.listen.listenOnFar(&pair.p1, .{ .far = model.FarRef.promise(5) });
    try std.testing.expectError(
        error.UnexpectedMessage,
        engine.listen.listenOnFar(&pair.p1, .{ .far = model.FarRef.promise(5) }),
    );
    try pair.p1.session_state.registerImport(.from(6));
    try std.testing.expectError(
        error.InvalidReference,
        engine.listen.listenOnFar(&pair.p1, .{ .far = model.FarRef.object(6) }),
    );

    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());
    var settling = pair.p1.takeOutbound().?;
    settling.deinit();
    try std.testing.expectEqual(engine.StepOutcome.idle, try pair.p1.step());
}

test "the listen's answer is installed before the op:listen is encoded" {
    const allocator = std.testing.allocator;
    for (profiles) |version| {
        var pair = try syrupPair(allocator, version);
        defer pair.deinit();

        try installRemotePromise(&pair.p1, .from(5));
        const answer = try engine.listen.listenOnFar(&pair.p1, .{ .far = model.FarRef.promise(5) });

        // Nothing has been encoded yet, and the answer is already one we hold,
        // so the notification cannot arrive on an answer we do not.
        try std.testing.expect(pair.p1.takeOutbound() == null);
        try std.testing.expect(pair.p1.session_state.outbound_answers.contains(answer));

        try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());
        var frame = pair.p1.takeOutbound().?;
        frame.deinit();
    }
}

test "a notification naming an answer the session does not hold is refused loudly" {
    const allocator = std.testing.allocator;
    var pair = try syrupPair(allocator, .next);
    defer pair.deinit();

    // The hazard the install ordering exists for, built by hand: a listener
    // export bound to an answer nothing ever installed.
    try pair.p1.session_state.registerExport(.from(7));
    try pair.p1.session_state.installOutboundResolver(.from(4242), .from(7));

    try pair.p2.session_state.registerImport(.from(7));
    try pair.p2.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{ .{ .symbol = "fulfill" }, .{ .bytes = "settled elsewhere" } },
        .answer = null,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());
    try pair.p1.feedOwned(pair.p2.takeOutbound().?);

    // `validateInboundResolve` refuses it, and the refusal is a typed
    // protocol_error the partner is told about rather than a silent drop. No
    // resolve surfaces for an answer nobody asked for.
    try std.testing.expectError(error.InvalidReference, pair.p1.step());
    try std.testing.expectEqual(model.AbortKind.protocol_error, pair.p1.lastAbort().?.kind.?);
    try std.testing.expect(pair.p1.pollEvent() == null);
}

// The rollback paths. Every refusal in the test above returns at the target
// check, before anything is reserved, so this sweep is the only thing that runs
// `nominateResolverExport`'s undo and `listenOnFar`'s. It arms the failure
// at a fixed offset into the call itself, so each offset names one allocation
// the call makes, and the offsets past the last one succeed, which is how the
// sweep proves it covered them all.
//
// Validated by injection. Caught: dropping the export release from
// `abandonResolverExport`, dropping either the release errdefer in
// `bindFreshResolverExport` or the link removal, installing the answer
// after the send (which the session-side pin
// `nominateResolverExport installs the answer it hands back` also names
// directly), and narrowing `listenOnFar`'s errdefer to the export-only
// `abandonResolverExport`, which strands the answer row (the session pin
// catches the sibling: a nomination undo that skips its answer half).
// Escaped: swapping the two statements in
// `abandonResolverExport`, because a single decrement's outcome does not depend
// on the link, so the two orders leave identical state and no test can tell
// them apart. States it does not reach: a failure during `step`'s encode (a
// failed attempt is never stepped under the armed allocator), and resize-path
// failures (`resize_fail_index` is left unarmed).
test "every allocation failure inside listenOnFar rolls the whole nomination back" {
    for (profiles) |version| {
        var successes: usize = 0;
        var failures: usize = 0;
        var offset: usize = 0;
        while (offset < 12) : (offset += 1) {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            var peer = peer_fixture.openPeerWith(failing.allocator(), .{ .captp_version = version });
            defer peer.deinit();
            try installRemotePromise(&peer, .from(5));

            // The two rows the attempt is about to reserve, read off the
            // session's own allocators before it runs.
            const listener = model.ExportPosition.from(peer.session_state.next_export_position);
            const answer = model.AnswerPosition.from(peer.session_state.next_outbound_answer);

            failing.fail_index = failing.alloc_index + offset;
            const attempt = engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(5) });
            failing.fail_index = std.math.maxInt(usize);

            if (attempt) |returned| {
                successes += 1;
                try std.testing.expectEqual(answer, returned);
                try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
                var frame = peer.takeOutbound().?;
                frame.deinit();
                continue;
            } else |_| {}
            try std.testing.expectError(error.OutOfMemory, attempt);
            failures += 1;

            // Nothing of the nomination survives: no export row, no answer
            // row, neither direction of the resolver link, and no `op:listen`
            // to encode.
            try std.testing.expectEqual(@as(u64, 0), peer.session_state.exportRefcount(listener));
            try std.testing.expect(!peer.session_state.outbound_answers.contains(answer));
            try std.testing.expectEqual(
                @as(?model.AnswerPosition, null),
                peer.session_state.answerForResolverExport(listener),
            );
            try std.testing.expectEqual(
                @as(?model.ExportPosition, null),
                peer.session_state.outbound_resolver_link.getByValue(.{ .application_answer = answer }),
            );
            try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
            try std.testing.expect(peer.takeOutbound() == null);

            // And the session still listens: the retry gets its own export and
            // a fresh answer, bound to each other.
            const retry_listener = model.ExportPosition.from(peer.session_state.next_export_position);
            const retry = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(5) });
            try std.testing.expect(retry.int() > answer.int());
            try std.testing.expectEqual(retry, peer.session_state.answerForResolverExport(retry_listener).?);
            try std.testing.expect(peer.session_state.outbound_answers.contains(retry));
            try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
            var retry_frame = peer.takeOutbound().?;
            retry_frame.deinit();
        }
        // The sweep ran past the last allocation the call makes, so every one of
        // them was injected.
        try std.testing.expect(failures > 0);
        try std.testing.expect(successes > 0);
    }
}
