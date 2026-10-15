//! Cold publication discovery uses real CapTP fetches and the explicit storage
//! lane. The caller never supplies a descriptor ID or restores an endpoint.
const std = @import("std");
const f = @import("fixture.zig");
const records = @import("../core/fixture.zig");
const hosts = @import("../../support/core_host.zig");
const pairs = @import("../../support/host_pair.zig");
const CapturedRef = @import("../../support/capture.zig").CapturedRef;

test "loam publication own key cold enliven coalesces public and owned fetches and cancels exact custody" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    _ = try stage(&fixture, 0x51);
    try f.hosting.publication.listen(fixture.attached, .{ .max_names = 1, .max_fetches = 3 });
    const designator = fixture.host.node.publicKey().toDesignator();
    const swiss = f.driver.Host.DurableSwiss.fromEntropy(@splat(0x51));
    const sturdy: @import("glowcap").ocapn.model.SturdyRef = .{
        .peer = .{ .transport = "webrtc", .designator = &designator },
        .swissnum = swiss.slice(),
    };
    const first = try fixture.host.enlivenCapability(std.testing.allocator, sturdy);
    defer first.deinit();
    const canceled = try fixture.host.enlivenCapability(std.testing.allocator, sturdy);
    const public = try fixture.host.enlivenSelectOrDial(sturdy);
    try std.testing.expect((try fixture.host.nextAction()) == null);
    const lookup = (try fixture.attached.nextWork()).?.lookup;
    try std.testing.expect((try fixture.attached.nextWork()) == null);
    canceled.deinit();
    try std.testing.expectEqual(@as(usize, 2), fixture.host.pending_enliven_count);
    try fixture.attached.completeLookup(lookup.ticket, fixture.data.backend.lookup(lookup));
    try drain(&fixture);
    const action = (try fixture.host.nextAction()).?;
    defer fixture.host.freeAction(action);
    try std.testing.expect(action == .settled);
    try std.testing.expectEqual(public, action.settled.vow_id);
    try std.testing.expectEqual(null, action.settled.peer_handle);
    try std.testing.expect(action.settled.value.capability.eql(first.result().ready.capability));
    try std.testing.expectEqual(.verified, first.result().ready.provenance);
    try std.testing.expectEqual(@as(usize, 0), fixture.host.sessions.count());
    try std.testing.expectEqual(@as(usize, 0), fixture.host.publications.count());
    try std.testing.expectEqual(@as(usize, 0), fixture.host.pending_enliven_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.host.pending_operations);
    try std.testing.expectEqual(@as(u64, 1), fixture.attached.stats.loads);
}

fn stage(fixture: *f.Fixture, byte: u8) !f.loam.core.ObjectId {
    try fixture.data.store.begin();
    const id = try f.hosting.publication.stage(fixture.attached, @splat(byte), fixture.root);
    try records.commit(&fixture.data.store, &fixture.data.backend);
    fixture.data.store.evict();
    return id;
}

test "loam publication own key cold enliven is canceled by Host shutdown while submitted storage drains" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    _ = try stage(&fixture, 0x52);
    try f.hosting.publication.listen(fixture.attached, .{});
    const designator = fixture.host.node.publicKey().toDesignator();
    const swiss = f.driver.Host.DurableSwiss.fromEntropy(@splat(0x52));
    const sturdy: @import("glowcap").ocapn.model.SturdyRef = .{
        .peer = .{ .transport = "webrtc", .designator = &designator },
        .swissnum = swiss.slice(),
    };
    const first = try fixture.host.enlivenCapability(std.testing.allocator, sturdy);
    defer first.deinit();
    const public = try fixture.host.enlivenSelectOrDial(sturdy);
    const lookup = (try fixture.attached.nextWork()).?.lookup;
    fixture.host.beginClose(.cancel, 0);
    const action = (try fixture.host.takeAction()).?;
    try std.testing.expect(first.result() == .failed);
    try std.testing.expectEqual(.closed, first.result().failed.kind);
    try std.testing.expect(action == .failed);
    try std.testing.expectEqual(public, action.failed.vow_id);
    try std.testing.expectEqual(.closed, action.failed.failure);
    try std.testing.expectEqual(@as(usize, 0), fixture.host.pending_enliven_count);
    try std.testing.expectEqual(@as(usize, 1), fixture.host.pending_operations);
    fixture.host.freeAction(action);
    try fixture.attached.completeLookup(lookup.ticket, fixture.data.backend.lookup(lookup));
    try drain(&fixture);
    try std.testing.expectEqual(@as(usize, 0), fixture.host.pending_operations);
    try std.testing.expect((try fixture.host.nextAction()) == null);
}

fn drain(fixture: *f.Fixture) !void {
    var slot: [1]f.hosting.Worker.Slot = undefined;
    var worker: f.hosting.Worker = .init(&slot, fixture.data.backend.readerCapacity());
    for (0..16) |_| {
        try fixture.attached.advance();
        try worker.drive(fixture.attached, &fixture.data.backend);
        if (fixture.host.pending_operations == 0) return;
    }
    return error.DidNotQuiesce;
}

test "loam publication cold fetch coalesces names and preserves exact authority without a registry row" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    _ = try stage(&fixture, 0x41);
    try f.hosting.publication.listen(fixture.attached, .{ .max_names = 1, .max_fetches = 2 });
    var client = hosts.init(std.testing.allocator, @splat(0x82), f.driver.Host.Options.withFrameCap(4096));
    defer client.deinit();
    const pair = try pairs.openPair(&client, &fixture.host, "127.0.0.1:9720");
    const swiss = f.driver.Host.DurableSwiss.fromEntropy(@splat(0x41));
    var captured: [2]CapturedRef = @splat(.{});
    for (&captured) |*capture| try client.vowOn(try client.fetch(pair.a, swiss.slice()), .{ .ctx = capture, .func = CapturedRef.record });
    try pairs.pumpToQuiescence(&.{pair});
    const lookup = (try fixture.attached.nextWork()).?.lookup;
    try std.testing.expect((try fixture.attached.nextWork()) == null);
    try fixture.attached.completeLookup(lookup.ticket, fixture.data.backend.lookup(lookup));
    try std.testing.expectError(error.StaleCompletion, fixture.attached.completeLookup(lookup.ticket, .missing));
    try drain(&fixture);
    try pairs.pumpToQuiescence(&.{pair});
    try std.testing.expectEqual(try captured[0].require(), try captured[1].require());
    try std.testing.expectEqual(@as(usize, 0), fixture.host.publications.count());
    try std.testing.expectEqual(@as(u64, 1), fixture.attached.stats.loads);
    var answer: f.Capture = .{};
    try client.vowOn(try client.send(pair.a, try captured[0].require(), .{ .verb = "get", .args = &.{} }), .{ .ctx = &answer, .func = f.Capture.record });
    try pairs.pumpToQuiescence(&.{pair});
    try fixture.drain();
    try pairs.pumpToQuiescence(&.{pair});
    try std.testing.expectEqual(@as(?i64, 0), answer.value);
}

test "loam publication canceled cold fetch retains submitted storage custody" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    _ = try stage(&fixture, 0x42);
    try f.hosting.publication.listen(fixture.attached, .{});
    var client = hosts.init(std.testing.allocator, @splat(0x83), f.driver.Host.Options.withFrameCap(4096));
    defer client.deinit();
    const pair = try pairs.openPair(&client, &fixture.host, "127.0.0.1:9721");
    const swiss = f.driver.Host.DurableSwiss.fromEntropy(@splat(0x42));
    _ = try client.fetch(pair.a, swiss.slice());
    try pairs.pumpToQuiescence(&.{pair});
    const lookup = (try fixture.attached.nextWork()).?.lookup;
    try fixture.host.releaseSession(pair.b);
    try client.releaseSession(pair.a);
    try std.testing.expectEqual(@as(usize, 1), fixture.host.pending_operations);
    try std.testing.expectError(error.Busy, fixture.attached.destroy());
    try std.testing.expectError(error.Busy, fixture.host.clearPublicationLookup(&fixture.attached.discovery.?.registration));
    try fixture.attached.completeLookup(lookup.ticket, fixture.data.backend.lookup(lookup));
    try fixture.attached.advance();
    try std.testing.expectEqual(@as(usize, 0), fixture.host.pending_operations);
    try std.testing.expectEqual(@as(u64, 0), fixture.attached.stats.loads);
}

test "loam publication cold fetch refuses pressure and distinguishes missing names from storage failure" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    _ = try stage(&fixture, 0x43);
    try f.hosting.publication.listen(fixture.attached, .{ .max_names = 1, .max_fetches = 1 });
    var client = hosts.init(std.testing.allocator, @splat(0x84), f.driver.Host.Options.withFrameCap(4096));
    defer client.deinit();
    const pair = try pairs.openPair(&client, &fixture.host, "127.0.0.1:9722");
    const swiss = f.driver.Host.DurableSwiss.fromEntropy(@splat(0x43));
    var first: CapturedRef = .{};
    var refused: CapturedRef = .{};
    try client.vowOn(try client.fetch(pair.a, swiss.slice()), .{ .ctx = &first, .func = CapturedRef.record });
    try client.vowOn(try client.fetch(pair.a, swiss.slice()), .{ .ctx = &refused, .func = CapturedRef.record });
    try pairs.pumpToQuiescence(&.{pair});
    try std.testing.expect(refused.broken);
    try std.testing.expectEqualStrings("FetchCapacity", refused.reason_buf[0..refused.reason_len]);
    const lookup = (try fixture.attached.nextWork()).?.lookup;
    try fixture.attached.completeLookup(lookup.ticket, .{ .failed = error.InjectedLookupFailure });
    try drain(&fixture);
    try pairs.pumpToQuiescence(&.{pair});
    try std.testing.expectEqualStrings("InjectedLookupFailure", first.reason_buf[0..first.reason_len]);
    const absent = f.driver.Host.DurableSwiss.fromEntropy(@splat(0x44));
    var missing: CapturedRef = .{};
    try client.vowOn(try client.fetch(pair.a, absent.slice()), .{ .ctx = &missing, .func = CapturedRef.record });
    try pairs.pumpToQuiescence(&.{pair});
    try drain(&fixture);
    try pairs.pumpToQuiescence(&.{pair});
    try std.testing.expectEqualStrings("unknown swissnum", missing.reason_buf[0..missing.reason_len]);
    var retry: CapturedRef = .{};
    try client.vowOn(try client.fetch(pair.a, swiss.slice()), .{ .ctx = &retry, .func = CapturedRef.record });
    try pairs.pumpToQuiescence(&.{pair});
    try drain(&fixture);
    try pairs.pumpToQuiescence(&.{pair});
    _ = try retry.require();
}

test "loam publication retirement races cold lookup and unknown outcomes fail closed" {
    for ([_]bool{ false, true }) |committed| {
        var fixture: f.Fixture = undefined;
        try fixture.init(.{});
        defer fixture.deinit();
        const publication = try stage(&fixture, 0x45);
        try f.hosting.publication.listen(fixture.attached, .{});
        var client = hosts.init(std.testing.allocator, @splat(0x85), f.driver.Host.Options.withFrameCap(4096));
        defer client.deinit();
        const pair = try pairs.openPair(&client, &fixture.host, "127.0.0.1:9723");
        const swiss = f.driver.Host.DurableSwiss.fromEntropy(@splat(0x45));
        var captured: CapturedRef = .{};
        try client.vowOn(try client.fetch(pair.a, swiss.slice()), .{ .ctx = &captured, .func = CapturedRef.record });
        try pairs.pumpToQuiescence(&.{pair});
        const lookup = (try fixture.attached.nextWork()).?.lookup;
        const old_result = fixture.data.backend.lookup(lookup);
        const lease = try records.load(&fixture.data.store, &fixture.data.backend, publication);
        try fixture.data.store.begin();
        try f.hosting.publication.stageRetirement(fixture.attached, lease);
        try fixture.data.store.release(lease);
        _ = try fixture.attached.submit();
        const batch = (try fixture.attached.nextWork()).?.write;
        if (committed) try std.testing.expect(fixture.data.backend.commit(batch) == .committed);
        try fixture.attached.completeWrite(batch.ticket, .unknown);
        try fixture.attached.completeLookup(lookup.ticket, old_result);
        try fixture.attached.advance();
        try pairs.pumpToQuiescence(&.{pair});
        try std.testing.expectEqualStrings("RecoveryRequired", captured.reason_buf[0..captured.reason_len]);
        try fixture.attached.resolve(batch.ticket, try fixture.data.backend.recover(try fixture.attached.recoveryBatch()));
        try std.testing.expectEqual(@as(usize, 0), fixture.host.publications.count());
        if (committed) try records.collect(&fixture.data.store, &fixture.data.backend);
        var retry: CapturedRef = .{};
        try client.vowOn(try client.fetch(pair.a, swiss.slice()), .{ .ctx = &retry, .func = CapturedRef.record });
        try pairs.pumpToQuiescence(&.{pair});
        try drain(&fixture);
        try pairs.pumpToQuiescence(&.{pair});
        if (committed) try std.testing.expect(retry.broken) else _ = try retry.require();
        var held: f.Capture = .{};
        try fixture.send("get", &.{}, &held);
        try fixture.drain();
        try std.testing.expectEqual(@as(?i64, 0), held.value);
    }
}

test "loam publication cold read failure and cancellation retire all storage ownership" {
    for ([_]bool{ false, true }) |cancel| {
        var fixture: f.Fixture = undefined;
        try fixture.init(.{});
        defer fixture.deinit();
        _ = try stage(&fixture, 0x46);
        try f.hosting.publication.listen(fixture.attached, .{});
        var client = hosts.init(std.testing.allocator, @splat(0x86), f.driver.Host.Options.withFrameCap(4096));
        defer client.deinit();
        const pair = try pairs.openPair(&client, &fixture.host, "127.0.0.1:9724");
        const swiss = f.driver.Host.DurableSwiss.fromEntropy(@splat(0x46));
        var captured: CapturedRef = .{};
        try client.vowOn(try client.fetch(pair.a, swiss.slice()), .{ .ctx = &captured, .func = CapturedRef.record });
        try pairs.pumpToQuiescence(&.{pair});
        const lookup = (try fixture.attached.nextWork()).?.lookup;
        try fixture.attached.completeLookup(lookup.ticket, fixture.data.backend.lookup(lookup));
        try fixture.attached.advance();
        const read = (try fixture.attached.nextWork()).?.read;
        if (cancel) {
            try fixture.host.releaseSession(pair.b);
            try client.releaseSession(pair.a);
            try std.testing.expectError(error.Busy, fixture.attached.destroy());
            try fixture.attached.completeRead(read.ticket, fixture.data.backend.read(read));
        } else {
            const result = fixture.data.backend.read(read);
            read.buffer[0] ^= 1;
            try std.testing.expectError(error.Corrupt, fixture.attached.completeRead(read.ticket, result));
        }
        try fixture.attached.advance();
        if (!cancel) {
            try pairs.pumpToQuiescence(&.{pair});
            try std.testing.expectEqualStrings("Corrupt", captured.reason_buf[0..captured.reason_len]);
        }
        try std.testing.expect(!fixture.attached.hasPendingWork());
        try std.testing.expectEqual(@as(usize, 0), fixture.host.pending_operations);
    }
}

test "loam publication cold population does not create startup endpoints or scan other records" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{ .max_endpoints = 1 });
    defer fixture.deinit();
    var entropy: f.hosting.publication.Entropy = @splat(0);
    for (1..1025) |i| {
        std.mem.writeInt(u64, entropy[0..8], i, .big);
        try fixture.data.store.begin();
        _ = try f.hosting.publication.stage(fixture.attached, entropy, fixture.root);
        try records.commit(&fixture.data.store, &fixture.data.backend);
    }
    fixture.data.store.evict();
    try f.hosting.publication.listen(fixture.attached, .{ .max_names = 1, .max_fetches = 1 });
    try std.testing.expectEqual(@as(usize, 0), fixture.host.publications.count());
    try std.testing.expectEqual(@as(usize, 0), fixture.data.store.cache.allocated_bytes);
    try std.testing.expectEqual(@as(u64, 0), fixture.attached.stats.loads);
    var client = hosts.init(std.testing.allocator, @splat(0x87), f.driver.Host.Options.withFrameCap(4096));
    defer client.deinit();
    const pair = try pairs.openPair(&client, &fixture.host, "127.0.0.1:9725");
    const swiss = f.driver.Host.DurableSwiss.fromEntropy(entropy);
    var captured: CapturedRef = .{};
    try client.vowOn(try client.fetch(pair.a, swiss.slice()), .{ .ctx = &captured, .func = CapturedRef.record });
    try pairs.pumpToQuiescence(&.{pair});
    try drain(&fixture);
    try pairs.pumpToQuiescence(&.{pair});
    _ = try captured.require();
    try std.testing.expectEqual(@as(u64, 1), fixture.attached.stats.loads);
    try std.testing.expectEqual(@as(usize, 0), fixture.host.publications.count());
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const previous = fixture.attached.allocator;
    fixture.attached.allocator = allocator;
    defer {
        if (fixture.attached.discovery) |discovery| discovery.destroy() catch unreachable;
        fixture.attached.allocator = previous;
    }
    try f.hosting.publication.listen(fixture.attached, .{});
}

test "loam publication lookup setup refuses allocation without installing partial authority" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}

test "loam publication cold fetch preserves pipelined calls in both protocol profiles" {
    const model = @import("glowcap").ocapn.model;
    for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| {
        var fixture: f.Fixture = undefined;
        try fixture.init(.{});
        defer fixture.deinit();
        _ = try stage(&fixture, 0x48);
        try f.hosting.publication.listen(fixture.attached, .{});
        var options = f.driver.Host.Options.withFrameCap(4096);
        options.captp_version = profile;
        options.features = model.FeatureSet.full().forCaptpVersion(profile);
        fixture.host.opts.captp_version = profile;
        fixture.host.opts.features = options.features;
        var client = hosts.init(std.testing.allocator, @splat(0x89), options);
        defer client.deinit();
        const pair = try pairs.openPair(&client, &fixture.host, "127.0.0.1:9726");
        try std.testing.expectEqual(profile, pair.a.served.port.peer.session_state.captp_version);
        const swiss = f.driver.Host.DurableSwiss.fromEntropy(@splat(0x48));
        const fetched = try client.fetch(pair.a, swiss.slice());
        const added = try client.vowSend(fetched, .{ .verb = "add", .args = &.{.{ .integer = 6 }} });
        var answer: f.Capture = .{};
        try client.vowOn(added, .{ .ctx = &answer, .func = f.Capture.record });
        try pairs.pumpToQuiescence(&.{pair});
        try std.testing.expect(answer.value == null and !answer.broken);
        for (0..8) |_| {
            try fixture.drain();
            try pairs.pumpToQuiescence(&.{pair});
            if (answer.value != null or answer.broken) break;
        }
        try std.testing.expect(!answer.broken);
        try std.testing.expectEqual(@as(?i64, 6), answer.value);
        try std.testing.expectEqual(@as(u64, 3), fixture.data.store.metadata.revision);
    }
}

fn feedFetch(fixture: *f.Fixture, server: *f.driver.HostSession, name: []const u8, answer: []const u8) !void {
    const wire = try std.fmt.allocPrint(std.testing.allocator, "<10'op:deliver<11'desc:export0+>[5'fetch{d}:{s}]{s}<19'desc:import-promise99+>>", .{ name.len, name, answer });
    defer std.testing.allocator.free(wire);
    try fixture.host.feed(server, .{ .bytes = wire, .shape = .byte });
}

test "loam publication deferred fetch preserves virtual answers and detached resolver custody" {
    const codec = @import("glowcap").ocapn.codec;
    for ([_]bool{ false, true }) |reused| {
        var fixture: f.Fixture = undefined;
        try fixture.init(.{});
        defer fixture.deinit();
        _ = try stage(&fixture, 0x49);
        try f.hosting.publication.listen(fixture.attached, .{});
        var client = hosts.init(std.testing.allocator, @splat(0x8a), f.driver.Host.Options.withFrameCap(4096));
        defer client.deinit();
        const pair = try pairs.openPair(&client, &fixture.host, "127.0.0.1:9727");
        const swiss = f.driver.Host.DurableSwiss.fromEntropy(@splat(0x49));
        try feedFetch(&fixture, pair.b, swiss.slice(), if (reused) "11+" else "f");
        try std.testing.expect(pair.b.served.port.peer.takeOutbound() == null);
        if (reused) {
            try fixture.host.feed(pair.b, .{ .bytes = "<13'op:gc-answers[11+]>", .shape = .byte });
            try fixture.host.feed(pair.b, .{ .bytes = "<10'op:deliver<11'desc:export0+>[5'fetch7:missing]11+<19'desc:import-promise100+>>", .shape = .byte });
        }
        try drain(&fixture);
        var old_fulfilled = false;
        var new_broken = false;
        while (try pair.b.takeOutbound()) |frame_value| {
            var frame = frame_value;
            defer frame.deinit();
            const body = try codec.syrup.decodeBodyForProfile(.v1_0, frame.view());
            if (body != .deliver) continue;
            const target = body.deliver.target.near.export_position.int();
            const verb = (try body.deliver.args.at(0)).symbol;
            if (target == 99) {
                try std.testing.expect(!old_fulfilled);
                try std.testing.expectEqualStrings("fulfill", verb);
                try std.testing.expect((try body.deliver.args.at(1)) == .reference);
                old_fulfilled = true;
            } else if (target == 100) {
                try std.testing.expectEqualStrings("break", verb);
                new_broken = true;
            } else return error.WrongResolver;
        }
        try std.testing.expect(old_fulfilled);
        try std.testing.expectEqual(reused, new_broken);
        try std.testing.expectEqual(@as(usize, 0), fixture.host.pending_operations);
    }
}

test "loam publication bounds distinct cold names separately from fetch waiters" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    _ = try stage(&fixture, 0x4a);
    try f.hosting.publication.listen(fixture.attached, .{ .max_names = 1, .max_fetches = 2 });
    var client = hosts.init(std.testing.allocator, @splat(0x8b), f.driver.Host.Options.withFrameCap(4096));
    defer client.deinit();
    const pair = try pairs.openPair(&client, &fixture.host, "127.0.0.1:9728");
    const swiss = f.driver.Host.DurableSwiss.fromEntropy(@splat(0x4a));
    const other = f.driver.Host.DurableSwiss.fromEntropy(@splat(0x4b));
    var accepted: CapturedRef = .{};
    var refused: CapturedRef = .{};
    try client.vowOn(try client.fetch(pair.a, swiss.slice()), .{ .ctx = &accepted, .func = CapturedRef.record });
    try client.vowOn(try client.fetch(pair.a, other.slice()), .{ .ctx = &refused, .func = CapturedRef.record });
    try pairs.pumpToQuiescence(&.{pair});
    try std.testing.expectEqualStrings("LookupCapacity", refused.reason_buf[0..refused.reason_len]);
    try drain(&fixture);
    try pairs.pumpToQuiescence(&.{pair});
    _ = try accepted.require();
    try std.testing.expectEqual(@as(u64, 1), fixture.attached.stats.loads);
}
