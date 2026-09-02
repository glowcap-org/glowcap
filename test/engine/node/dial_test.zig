//! The serve step's redeem state machine: acceptGive turns an unknown
//! exporter into one dial action, waiters join on peer identity, alternative
//! locators retry in order on one ticket, cancellation settles every waiter,
//! and a session that never opens fails the redeem closed.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const engine = glowcap.ocapn.engine;
const crypto = glowcap.foundation.crypto;
const LiveBytesAllocator = @import("../../support/alloc_metrics.zig").LiveBytesAllocator;

const Node = engine.Node;

const harness = @import("harness.zig");
const pendingWithdrawAnswer = harness.pendingWithdrawAnswer;
const peerUri = harness.peerUri;
const peerUriWithAlternatives = harness.peerUriWithAlternatives;
const takeWithdrawCount = harness.takeWithdrawCount;
const testGiveBytes = harness.testGiveBytes;
const mintRedeemedRoute = harness.mintRedeemedRoute;
const openKeyedSessionWithCounterpart = harness.openKeyedSessionWithCounterpart;

// ── The serve step: the sans-io redeem state machine ─────────────────────────
//
// These prove the *decisions* the serve step owns — interception, the exporter
// cache, dial dedup, pending withdraws, route settlement, fail-closed arms —
// as data in and actions out, with no socket. The live proof that the same
// step drives a real three-party redeem is `zig build goblins-handoff`.

test "acceptGive with no dialable exporter locator fails the answer closed" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(2)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    try node.acceptGive(recipient, 7, "give-bytes", "");

    const action = node.nextAction().?;
    try std.testing.expectEqual(recipient, action.fail.dest.answer.recipient_peer);
    try std.testing.expectEqual(@as(u64, 7), action.fail.dest.answer.answer.int());
    try std.testing.expectEqualStrings("handoff give names no dialable exporter locator", action.fail.reason.bytes());
    try std.testing.expect(node.nextAction() == null);
}

test "an unknown exporter becomes one dial action; a second give joins it" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(4)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const locator = "ocapn://127.0.0.1%3A9050.tcp";
    try node.acceptGive(recipient, 11, "give-one", locator);
    // A second redeem naming the same exporter joins the pending dial instead
    // of opening a second connection.
    try node.acceptGive(recipient, 12, "give-two", locator);

    const action = node.nextAction().?;
    const join_view = node.pendingDial(action.dial.pending, 0).?;
    try std.testing.expectEqualStrings("tcp", join_view.locator.transport);
    try std.testing.expectEqualStrings("127.0.0.1:9050", join_view.locator.designator);
    try std.testing.expect(node.nextAction() == null);

    // The dial failing breaks both waiting answers, in order.
    _ = try node.dialFailed(action.dial.pending, 0, "connection refused");
    const first = node.nextAction().?;
    try std.testing.expectEqual(@as(u64, 11), first.fail.dest.answer.answer.int());
    try std.testing.expectEqualStrings("handoff redeem failed: connection refused", first.fail.reason.bytes());
    const second = node.nextAction().?;
    try std.testing.expectEqual(@as(u64, 12), second.fail.dest.answer.answer.int());
    try std.testing.expect(node.nextAction() == null);

    // The settled ticket is retired: reporting it again is a no-op.
    _ = try node.dialFailed(action.dial.pending, 0, "late");
    try std.testing.expect(node.nextAction() == null);
}

test "fresh dial ticket exhaustion refuses atomically and remains retryable" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x40)));
    defer node.deinit();

    const locator = "ocapn://127.0.0.1%3A9050.tcp";
    node.actions.next_ticket = std.math.maxInt(u64);
    try std.testing.expectError(error.CapabilitySpaceExhausted, node.stageDial(locator));
    try std.testing.expectEqual(@as(usize, 0), node.pendingDialCount());
    try std.testing.expectEqual(@as(usize, 0), node.redeems.dials.by_identity.count());
    try std.testing.expectEqual(std.math.maxInt(u64), node.actions.next_ticket);
    try std.testing.expect(node.nextAction() == null);

    node.actions.next_ticket = 0;
    const retried = try node.stageDial(locator);
    try std.testing.expectEqual(@as(u64, 0), retried.pending);
    try std.testing.expectEqual(retried.pending, node.nextAction().?.dial.pending);
}

test "fresh give dial ticket exhaustion retains no waiter or action" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x42)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const locator = "ocapn://127.0.0.1%3A9051.tcp";
    node.actions.next_ticket = std.math.maxInt(u64);
    try std.testing.expectError(
        error.CapabilitySpaceExhausted,
        node.acceptGive(recipient, 17, "give", locator),
    );
    try std.testing.expectEqual(@as(usize, 0), node.pendingDialCount());
    try std.testing.expectEqual(@as(usize, 0), node.redeems.dials.by_identity.count());
    try std.testing.expectEqual(
        @as(usize, 0),
        node.redeems.dials.waiter_action_reservations,
    );
    try std.testing.expectEqual(std.math.maxInt(u64), node.actions.next_ticket);
    try std.testing.expect(node.nextAction() == null);

    node.actions.next_ticket = 0;
    try node.acceptGive(recipient, 17, "give", locator);
    try std.testing.expectEqual(@as(u64, 0), node.nextAction().?.dial.pending);
}

test "cache hits and identity joins mint no pending ticket" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x43)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const locator = "ocapn://127.0.0.1%3A9052.tcp";
    const first_give = try testGiveBytes(allocator);
    defer allocator.free(first_give);
    const second_give = try testGiveBytes(allocator);
    defer allocator.free(second_give);
    const third_give = try testGiveBytes(allocator);
    defer allocator.free(third_give);
    try node.acceptGive(recipient, 18, first_give, locator);
    const pending = node.nextAction().?.dial.pending;
    node.actions.next_ticket = std.math.maxInt(u64);

    // The second give joins the existing canonical-identity row; max is still
    // the unissued sentinel and no second dial action appears.
    try node.acceptGive(recipient, 19, second_give, locator);
    try std.testing.expectEqual(std.math.maxInt(u64), node.actions.next_ticket);
    try std.testing.expectEqual(@as(usize, 1), node.pendingDialCount());
    try std.testing.expect(node.nextAction() == null);

    const exporter = try node.registerPeer(.{});
    var counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(exporter).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x44)),
    );
    defer counterpart.deinit();
    _ = try node.exporterDialed(pending, 0, exporter);
    try std.testing.expectEqual(exporter, node.nextAction().?.flush);
    try std.testing.expectEqual(exporter, node.nextAction().?.flush);

    // The live cache likewise starts a withdrawal without minting a ticket.
    try node.acceptGive(recipient, 20, third_give, locator);
    try std.testing.expectEqual(std.math.maxInt(u64), node.actions.next_ticket);
    try std.testing.expectEqual(exporter, node.nextAction().?.flush);
}

test "owner cancellation settles every queued dial waiter without allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x44)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const locator = "ocapn://127.0.0.1%3A9050.tcp";
    try node.acceptGive(recipient, 21, "give-one", locator);
    try node.acceptGive(recipient, 22, "give-two", locator);

    failing.fail_index = failing.alloc_index;
    var cancellations = node.requestDialCancellations();
    try std.testing.expect(cancellations.next() == null);
    try std.testing.expectEqual(@as(usize, 0), node.pendingDialCount());

    // The queued dial is now stale and is discarded by the action boundary.
    // Its two terminal consequences still follow in admission order and
    // required no close-time allocation.
    const first = node.nextAction().?;
    const second = node.nextAction().?;
    try std.testing.expectEqual(@as(u64, 21), first.fail.dest.answer.answer.int());
    try std.testing.expectEqual(@as(u64, 22), second.fail.dest.answer.answer.int());
    try std.testing.expectEqualStrings("handoff redeem failed: host closing", first.fail.reason.bytes());
    try std.testing.expect(node.nextAction() == null);
}

test "owner cancellation settles in-flight dial waiters once before physical join" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x45)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const locator = "ocapn://127.0.0.1%3A9050.tcp";
    try node.acceptGive(recipient, 31, "give-one", locator);
    try node.acceptGive(recipient, 32, "give-two", locator);
    const dial = node.nextAction().?;
    const ticket = dial.dial.pending;

    var cancellations = node.requestDialCancellations();
    const cancellation = cancellations.next().?;
    try std.testing.expectEqual(ticket, cancellation.pending);
    try std.testing.expectEqual(@as(usize, 0), cancellation.route_index);
    try std.testing.expect(cancellations.next() == null);
    try std.testing.expectEqual(@as(usize, 1), node.pendingDialCount());
    try std.testing.expect(node.pendingDial(ticket, 0) == null);

    const first = node.nextAction().?;
    const second = node.nextAction().?;
    try std.testing.expectEqual(@as(u64, 31), first.fail.dest.answer.answer.int());
    try std.testing.expectEqual(@as(u64, 32), second.fail.dest.answer.answer.int());
    try std.testing.expect(node.nextAction() == null);

    node.dialCancelled(ticket, 0);
    node.dialCancelled(ticket, 0);
    try std.testing.expectEqual(@as(usize, 0), node.pendingDialCount());
    try std.testing.expect(node.nextAction() == null);
}

test "acceptGive materializes dial view once for pendingDial" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(4)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const locator = "ocapn://127.0.0.1%3A9049.tcp?direct-addresses=10.0.0.1%3A1";
    try node.acceptGive(recipient, 9, "give-bytes", locator);
    const action = node.nextAction().?;
    const view = node.pendingDial(action.dial.pending, 0).?;
    try std.testing.expectEqualStrings("tcp", view.locator.transport);
    try std.testing.expectEqualStrings("127.0.0.1:9049", view.locator.designator);
    try std.testing.expectEqualStrings(model.transport.hint_direct_addresses, view.locator.hints.entries[0].name);
    try std.testing.expectEqualStrings("10.0.0.1:1", view.locator.hints.entries[0].value.string);
    _ = try node.dialFailed(action.dial.pending, 0, "stop");
    _ = node.nextAction();
}

test "alternative locators retry in order on one ticket and a later path succeeds" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x2a)));
    defer node.deinit();

    const first_alt = try peerUri(allocator, "127.0.0.1:9050");
    defer allocator.free(first_alt);
    const second_alt = try peerUri(allocator, "127.0.0.1:9051");
    defer allocator.free(second_alt);
    const alternatives = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ first_alt, second_alt });
    defer allocator.free(alternatives);
    const primary = try peerUriWithAlternatives(allocator, "127.0.0.1:9049", alternatives);
    defer allocator.free(primary);

    const staged = try node.stageDial(primary);
    const ticket = staged.pending;
    const first = node.nextAction().?;
    try std.testing.expect(first == .dial);
    try std.testing.expectEqual(ticket, first.dial.pending);
    try std.testing.expectEqualStrings("127.0.0.1:9049", node.pendingDial(ticket, 0).?.locator.designator);

    // The primary is unreachable. The next action is the same logical dial,
    // and only its active parsed path changes.
    _ = try node.dialFailed(ticket, 0, "primary unreachable");
    const retry_one = node.nextAction().?;
    try std.testing.expect(retry_one == .dial);
    try std.testing.expectEqual(ticket, retry_one.dial.pending);
    try std.testing.expectEqualStrings("127.0.0.1:9050", node.pendingDial(ticket, 1).?.locator.designator);

    _ = try node.dialFailed(ticket, 1, "first alternative unreachable");
    const retry_two = node.nextAction().?;
    try std.testing.expect(retry_two == .dial);
    try std.testing.expectEqual(ticket, retry_two.dial.pending);
    try std.testing.expectEqualStrings("127.0.0.1:9051", node.pendingDial(ticket, 2).?.locator.designator);

    // The embedder reports the final path as opened. The ticket is consumed,
    // with no retry or failure action left behind.
    const exporter = try node.registerPeer(.{});
    try std.testing.expect(try node.exporterDialed(ticket, 2, exporter));
    try std.testing.expect(node.pendingDial(ticket, 2) == null);
    try std.testing.expect(node.nextAction() == null);

    // A weak fallback serves only the ticket that carried it. It must not
    // become the canonical session for a later request naming the primary.
    const restaged = try node.stageDial(primary);
    try std.testing.expect(restaged == .pending);
    try std.testing.expect(node.nextAction().? == .dial);
}

test "pending dials share identity only when their route plans match" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x31)));
    defer node.deinit();

    const first_alt = try peerUri(allocator, "127.0.0.1:9060");
    defer allocator.free(first_alt);
    const second_alt = try peerUri(allocator, "127.0.0.1:9061");
    defer allocator.free(second_alt);
    const first_plan = try peerUriWithAlternatives(allocator, "127.0.0.1:9059", first_alt);
    defer allocator.free(first_plan);
    const second_plan = try peerUriWithAlternatives(allocator, "127.0.0.1:9059", second_alt);
    defer allocator.free(second_plan);

    const staged = try node.stageDial(first_plan);
    try std.testing.expectError(error.ConflictingDialPlan, node.stageDial(second_plan));
    const action = node.nextAction().?;
    try std.testing.expectEqual(staged.pending, action.dial.pending);
    try std.testing.expectEqualStrings("127.0.0.1:9059", node.pendingDial(staged.pending, 0).?.locator.designator);
    try std.testing.expect(node.nextAction() == null);
}

test "a conflicting handoff route plan fails instead of joining pending work" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x32)));
    defer node.deinit();
    const recipient = try node.registerPeer(.{});

    const first_alt = try peerUri(allocator, "127.0.0.1:9063");
    defer allocator.free(first_alt);
    const second_alt = try peerUri(allocator, "127.0.0.1:9064");
    defer allocator.free(second_alt);
    const first_plan = try peerUriWithAlternatives(allocator, "127.0.0.1:9062", first_alt);
    defer allocator.free(first_plan);
    const second_plan = try peerUriWithAlternatives(allocator, "127.0.0.1:9062", second_alt);
    defer allocator.free(second_plan);

    try node.acceptGive(recipient, 61, "give-one", first_plan);
    try node.acceptGive(recipient, 62, "give-two", second_plan);
    const dial = node.nextAction().?;
    try std.testing.expect(dial == .dial);
    const refused = node.nextAction().?;
    try std.testing.expect(refused == .fail);
    try std.testing.expectEqual(@as(u64, 62), refused.fail.dest.answer.answer.int());
    try std.testing.expect(std.mem.indexOf(u8, refused.fail.reason.bytes(), "conflicts") != null);
    try std.testing.expect(node.pendingDial(dial.dial.pending, 0) != null);
}

test "a direct key fallback does not inherit the primary durable-key demand" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x33)));
    defer node.deinit();

    const key = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x34))).publicKey();
    const designator = key.toDesignator();
    const alternate = try std.fmt.allocPrint(allocator, "ocapn://{s}.iroh", .{designator[0..]});
    defer allocator.free(alternate);
    const locator = try std.fmt.allocPrint(
        allocator,
        "ocapn://{s}.iroh?alt-locators={s}",
        .{ designator[0..], alternate },
    );
    defer allocator.free(locator);

    const staged = try node.stageDial(locator);
    const ticket = staged.pending;
    try std.testing.expect(node.pendingDial(ticket, 0).?.demanded_partner_key.?.eql(key));
    _ = node.nextAction();
    _ = try node.dialFailed(ticket, 0, "primary unavailable");
    try std.testing.expect(node.pendingDial(ticket, 1).?.demanded_partner_key == null);
}

test "alternative locator staging refuses malformed and oversized hints" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x2b)));
    defer node.deinit();
    const recipient = try node.registerPeer(.{});

    const malformed = "ocapn://127.0.0.1%3A9049.tcp?alt-locators=not-a-peer-uri";
    try node.acceptGive(recipient, 31, "give-malformed", malformed);
    const malformed_action = node.nextAction().?;
    try std.testing.expect(malformed_action == .fail);
    try std.testing.expectEqual(@as(u64, 31), malformed_action.fail.dest.answer.answer.int());
    try std.testing.expect(node.pendingDial(0, 0) == null);

    var oversized_hint: [model.route_bundle.max_route_list_bytes + 1]u8 = undefined;
    @memset(&oversized_hint, 'x');
    const oversized = try std.fmt.allocPrint(
        allocator,
        "ocapn://127.0.0.1%3A9050.tcp?alt-locators={s}",
        .{oversized_hint},
    );
    defer allocator.free(oversized);
    try node.acceptGive(recipient, 32, "give-oversized", oversized);
    const oversized_action = node.nextAction().?;
    try std.testing.expect(oversized_action == .fail);
    try std.testing.expectEqual(@as(u64, 32), oversized_action.fail.dest.answer.answer.int());

    var too_many = std.ArrayList(u8).empty;
    defer too_many.deinit(allocator);
    for (0..model.route_bundle.max_route_list_count + 1) |index| {
        if (index != 0) try too_many.append(allocator, '|');
        try too_many.appendSlice(allocator, "ocapn://127.0.0.1%3A9051.tcp");
    }
    const count_limited = try peerUriWithAlternatives(allocator, "127.0.0.1:9050", too_many.items);
    defer allocator.free(count_limited);
    try node.acceptGive(recipient, 33, "give-too-many", count_limited);
    const count_action = node.nextAction().?;
    try std.testing.expect(count_action == .fail);
    try std.testing.expectEqual(@as(u64, 33), count_action.fail.dest.answer.answer.int());
    try std.testing.expect(node.nextAction() == null);
}

test "alternative locator retry exhaustion breaks waiters only after the last path" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x2c)));
    defer node.deinit();
    const recipient = try node.registerPeer(.{});
    const alternative = try peerUri(allocator, "127.0.0.1:9052");
    defer allocator.free(alternative);
    const primary = try peerUriWithAlternatives(allocator, "127.0.0.1:9049", alternative);
    defer allocator.free(primary);

    try node.acceptGive(recipient, 41, "give-retry", primary);
    const first = node.nextAction().?;
    const ticket = first.dial.pending;
    _ = try node.dialFailed(ticket, 0, "primary down");
    const second = node.nextAction().?;
    try std.testing.expectEqual(ticket, second.dial.pending);
    try std.testing.expect(node.pendingDial(ticket, 1) != null);

    _ = try node.dialFailed(ticket, 1, "alternative down");
    const failed = node.nextAction().?;
    try std.testing.expect(failed == .fail);
    try std.testing.expectEqual(@as(u64, 41), failed.fail.dest.answer.answer.int());
    try std.testing.expectEqualStrings("handoff redeem failed: alternative down", failed.fail.reason.bytes());
    try std.testing.expect(node.pendingDial(ticket, 0) == null);
    try std.testing.expect(node.nextAction() == null);
}

test "ordinary primary dial success keeps the existing pending ticket contract" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x2d)));
    defer node.deinit();

    const staged = try node.stageDial("ocapn://127.0.0.1%3A9053.tcp");
    const ticket = staged.pending;
    const action = node.nextAction().?;
    try std.testing.expectEqual(ticket, action.dial.pending);
    try std.testing.expectEqualStrings("127.0.0.1:9053", node.pendingDial(ticket, 0).?.locator.designator);
    const exporter = try node.registerPeer(.{});
    _ = try node.exporterDialed(ticket, 0, exporter);
    try std.testing.expect(node.pendingDial(ticket, 0) == null);
    try std.testing.expect(node.nextAction() == null);
}

test "pending alternative paths are released when the node tears down" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x2e)));
    defer node.deinit();

    const alternative = try peerUri(allocator, "127.0.0.1:9054");
    defer allocator.free(alternative);
    const primary = try peerUriWithAlternatives(allocator, "127.0.0.1:9049", alternative);
    defer allocator.free(primary);
    const recipient = try node.registerPeer(.{});
    try node.acceptGive(recipient, 51, "give-teardown", primary);
    const action = node.nextAction().?;
    try std.testing.expect(node.pendingDial(action.dial.pending, 0) != null);
    // `deinit` owns both the queued action and every parsed path in the
    // pending row. The testing allocator turns either missed owner into a
    // failure without a separate production-only hook.
}

test "acceptGive fails closed on unparseable exporter locator" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(6)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    try node.acceptGive(recipient, 3, "give-bytes", "not-a-locator");
    const action = node.nextAction().?;
    try std.testing.expect(action == .fail);
    try std.testing.expectEqual(@as(u64, 3), action.fail.dest.answer.answer.int());
    try std.testing.expect(std.mem.indexOf(u8, action.fail.reason.bytes(), "unparseable") != null);
    try std.testing.expect(node.nextAction() == null);
}

test "exporterDialed frees empty hint sentinel without leaking" {
    // Hint-less URI stages an unowned empty hint; exporterDialed must free
    // through freeDialPart (not raw allocator.free on "").
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(7)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const exporter = try node.registerPeer(.{});
    const locator = "ocapn://127.0.0.1%3A9051.tcp";
    try node.acceptGive(recipient, 4, "give-bytes", locator);
    const action = node.nextAction().?;
    const view = node.pendingDial(action.dial.pending, 0).?;
    try std.testing.expectEqual(@as(usize, 0), view.locator.hints.entries.len);
    _ = try node.exporterDialed(action.dial.pending, 0, exporter);
    // Withdraw flush against the exporter; drain so deinit is clean.
    while (node.nextAction()) |_| {}
}

test "acceptGive joins pending dials on peer identity, not URI representation" {
    // ADR-0012: hints are connection advice, not identity. Two gives that name
    // the same transport+designator must share one in-flight dial even when the
    // URI bytes differ (query hints / encoding).
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(5)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const bare = "ocapn://127.0.0.1%3A9050.tcp";
    const hinted = "ocapn://127.0.0.1%3A9050.tcp?host=127.0.0.1&port=9050";
    try node.acceptGive(recipient, 11, "give-one", bare);
    try node.acceptGive(recipient, 12, "give-two", hinted);

    const action = node.nextAction().?;
    const identity_view = node.pendingDial(action.dial.pending, 0).?;
    try std.testing.expectEqualStrings("tcp", identity_view.locator.transport);
    try std.testing.expectEqualStrings("127.0.0.1:9050", identity_view.locator.designator);
    try std.testing.expect(node.nextAction() == null);

    _ = try node.dialFailed(action.dial.pending, 0, "connection refused");
    try std.testing.expectEqual(@as(u64, 11), node.nextAction().?.fail.dest.answer.answer.int());
    try std.testing.expectEqual(@as(u64, 12), node.nextAction().?.fail.dest.answer.answer.int());
    try std.testing.expect(node.nextAction() == null);
}

test "a dialed exporter whose session never opened fails the redeem closed" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(6)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    try node.acceptGive(recipient, 21, "give-bytes", "ocapn://127.0.0.1%3A9051.tcp");
    const dial = node.nextAction().?;

    // The embedder registers the exporter conn but the keyed session is not
    // open (no partner key), so the withdraw cannot be signed: the redeem
    // breaks instead of hanging.
    const exporter = try node.registerPeer(.{});
    _ = try node.exporterDialed(dial.dial.pending, 0, exporter);
    const action = node.nextAction().?;
    try std.testing.expectEqual(recipient, action.fail.dest.answer.recipient_peer);
    try std.testing.expectEqual(@as(u64, 21), action.fail.dest.answer.answer.int());
    try std.testing.expect(std.mem.startsWith(u8, action.fail.reason.bytes(), "handoff redeem failed:"));
}
