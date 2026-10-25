//! Live fields retain exact authority through storage outcomes and end at restart.
const std = @import("std");
const f = @import("fixture.zig");
const records = @import("../core/fixture.zig");
const support = @import("../../support/core_host.zig");
const pairs = @import("../../support/host_pair.zig");
const CapturedRef = @import("../../support/capture.zig").CapturedRef;
const refs = f.hosting.references;
const a = std.testing.allocator;
const schemas = f.schemas ++ [_]f.loam.core.Schema{ refs.schema, f.hosting.LiveEpoch.schema };

const Echo = struct {
    pub fn handle(_: *Echo, turn: *f.driver.HostTurn, _: []const u8, args: f.driver.Args) !f.driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        return .{ .integer = 42 };
    }
};

const Edit = struct {
    call: *f.hosting.Call,
    saved: ?*refs.Saved,
    fn stage(context: *anyopaque, store: *f.loam.core.Store) !void {
        const self: *Edit = @ptrCast(@alignCast(context));
        const view = self.call.view;
        const edges: []const f.loam.core.Edge = if (self.saved) |saved| &.{try saved.stage(store)} else &.{};
        try store.putCopying(.{ .id = view.id, .revision = 0, .schema = 7, .rooted = true, .payload = view.payload, .edges = edges }, view.revision);
    }
};

fn prepare(call: *f.hosting.Call, verb: []const u8, args: []const f.driver.Value) !f.hosting.Preparation {
    const requests: []const refs.Request = if (std.mem.startsWith(u8, verb, "putDependent")) &.{.{ .save_live_dependent = .{ .source = args[1].capability, .target = args[0].capability } }} else if (std.mem.startsWith(u8, verb, "put")) &.{.{ .save_live = args[0].capability }} else if (std.mem.eql(u8, verb, "get")) &.{.{ .restore = 0 }} else &.{};
    const set = try refs.Set.create(call, call.view, requests);
    return .{ .context = set, .advanceFn = advance, .completeFn = complete, .deinitFn = deinit };
}
fn advance(context: *anyopaque) !f.hosting.Preparation.Step {
    const set: *refs.Set = @ptrCast(@alignCast(context));
    return set.advance();
}
fn complete(context: *anyopaque, ticket: f.loam.core.Ticket, result: f.loam.core.ReadResult) !void {
    const set: *refs.Set = @ptrCast(@alignCast(context));
    return set.completeRead(ticket, result);
}
fn deinit(_: *anyopaque) void {} // Call owns reference preparation retirement.

fn invoke(call: *f.hosting.Call, _: f.loam.core.RecordView, verb: []const u8, args: []const f.driver.Value) !f.driver.Value {
    if (std.mem.eql(u8, verb, "get")) return .{ .capability = try call.edge(0) };
    const edit = try call.arena().create(Edit);
    const target: ?f.driver.Capability = if (std.mem.startsWith(u8, verb, "putDependent")) try call.references.?.preparedDependent(args[1].capability, args[0].capability) else if (args.len != 0) args[0].capability else null;
    edit.* = .{ .call = call, .saved = if (std.mem.startsWith(u8, verb, "put")) (try call.references.?.captured(target.?)).saved else null };
    call.transaction = .{ .context = edit, .stage = Edit.stage };
    if (std.mem.endsWith(u8, verb, "Huge")) return .{ .string = &@as([500]u8, @splat('x')) };
    return .{ .void = {} };
}
const behaviors = [_]f.hosting.Behavior{.{ .schema = 7, .prepare = prepare, .invoke = invoke }};

const Fixture = struct {
    data: records.Fixture,
    host: f.driver.Host,
    scope: f.hosting.LiveScope,
    attached: *f.hosting.Attachment,
    root: f.driver.Capability,
    target: f.driver.Capability,
    id: f.loam.core.ObjectId,
    marker: f.loam.core.ObjectId,

    fn init(self: *Fixture) !void {
        self.data.backend = try f.loam.Volatile.init(a, records.id, 1024 * 1024);
        self.data.store = try f.loam.core.Store.init(a, try self.data.backend.open(), &schemas, records.limits);
        self.host = support.init(a, @splat(0x71), .{});
        self.scope = try f.hosting.LiveScope.init(a, &self.host, &self.data.store, 2);
        try self.data.store.begin();
        self.marker = try self.scope.stageStart(null);
        self.id = try self.data.store.allocateId();
        var row = records.record(self.id, &@as([8]u8, @splat(0)));
        row.rooted = true;
        try self.data.store.putCopying(row, null);
        try records.commit(&self.data.store, &self.data.backend);
        const lease = try records.load(&self.data.store, &self.data.backend, self.marker);
        try self.scope.confirmStart(lease);
        try self.data.store.release(lease);
        self.attached = try f.hosting.Attachment.create(a, &self.host, &self.data.store, &behaviors, .{ .live_scope = &self.scope });
        const root = try records.load(&self.data.store, &self.data.backend, self.id);
        self.root = try self.attached.restore(root);
        try self.data.store.release(root);
        const actor = try self.host.vat.spawn(f.driver.Hosting(Echo), .{ .inner = .{} });
        self.target = try self.host.liftLocalActor(actor);
    }
    fn deinit(self: *Fixture) void {
        self.host.releaseCapabilityTerminal(self.target, null);
        self.host.releaseCapabilityTerminal(self.root, null);
        self.attached.destroy() catch unreachable;
        self.scope.deinit() catch unreachable;
        self.host.deinit();
        self.data.deinit();
    }
    fn tick(self: *Fixture, writes: bool) !?f.loam.core.Batch {
        _ = try self.host.vat.driveIngressBudgeted(.local, 64);
        try self.attached.advance();
        while (try self.attached.nextWork()) |work| switch (work) {
            .read => |read| try self.attached.completeRead(read.ticket, self.data.backend.read(read)),
            .lookup => return error.UnexpectedLookup,
            .write => |batch| {
                if (!writes) return batch;
                try self.attached.completeWrite(batch.ticket, self.data.backend.commit(batch));
            },
        };
        return null;
    }
    fn drain(self: *Fixture) !void {
        for (0..128) |_| {
            _ = try self.tick(true);
            if (!self.attached.hasPendingWork() and !self.host.hasRunnableWork()) return;
        }
        return error.DidNotQuiesce;
    }
    fn put(self: *Fixture, verb: []const u8, bytes: usize) !*f.driver.Host.Call {
        return self.host.callLocalCapability(a, self.root, verb, &.{ .{ .capability = self.target }, .{ .capability = self.root } }, bytes);
    }
    fn drainPair(self: *Fixture, pair: pairs.Pair) !void {
        for (0..128) |_| {
            _ = try self.tick(true);
            try pairs.pumpToQuiescence(&.{pair});
            // The byte shuttle consumes frames; retire their adapter wake hints.
            while (try self.host.nextAction()) |action| switch (action) {
                .flush => {},
                else => return error.UnexpectedHostAction,
            };
            if (!self.attached.hasPendingWork() and !self.host.hasRunnableWork()) return;
        }
        return error.DidNotQuiesce;
    }
    fn get(self: *Fixture) !*f.driver.Host.Call {
        return self.host.callLocalCapability(a, self.root, "get", &.{}, 256);
    }
    fn write(self: *Fixture) !f.loam.core.Batch {
        for (0..128) |_| if (try self.tick(false)) |batch| return batch;
        return error.WriteNotSubmitted;
    }
};

test "loam live reference reserves exact custody before waits and capacity refusal cancels declarations" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const store = &fixture.data.store;
    const lease = try records.load(store, &fixture.data.backend, fixture.id);
    defer store.release(lease) catch unreachable;
    var memory: f.hosting.Call.Memory = undefined;
    memory.init(a, 65536);
    defer memory.deinit();
    var call: f.hosting.Call = .{ .memory = &memory, .attachment = fixture.attached, .view = try store.currentView(lease) };
    defer call.release();
    const before = fixture.host.capabilities.retainCount(fixture.target).?;
    const request: refs.Request = .{ .save_live = fixture.target };
    try std.testing.expectError(error.ReferenceCapacity, refs.Set.create(&call, call.view, &.{ request, request, request }));
    try std.testing.expect(call.references == null);
    try std.testing.expectEqual(before, fixture.host.capabilities.retainCount(fixture.target).?);
    _ = try refs.Set.create(&call, call.view, &.{ request, request });
    try std.testing.expectEqual(before + 2, fixture.host.capabilities.retainCount(fixture.target).?);
    try std.testing.expectError(error.NotDurable, refs.beginSave(fixture.attached, a, fixture.target, null));
    call.release();
    try std.testing.expectEqual(before, fixture.host.capabilities.retainCount(fixture.target).?);
}

test "loam live reference indexed lookup refreshes after cold preparation and preserves live capture" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const put = try fixture.put("put", 256);
    defer put.deinit();
    try fixture.drain();
    try std.testing.expect(put.result() == .ready);
    const store = &fixture.data.store;
    store.evict();
    const lease = try records.load(store, &fixture.data.backend, fixture.id);
    defer store.release(lease) catch unreachable;
    const view = try store.currentView(lease);
    var memory: f.hosting.Call.Memory = undefined;
    memory.init(a, 65536);
    defer memory.deinit();
    var call: f.hosting.Call = .{ .memory = &memory, .attachment = fixture.attached, .view = view };
    defer call.release();
    const views = [_]f.loam.core.RecordView{ view, view };
    const set = try refs.Set.createViews(&call, &views, &.{
        .{ .restore_record = .{ .record = 1, .index = 0 } },
        .{ .save_live = fixture.target },
        .{ .restore = 0 },
    });
    const recipe = (try set.advance()).read;
    try set.completeRead(recipe.ticket, fixture.data.backend.read(recipe));
    const marker = (try set.advance()).read;
    // Cache a partial lookup while the restored live epoch still awaits I/O.
    try std.testing.expectError(error.ReferenceUnprepared, set.captured(fixture.target));
    try std.testing.expectError(error.ReferenceUnprepared, set.restored(view, 0));
    try set.completeRead(marker.ticket, fixture.data.backend.read(marker));
    // The two-slot cache can evict the duplicate recipe while loading its
    // epoch. Complete that exact read rather than assuming cache residency.
    for (0..8) |_| switch (try set.advance()) {
        .ready => break,
        .read => |read| try set.completeRead(read.ticket, fixture.data.backend.read(read)),
        .waiting => return error.UnexpectedWait,
    } else return error.PreparationDidNotFinish;
    try std.testing.expect((try set.restored(view, 0)).eql(fixture.target));
    var stale = view;
    stale.revision += 1;
    try std.testing.expectError(error.ReferenceUnprepared, set.restored(stale, 0));
    try std.testing.expectError(error.ReferenceUnprepared, set.restored(view, 1));
    // The explicit live save wins over the earlier restored recipe, and its status-allow: event or source ordering
    // borrowed proof remains the same across subsequent lookup and advance.
    const saved = (try set.captured(fixture.target)).saved;
    try std.testing.expectEqual(saved, (try set.captured(fixture.target)).saved);
    try std.testing.expect(try set.advance() == .ready);
    try std.testing.expectEqual(saved, (try set.captured(fixture.target)).saved);
    try std.testing.expectError(error.ReferenceUnprepared, set.captured(fixture.root));
}

test "loam live recipe metadata reports no durable URI after exact restoration" {
    inline for (.{ "put", "putDependent" }) |verb| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const put = try fixture.put(verb, 256);
        defer put.deinit();
        try fixture.drain();
        try std.testing.expect(put.result() == .ready);
        const store = &fixture.data.store;
        store.evict();
        const lease = try records.load(store, &fixture.data.backend, fixture.id);
        defer store.release(lease) catch unreachable;
        const view = try store.currentView(lease);
        var memory: f.hosting.Call.Memory = undefined;
        memory.init(a, 65536);
        defer memory.deinit();
        var call: f.hosting.Call = .{ .memory = &memory, .attachment = fixture.attached, .view = view };
        defer call.release();
        const set = try refs.Set.create(&call, view, &.{.{ .restore_record = .{ .record = 0, .index = 0, .retain_uri = true } }});
        try std.testing.expectError(error.ReferenceUnprepared, set.restoredUri(view, 0));
        for (0..8) |_| switch (try set.advance()) {
            .ready => break,
            .read => |read| try set.completeRead(read.ticket, fixture.data.backend.read(read)),
            .waiting => return error.UnexpectedWait,
        } else return error.PreparationDidNotFinish;
        _ = try set.restored(view, 0);
        try std.testing.expect((try set.restoredUri(view, 0)) == null);
        var stale = view;
        stale.revision += 1;
        try std.testing.expectError(error.ReferenceUnprepared, set.restoredUri(stale, 0));
        try std.testing.expectError(error.ReferenceUnprepared, set.restoredUri(view, 1));
    }
}

test "loam live dependent declaration reserves both authorities and rolls back capacity refusal" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const store = &fixture.data.store;
    const lease = try records.load(store, &fixture.data.backend, fixture.id);
    defer store.release(lease) catch unreachable;
    var memory: f.hosting.Call.Memory = undefined;
    memory.init(a, 65536);
    defer memory.deinit();
    var call: f.hosting.Call = .{ .memory = &memory, .attachment = fixture.attached, .view = try store.currentView(lease) };
    defer call.release();
    const before = fixture.host.capabilities.retainCount(fixture.target).?;
    const source_before = fixture.host.capabilities.retainCount(fixture.root).?;
    const request: refs.Request = .{ .save_live_dependent = .{ .source = fixture.root, .target = fixture.target } };
    try std.testing.expectError(error.ReferenceCapacity, refs.Set.create(&call, call.view, &.{ request, request, request }));
    try std.testing.expect(call.references == null);
    try fixture.drain(); // Facet destructors retire through the existing Vat boundary.
    try std.testing.expectEqual(before, fixture.host.capabilities.retainCount(fixture.target).?);
    try std.testing.expectEqual(source_before, fixture.host.capabilities.retainCount(fixture.root).?);
    const set = try refs.Set.create(&call, call.view, &.{request});
    try std.testing.expectEqual(before + 1, fixture.host.capabilities.retainCount(fixture.target).?);
    try std.testing.expectEqual(source_before + 1, fixture.host.capabilities.retainCount(fixture.root).?);
    try std.testing.expectError(error.ReferenceUnprepared, set.preparedDependent(fixture.root, fixture.target));
    try std.testing.expect(try set.advance() == .ready);
    const facet = try set.preparedDependent(fixture.root, fixture.target);
    try std.testing.expectError(error.ReferenceUnprepared, set.preparedDependent(fixture.root, fixture.root));
    try std.testing.expect(!fixture.scope.matchesDependent(facet, fixture.root, fixture.target));
    call.release();
    try fixture.drain();
    try std.testing.expectEqual(before, fixture.host.capabilities.retainCount(fixture.target).?);
    try std.testing.expectEqual(source_before, fixture.host.capabilities.retainCount(fixture.root).?);
}

test "loam live dependent exporter observes only exact committed remote custody" {
    var remote = support.init(a, @splat(0x73), .{});
    defer remote.deinit();
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const actor = try remote.vat.spawn(f.driver.Hosting(Echo), .{ .inner = .{} });
    const endpoint = try remote.liftLocalActor(actor);
    defer remote.releaseCapabilityTerminal(endpoint, null);
    const swiss = try remote.publishDurableCapability(@splat(0x37), endpoint);
    const pair = try pairs.openPair(&fixture.host, &remote, "127.0.0.1:9737");
    var fetched: CapturedRef = .{};
    try fixture.host.vowOn(try fixture.host.fetch(pair.a, swiss.slice()), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pairs.pumpToQuiescence(&.{pair});
    fixture.host.releaseCapabilityTerminal(fixture.target, null);
    fixture.target = try fixture.host.liftCapability(pair.a, try fetched.require());
    try std.testing.expect((try fixture.scope.dependentExporter(fixture.target)) == null);
    try std.testing.expect((try fixture.scope.dependentExporter(fixture.root)) == null);
    const put = try fixture.put("putDependent", 256);
    defer put.deinit();
    const batch = try fixture.write();
    const facet = fixture.scope.entries[0].capability;
    try std.testing.expect((try fixture.scope.dependentExporter(facet)) == null);
    try fixture.attached.completeWrite(batch.ticket, fixture.data.backend.commit(batch));
    try fixture.drainPair(pair);
    try std.testing.expectEqual(pair.a, (try fixture.scope.dependentExporter(facet)).?);
    var other = try f.hosting.LiveScope.init(a, &fixture.host, &fixture.data.store, 2);
    defer other.deinit() catch unreachable;
    try std.testing.expect((try other.dependentExporter(facet)) == null);
    const clear = try fixture.host.callLocalCapability(a, fixture.root, "clear", &.{}, 256);
    defer clear.deinit();
    try fixture.drainPair(pair);
    try records.collect(&fixture.data.store, &fixture.data.backend);
    fixture.data.store.evict();
    try fixture.drainPair(pair);
    _ = try fixture.attached.advanceProgress();
    try std.testing.expect((try fixture.scope.dependentExporter(facet)) == null);
}

test "loam live reference unknown outcome retains reservation through commit or absence and canceled observation" {
    for ([_][]const u8{ "put", "putDependent" }) |verb| for ([_]bool{ false, true }) |applied| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const call = try fixture.put(verb, 256);
        const batch = try fixture.write();
        try std.testing.expectEqual(@as(u32, 0), fixture.scope.by_recipe.count());
        if (applied) try std.testing.expect(fixture.data.backend.commit(batch) == .committed);
        try fixture.attached.completeWrite(batch.ticket, .unknown);
        call.deinit();
        try std.testing.expectError(error.Busy, fixture.attached.destroy());
        try std.testing.expect(fixture.scope.entries[0].phase == .reserved);
        const resolution = try (try fixture.attached.recoveryBatch()).resolve(fixture.data.backend.metadata);
        try fixture.attached.resolve(batch.ticket, resolution);
        // Installation happens at known commit, before observer settlement.
        try std.testing.expectEqual(@as(u32, if (applied) 1 else 0), fixture.scope.by_recipe.count());
        try fixture.drain();
        // Absent recovery retires a facet after the runner's current boundary.
        // Cross its next ordinary boundary before observing both final retains.
        _ = try fixture.attached.advanceProgress();
        try std.testing.expectEqual(@as(?u64, if (applied) 2 else 1), fixture.host.capabilities.retainCount(fixture.target));
        if (applied) {
            fixture.data.store.evict();
            const get = try fixture.get();
            defer get.deinit();
            try fixture.drain();
            try std.testing.expect(get.result() == .ready);
            const actual = get.result().ready.capability;
            if (std.mem.eql(u8, verb, "putDependent")) {
                try std.testing.expect(!actual.eql(fixture.target));
                try std.testing.expect(fixture.scope.matchesDependent(actual, fixture.root, fixture.target));
                try std.testing.expect(!fixture.scope.matchesDependent(actual, fixture.root, fixture.root));
                try std.testing.expect(!fixture.scope.matchesDependent(actual, fixture.target, fixture.target));
                const again = try fixture.get();
                defer again.deinit();
                try fixture.drain();
                try std.testing.expect(again.result() == .ready);
                try std.testing.expect(again.result().ready.capability.eql(actual));
            } else try std.testing.expect(actual.eql(fixture.target));
        }
    };
}

test "loam live reference committed custody survives reply refusal and collection releases the last occurrence" {
    for ([_][]const u8{ "putHuge", "putDependentHuge" }) |verb| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const put = try fixture.put(verb, 64);
        defer put.deinit();
        try fixture.drain();
        try std.testing.expect(put.result() == .failed);
        try std.testing.expectEqual(@as(u32, 1), fixture.scope.by_recipe.count());
        const get = try fixture.get();
        try fixture.drain();
        try std.testing.expect(get.result() == .ready);
        const actual = get.result().ready.capability;
        if (std.mem.startsWith(u8, verb, "putDependent")) {
            try std.testing.expect(fixture.scope.matchesDependent(actual, fixture.root, fixture.target));
        } else try std.testing.expect(actual.eql(fixture.target));
        get.deinit();
        const clear = try fixture.host.callLocalCapability(a, fixture.root, "clear", &.{}, 256);
        defer clear.deinit();
        try fixture.drain();
        try records.collect(&fixture.data.store, &fixture.data.backend);
        fixture.data.store.evict();
        try fixture.drain();
        _ = try fixture.attached.advanceProgress();
        try std.testing.expectEqual(@as(u32, 0), fixture.scope.by_recipe.count());
        try std.testing.expectEqual(@as(?u64, 1), fixture.host.capabilities.retainCount(fixture.target));
    }
}

test "loam live reference restart in an open Store refuses old fields without substituting new authority" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const put = try fixture.put("put", 256);
    try fixture.drain();
    put.deinit();
    fixture.host.releaseCapabilityTerminal(fixture.root, null);
    try fixture.attached.destroy();
    try fixture.scope.deinit();
    fixture.host.releaseCapabilityTerminal(fixture.target, null);
    fixture.host.deinit();
    const incarnation = fixture.data.store.metadata.incarnation;
    fixture.host = support.init(a, @splat(0x72), .{});
    fixture.scope = try f.hosting.LiveScope.init(a, &fixture.host, &fixture.data.store, 2);
    try std.testing.expectError(error.LiveScopeNotStarted, f.hosting.Attachment.create(a, &fixture.host, &fixture.data.store, &behaviors, .{ .live_scope = &fixture.scope }));
    const lease = try records.load(&fixture.data.store, &fixture.data.backend, fixture.marker);
    try fixture.data.store.begin();
    _ = try fixture.scope.stageStart(lease);
    try fixture.data.store.release(lease);
    try records.commit(&fixture.data.store, &fixture.data.backend);
    const current = try records.load(&fixture.data.store, &fixture.data.backend, fixture.marker);
    try fixture.scope.confirmStart(current);
    try fixture.data.store.release(current);
    try std.testing.expectEqual(incarnation, fixture.data.store.metadata.incarnation);
    fixture.attached = try f.hosting.Attachment.create(a, &fixture.host, &fixture.data.store, &behaviors, .{ .live_scope = &fixture.scope });
    const root = try records.load(&fixture.data.store, &fixture.data.backend, fixture.id);
    fixture.root = try fixture.attached.restore(root);
    try fixture.data.store.release(root);
    const actor = try fixture.host.vat.spawn(f.driver.Hosting(Echo), .{ .inner = .{} });
    fixture.target = try fixture.host.liftLocalActor(actor);
    const get = try fixture.get();
    defer get.deinit();
    try fixture.drain();
    try std.testing.expect(get.result() == .failed);
    try std.testing.expectEqualStrings("LiveReferenceExpired", get.result().failed.message);
    try std.testing.expectEqual(@as(u32, 0), fixture.scope.by_recipe.count());
}

test "loam live reference hosted startup fences admission through exact unknown write recovery" {
    for ([_]bool{ false, true }) |applied| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        fixture.host.releaseCapabilityTerminal(fixture.root, null);
        try fixture.attached.destroy();
        try fixture.scope.deinit();
        fixture.attached = try f.hosting.Attachment.create(a, &fixture.host, &fixture.data.store, &behaviors, .{});
        const lease = try records.load(&fixture.data.store, &fixture.data.backend, fixture.id);
        fixture.root = try fixture.attached.restore(lease);
        try fixture.data.store.release(lease);
        fixture.scope = try f.hosting.LiveScope.init(a, &fixture.host, &fixture.data.store, 2);
        try fixture.scope.startHosted(fixture.attached, fixture.marker);
        const batch = try fixture.write();
        try std.testing.expect(fixture.scope.result() == .pending);
        try std.testing.expectError(error.LiveScopeNotStarted, fixture.scope.reserve(a, fixture.target));
        if (applied) try std.testing.expect(fixture.data.backend.commit(batch) == .committed);
        try fixture.attached.completeWrite(batch.ticket, .unknown);
        try std.testing.expectError(error.Busy, fixture.attached.destroy());
        const resolution = try (try fixture.attached.recoveryBatch()).resolve(fixture.data.backend.metadata);
        try fixture.attached.resolve(batch.ticket, resolution);
        try std.testing.expect(fixture.scope.epoch == null);
        try fixture.drain();
        if (applied) {
            try std.testing.expect(fixture.scope.result() == .ready);
            try std.testing.expectEqual(@as(u64, 2), fixture.scope.result().ready.generation);
            const put = try fixture.put("put", 256);
            defer put.deinit();
            try fixture.drain();
            try std.testing.expect(put.result() == .ready);
        } else {
            try std.testing.expect(fixture.scope.result() == .failed);
            try std.testing.expectEqual(error.WriteNotCommitted, fixture.scope.result().failed);
        }
    }
}
