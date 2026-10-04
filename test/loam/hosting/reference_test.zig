//! Local restoration retains dependencies before their attachment is present.
const std = @import("std");
const f = @import("fixture.zig");
const records = @import("../core/fixture.zig");
const refs = f.hosting.references;
const a = std.testing.allocator;
const schemas = f.schemas ++ [_]f.loam.core.Schema{refs.schema};

test "loam reference declarations retain every save target before preparation advances" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const store = &fixture.data.store;
    try store.begin();
    const id = try store.allocateId();
    var row = records.record(id, &@as([8]u8, @splat(0)));
    row.rooted = true;
    try store.putCopying(row, null);
    try records.commit(store, &fixture.data.backend);
    const lease = try records.load(store, &fixture.data.backend, id);
    defer store.release(lease) catch unreachable;
    const target = try fixture.attached.restore(lease);
    var target_owned = true;
    defer if (target_owned) fixture.host.releaseCapabilityTerminal(target, null);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var call: f.hosting.Call = .{ .arena = arena.allocator(), .attachment = fixture.attached, .view = try store.currentView(lease) };
    defer call.release();
    const working = try refs.Set.create(&call, call.view, &.{ .{ .save = .{ .capability = fixture.root } }, .{ .save = .{ .capability = target } } });
    fixture.host.releaseCapabilityTerminal(target, null);
    target_owned = false;
    try std.testing.expect(fixture.host.localActorFor(target) != null);
    try std.testing.expect(try working.advance() == .ready);
    call.release();
    try std.testing.expect(fixture.host.localActorFor(target) == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.attached.reference_saves);
    const baseline = fixture.host.capabilities.retainCount(fixture.root).?;
    try std.testing.expectError(error.UnknownCapability, refs.Set.create(&call, call.view, &.{ .{ .save = .{ .capability = fixture.root } }, .{ .save = .{ .capability = target } } }));
    try std.testing.expect(call.references == null);
    try std.testing.expectEqual(baseline, fixture.host.capabilities.retainCount(fixture.root).?);
    _ = try refs.Set.create(&call, call.view, &.{.{ .save = .{ .capability = fixture.root } }});
    call.release();
    try std.testing.expectEqual(baseline, fixture.host.capabilities.retainCount(fixture.root).?);
}

test "loam local save allocation refusal and dependent spawn preserve custody" {
    try std.testing.checkAllAllocationFailures(a, saveAllocation, .{});
    try std.testing.checkAllAllocationFailures(a, facetAllocation, .{});
}

fn saveAllocation(allocator: std.mem.Allocator) !void {
    var fixture: f.Fixture = undefined;
    try fixture.initAllocator(allocator, .{ .max_reference_saves = 1 });
    defer fixture.deinit();
    const save = try refs.beginSave(fixture.attached, allocator, fixture.root, null);
    defer save.deinit();
    try std.testing.expect(save.result() == .ready);
    try std.testing.expectError(error.ReferenceCapacity, refs.beginSave(fixture.attached, allocator, fixture.root, null));
}

fn facetAllocation(allocator: std.mem.Allocator) !void {
    var fixture: f.Fixture = undefined;
    try fixture.initAllocator(allocator, .{});
    defer fixture.deinit();
    const facet = try fixture.attached.projectDependent(fixture.id, fixture.root);
    fixture.host.releaseCapabilityTerminal(facet, null);
    _ = try fixture.host.vat.near(fixture.host.localActorFor(fixture.root).?, .{ .verb = "get", .args = &.{} });
    try std.testing.expectEqual(@as(usize, 0), fixture.attached.dependent_facets);
}

test "loam saved proof refuses another attachment's restoration owner" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const other = try f.hosting.Attachment.create(a, &fixture.host, &fixture.data.store, &f.behaviors, .{});
    defer other.destroy() catch unreachable;
    const save = try refs.beginSave(fixture.attached, a, fixture.root, null);
    defer save.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var call: f.hosting.Call = .{ .arena = arena.allocator(), .attachment = other, .view = undefined };
    defer call.release();
    try std.testing.expectError(error.ForeignAttachment, refs.copySaved(&call, save));
}

test "loam foreign promise save refuses before fetching a durable name" {
    const wire = @import("../../driver/core_host/harness.zig");
    const support = @import("../../support/core_host.zig");
    const model = @import("glowcap").ocapn.model;
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    var remote = support.init(a, @splat(0x73), f.driver.Host.Options.withFrameCap(wire.frame_cap));
    defer remote.deinit();
    var dials: std.ArrayList(wire.ParkedDial) = .empty;
    defer dials.deinit(a);
    const pair = try wire.openPair(a, &fixture.host, &remote, "127.0.0.1:7917", &dials);
    try pair.a.served.port.peer.importObject(7);
    const promise = try fixture.host.liftCapability(pair.a, .{ .far = model.FarRef.promise(7) });
    defer fixture.host.releaseCapabilityTerminal(promise, null);
    const uri = try model.uri.writeSturdyref(a, wire.tcpSturdyref("127.0.0.1:7917", "promise"));
    defer a.free(uri);
    const result = refs.beginSave(fixture.attached, a, promise, uri);
    defer if (result) |save| save.deinit() else |_| {};
    try std.testing.expectError(error.NotDurable, result);
    try std.testing.expectEqual(@as(usize, 0), fixture.attached.reference_saves);
    try std.testing.expectEqual(@as(usize, 0), fixture.host.pendingVowCount());
}

test "loam local recipe survives reverse attachment startup and collection while parked" {
    var backend = try f.loam.Volatile.init(a, records.id, 1024 * 1024);
    defer backend.deinit();
    var limits = records.limits;
    limits.cache_slots = 8;
    limits.max_leases = 8;
    limits.resident_bytes = 8192;
    var store = try f.loam.core.Store.init(a, try backend.open(), &schemas, limits);
    defer store.deinit() catch unreachable;
    var scope = try refs.Scope.init(a, 2);
    defer scope.deinit() catch unreachable;
    var host = @import("../../support/core_host.zig").init(a, @splat(0x72), .{});
    defer host.deinit();
    var source = try f.hosting.Attachment.create(a, &host, &store, &f.behaviors, .{ .reference_scope = &scope, .attachment_name = "source" });
    defer source.destroy() catch unreachable;
    var target = try f.hosting.Attachment.create(a, &host, &store, &f.behaviors, .{ .reference_scope = &scope, .attachment_name = "target" });
    var target_open = true;
    defer if (target_open) target.destroy() catch unreachable;
    try store.begin();
    const target_id = try store.allocateId();
    var number: [8]u8 = undefined;
    std.mem.writeInt(i64, &number, 29, .little);
    var row = records.record(target_id, &number);
    row.rooted = true;
    try store.putCopying(row, null);
    try records.commit(&store, &backend);
    var lease = try records.load(&store, &backend, target_id);
    const cap = try target.restore(lease);
    try store.release(lease);
    const save = try refs.beginSave(source, a, cap, null);
    try std.testing.expect(save.result() == .ready);
    try std.testing.expectError(error.Busy, source.destroy());
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    lease = try records.load(&store, &backend, target_id);
    var call: f.hosting.Call = .{ .arena = arena.allocator(), .attachment = source, .view = try store.currentView(lease) };
    defer call.release();
    const replacement = try refs.copySaved(&call, save);
    try store.begin();
    const edge = try replacement.saved.stage(&store);
    const root = try store.allocateId();
    row = records.record(root, &number);
    row.rooted = true;
    row.edges = &.{edge};
    try store.putCopying(row, null);
    const target_view = try store.currentView(lease);
    try store.putCopying(.{ .id = target_id, .revision = 0, .schema = 7, .payload = target_view.payload }, target_view.revision);
    try records.commit(&store, &backend);
    call.release();
    try store.release(lease);
    save.deinit();
    host.releaseCapabilityTerminal(cap, null);
    try target.destroy();
    target_open = false;
    try source.destroy();
    host.deinit();
    try store.deinit();
    backend.close();
    store = try f.loam.core.Store.init(a, try backend.open(), &schemas, limits);
    host = @import("../../support/core_host.zig").init(a, @splat(0x72), .{});
    source = try f.hosting.Attachment.create(a, &host, &store, &f.behaviors, .{ .reference_scope = &scope, .attachment_name = "source" });
    // The durable edge protects the target before its restoration owner exists.
    try records.collect(&store, &backend);
    store.evict();
    lease = try records.load(&store, &backend, root);
    call = .{ .arena = arena.allocator(), .attachment = source, .view = try store.currentView(lease) };
    // A refused recipe read retires its ticket and all preparation custody.
    var working = try refs.Set.create(&call, call.view, &.{.{ .restore = 0 }});
    const refused = (try working.advance()).read;
    try std.testing.expectError(error.InjectedRead, working.completeRead(refused.ticket, .{ .failed = error.InjectedRead }));
    call.release();
    call = .{ .arena = arena.allocator(), .attachment = source, .view = try store.currentView(lease) };
    working = try refs.Set.create(&call, call.view, &.{.{ .restore = 0 }});
    for (0..8) |_| switch (try working.advance()) {
        .read => |read| try working.completeRead(read.ticket, backend.read(read)),
        .waiting => break,
        .ready => return error.RestoredMissingAttachment,
    };
    try records.collect(&store, &backend);
    try std.testing.expectEqual(@as(u64, 3), store.metadata.objects);
    try std.testing.expectError(error.StaleSnapshot, working.advance());
    call.release();
    try store.release(lease);
    lease = try records.load(&store, &backend, root);
    call = .{ .arena = arena.allocator(), .attachment = source, .view = try store.currentView(lease) };
    working = try refs.Set.create(&call, call.view, &.{.{ .restore = 0 }});
    for (0..8) |_| switch (try working.advance()) {
        .read => |read| try working.completeRead(read.ticket, backend.read(read)),
        .waiting => break,
        .ready => return error.RestoredMissingAttachment,
    };
    target = try f.hosting.Attachment.create(a, &host, &store, &f.behaviors, .{ .reference_scope = &scope, .attachment_name = "target" });
    target_open = true;
    try std.testing.expect(try working.advance() == .ready);
    const restored = try call.edge(0);
    const target_lease = try records.load(&store, &backend, target_id);

    const result = try host.vat.near(host.localActorFor(restored).?, .{ .verb = "get", .args = &.{} });
    try std.testing.expectEqual(@as(i64, 29), result.integer);
    try store.release(target_lease);
    call.release();
    try store.release(lease);
    try target.destroy();
    target_open = false;
    lease = try records.load(&store, &backend, root);
    const old = try store.currentView(lease);
    try store.begin();
    try store.putCopying(.{ .id = root, .revision = 0, .schema = 7, .rooted = true, .payload = old.payload }, old.revision);
    try records.commit(&store, &backend);
    try store.release(lease);
    store.evict();
    try records.collect(&store, &backend);
    try std.testing.expectEqual(@as(u64, 1), store.metadata.objects);
    try std.testing.expectError(error.Gone, records.load(&store, &backend, target_id));
}
