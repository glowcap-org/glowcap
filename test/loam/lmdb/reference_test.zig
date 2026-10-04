//! Typed foreign fields retain role distinctions across compaction and restart.
const std = @import("std");
const f = @import("../access/reference_fixture.zig");
const sharing = @import("../access/sharing_fixture.zig");
const h = f.h;
const Lmdb = @import("loam_lmdb").Lmdb;
const a = std.testing.allocator;
const collect = @import("loam_test_support").collect;

fn entropy(context: ?*anyopaque, bytes: *h.driver.Host.DurableSwiss.Entropy) !void {
    const counter: *u64 = @ptrCast(@alignCast(context.?));
    counter.* += 1;
    @memset(bytes, 0);
    std.mem.writeInt(u64, bytes[0..8], counter.*, .big);
}

test "loam LMDB foreign roles survive compaction and restore a later vat during collection" {
    var source_dir = std.testing.tmpDir(.{});
    defer source_dir.cleanup();
    var target_dir = std.testing.tmpDir(.{});
    defer target_dir.cleanup();
    const source_path = try source_dir.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(source_path);
    const target_path = try target_dir.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(target_path);
    const source_z = try a.dupeSentinel(u8, source_path, 0);
    defer a.free(source_z);
    const target_z = try a.dupeSentinel(u8, target_path, 0);
    defer a.free(target_z);
    var source_db = try Lmdb.open(source_z, .{ .mode = .{ .create = h.f.store_id } });
    defer source_db.close() catch unreachable;
    var target_db = try Lmdb.open(target_z, .{ .mode = .{ .create = @fromBackingInt(95) } });
    defer target_db.close() catch unreachable;
    var source_store = try h.loam.core.Store.init(a, source_db.metadata, &f.schemas, h.limits);
    defer source_store.deinit() catch unreachable;
    var target_store = try h.loam.core.Store.init(a, target_db.metadata, &h.schemas, h.limits);
    defer target_store.deinit() catch unreachable;
    const source_data = try h.seed(&source_store, &source_db);
    try f.fields(&source_store, &source_db, source_data.content, 3);
    const target_data = try h.seedDepth(&target_store, &target_db, 1);
    var restricted_name: ?h.driver.Host.DurableSwiss = null;
    {
        var source: h.Hosted = undefined;
        try source.init(&source_store, &source_db, source_data);
        defer source.deinit();
        source.service.contents = &f.contents;
        var target: h.Hosted = undefined;
        try target.initIdentity(&target_store, &target_db, target_data, .{}, @splat(0x65));
        defer target.deinit();
        const original_name = try f.publication(&target, &target_db, target_data.use, @splat(0x74));
        const control_name = try f.publication(&target, &target_db, target_data.control, @splat(0x75));
        const pair = try f.pairs.openPair(&source.host, &target.host, "127.0.0.1:9791");
        const original = try f.fetch(&source, &source_db, &target, &target_db, pair, original_name);
        defer source.host.releaseCapabilityTerminal(original, null);
        const control = try f.fetch(&source, &source_db, &target, &target_db, pair, control_name);
        defer source.host.releaseCapabilityTerminal(control, null);
        var counter: u64 = 100;
        target.service.decode_derive = sharing.decode;
        target.service.entropy = .{ .context = &counter, .fill = entropy };
        const derived = try f.send(&source, &source_db, &target, &target_db, pair, original, "derive", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 } });
        defer derived.deinit();
        const use = derived.result().ready.capability;
        const named = try f.send(&source, &source_db, &target, &target_db, pair, use, "durable-name", &.{});
        defer named.deinit();
        const use_name = h.driver.Host.DurableSwiss.fromEntropy(h.driver.Host.DurableSwiss.parse(named.result().ready.string) orelse return error.InvalidName);
        restricted_name = use_name;
        for ([_]h.driver.Capability{ original, use, control }, [_]h.driver.Host.DurableSwiss{ original_name, use_name, control_name }, 0..) |cap, name, index| {
            const uri = try f.uri(a, name);
            defer a.free(uri);
            const put = try f.send(&source, &source_db, &target, &target_db, pair, source.use, "put", &.{ .{ .integer = @intCast(index) }, .{ .capability = cap }, .{ .string = uri } });
            defer put.deinit();
            try std.testing.expect(put.result().ready.boolean);
        }
    }
    try source_store.deinit();
    try target_store.deinit();
    try source_db.compact();
    try target_db.compact();
    try source_db.close();
    try target_db.close();
    source_db = try Lmdb.open(source_z, .{ .mode = .{ .open = h.f.store_id } });
    target_db = try Lmdb.open(target_z, .{ .mode = .{ .open = @fromBackingInt(95) } });
    source_store = try h.loam.core.Store.init(a, source_db.metadata, &f.schemas, h.limits);
    target_store = try h.loam.core.Store.init(a, target_db.metadata, &h.schemas, h.limits);
    var source: h.Hosted = undefined;
    try source.init(&source_store, &source_db, source_data);
    defer source.deinit();
    source.service.contents = &f.contents;
    // Restore the source before its remote vat exists. Its ordinary local
    // content remains usable; reference preparation parks at Host's dial owner.
    var local: h.Answer = .{};
    try source.send(source.use, "get", &.{}, &local);
    try source.drain(&source_db);
    try std.testing.expectEqual(@as(?i64, 17), local.number);
    // A parked restoration is neither admission nor a frozen grant snapshot.
    // Exercise unavailable transport and a concurrent source grant change
    // before starting the target vat; both retire the network owner cleanly.
    for ([_]bool{ false, true }) |pause_source| {
        var parked: h.Answer = .{};
        try source.send(source.use, "ref", &.{.{ .integer = 0 }}, &parked);
        for (0..64) |_| {
            _ = try source.host.vat.driveIngressBudgeted(.local, 64);
            try source.attached.advance();
            if (try source.reads(&source_db)) |_| return error.UnexpectedWrite;
            if (source.host.pending_enliven_count == 1) break;
        } else return error.RestorationDidNotPark;
        if (pause_source) {
            _ = try h.f.change(&source_store, &source_db, source_data.owner, .{ .pause = source_data.grant });
        } else {
            const unavailable = blk: {
                while (try source.host.nextAction()) |action| if (action == .dial) break :blk action.dial;
                return error.MissingDial;
            };
            try source.host.dialFailed(unavailable.ticket, unavailable.route_index, "unavailable");
        }
        try source.drain(&source_db);
        try std.testing.expect(parked.broken);
        try std.testing.expectEqual(@as(usize, 0), source.host.pending_enliven_count);
        try std.testing.expectEqual(@as(usize, 0), source.attached.reference_saves);
        // Retire any emitted adapter intent whose observer was canceled.
        while (try source.host.nextAction()) |action| if (action == .dial)
            try source.host.dialFailed(action.dial.ticket, action.dial.route_index, "unavailable");
        if (pause_source) _ = try h.f.change(&source_store, &source_db, source_data.owner, .{ .resume_access = source_data.grant });
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var lease = try h.c.load(&source_store, &source_db, source_data.content);
    var call: h.loam.hosting.Call = .{ .arena = arena.allocator(), .attachment = source.attached, .view = try source_store.currentView(lease) };
    defer call.release();
    var prepared = try f.refs.Set.create(&call, call.view, &.{ .{ .restore = 0 }, .{ .restore = 1 }, .{ .restore = 2 } });
    for (0..32) |_| switch (try prepared.advance()) {
        .read => |read| try prepared.completeRead(read.ticket, source_db.read(read)),
        .waiting => break,
        .ready => return error.RestoredMissingVat,
    };
    const dial = blk: {
        while (try source.host.nextAction()) |action| if (action == .dial) break :blk action.dial;
        return error.MissingDial;
    };
    try collect(&source_store, &source_db);
    try collect(&target_store, &target_db);
    call.release();
    try source_store.release(lease);
    lease = try h.c.load(&source_store, &source_db, source_data.content);
    defer source_store.release(lease) catch unreachable;
    call = .{ .arena = arena.allocator(), .attachment = source.attached, .view = try source_store.currentView(lease) };
    prepared = try f.refs.Set.create(&call, call.view, &.{ .{ .restore = 0 }, .{ .restore = 1 }, .{ .restore = 2 } });
    var target: h.Hosted = undefined;
    try target.initIdentity(&target_store, &target_db, target_data, .{}, @splat(0x65));
    defer target.deinit();
    try h.loam.hosting.publication.listen(target.attached, .{});
    const accepted = try f.pairs.publishAndOpenAccepted(&target.host, "tcp", "127.0.0.1:9791", &.{});
    try source.host.ensureAdvertisedLocator("tcp");
    const connected = (try source.host.openPendingDial(dial.ticket, dial.route_index)).?;
    const pair: f.pairs.Pair = .{ .ah = &source.host, .a = connected, .bh = &target.host, .b = accepted };
    try f.pairs.pumpToQuiescence(&.{pair});
    _ = try source.host.exporterDialed(dial.ticket, dial.route_index, connected);
    for (0..64) |_| {
        switch (try prepared.advance()) {
            .read => |read| try prepared.completeRead(read.ticket, source_db.read(read)),
            .waiting => {},
            .ready => break,
        }
        try f.pump(&source, &source_db, &target, &target_db, pair);
    } else return error.RestorationDidNotFinish;
    const original = try call.edge(0);
    const use = try call.edge(1);
    const control = try call.edge(2);
    try std.testing.expect(!original.eql(use) and !use.eql(control) and !original.eql(control));
    const read = try f.send(&source, &source_db, &target, &target_db, pair, use, "get", &.{});
    defer read.deinit();
    try std.testing.expectEqual(@as(i64, 0), read.result().ready.integer);
    const denied = try f.send(&source, &source_db, &target, &target_db, pair, use, "mutate", &.{ .{ .integer = 1 }, .{ .string = "add" }, .{ .integer = 3 } });
    defer denied.deinit();
    try std.testing.expect(denied.result() == .failed);
    const written = try f.send(&source, &source_db, &target, &target_db, pair, original, "mutate", &.{ .{ .integer = 1 }, .{ .string = "add" }, .{ .integer = 3 } });
    defer written.deinit();
    try std.testing.expectEqual(@as(i64, 3), written.result().ready.integer);
    const paused = try f.send(&source, &source_db, &target, &target_db, pair, control, "pause", &.{});
    defer paused.deinit();
    try std.testing.expect(paused.result().ready.boolean);
    const inactive = try f.send(&source, &source_db, &target, &target_db, pair, use, "get", &.{});
    defer inactive.deinit();
    try std.testing.expect(inactive.result() == .failed);
    const revoked = try f.send(&source, &source_db, &target, &target_db, pair, control, "revoke", &.{});
    defer revoked.deinit();
    try std.testing.expect(revoked.result().ready.boolean);
    // The name still restores the exact role after revocation; neither a held
    // field nor repeated enlivenment can revive its removed authority.
    const retired_use = try f.fetch(&source, &source_db, &target, &target_db, pair, restricted_name.?);
    defer source.host.releaseCapabilityTerminal(retired_use, null);
    try std.testing.expect(retired_use.eql(use));
    const refused = try f.send(&source, &source_db, &target, &target_db, pair, retired_use, "get", &.{});
    defer refused.deinit();
    try std.testing.expect(refused.result() == .failed);
    call.release();
}
