//! Authority tests for the session-owned `engine.bootstrap.gifts.GiftRegistry`:
//! deposit / withdraw bookkeeping, recipient match, monotonic handoff-count
//! replay rejection, re-deposit replacement, and the deposited-gift cap. Gift withdrawal moves authority only behind signature
//! verification, so these exercise the registry the way the verified callers do
//! (`engine.bootstrap.resolveForWithdraw`, the test-support
//! `cross_peer.withdrawGift` harness),
//! never through the unauthenticated generic recv path.

const std = @import("std");
const pancake = @import("pancake");

const crypto = pancake.foundation.crypto;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const session = pancake.ocapn.session;

const GiftRegistry = engine.bootstrap.gifts.GiftRegistry;

/// A synthetic 32-byte receiver name from a short label. The exporter checks an
/// inbound receive against names it derives from session keys, and a derived
/// name is always 32 bytes, so a fixture that wants to reach the registry's gift
/// and replay logic has to carry names of that width.
fn name32(label: []const u8) [32]u8 {
    var out = @as([32]u8, @splat(0));
    @memcpy(out[0..label.len], label);
    return out;
}

const session_a = name32("session-a");
const recipient_side = name32("recipient-side");

/// Every fixture below withdraws as the same synthetic recipient on the same
/// synthetic session, so the identity the exporter derives is this constant.
/// Tests for the derivation check itself call `validateWithdraw` directly.
const expected_receiver: engine.handoff_names.ExpectedReceiver = .{
    .side = recipient_side,
    .session = session_a,
};

fn validate(registry: *const GiftRegistry, receive: model.HandoffReceive) session.Error!void {
    return registry.validateWithdraw(receive, expected_receiver);
}

fn apply(
    registry: *GiftRegistry,
    allocator: std.mem.Allocator,
    receive: model.HandoffReceive,
) !?model.Reference {
    return registry.applyWithdraw(registry, allocator, null, receive);
}

fn makeReceive(
    gift_id: []const u8,
    recipient_key: []const u8,
    session_id: *const [32]u8,
    count: u64,
) model.HandoffReceive {
    return makeReceiveAs(gift_id, recipient_key, &recipient_side, session_id, count);
}

fn makeReceiveAs(
    gift_id: []const u8,
    recipient_key: []const u8,
    side: *const [32]u8,
    session_id: *const [32]u8,
    count: u64,
) model.HandoffReceive {
    return .{
        .receiving_session = session_id,
        .receiving_side = side,
        .handoff_count = count,
        .signed_give = .{
            .recipient_key = recipient_key,
            .exporter = .{ .transport = "memory", .designator = "exporter" },
            .gifter_exporter_session = "gifter-session",
            .gifter_side = "gifter-side",
            .gift_id = gift_id,
            .signature = &.{},
        },
        .signature = &.{},
    };
}

const default_limits: session.SessionLimits = .{};

test "deposit rejects non-32-byte gift id before copy or registry mutation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var s = session.Session.initWith(allocator, .{ .captp_version = .next });
    defer {
        failing.fail_index = std.math.maxInt(usize);
        s.deinit();
    }
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator, null);

    const gifted = model.Reference{ .broken = .{ .message = "would require a copy" } };
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        session.Error.MalformedMessage,
        engine.bootstrap.resolveForDeposit(&s, &registry, null, null, .{
            .gift_id = "short",
            .gifted = model.view.Reference.fromOwned(&gifted),
            .answer = null,
        }),
    );
    try std.testing.expect(!registry.giftLive("short"));
}

test "next deposit rejects non-32-byte gift id before registry mutation" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{ .captp_version = .next });
    defer s.deinit();
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator, null);

    const gifted = model.Reference{ .broken = .{ .message = "invalid gift" } };
    try std.testing.expectError(
        session.Error.MalformedMessage,
        engine.bootstrap.resolveForDeposit(&s, &registry, null, null, .{
            .gift_id = "short",
            .gifted = model.view.Reference.fromOwned(&gifted),
            .answer = null,
        }),
    );
    try std.testing.expect(!registry.giftLive("short"));
}

test "withdraw rejects non-32-byte gift id before lookup or parking" {
    const allocator = std.testing.allocator;
    const receive: model.HandoffReceive = .{
        .receiving_session = "receiving-session",
        .receiving_side = "receiving-side",
        .handoff_count = 0,
        .signed_give = .{
            .recipient_key = "recipient-key",
            .exporter = .{ .transport = "memory", .designator = "exporter" },
            .gifter_exporter_session = "gifter-session",
            .gifter_side = "gifter-side",
            .gift_id = "short",
            .signature = "give-signature",
        },
        .signature = "receive-signature",
    };
    var handoff = model.Handoff{ .receive = receive };
    const view = model.view.Handoff.fromOwned(&handoff).receive;

    var next_session = session.Session.initWith(allocator, .{ .captp_version = .next });
    defer next_session.deinit();
    var next_registry: GiftRegistry = .{};
    defer next_registry.deinit(allocator, null);
    var refused = switch (try engine.bootstrap.resolveForWithdraw(
        allocator,
        &next_session,
        &next_registry,
        null,
        null,
        null,
        .{ .receive = view, .answer = .fromWire(.from(1)) },
    )) {
        .settled => |prepared| prepared,
        .awaiting_deposit => return error.TestUnexpectedPending,
    };
    defer refused.deinit(allocator);
    try std.testing.expectEqualStrings(
        "handoff gift id has invalid width",
        refused.resolution.?.@"break".message,
    );

    // The baseline profile does not take that width rule, so the same receive
    // reaches the ordinary lookup and parks for its deposit like any other. The
    // pinned OCapN suite gives with a seven-byte id, and refusing it here would
    // retire the session before the handoff is read
    // (`conformance/ocapn-findings`, gift-id width).
    var v1_session = session.Session.init(allocator);
    defer v1_session.deinit();
    var v1_registry: GiftRegistry = .{};
    defer v1_registry.deinit(allocator, null);
    switch (try engine.bootstrap.resolveForWithdraw(
        allocator,
        &v1_session,
        &v1_registry,
        null,
        null,
        null,
        .{ .receive = view, .answer = .fromWire(.from(2)) },
    )) {
        // Whatever else this unsigned fixture is refused for, it is no longer
        // refused for its width: that is the whole claim.
        .settled => |prepared| {
            var settled = prepared;
            defer settled.deinit(allocator);
            try std.testing.expect(!std.mem.eql(
                u8,
                settled.resolution.?.@"break".message,
                "handoff gift id has invalid width",
            ));
        },
        .awaiting_deposit => {},
    }
    try std.testing.expect(!v1_registry.giftLive("short"));
}

test "registry deposits a gift and accepts a matching withdrawal" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator, null);

    try registry.deposit(allocator, default_limits, null, "gift-1", "recipient-key");
    try std.testing.expect(registry.giftLive("gift-1"));

    const receive = makeReceive("gift-1", "recipient-key", &session_a, 1);
    try validate(&registry, receive);
    _ = try apply(&registry, allocator, receive);
    try std.testing.expect(!registry.giftLive("gift-1"));
}

test "the generic inbound path moves no gift-withdrawal authority" {
    const allocator = std.testing.allocator;
    const gift_id = @as([model.HANDOFF_GIFT_ID_BYTES]u8, @splat(0x41));
    var exporter = engine.Peer.init(allocator);
    defer exporter.deinit();

    try exporter.giftRegistry().deposit(
        allocator,
        exporter.session_state.limits,
        null,
        &gift_id,
        "recipient-key",
    );
    try exporter.session_state.registerExport(.from(1));
    var handoff = model.Handoff{ .receive = makeReceive(&gift_id, "recipient-key", &session_a, 1) };
    // Merely carrying a receive certificate as a passable value cannot burn a
    // gift. Withdrawal authority belongs to the verified bootstrap method.
    try exporter.session_state.recordRecv(.{ .deliver = .{
        .target = .{ .near = model.NearRef.object(1) },
        .args = &.{.{ .handoff = &handoff }},
    } });
    try std.testing.expect(exporter.giftRegistry().giftLive(&gift_id));
}

test "registry rejects withdrawal of an unknown gift" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator, null);

    try std.testing.expectError(
        session.Error.InvalidGift,
        validate(&registry, makeReceive("ghost-gift", "recipient-key", &session_a, 1)),
    );
}

test "registry rejects withdrawal with a mismatched recipient key" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator, null);
    try registry.deposit(allocator, default_limits, null, "gift-1", "recipient-key");

    try std.testing.expectError(
        session.Error.InvalidGift,
        validate(&registry, makeReceive("gift-1", "imposter-key", &session_a, 1)),
    );
    try std.testing.expect(registry.giftLive("gift-1"));
}

test "registry rejects a replayed or out-of-order handoff count" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator, null);
    try registry.deposit(allocator, default_limits, null, "gift-1", "recipient-key");
    try registry.deposit(allocator, default_limits, null, "gift-2", "recipient-key");

    const first = makeReceive("gift-1", "recipient-key", &session_a, 2);
    try validate(&registry, first);
    _ = try apply(&registry, allocator, first);

    try std.testing.expectError(
        session.Error.HandoffReplay,
        validate(&registry, makeReceive("gift-2", "recipient-key", &session_a, 1)),
    );
    try std.testing.expect(registry.giftLive("gift-2"));
}

test "a withdrawn gift cannot be withdrawn twice" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator, null);

    try registry.deposit(allocator, default_limits, null, "gift-1", "recipient-key");
    const first = makeReceive("gift-1", "recipient-key", &session_a, 1);
    try validate(&registry, first);
    _ = try apply(&registry, allocator, first);

    // A fresh signed receive with a higher handoff count is not a replay, so
    // the refusal here is the consumed gift's row being gone: a gift is spent
    // exactly once, even across an otherwise-valid second certificate.
    try std.testing.expectError(
        session.Error.InvalidGift,
        validate(&registry, makeReceive("gift-1", "recipient-key", &session_a, 2)),
    );
}

test "a re-deposit of the same gift id replaces the prior row and frees it" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator, null);

    // Both deposited capabilities carry heap (a broken ref owns its message), so
    // the testing allocator proves the first is freed on overwrite, a leak or a
    // double free fails this test.
    const first = model.Reference{ .broken = .{ .message = try allocator.dupe(u8, "first") } };
    try registry.depositOwned(allocator, default_limits, null, "gift-1", first);

    // A second deposit on the same live session replaces that session's row.
    const second = model.Reference{ .broken = .{ .message = try allocator.dupe(u8, "second") } };
    try registry.depositOwned(allocator, default_limits, null, "gift-1", second);
    try std.testing.expectEqualStrings("second", registry.giftedCap("gift-1").?.broken.message);
}

test "a re-deposit after withdrawal re-arms the gift" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator, null);

    try registry.deposit(allocator, default_limits, null, "gift-1", "recipient-key");
    const first = makeReceive("gift-1", "recipient-key", &session_a, 1);
    try validate(&registry, first);
    _ = try apply(&registry, allocator, first);
    try std.testing.expect(!registry.giftLive("gift-1"));

    // Re-authorizing the same gift id replaces the consumed row. Replay stays
    // blocked by the monotonic handoff count, not by refusing the deposit: the
    // first certificate cannot be presented again, but a fresh higher-count
    // receive withdraws the re-armed gift.
    try registry.deposit(allocator, default_limits, null, "gift-1", "recipient-key");
    try std.testing.expect(registry.giftLive("gift-1"));
    try std.testing.expectError(
        session.Error.HandoffReplay,
        validate(&registry, makeReceive("gift-1", "recipient-key", &session_a, 1)),
    );
    const fresh = makeReceive("gift-1", "recipient-key", &session_a, 2);
    try validate(&registry, fresh);
    _ = try apply(&registry, allocator, fresh);
    try std.testing.expect(!registry.giftLive("gift-1"));
}

test "deposited gifts are bounded by max_deposited_gifts (ADR-0025)" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator, null);
    const limits: session.SessionLimits = .{ .max_deposited_gifts = 1 };

    try registry.deposit(allocator, limits, null, "gift-a", "recipient");
    try std.testing.expectError(
        session.Error.DepositedGiftCapExceeded,
        registry.deposit(allocator, limits, null, "gift-b", "recipient"),
    );
    try std.testing.expect(registry.giftLive("gift-a"));
    try std.testing.expect(!registry.giftLive("gift-b"));
}

test "consumed gifts do not count toward max_deposited_gifts" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator, null);
    // A registry that has already served max_deposited_gifts *completed*
    // handoffs must keep accepting new deposits: a spent gift no longer counts.
    const limits: session.SessionLimits = .{ .max_deposited_gifts = 1 };

    var buf: [8]u8 = undefined;
    var i: u64 = 0;
    while (i < 5) : (i += 1) {
        const id = try std.fmt.bufPrint(&buf, "gift-{d}", .{i});
        // Only one gift is ever live at a time, so a cap of 1 admits every
        // deposit once its predecessor has been withdrawn.
        try registry.deposit(allocator, limits, null, id, "recipient");
        const receive = makeReceive(id, "recipient", &session_a, i + 1);
        try validate(&registry, receive);
        _ = try apply(&registry, allocator, receive);
    }
}

test "re-arming a consumed gift still respects max_deposited_gifts" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator, null);
    // The live-gift cap must hold across re-arm: consuming a gift and re-depositing
    // its id is a fresh row through the cap check, not a bypass that inflates the
    // live count past the bound.
    const limits: session.SessionLimits = .{ .max_deposited_gifts = 2 };

    try registry.deposit(allocator, limits, null, "gift-a", "recipient");
    try registry.deposit(allocator, limits, null, "gift-b", "recipient");
    const withdraw_a = makeReceive("gift-a", "recipient", &session_a, 1);
    try validate(&registry, withdraw_a);
    _ = try apply(&registry, allocator, withdraw_a); // a consumed, one slot free
    try registry.deposit(allocator, limits, null, "gift-c", "recipient"); // fills the free slot
    // Re-depositing the consumed gift-a would push live gifts to three; the cap
    // refuses it just as it refuses any third live deposit.
    try std.testing.expectError(
        session.Error.DepositedGiftCapExceeded,
        registry.deposit(allocator, limits, null, "gift-a", "recipient"),
    );
}

test "each session registry commits one monotonic emitted handoff count" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator, null);

    // A fresh receiving session starts at 0 and rises by one per withdrawal,
    // the recipient-side mirror of the accepted-count replay guard, so the count
    // this node emits is exactly the count the exporter's `validateWithdraw`
    // expects next.
    const first = try registry.prepareEmittedCount();
    const duplicate = try registry.prepareEmittedCount();
    try std.testing.expectEqual(@as(u64, 0), first.count);
    try std.testing.expectEqual(@as(u64, 0), duplicate.count);
    try first.commit();
    try std.testing.expectError(error.StaleHandoffCountPreparation, duplicate.commit());

    const second = try registry.prepareEmittedCount();
    try std.testing.expectEqual(@as(u64, 1), second.count);
    try second.commit();
    try std.testing.expectEqual(@as(u64, 2), (try registry.prepareEmittedCount()).count);
}

test "an issuer-bound handoff count refuses a tampered preparation" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator, null);

    var fabricated = try registry.prepareEmittedCount();
    fabricated.count = 9;
    try std.testing.expectError(error.StaleHandoffCountPreparation, fabricated.commit());
    try std.testing.expectEqual(@as(u64, 0), (try registry.prepareEmittedCount()).count);
}

test "a receive naming a session other than the derived one is refused" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator, null);
    try registry.deposit(allocator, default_limits, null, "gift-1", "recipient-key");

    // `expected_receiver` names `session_a`; this receive names another session.
    // An exporter that knows its own key holds the receive to the pair it
    // actually belongs to.
    const elsewhere = name32("some-other-session");
    try std.testing.expectError(
        session.Error.InvalidHandoffSession,
        validate(&registry, makeReceive("gift-1", "recipient-key", &elsewhere, 1)),
    );
    try std.testing.expect(registry.giftLive("gift-1"));
}

test "an unkeyed exporter still keys the counter by the derived side" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator, null);
    try registry.deposit(allocator, default_limits, null, "gift-1", "recipient-key");

    // With no session key of its own, the exporter cannot say which session the
    // receive belongs to, so it does not check that name. The side it derives
    // from the give is what keys the counter, so the guard still holds.
    const unkeyed: engine.handoff_names.ExpectedReceiver = .{ .side = recipient_side, .session = null };
    const anywhere = name32("any-session-at-all");
    const first = makeReceive("gift-1", "recipient-key", &anywhere, 7);
    try registry.validateWithdraw(first, unkeyed);
    _ = try registry.applyWithdraw(&registry, allocator, null, first);

    try registry.deposit(allocator, default_limits, null, "gift-2", "recipient-key");
    try std.testing.expectError(
        session.Error.HandoffReplay,
        registry.validateWithdraw(makeReceive("gift-2", "recipient-key", &anywhere, 7), unkeyed),
    );
}

test "a receive naming the wrong side is refused" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator, null);
    try registry.deposit(allocator, default_limits, null, "gift-1", "recipient-key");

    const other_side: engine.handoff_names.ExpectedReceiver = .{
        .session = session_a,
        .side = name32("somebody-else"),
    };
    try std.testing.expectError(
        session.Error.InvalidHandoffSession,
        registry.validateWithdraw(makeReceive("gift-1", "recipient-key", &session_a, 1), other_side),
    );
    try std.testing.expect(registry.giftLive("gift-1"));
}

test "the exporter derives the receiver names the recipient signs" {
    // The recipient builds a receive naming `sessionName(our side, exporter
    // side)` and its own side; the exporter checks the receive against names it
    // derives from the give's recipient key and its own session key. The two
    // derivations have to agree or every honest handoff breaks, so pin them
    // against each other rather than against a copied constant.
    const recipient = crypto.SecretKey.fromSeed(@as([32]u8, @splat(0x11))).publicKey();
    const exporter = crypto.SecretKey.fromSeed(@as([32]u8, @splat(0x22))).publicKey();

    const recipient_side_name = try engine.handoff_recipient.sideName(recipient.asBytes());
    const exporter_side_name = try engine.handoff_recipient.sideName(exporter.asBytes());
    const as_recipient_builds_it = engine.handoff_recipient.sessionName(recipient_side_name, exporter_side_name);

    const as_exporter_checks_it = try engine.handoff_names.ExpectedReceiver.derive(
        recipient.asBytes(),
        exporter.asBytes(),
    );

    try std.testing.expectEqualSlices(u8, &as_recipient_builds_it, &as_exporter_checks_it.session.?);
    try std.testing.expectEqualSlices(u8, &recipient_side_name, &as_exporter_checks_it.side);

    // Without a key of its own the exporter derives the same side and declines
    // to claim a session name, rather than guessing one.
    const unkeyed = try engine.handoff_names.ExpectedReceiver.fromPartner(recipient.asBytes());
    try std.testing.expectEqualSlices(u8, &recipient_side_name, &unkeyed.side);
    try std.testing.expect(unkeyed.session == null);
}

test "a non-key-width handoff key is refused rather than derived from" {
    try std.testing.expectError(
        error.MalformedKey,
        engine.handoff_names.ExpectedReceiver.derive("short", &(@as([32]u8, @splat(0x22)))),
    );
    try std.testing.expectError(
        error.MalformedKey,
        engine.handoff_names.ExpectedReceiver.derive(&(@as([32]u8, @splat(0x11))), "short"),
    );
}

test "a gifted near with no published name is refused at deposit" {
    const allocator = std.testing.allocator;
    const peer_fixture = @import("../support/peer_fixture.zig");
    const cross_peer = @import("../support/cross_peer.zig");

    // The gifter and the exporter, wired so the deposit crosses a real wire.
    var gifter = peer_fixture.openPeer(allocator);
    defer gifter.deinit();
    var exporter = peer_fixture.openPeer(allocator);
    defer exporter.deinit();

    // A near names an export position, and a position means whatever the
    // session reading it says it means. The withdraw lands on the recipient's
    // session, where this number belongs to nobody: accepting the deposit
    // would have the exporter hand out a reference into another session's
    // range, mint an export row for it there, and drag that session's
    // allocator past the end of its own range.
    // The gifter holds the exporter's object as an import; the exporter reads
    // that same reference back as one of its own exports.
    const gift_id = @as([model.HANDOFF_GIFT_ID_BYTES]u8, @splat(0x71));
    try exporter.session_state.registerExport(.from(9));
    try gifter.session_state.registerImport(.from(9));
    try gifter.sendDepositGift(&gift_id, .{ .far = model.FarRef.object(9) });
    try std.testing.expectError(error.InvalidGift, cross_peer.pumpAll(&gifter, &exporter));

    // The accepted side of this rule — a deposit whose gifted near does carry
    // a swissnum — is what every live handoff step exercises end to end
    // (`goblins-handoff`, `goblins-gift`, `deno-gifter-handoff`), so it is not
    // restated here against a hand-built session.
}

test "a gifted far is refused at deposit rather than at the recipient's expense" {
    const allocator = std.testing.allocator;
    const peer_fixture = @import("../support/peer_fixture.zig");
    const cross_peer = @import("../support/cross_peer.zig");

    var gifter = peer_fixture.openPeer(allocator);
    defer gifter.deinit();
    var exporter = peer_fixture.openPeer(allocator);
    defer exporter.deinit();

    // The mirror of the near rule above, from the import side. The gifter
    // gifts one of its *own* exports, so the exporter reads it back as a far:
    // an object the gifter hosts, which this exporter cannot serve to anybody.
    // Handed back verbatim on the recipient's session it would name an export
    // that session never made.
    const gift_id = @as([model.HANDOFF_GIFT_ID_BYTES]u8, @splat(0x72));
    try gifter.session_state.registerExport(.from(9));
    try gifter.sendDepositGift(&gift_id, .{ .near = model.NearRef.object(9) });
    try std.testing.expectError(error.InvalidGift, cross_peer.pumpAll(&gifter, &exporter));

    // Refusing at the deposit is what puts the refusal on the gifter's own
    // session. Left for the withdraw responder to discover, the same gift
    // would abort the *recipient's* session instead, which is a seam a gifter
    // could aim deliberately.
    try std.testing.expect(!exporter.giftRegistry().giftLive(&gift_id));
}

test "two gifters reusing one gift id keep separate rows" {
    const allocator = std.testing.allocator;
    // Gift ids are unique only within the Gifter–Exporter session. Separate
    // session registries make reuse structural rather than adding another
    // gifter dimension to every row.
    var alice_registry: GiftRegistry = .{};
    defer alice_registry.deinit(allocator, null);
    var bob_registry: GiftRegistry = .{};
    defer bob_registry.deinit(allocator, null);

    const from_alice = model.Reference{ .broken = .{ .message = try allocator.dupe(u8, "alice's") } };
    try alice_registry.depositOwned(allocator, default_limits, null, "my-gift", from_alice);
    const from_bob = model.Reference{ .broken = .{ .message = try allocator.dupe(u8, "bob's") } };
    try bob_registry.depositOwned(allocator, default_limits, null, "my-gift", from_bob);

    try std.testing.expectEqualStrings("alice's", alice_registry.giftedCap("my-gift").?.broken.message);
    try std.testing.expectEqualStrings("bob's", bob_registry.giftedCap("my-gift").?.broken.message);
}
