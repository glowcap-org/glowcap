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

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const session = pancake.ocapn.session;

const GiftRegistry = engine.bootstrap.GiftRegistry;

fn makeReceive(
    gift_id: []const u8,
    recipient_key: []const u8,
    session_id: []const u8,
    count: u64,
) model.HandoffReceive {
    return .{
        .receiving_session = session_id,
        .receiving_side = "recipient-side",
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

    const receive = makeReceive("gift-1", "recipient-key", "session-a", 1);
    try registry.validateWithdraw(receive);
    _ = try registry.applyWithdraw(allocator, default_limits, receive);
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
        .handoff = .{ .receive = makeReceive("gift-1", "recipient-key", "session-a", 1) },
    });
    try std.testing.expect(exporter.giftRegistry().giftLive("gift-1"));
}

test "registry rejects withdrawal of an unknown gift" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);

    try std.testing.expectError(
        session.Error.InvalidGift,
        registry.validateWithdraw(makeReceive("ghost-gift", "recipient-key", "session-a", 1)),
    );
}

test "registry rejects withdrawal with a mismatched recipient key" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);
    try registry.deposit(allocator, default_limits, "gift-1", "recipient-key", "");

    try std.testing.expectError(
        session.Error.InvalidGift,
        registry.validateWithdraw(makeReceive("gift-1", "imposter-key", "session-a", 1)),
    );
    try std.testing.expect(registry.giftLive("gift-1"));
}

test "registry rejects a replayed or out-of-order handoff count" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);
    try registry.deposit(allocator, default_limits, "gift-1", "recipient-key", "");
    try registry.deposit(allocator, default_limits, "gift-2", "recipient-key", "");

    const first = makeReceive("gift-1", "recipient-key", "session-a", 2);
    try registry.validateWithdraw(first);
    _ = try registry.applyWithdraw(allocator, default_limits, first);

    try std.testing.expectError(
        session.Error.HandoffReplay,
        registry.validateWithdraw(makeReceive("gift-2", "recipient-key", "session-a", 1)),
    );
    try std.testing.expect(registry.giftLive("gift-2"));
}

test "a withdrawn gift cannot be withdrawn twice" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);

    try registry.deposit(allocator, default_limits, "gift-1", "recipient-key", "");
    const first = makeReceive("gift-1", "recipient-key", "session-a", 1);
    try registry.validateWithdraw(first);
    _ = try registry.applyWithdraw(allocator, default_limits, first);

    // A fresh signed receive with a higher handoff count is not a replay, so
    // the refusal here is the consumed gift's row being gone: a gift is spent
    // exactly once, even across an otherwise-valid second certificate.
    try std.testing.expectError(
        session.Error.InvalidGift,
        registry.validateWithdraw(makeReceive("gift-1", "recipient-key", "session-a", 2)),
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
    const first = makeReceive("gift-1", "recipient-key", "session-a", 1);
    try registry.validateWithdraw(first);
    _ = try registry.applyWithdraw(allocator, default_limits, first);
    try std.testing.expect(!registry.giftLive("gift-1"));

    // Re-authorizing the same gift id replaces the consumed row. Replay stays
    // blocked by the monotonic handoff count, not by refusing the deposit: the
    // first certificate cannot be presented again, but a fresh higher-count
    // receive withdraws the re-armed gift.
    try registry.deposit(allocator, default_limits, "gift-1", "recipient-key", "");
    try std.testing.expect(registry.giftLive("gift-1"));
    try std.testing.expectError(
        session.Error.HandoffReplay,
        registry.validateWithdraw(makeReceive("gift-1", "recipient-key", "session-a", 1)),
    );
    const fresh = makeReceive("gift-1", "recipient-key", "session-a", 2);
    try registry.validateWithdraw(fresh);
    _ = try registry.applyWithdraw(allocator, default_limits, fresh);
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
        const receive = makeReceive(id, "recipient", "session-a", i + 1);
        try registry.validateWithdraw(receive);
        _ = try registry.applyWithdraw(allocator, limits, receive);
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
    const withdraw_a = makeReceive("gift-a", "recipient", "session-a", 1);
    try registry.validateWithdraw(withdraw_a);
    _ = try registry.applyWithdraw(allocator, limits, withdraw_a); // a consumed, one slot free
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
    try std.testing.expectEqual(@as(u64, 0), try registry.nextEmittedCount(allocator, default_limits, "session-a"));
    try std.testing.expectEqual(@as(u64, 1), try registry.nextEmittedCount(allocator, default_limits, "session-a"));
    try std.testing.expectEqual(@as(u64, 2), try registry.nextEmittedCount(allocator, default_limits, "session-a"));

    // Counters are per receiving session: a second exporter session starts fresh.
    try std.testing.expectEqual(@as(u64, 0), try registry.nextEmittedCount(allocator, default_limits, "session-b"));
    try std.testing.expectEqual(@as(u64, 3), try registry.nextEmittedCount(allocator, default_limits, "session-a"));
}

test "emitted-handoff-count rows are bounded by max_seen_handoff_counts (ADR-0025)" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);
    const limits: session.SessionLimits = .{ .max_seen_handoff_counts = 1 };

    // The first receiving session allocates the one permitted row; a second
    // distinct session overflows it, the same cap its accepted-count mirror holds.
    _ = try registry.nextEmittedCount(allocator, limits, "session-1");
    _ = try registry.nextEmittedCount(allocator, limits, "session-1");
    try std.testing.expectError(
        session.Error.HandoffCountCapExceeded,
        registry.nextEmittedCount(allocator, limits, "session-2"),
    );
}

test "seen-handoff-count rows are bounded by max_seen_handoff_counts (ADR-0025)" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);
    const limits: session.SessionLimits = .{ .max_seen_handoff_counts = 1 };

    // Two gifts so two distinct receiving sessions can withdraw.
    try registry.deposit(allocator, limits, "gift-a", "recipient", "");
    try registry.deposit(allocator, limits, "gift-b", "recipient", "");

    // The replay-tracking table grows through the verified withdraw apply, so
    // drive it the way `resolveForWithdraw` and the test-support withdraw
    // harness (`test/support/cross_peer.zig`) do.
    // First receiving session records a row.
    _ = try registry.applyWithdraw(allocator, limits, makeReceive("gift-a", "recipient", "session-1", 1));
    // A second distinct receiving session overflows the replay-tracking table.
    try std.testing.expectError(
        session.Error.HandoffCountCapExceeded,
        registry.applyWithdraw(allocator, limits, makeReceive("gift-b", "recipient", "session-2", 1)),
    );
}
