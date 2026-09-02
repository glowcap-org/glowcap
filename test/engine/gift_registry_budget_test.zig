//! Retained-byte admission and transactional ownership for deposited gifts.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const session = glowcap.ocapn.session;
const LiveBytesAllocator = @import("../support/alloc_metrics.zig").LiveBytesAllocator;

const GiftRegistry = engine.bootstrap.gifts.GiftRegistry;

fn limitsForBytes(bytes: usize) session.SessionLimits {
    var limits: session.SessionLimits = .{};
    limits.max_deposited_gift_bytes = @intCast(bytes);
    return limits;
}

fn ownedBroken(allocator: std.mem.Allocator, message: []const u8) !model.Reference {
    return .{ .broken = .{ .message = try allocator.dupe(u8, message) } };
}

fn makeReceive(gift_id: []const u8, recipient_key: []const u8, count: u64) model.HandoffReceive {
    return .{
        .receiving_session = "receiver-session",
        .receiving_side = "receiver-side",
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

test "retained-byte admission saturates on a whole new row" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator, null);

    try registry.deposit(allocator, .{}, null, "a", "r");
    const first_charge = registry.retainedBytes();
    const limits = limitsForBytes(first_charge);

    try std.testing.expectError(
        session.Error.DepositedGiftCapExceeded,
        registry.deposit(allocator, limits, null, "b", "r"),
    );
    try std.testing.expect(registry.giftLive("a"));
    try std.testing.expect(!registry.giftLive("b"));
    try std.testing.expectEqual(first_charge, registry.retainedBytes());
}

test "row-count admission remains independent of replacement" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator, null);
    var limits: session.SessionLimits = .{};
    limits.max_deposited_gifts = 1;

    try registry.deposit(allocator, limits, null, "a", "old");
    try std.testing.expectError(
        session.Error.DepositedGiftCapExceeded,
        registry.deposit(allocator, limits, null, "b", "new"),
    );
    try registry.deposit(allocator, limits, null, "a", "replacement");
    try std.testing.expect(registry.giftLive("a"));
    try std.testing.expect(!registry.giftLive("b"));
}

test "replacement growth refusal preserves the old row and caller authority" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var registry: GiftRegistry = .{};
    defer {
        failing.fail_index = std.math.maxInt(usize);
        registry.deinit(allocator, null);
    }

    const old = try ownedBroken(allocator, "old");
    try registry.depositOwned(allocator, .{}, null, "gift", old);
    const old_charge = registry.retainedBytes();

    const incoming = try ownedBroken(allocator, "a much larger replacement");
    defer model.freeReference(allocator, incoming);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        session.Error.DepositedGiftCapExceeded,
        registry.depositOwned(allocator, limitsForBytes(old_charge), null, "gift", incoming),
    );
    try std.testing.expectEqualStrings("old", registry.giftedCap("gift").?.broken.message);
    try std.testing.expectEqual(old_charge, registry.retainedBytes());
}

test "replacement shrink releases the exact variable reference payload charge" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator, null);

    const large_message = "a retained variable-sized broken-reference message";
    const small_message = "small";
    const large = try ownedBroken(allocator, large_message);
    try registry.depositOwned(allocator, .{}, null, "gift", large);
    const before = registry.retainedBytes();

    const small = try ownedBroken(allocator, small_message);
    try registry.depositOwned(allocator, .{}, null, "gift", small);
    const after = registry.retainedBytes();

    try std.testing.expectEqual(large_message.len - small_message.len, before - after);
    try std.testing.expectEqualStrings(small_message, registry.giftedCap("gift").?.broken.message);
}

test "withdraw releases the row budget and accepts the full u64 count domain" {
    var live = LiveBytesAllocator{ .backing = std.testing.allocator };
    const allocator = live.allocator();
    var registry: GiftRegistry = .{};
    defer registry.deinit(allocator, null);
    const baseline = live.liveBytes();

    // V1 gift ids are opaque nonempty bytes. Keep both a suite-style short id
    // and the smallest possible id pinned independently of the next profile's
    // 32-byte validation at the bootstrap boundary.
    try registry.deposit(allocator, .{}, null, "x", "recipient");
    const charge = registry.retainedBytes();
    try std.testing.expect(live.liveBytes() > baseline);
    const receive = makeReceive("x", "recipient", std.math.maxInt(u64));
    try registry.validateWithdraw(receive, null);
    _ = try registry.applyWithdraw(&registry, allocator, null, receive);

    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), registry.acceptedHandoffCount());
    try std.testing.expectEqual(@as(usize, 0), registry.retainedBytes());
    try std.testing.expect(!registry.giftLive("x"));
    try std.testing.expectEqual(baseline, live.liveBytes());

    try registry.deposit(allocator, limitsForBytes(charge + 16), null, "gift-v1", "recipient");
    try std.testing.expect(registry.giftLive("gift-v1"));
    try std.testing.expectError(
        session.Error.HandoffReplay,
        registry.validateWithdraw(makeReceive("gift-v1", "recipient", std.math.maxInt(u64)), null),
    );
}

test "replacement allocation failure preserves authority and accounting" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var registry: GiftRegistry = .{};
    defer {
        failing.fail_index = std.math.maxInt(usize);
        registry.deinit(allocator, null);
    }

    try registry.deposit(allocator, .{}, null, "gift", "old recipient");
    const old_charge = registry.retainedBytes();
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        registry.deposit(allocator, .{}, null, "gift", "new recipient"),
    );
    try std.testing.expectEqual(old_charge, registry.retainedBytes());
    try registry.validateWithdrawGift(makeReceive("gift", "old recipient", 0));
    try std.testing.expectError(
        session.Error.InvalidGift,
        registry.validateWithdrawGift(makeReceive("gift", "new recipient", 0)),
    );
}

test "every first-insert allocation failure leaves caller authority unadopted" {
    var fail_offset: usize = 0;
    var reached_success = false;
    while (fail_offset < 8 and !reached_success) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const allocator = failing.allocator();
        var registry: GiftRegistry = .{};
        const gifted = try ownedBroken(allocator, "caller-owned until commit");
        var transferred = false;
        defer {
            failing.fail_index = std.math.maxInt(usize);
            registry.deinit(allocator, null);
            if (!transferred) model.freeReference(allocator, gifted);
        }

        failing.fail_index = failing.alloc_index + fail_offset;
        if (registry.depositOwned(allocator, .{}, null, "gift", gifted)) |_| {
            transferred = true;
            reached_success = true;
            try std.testing.expect(registry.giftLive("gift"));
            try std.testing.expect(registry.retainedBytes() > 0);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(!registry.giftLive("gift"));
            try std.testing.expectEqual(@as(usize, 0), registry.retainedBytes());
            try std.testing.expectEqualStrings("caller-owned until commit", gifted.broken.message);
        }
    }
    try std.testing.expect(reached_success);
}

test "deinit releases every retained row and resets accounting" {
    const allocator = std.testing.allocator;
    var registry: GiftRegistry = .{};
    try registry.deposit(allocator, .{}, null, "one", "recipient");
    const broken = try ownedBroken(allocator, "variable payload");
    try registry.depositOwned(allocator, .{}, null, "two", broken);
    try std.testing.expect(registry.retainedBytes() > 0);

    registry.deinit(allocator, null);
    try std.testing.expectEqual(@as(usize, 0), registry.retainedBytes());
    registry.deinit(allocator, null);
}
