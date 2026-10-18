//! Host fan-out preserves one producer, independent custody and exact release.
const std = @import("std");
const glowcap = @import("glowcap");
const h = @import("../harness.zig");
const test_host = @import("../../../support/core_host.zig");
const Host = glowcap.driver.core.Host;
const a = std.testing.allocator;
const sturdy = h.tcpSturdyref("127.0.0.1:7920", "widget");

const Fixture = struct {
    client: Host,
    server: Host,
    pair: h.Pair,
    dials: std.ArrayList(h.ParkedDial) = .empty,

    fn init(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.* = .{
            .client = test_host.init(allocator, @splat(0x61), Host.Options.withFrameCap(h.frame_cap)),
            .server = test_host.init(a, @splat(0x62), Host.Options.withFrameCap(h.frame_cap)),
            .pair = undefined,
        };
        errdefer self.deinit();
        self.pair = try h.openPair(a, &self.client, &self.server, sturdy.peer.designator, &self.dials);
        _ = try self.pair.b.served.publish(&self.server.vat, "widget", h.Widget, .{});
    }

    fn pump(self: *Fixture) !void {
        try h.pumpToQuiescence(a, &.{ &self.client, &self.server }, &.{self.pair}, &self.dials);
    }

    fn deinit(self: *Fixture) void {
        self.server.deinit();
        self.client.deinit();
        self.dials.deinit(a);
    }
};

test "core host: shared enliven gives independent retains with one wire answer" {
    var fixture: Fixture = undefined;
    try fixture.init(a);
    defer fixture.deinit();
    const state = &fixture.pair.a.served.port.peer.session_state;
    const baseline = state.outbound_answers.len();
    const first = try fixture.client.enlivenCapability(a, sturdy);
    var first_released = false;
    defer if (!first_released) first.deinit();
    const second = try fixture.client.enlivenCapability(a, sturdy);
    var second_released = false;
    defer if (!second_released) second.deinit();
    try std.testing.expectEqual(baseline + 1, state.outbound_answers.len());
    try std.testing.expectEqual(@as(usize, 1), fixture.client.enliven_groups.count());
    try fixture.pump();
    const cap = first.result().ready.capability;
    try std.testing.expect(cap.eql(second.result().ready.capability));
    try std.testing.expectEqual(@as(u64, 2), fixture.client.capabilities.retainCount(cap).?);
    first.deinit();
    first_released = true;
    try std.testing.expectEqual(@as(u64, 1), fixture.client.capabilities.retainCount(cap).?);
    second.deinit();
    second_released = true;
    try fixture.pump();
    try std.testing.expectEqual(baseline, state.outbound_answers.len());
    try std.testing.expectEqual(@as(usize, 0), fixture.client.enliven_groups.count());
}

test "core host: shared enliven public handles preserve pipelining after sibling release" {
    for ([_]bool{ false, true }) |release_first| {
        var fixture: Fixture = undefined;
        try fixture.init(a);
        defer fixture.deinit();
        const state = &fixture.pair.a.served.port.peer.session_state;
        const baseline = state.outbound_answers.len();
        const first = try fixture.client.enlivenSelectOrDial(sturdy);
        const second = try fixture.client.enlivenSelectOrDial(sturdy);
        const observed = try fixture.client.enlivenCapability(a, sturdy);
        defer observed.deinit();
        try fixture.pump();
        const gone = if (release_first) first else second;
        const held = if (release_first) second else first;
        try fixture.client.vowRelease(gone);
        try std.testing.expectEqual(baseline + 1, state.outbound_answers.len());
        var reply = h.CapturedString{};
        const call = try fixture.client.vowSend(held, .{ .verb = "poke" });
        try fixture.client.vowOn(call, .{ .ctx = &reply, .func = h.CapturedString.record });
        try fixture.pump();
        try std.testing.expectEqualStrings("poked over fed bytes", reply.buf[0..reply.len]);
        try fixture.client.vowRelease(held);
        try fixture.pump();
        try std.testing.expectEqual(baseline, state.outbound_answers.len());
        try std.testing.expect(observed.result() == .ready);
    }
}

test "core host: shared enliven pending public cancellation preserves owned observation" {
    var fixture: Fixture = undefined;
    try fixture.init(a);
    defer fixture.deinit();
    const first = try fixture.client.enlivenSelectOrDial(sturdy);
    const second = try fixture.client.enlivenCapability(a, sturdy);
    defer second.deinit();
    try fixture.client.vowRelease(first);
    try std.testing.expect(second.result() == .pending);
    try fixture.pump();
    try std.testing.expect(second.result() == .ready);
    try std.testing.expectEqual(@as(usize, 0), fixture.client.pendingVowCount());
}

test "core host: shared enliven observer failure and session retirement settle every caller" {
    for ([_]bool{ false, true }) |close| {
        var fixture: Fixture = undefined;
        try fixture.init(a);
        defer fixture.deinit();
        const missing = h.tcpSturdyref(sturdy.peer.designator, "missing");
        const first = try fixture.client.enlivenCapability(a, missing);
        defer first.deinit();
        const second = try fixture.client.enlivenCapability(a, missing);
        defer second.deinit();
        if (close) try fixture.client.releaseSession(fixture.pair.a) else try fixture.pump();
        try std.testing.expect(first.result() == .failed and second.result() == .failed);
        try std.testing.expectEqual(first.result().failed.kind, second.result().failed.kind);
        try std.testing.expectEqualStrings(first.result().failed.message, second.result().failed.message);
        try std.testing.expectEqual(@as(usize, 0), fixture.client.pendingVowCount());
        try std.testing.expectEqual(@as(usize, 0), fixture.client.enliven_groups.count());
    }
}

test "core host: shared enliven cancellation allocates nothing and permits immediate retry" {
    var failing = std.testing.FailingAllocator.init(a, .{});
    var fixture: Fixture = undefined;
    try fixture.init(failing.allocator());
    defer fixture.deinit();
    var before: usize = undefined;
    {
        const first = try fixture.client.enlivenCapability(a, sturdy);
        defer first.deinit();
        const second = try fixture.client.enlivenCapability(a, sturdy);
        defer second.deinit();
        failing.fail_index = failing.alloc_index;
        before = failing.alloc_index;
    }
    try std.testing.expectEqual(before, failing.alloc_index);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), fixture.client.enliven_groups.count());
    failing.fail_index = std.math.maxInt(usize);
    const retry = try fixture.client.enlivenCapability(a, sturdy);
    defer retry.deinit();
    try fixture.pump();
    try std.testing.expect(retry.result() == .ready);
}

test "core host: shared enliven follower admission rolls back under every allocation refusal" {
    for (0..64) |offset| {
        var failing = std.testing.FailingAllocator.init(a, .{});
        var fixture: Fixture = undefined;
        try fixture.init(failing.allocator());
        defer fixture.deinit();
        const original = try fixture.client.enlivenCapability(a, sturdy);
        defer original.deinit();
        failing.fail_index = failing.alloc_index + offset;
        const follower = fixture.client.enlivenCapability(failing.allocator(), sturdy) catch |err| {
            failing.fail_index = std.math.maxInt(usize);
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 1), fixture.client.pendingVowCount());
            try fixture.pump();
            try std.testing.expect(original.result() == .ready);
            continue;
        };
        failing.fail_index = std.math.maxInt(usize);
        defer follower.deinit();
        try fixture.pump();
        try std.testing.expect(follower.result() == .ready and original.result() == .ready);
        return;
    }
    return error.AllocationSweepIncomplete;
}

test "core host: shared enliven coalesces equal callers resumed from one parked dial" {
    var client = test_host.init(a, @splat(0x63), Host.Options.withFrameCap(h.frame_cap));
    defer client.deinit();
    var server = test_host.init(a, @splat(0x64), Host.Options.withFrameCap(h.frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer dials.deinit(a);
    const first = try client.enlivenCapability(a, sturdy);
    defer first.deinit();
    const second = try client.enlivenCapability(a, sturdy);
    defer second.deinit();
    const public = try client.enlivenSelectOrDial(sturdy);
    const dial = (try client.nextAction()).?.dial;
    const accepted = try h.publishAndOpenAccepted(&server, "tcp", sturdy.peer.designator, &.{});
    _ = try accepted.served.publish(&server.vat, "widget", h.Widget, .{});
    try client.ensureAdvertisedLocator("tcp");
    const dialed = (try client.openPendingDial(dial.ticket, dial.route_index)).?;
    const pair = h.Pair{ .ah = &client, .a = dialed, .bh = &server, .b = accepted };
    try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
    _ = try client.exporterDialed(dial.ticket, dial.route_index, dialed);
    try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(first.result() == .ready and second.result() == .ready);
    try std.testing.expect(first.result().ready.capability.eql(second.result().ready.capability));
    try std.testing.expectEqual(@as(usize, 0), client.pending_enliven_count);
    try client.vowRelease(public);
}

// Replay dial completion with each allocation refused in turn. Persistent
// exhaustion may fail every resumed observer. Once allocation recovers, an
// immediate retry on the live session must join or restart the same fetch.
// The replay fails if rollback leaves the pending marker, parked cancellation
// skips its accounting, or a pre-minted continuation ID advances. It drives
// byte-fed Host admission, so physical dial and storage failures are out of reach.
test "core host: enliven dial continuation replay preserves cancellation refusal retry and close" {
    const model = glowcap.ocapn.model;
    for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| {
        for ([_]model.CodecId{ .syrup, .capnp }) |codec| {
            for ([_]bool{ false, true }) |close_first| {
                var failures: usize = 0;
                for (0..64) |offset| {
                    if (!try replayDialContinuation(profile, codec, close_first, offset)) break;
                    failures += 1;
                } else return error.AllocationSweepIncomplete;
                try std.testing.expect(failures != 0);
            }
        }
    }
}

fn replayDialContinuation(profile: glowcap.ocapn.model.CaptpVersion, codec: glowcap.ocapn.model.CodecId, close_first: bool, offset: usize) !bool {
    var failing = std.testing.FailingAllocator.init(a, .{});
    var options = Host.Options.withFrameCap(h.frame_cap);
    options.captp_version = profile;
    options.codec = codec;
    options.features = glowcap.ocapn.model.FeatureSet.full().forCaptpVersion(profile);
    var client = test_host.init(failing.allocator(), @splat(0x65), options);
    defer client.deinit();
    var server = test_host.init(a, @splat(0x66), options);
    defer server.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer dials.deinit(a);
    const canceled = try client.enlivenCapability(a, sturdy);
    const first = try client.enlivenCapability(a, sturdy);
    defer first.deinit();
    const second = try client.enlivenCapability(a, sturdy);
    defer second.deinit();
    const public = try client.enlivenSelectOrDial(sturdy);
    const dial = (try client.nextAction()).?.dial;
    canceled.deinit();
    try std.testing.expectEqual(@as(usize, 3), client.pending_enliven_count);
    const accepted = try h.publishAndOpenAccepted(&server, "tcp", sturdy.peer.designator, &.{});
    _ = try accepted.served.publish(&server.vat, "widget", h.Widget, .{});
    try client.ensureAdvertisedLocator("tcp");
    const dialed = (try client.openPendingDial(dial.ticket, dial.route_index)).?;
    const pair = h.Pair{ .ah = &client, .a = dialed, .bh = &server, .b = accepted };
    try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expectEqual(profile, dialed.served.port.peer.session_state.captp_version);
    try std.testing.expectEqual(codec, dialed.served.port.peer.session_state.codec);
    const next_id = client.vow_ids.next;
    failing.fail_index = failing.alloc_index + offset;
    const adoption = client.exporterDialed(dial.ticket, dial.route_index, dialed);
    const induced = failing.has_induced_failure;
    failing.fail_index = std.math.maxInt(usize);
    const adopted = adoption catch |err| blk: {
        try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expect(induced);
        break :blk try client.exporterDialed(dial.ticket, dial.route_index, dialed);
    };
    try std.testing.expect(adopted);
    try std.testing.expectEqual(next_id, client.vow_ids.next);
    try std.testing.expectEqual(@as(usize, 0), client.pending_enliven_count);
    try std.testing.expectEqual(@as(usize, 0), client.pending_enlivens.count());
    const retry = try client.enlivenCapability(a, sturdy);
    defer retry.deinit();
    if (close_first) {
        try client.releaseSession(dialed);
        try server.releaseSession(accepted);
    }
    var public_completions: usize = 0;
    for (0..64) |_| {
        const moved = if (close_first) false else try h.shuttleAll(&.{pair});
        var acted = false;
        for ([_]*Host{ &client, &server }) |host| {
            while (try host.takeAction()) |action| {
                defer host.freeAction(action);
                acted = true;
                if (host != &client) continue;
                switch (action) {
                    .settled => |value| if (value.vow_id == public) {
                        try std.testing.expect(!close_first);
                        public_completions += 1;
                    },
                    .failed => |value| if (value.vow_id == public) {
                        if (value.message == .fallback) {
                            // Public failure detail needs its own retain, so
                            // exhaustion may replace it with the typed fallback.
                            try std.testing.expect(induced);
                            try std.testing.expectEqual(.broken, value.failure);
                        } else try expectReplayFailure(value.failure, value.message.owned, close_first, induced);
                        public_completions += 1;
                    },
                    else => {},
                }
            }
        }
        if (!moved and !acted) break;
    } else return error.PumpDidNotQuiesce;
    try std.testing.expectEqual(@as(usize, 1), public_completions);
    for ([_]*Host.Enliven{ first, second }) |owned| {
        try std.testing.expect(owned.result() != .pending);
        if (owned.result() == .failed) {
            const failed = owned.result().failed;
            try expectReplayFailure(failed.kind, failed.message, close_first, induced);
        }
        if (owned.result() == .ready) try std.testing.expect(owned.result().ready.capability.eql(retry.result().ready.capability));
    }
    if (close_first) {
        try std.testing.expect(retry.result() == .failed);
        try std.testing.expectEqual(.closed, retry.result().failed.kind);
    } else {
        try std.testing.expect(retry.result() == .ready);
        if (client.vows.contains(public)) try client.vowRelease(public);
        try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
        try std.testing.expectEqual(@as(usize, 0), dialed.served.port.peer.pending_send_reservations);
    }
    try std.testing.expectEqual(@as(usize, 0), client.pendingVowCount());
    try std.testing.expectEqual(@as(usize, 0), client.enliven_groups.count());
    try std.testing.expectEqual(@as(usize, 0), client.pending_operations);
    return induced;
}

fn expectReplayFailure(kind: glowcap.driver.core.VowFailure, message: []const u8, close_first: bool, induced: bool) !void {
    if (kind == .closed) {
        try std.testing.expect(close_first);
        return;
    }
    try std.testing.expect(induced);
    try std.testing.expectEqual(.broken, kind);
    try std.testing.expectEqualStrings("OutOfMemory", message);
}
