//! URI parse state retires before waiting and between prepared references.
const std = @import("std");
const f = @import("fixture.zig");
const records = @import("../core/fixture.zig");
const wire = @import("../../driver/core_host/harness.zig");
const pair_support = @import("../../support/host_pair.zig");
const model = @import("glowcap").ocapn.model;
const refs = f.hosting.references;
const a = std.testing.allocator;

fn maximumUri(input: model.SturdyRef) ![4096]u8 {
    var hints: [model.max_locator_hint_count]model.HintEntry = undefined;
    var names: [model.max_locator_hint_count][4]u8 = undefined;
    for (&hints, &names, 0..) |*hint, *name, index| hint.* = .{
        .name = try std.fmt.bufPrint(name, "h{d:0>2}", .{index}),
        .value = .{ .string = if (index + 1 == hints.len) "" else "x" },
    };
    var sturdy = input;
    sturdy.peer.hints = .{ .entries = &hints };
    const prefix = try model.uri.measureSturdyrefForProfile(.v1_0, sturdy);
    const padding: [4096]u8 = @splat('x');
    hints[hints.len - 1].value = .{ .string = padding[0 .. padding.len - prefix] };
    var uri: [4096]u8 = undefined;
    const written = try model.uri.writeSturdyrefForProfileBounded(.v1_0, sturdy, &uri);
    try std.testing.expect(written.complete and written.len == uri.len);
    return uri;
}

fn reuseScratch(memory: *f.hosting.Call.Memory) !void {
    var scratch = memory.scratch();
    defer scratch.deinit();
    @memset(try scratch.allocator().alloc(u8, 32 * 1024), 0xab);
}

test "loam URI allocation bound includes escaped Swiss and refused hint-spine resizing" {
    const canonical = try maximumUri(wire.tcpSturdyref("127.0.0.1:7930", "owned Swiss bytes"));
    const path = std.mem.indexOf(u8, &canonical, "/s/").? + 3;
    var escaped: [canonical.len + 2]u8 = undefined;
    @memcpy(escaped[0..path], canonical[0..path]);
    escaped[path] = '%';
    const alphabet = "0123456789ABCDEF";
    escaped[path + 1] = alphabet[canonical[path] >> 4];
    escaped[path + 2] = alphabet[canonical[path] & 15];
    @memcpy(escaped[path + 3 ..], canonical[path + 1 ..]);
    var measured = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
    const parsed = try model.uri.parseSturdyref(measured.allocator(), &escaped);
    defer model.uri.freeSturdyref(measured.allocator(), parsed);
    try std.testing.expectEqualStrings("owned Swiss bytes", parsed.swissnum);
    try std.testing.expectEqual(model.max_locator_hint_count, parsed.peer.hints.entries.len);
    const bound = try model.uri.parseAllocationBound(escaped.len, model.max_locator_hint_count);
    try std.testing.expect(measured.alloc_index <= bound.allocations);
    try std.testing.expect(measured.allocated_bytes <= bound.bytes);
    try std.testing.expectError(error.InvalidLocator, model.uri.parseAllocationBound(escaped.len, model.max_locator_hint_count + 1));
    try std.testing.expectError(error.Overflow, model.uri.parseAllocationBound(std.math.maxInt(usize), 0));
}

test "loam reference allocation bounds compose recipes and one URI window without allocating" {
    const one = try refs.allocationBound(1, 1, 4096);
    const many = try refs.allocationBound(3592, 3592, 4096);
    try std.testing.expect(many.bytes > one.bytes);
    // URI parser spines are one synchronous window, not one retained population.
    try std.testing.expect(many.bytes < try std.math.mul(usize, one.bytes, 3592));

    try std.testing.expectError(error.RecordTooLarge, refs.allocationBound(1, 1, 4097));
    try std.testing.expectError(error.Overflow, refs.allocationBound(std.math.maxInt(usize), 1, 4096));
}

test "loam empty reference preparation fits its allocation bound" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const lease = try records.load(&fixture.data.store, &fixture.data.backend, fixture.id);
    defer fixture.data.store.release(lease) catch unreachable;
    const bound = try refs.allocationBound(0, 0, 0);
    try std.testing.expect(bound.bytes != 0 and bound.allocations == 1);
    var memory: f.hosting.Call.Memory = undefined;
    memory.init(a, try bound.physicalBytes());
    defer memory.deinit();
    var call: f.hosting.Call = .{ .memory = &memory, .attachment = fixture.attached, .view = try fixture.data.store.currentView(lease) };
    defer call.release();
    const working = try refs.Set.create(&call, call.view, &.{});
    try std.testing.expect(try working.advance() == .ready);
}

test "loam save URI bound includes canonical percent expansion of accepted input" {
    const slashes: [1000]u8 = @splat('/');
    var input: [1100]u8 = undefined;
    const supplied = try std.fmt.bufPrint(&input, "ocapn://127.0.0.1%3A7930.tcp/s/YQ?hint={s}", .{slashes});
    const parsed = try model.uri.parseSturdyref(a, supplied);
    defer model.uri.freeSturdyref(a, parsed);
    const canonical = try model.uri.writeSturdyref(a, parsed);
    defer a.free(canonical);
    try std.testing.expect(canonical.len > supplied.len);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "%2F") != null);
    try std.testing.expect(canonical.len <= try refs.Save.canonicalUriBytesBound(supplied.len));
    try std.testing.expectEqual(@as(usize, 4096), try refs.Save.canonicalUriBytesBound(4096));
    try std.testing.expectError(error.RecordTooLarge, refs.Save.canonicalUriBytesBound(4097));
}

test "loam many maximum URI saves share one scratch window through pending readiness and cancellation" {
    for ([_]bool{ false, true }) |cancel| {
        var fixture: f.Fixture = undefined;
        try fixture.init(.{ .max_reference_saves = 32 });
        defer fixture.deinit();
        var remote = @import("../../support/core_host.zig").init(a, @splat(0x73), f.driver.Host.Options.withFrameCap(wire.frame_cap));
        defer remote.deinit();
        _ = try remote.publish("field", wire.Widget, .{});
        const pair = try pair_support.openPair(&fixture.host, &remote, "127.0.0.1:7931");
        const fetched = try fixture.host.enlivenCapability(a, wire.tcpSturdyref("127.0.0.1:7931", "field"));
        defer fetched.deinit();
        try pair_support.pumpToQuiescence(&.{pair});
        const held = fetched.result().ready.capability;
        const target = (try remote.publishedCapability(pair.b, "field")).?;
        defer remote.releaseCapabilityTerminal(target, null);
        // This new durable name points to the held object, but has never been
        // fetched by the source. The first save must wait for wire readiness.
        const swiss = try remote.publishDurableCapability(@splat(0x74), target);
        const uri = try maximumUri(wire.tcpSturdyref("127.0.0.1:7931", swiss.slice()));
        const lease = try records.load(&fixture.data.store, &fixture.data.backend, fixture.id);
        defer fixture.data.store.release(lease) catch unreachable;
        var memory: f.hosting.Call.Memory = undefined;
        memory.init(a, 256 * 1024);
        defer memory.deinit();
        var call: f.hosting.Call = .{ .memory = &memory, .attachment = fixture.attached, .view = try fixture.data.store.currentView(lease) };
        defer call.release();
        const baseline = fixture.host.capabilities.retainCount(held).?;
        const requests: [32]refs.Request = @splat(.{ .save = .{ .capability = held, .uri = &uri } });
        const working = try refs.Set.create(&call, call.view, &requests);
        try std.testing.expect(try working.advance() == .waiting);
        try std.testing.expectEqual(@as(usize, 1), fixture.attached.reference_saves);
        const waiting_bytes = memory.backing.used;
        try reuseScratch(&memory);
        try std.testing.expectEqual(waiting_bytes, memory.backing.used);
        if (!cancel) {
            try pair_support.pumpToQuiescence(&.{pair});
            try std.testing.expect(try working.advance() == .ready);
            try std.testing.expectEqual(requests.len, fixture.attached.reference_saves);
            try std.testing.expect((try working.captured(held)) == .saved);
            try std.testing.expect(memory.backing.used > waiting_bytes);
        }
        call.release();
        try std.testing.expectEqual(@as(usize, 0), fixture.attached.reference_saves);
        try std.testing.expectEqual(baseline, fixture.host.capabilities.retainCount(held).?);
        // An already queued fetch may still finish after its observer retires.
        try pair_support.pumpToQuiescence(&.{pair});
    }
}

test "loam cold foreign recipes retire URI scratch before readiness and each next cache window" {
    var backend = try f.loam.Volatile.init(a, records.id, 1024 * 1024);
    defer backend.deinit();
    const schemas = [_]f.loam.core.Schema{ .{ .id = 7, .version = 1, .max_payload = 8, .max_edges = 32 }, refs.schema };
    var limits = records.limits;
    limits.records = .{ .max_record_bytes = 8192, .max_edges = 32 };
    limits.resident_bytes = 16 * 1024;
    limits.staging_bytes = 256 * 1024;
    limits.max_changes = 33;
    var store = try f.loam.core.Store.init(a, try backend.open(), &schemas, limits);
    defer store.deinit() catch unreachable;
    var host = @import("../../support/core_host.zig").init(a, @splat(0x75), f.driver.Host.Options.withFrameCap(wire.frame_cap));
    defer host.deinit();
    const attached = try f.hosting.Attachment.create(a, &host, &store, &f.behaviors, .{});
    defer attached.destroy() catch unreachable;
    var remote = @import("../../support/core_host.zig").init(a, @splat(0x76), f.driver.Host.Options.withFrameCap(wire.frame_cap));
    defer remote.deinit();
    _ = try remote.publish("field", wire.Widget, .{});
    const pair = try pair_support.openPair(&host, &remote, "127.0.0.1:7932");
    const fetched = try host.enlivenCapability(a, wire.tcpSturdyref("127.0.0.1:7932", "field"));
    defer fetched.deinit();
    try pair_support.pumpToQuiescence(&.{pair});
    const held = fetched.result().ready.capability;
    const target = (try remote.publishedCapability(pair.b, "field")).?;
    defer remote.releaseCapabilityTerminal(target, null);
    const swiss = try remote.publishDurableCapability(@splat(0x77), target);
    const uri = try maximumUri(wire.tcpSturdyref("127.0.0.1:7932", swiss.slice()));
    var payload: [4097]u8 = undefined;
    payload[0] = 1;
    @memcpy(payload[1..], &uri);
    try store.begin();
    const root = try store.allocateId();
    var edges: [32]f.loam.core.Edge = undefined;
    for (&edges) |*edge| {
        const id = try store.allocateId();
        try store.putCopying(.{ .id = id, .revision = 0, .schema = refs.schema.id, .payload = &payload }, null);
        edge.* = .{ .target = id, .restoration = .recipe };
    }
    try store.putCopying(.{ .id = root, .revision = 0, .schema = 7, .payload = &@as([8]u8, @splat(0)), .edges = &edges, .rooted = true }, null);
    try records.commit(&store, &backend);
    store.evict();
    const lease = try records.load(&store, &backend, root);
    defer store.release(lease) catch unreachable;
    var memory: f.hosting.Call.Memory = undefined;
    memory.init(a, 256 * 1024);
    defer memory.deinit();
    var call: f.hosting.Call = .{ .memory = &memory, .attachment = attached, .view = try store.currentView(lease) };
    defer call.release();
    const baseline = host.capabilities.retainCount(held).?;
    var requests: [32]refs.Request = undefined;
    for (&requests, 0..) |*request, index| request.* = .{ .restore = index };
    const working = try refs.Set.create(&call, call.view, &requests);
    var reads: usize = 0;
    while (true) switch (try working.advance()) {
        .read => |read| {
            reads += 1;
            try working.completeRead(read.ticket, backend.read(read));
        },
        .waiting => break,
        .ready => return error.ExpectedPendingForeignRestore,
    };
    const waiting_bytes = memory.backing.used;
    try reuseScratch(&memory);
    try std.testing.expectEqual(waiting_bytes, memory.backing.used);
    try pair_support.pumpToQuiescence(&.{pair});
    while (true) switch (try working.advance()) {
        .read => |read| {
            reads += 1;
            try working.completeRead(read.ticket, backend.read(read));
        },
        .waiting => return error.UnexpectedWait,
        .ready => break,
    };
    try std.testing.expectEqual(requests.len, reads);
    try std.testing.expectEqual(@as(usize, 2), store.cache.slots.len);
    for (0..requests.len) |index| try std.testing.expect((try call.storedEdge(call.view, index)).eql(held));
    call.release();
    try std.testing.expectEqual(baseline, host.capabilities.retainCount(held).?);
}
