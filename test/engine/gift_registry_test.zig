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
            .exporter_location = "memory:exporter",
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
    try std.testing.expect(registry.giftDeposited("gift-1"));
    try std.testing.expect(!registry.giftWithdrawn("gift-1"));

    const receive = makeReceive("gift-1", "recipient-key", "session-a", 1);
    try registry.validateWithdraw(receive);
    try registry.applyWithdraw(allocator, default_limits, receive);
    try std.testing.expect(registry.giftWithdrawn("gift-1"));
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
    try std.testing.expect(!exporter.giftRegistry().giftWithdrawn("gift-1"));
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
    try std.testing.expect(!registry.giftWithdrawn("gift-1"));
}

test "registry rejects a replayed or out-of-order handoff count" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);
    try registry.deposit(allocator, default_limits, "gift-1", "recipient-key", "");
    try registry.deposit(allocator, default_limits, "gift-2", "recipient-key", "");

    const first = makeReceive("gift-1", "recipient-key", "session-a", 2);
    try registry.validateWithdraw(first);
    try registry.applyWithdraw(allocator, default_limits, first);

    try std.testing.expectError(
        session.Error.HandoffReplay,
        registry.validateWithdraw(makeReceive("gift-2", "recipient-key", "session-a", 1)),
    );
    try std.testing.expect(!registry.giftWithdrawn("gift-2"));
}

test "a withdrawn gift cannot be withdrawn twice" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator);

    try registry.deposit(allocator, default_limits, "gift-1", "recipient-key", "");
    const first = makeReceive("gift-1", "recipient-key", "session-a", 1);
    try registry.validateWithdraw(first);
    try registry.applyWithdraw(allocator, default_limits, first);

    // A fresh signed receive with a higher handoff count is not a replay, so
    // the refusal here is the withdrawn flag itself: a gift is spent exactly
    // once, even across an otherwise-valid second certificate.
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
    // the testing allocator proves the first is freed on overwrite — a leak or a
    // double free fails this test.
    const first = model.Reference{ .broken = .{ .message = try allocator.dupe(u8, "first") } };
    try registry.depositOwned(allocator, default_limits, "gift-1", first, "gifter-key-a");

    const second = model.Reference{ .broken = .{ .message = try allocator.dupe(u8, "second") } };
    try registry.depositOwned(allocator, default_limits, "gift-1", second, "gifter-key-b");

    // The replacement also resets the withdrawn flag and the provenance: a
    // withdraw now yields the second capability under the second gifter key.
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
    try registry.applyWithdraw(allocator, default_limits, first);
    try std.testing.expect(registry.giftWithdrawn("gift-1"));

    // Re-authorizing the same gift id replaces the consumed row. Replay stays
    // blocked by the monotonic handoff count, not by refusing the deposit: the
    // first certificate cannot be presented again, but a fresh higher-count
    // receive withdraws the re-armed gift.
    try registry.deposit(allocator, default_limits, "gift-1", "recipient-key", "");
    try std.testing.expect(!registry.giftWithdrawn("gift-1"));
    try std.testing.expectError(
        session.Error.HandoffReplay,
        registry.validateWithdraw(makeReceive("gift-1", "recipient-key", "session-a", 1)),
    );
    const fresh = makeReceive("gift-1", "recipient-key", "session-a", 2);
    try registry.validateWithdraw(fresh);
    try registry.applyWithdraw(allocator, default_limits, fresh);
    try std.testing.expect(registry.giftWithdrawn("gift-1"));
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
    try std.testing.expect(registry.giftDeposited("gift-a"));
    try std.testing.expect(!registry.giftDeposited("gift-b"));
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
    try registry.applyWithdraw(allocator, limits, makeReceive("gift-a", "recipient", "session-1", 1));
    // A second distinct receiving session overflows the replay-tracking table.
    try std.testing.expectError(
        session.Error.HandoffCountCapExceeded,
        registry.applyWithdraw(allocator, limits, makeReceive("gift-b", "recipient", "session-2", 1)),
    );
}
