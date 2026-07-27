//! Authority tests for the vat-scoped `engine.bootstrap.GiftRegistry`
//! (ADR-0056): deposit / withdraw bookkeeping, recipient match, monotonic
//! handoff-count replay rejection, re-deposit replacement, and the ADR-0025
//! resource caps. Gift withdrawal moves authority only behind signature
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

const GiftRegistry = engine.bootstrap.GiftRegistry;

/// A synthetic 32-byte receiver name from a short label. The exporter checks an
/// inbound receive against names it derives from session keys, and a derived
/// name is always 32 bytes, so a fixture that wants to reach the registry's gift
/// and replay logic has to carry names of that width.
fn name32(label: []const u8) [32]u8 {
    var out = [_]u8{0} ** 32;
    @memcpy(out[0..label.len], label);
    return out;
}

const session_a = name32("session-a");
const session_1 = name32("session-1");
const session_2 = name32("session-2");
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
    limits: session.SessionLimits,
    receive: model.HandoffReceive,
) !?model.Reference {
    return registry.applyWithdraw(allocator, limits, receive, expected_receiver);
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

test "registry deposits a gift and accepts a matching withdrawal" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);

    try registry.deposit(allocator, default_limits, "gift-1", "recipient-key", "");
    try std.testing.expect(registry.giftLive("gift-1"));

    const receive = makeReceive("gift-1", "recipient-key", &session_a, 1);
    try validate(&registry, receive);
    _ = try apply(&registry, allocator, default_limits, receive);
    try std.testing.expect(!registry.giftLive("gift-1"));
}

test "the generic inbound path moves no gift-withdrawal authority" {
    const allocator = std.testing.allocator;
    var exporter = engine.Peer.init(allocator);
    defer exporter.deinit();

    try exporter.giftRegistry().deposit(
        allocator,
        exporter.session_state.limits,
        "gift-1",
        "recipient-key",
        "",
    );
    // A top-level handoff frame on the generic recv path (the surface a hostile
    // socket peer reaches directly) must never burn a deposited gift: no
    // Ed25519 check has run here. The session validates well-formedness only and
    // holds no gift state, so the registry row stays untouched.
    try exporter.session_state.recordRecv(.{
        .handoff = .{ .receive = makeReceive("gift-1", "recipient-key", &session_a, 1) },
    });
    try std.testing.expect(exporter.giftRegistry().giftLive("gift-1"));
}

test "registry rejects withdrawal of an unknown gift" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);

    try std.testing.expectError(
        session.Error.InvalidGift,
        validate(&registry, makeReceive("ghost-gift", "recipient-key", &session_a, 1)),
    );
}

test "registry rejects withdrawal with a mismatched recipient key" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);
    try registry.deposit(allocator, default_limits, "gift-1", "recipient-key", "");

    try std.testing.expectError(
        session.Error.InvalidGift,
        validate(&registry, makeReceive("gift-1", "imposter-key", &session_a, 1)),
    );
    try std.testing.expect(registry.giftLive("gift-1"));
}

test "registry rejects a replayed or out-of-order handoff count" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);
    try registry.deposit(allocator, default_limits, "gift-1", "recipient-key", "");
    try registry.deposit(allocator, default_limits, "gift-2", "recipient-key", "");

    const first = makeReceive("gift-1", "recipient-key", &session_a, 2);
    try validate(&registry, first);
    _ = try apply(&registry, allocator, default_limits, first);

    try std.testing.expectError(
        session.Error.HandoffReplay,
        validate(&registry, makeReceive("gift-2", "recipient-key", &session_a, 1)),
    );
    try std.testing.expect(registry.giftLive("gift-2"));
}

test "a withdrawn gift cannot be withdrawn twice" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);

    try registry.deposit(allocator, default_limits, "gift-1", "recipient-key", "");
    const first = makeReceive("gift-1", "recipient-key", &session_a, 1);
    try validate(&registry, first);
    _ = try apply(&registry, allocator, default_limits, first);

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
    defer registry.deinit(allocator);

    // Both deposited capabilities carry heap (a broken ref owns its message), so
    // the testing allocator proves the first is freed on overwrite, a leak or a
    // double free fails this test.
    const first = model.Reference{ .broken = .{ .message = try allocator.dupe(u8, "first") } };
    try registry.depositOwned(allocator, default_limits, "gift-1", first, "gifter-key-a");

    const second = model.Reference{ .broken = .{ .message = try allocator.dupe(u8, "second") } };
    try registry.depositOwned(allocator, default_limits, "gift-1", second, "gifter-key-b");

    // The replacement also swaps the provenance: a withdraw now yields the
    // second capability under the second gifter key.
    try std.testing.expectEqualStrings("gifter-key-b", registry.giftGifterKey("gift-1").?);
    try std.testing.expectEqualStrings("second", registry.giftedCap("gift-1").?.broken.message);
}

test "a re-deposit after withdrawal re-arms the gift" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);

    try registry.deposit(allocator, default_limits, "gift-1", "recipient-key", "");
    const first = makeReceive("gift-1", "recipient-key", &session_a, 1);
    try validate(&registry, first);
    _ = try apply(&registry, allocator, default_limits, first);
    try std.testing.expect(!registry.giftLive("gift-1"));

    // Re-authorizing the same gift id replaces the consumed row. Replay stays
    // blocked by the monotonic handoff count, not by refusing the deposit: the
    // first certificate cannot be presented again, but a fresh higher-count
    // receive withdraws the re-armed gift.
    try registry.deposit(allocator, default_limits, "gift-1", "recipient-key", "");
    try std.testing.expect(registry.giftLive("gift-1"));
    try std.testing.expectError(
        session.Error.HandoffReplay,
        validate(&registry, makeReceive("gift-1", "recipient-key", &session_a, 1)),
    );
    const fresh = makeReceive("gift-1", "recipient-key", &session_a, 2);
    try validate(&registry, fresh);
    _ = try apply(&registry, allocator, default_limits, fresh);
    try std.testing.expect(!registry.giftLive("gift-1"));
}

test "deposited gifts are bounded by max_deposited_gifts (ADR-0025)" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);
    const limits: session.SessionLimits = .{ .max_deposited_gifts = 1 };

    try registry.deposit(allocator, limits, "gift-a", "recipient", "");
    try std.testing.expectError(
        session.Error.DepositedGiftCapExceeded,
        registry.deposit(allocator, limits, "gift-b", "recipient", ""),
    );
    try std.testing.expect(registry.giftLive("gift-a"));
    try std.testing.expect(!registry.giftLive("gift-b"));
}

test "consumed gifts do not count toward max_deposited_gifts" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);
    // A registry that has already served max_deposited_gifts *completed*
    // handoffs must keep accepting new deposits: a spent gift no longer counts.
    const limits: session.SessionLimits = .{ .max_deposited_gifts = 1 };

    var buf: [8]u8 = undefined;
    var i: u64 = 0;
    while (i < 5) : (i += 1) {
        const id = try std.fmt.bufPrint(&buf, "gift-{d}", .{i});
        // Only one gift is ever live at a time, so a cap of 1 admits every
        // deposit once its predecessor has been withdrawn.
        try registry.deposit(allocator, limits, id, "recipient", "");
        const receive = makeReceive(id, "recipient", &session_a, i + 1);
        try validate(&registry, receive);
        _ = try apply(&registry, allocator, limits, receive);
    }
}

test "re-arming a consumed gift still respects max_deposited_gifts" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);
    // The live-gift cap must hold across re-arm: consuming a gift and re-depositing
    // its id is a fresh row through the cap check, not a bypass that inflates the
    // live count past the bound.
    const limits: session.SessionLimits = .{ .max_deposited_gifts = 2 };

    try registry.deposit(allocator, limits, "gift-a", "recipient", "");
    try registry.deposit(allocator, limits, "gift-b", "recipient", "");
    const withdraw_a = makeReceive("gift-a", "recipient", &session_a, 1);
    try validate(&registry, withdraw_a);
    _ = try apply(&registry, allocator, limits, withdraw_a); // a consumed, one slot free
    try registry.deposit(allocator, limits, "gift-c", "recipient", ""); // fills the free slot
    // Re-depositing the consumed gift-a would push live gifts to three; the cap
    // refuses it just as it refuses any third live deposit.
    try std.testing.expectError(
        session.Error.DepositedGiftCapExceeded,
        registry.deposit(allocator, limits, "gift-a", "recipient", ""),
    );
}

test "the registry mints monotonic emitted handoff counts per receiving session" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);

    // A fresh receiving session starts at 0 and rises by one per withdrawal,
    // the recipient-side mirror of the accepted-count replay guard, so the count
    // this node emits is exactly the count the exporter's `validateWithdraw`
    // expects next.
    try std.testing.expectEqual(@as(u64, 0), try registry.nextEmittedCount(allocator, default_limits, &session_a));
    try std.testing.expectEqual(@as(u64, 1), try registry.nextEmittedCount(allocator, default_limits, &session_a));
    try std.testing.expectEqual(@as(u64, 2), try registry.nextEmittedCount(allocator, default_limits, &session_a));

    // Counters are per receiving session: a second exporter session starts fresh.
    try std.testing.expectEqual(@as(u64, 0), try registry.nextEmittedCount(allocator, default_limits, "session-b"));
    try std.testing.expectEqual(@as(u64, 3), try registry.nextEmittedCount(allocator, default_limits, &session_a));
}

test "emitted-handoff-count rows are bounded by max_seen_handoff_counts (ADR-0025)" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);
    const limits: session.SessionLimits = .{ .max_seen_handoff_counts = 1 };

    // The first receiving session allocates the one permitted row; a second
    // distinct session overflows it, the same cap its accepted-count mirror holds.
    _ = try registry.nextEmittedCount(allocator, limits, &session_1);
    _ = try registry.nextEmittedCount(allocator, limits, &session_1);
    try std.testing.expectError(
        session.Error.HandoffCountCapExceeded,
        registry.nextEmittedCount(allocator, limits, &session_2),
    );
}

test "seen-handoff-count rows are bounded by max_seen_handoff_counts (ADR-0025)" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);
    const limits: session.SessionLimits = .{ .max_seen_handoff_counts = 1 };

    // Two gifts so two distinct recipients can withdraw. A row is keyed by the
    // recipient's derived side name, so distinct recipients are what grow the
    // table, and one recipient cannot grow it at all.
    try registry.deposit(allocator, limits, "gift-a", "recipient", "");
    try registry.deposit(allocator, limits, "gift-b", "recipient", "");

    const first: engine.handoff_names.ExpectedReceiver = .{ .side = name32("recipient-1"), .session = session_1 };
    const second: engine.handoff_names.ExpectedReceiver = .{ .side = name32("recipient-2"), .session = session_2 };

    // The replay-tracking table grows through the verified withdraw apply, so
    // drive it the way `resolveForWithdraw` and the test-support withdraw
    // harness (`test/support/cross_peer.zig`) do.
    _ = try registry.applyWithdraw(
        allocator,
        limits,
        makeReceive("gift-a", "recipient", &session_1, 1),
        first,
    );
    try std.testing.expectError(
        session.Error.HandoffCountCapExceeded,
        registry.applyWithdraw(
            allocator,
            limits,
            makeReceive("gift-b", "recipient", &session_2, 1),
            second,
        ),
    );
}

test "one peer's maxed-out handoff count cannot refuse another peer's handoffs" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);

    // The registry is shared by every session on the host, so the replay counter
    // has to be keyed by something the withdrawing peer cannot choose. A peer
    // holding both the gifter and the recipient key satisfies both signature
    // checks with a gift it deposited itself, so signatures alone constrain
    // nothing about the name it writes: here it withdraws at the highest count
    // there is, which would be a permanent refusal for anyone sharing its row.
    try registry.deposit(allocator, default_limits, "attacker-gift", "recipient-key", "");
    const attacker_side = name32("attacker-side");
    const named_session = name32("victim-and-exporter");
    const attacker: engine.handoff_names.ExpectedReceiver = .{
        .side = attacker_side,
        .session = named_session,
    };
    const maxed = makeReceiveAs(
        "attacker-gift",
        "recipient-key",
        &attacker_side,
        &named_session,
        std.math.maxInt(u64),
    );
    try registry.validateWithdraw(maxed, attacker);
    _ = try registry.applyWithdraw(allocator, default_limits, maxed, attacker);

    // The row it wrote is its own — keyed by its derived side, not by the
    // session name it named — so another peer's very first withdraw, at the
    // lowest count a fresh session mints, still lands.
    try registry.deposit(allocator, default_limits, "victim-gift", "recipient-key", "");
    const honest = makeReceive("victim-gift", "recipient-key", &session_a, 1);
    try validate(&registry, honest);
    _ = try apply(&registry, allocator, default_limits, honest);
    try std.testing.expect(!registry.giftLive("victim-gift"));
}

test "a receive naming a session other than the derived one is refused" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);
    try registry.deposit(allocator, default_limits, "gift-1", "recipient-key", "");

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
    defer registry.deinit(allocator);
    try registry.deposit(allocator, default_limits, "gift-1", "recipient-key", "");

    // With no session key of its own, the exporter cannot say which session the
    // receive belongs to, so it does not check that name. The side it derives
    // from the give is what keys the counter, so the guard still holds.
    const unkeyed: engine.handoff_names.ExpectedReceiver = .{ .side = recipient_side, .session = null };
    const anywhere = name32("any-session-at-all");
    const first = makeReceive("gift-1", "recipient-key", &anywhere, 7);
    try registry.validateWithdraw(first, unkeyed);
    _ = try registry.applyWithdraw(allocator, default_limits, first, unkeyed);

    try registry.deposit(allocator, default_limits, "gift-2", "recipient-key", "");
    try std.testing.expectError(
        session.Error.HandoffReplay,
        registry.validateWithdraw(makeReceive("gift-2", "recipient-key", &anywhere, 7), unkeyed),
    );
}

test "a receive naming the wrong side is refused" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);
    try registry.deposit(allocator, default_limits, "gift-1", "recipient-key", "");

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
    const recipient = crypto.SecretKey.fromSeed([_]u8{0x11} ** 32).publicKey();
    const exporter = crypto.SecretKey.fromSeed([_]u8{0x22} ** 32).publicKey();

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
        engine.handoff_names.ExpectedReceiver.derive("short", &([_]u8{0x22} ** 32)),
    );
    try std.testing.expectError(
        error.MalformedKey,
        engine.handoff_names.ExpectedReceiver.derive(&([_]u8{0x11} ** 32), "short"),
    );
}
