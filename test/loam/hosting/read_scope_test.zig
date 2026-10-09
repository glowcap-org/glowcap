//! Retained recursive reader interfaces protect every returned authority.
const std = @import("std");
const f = @import("fixture.zig");
const records = @import("../core/fixture.zig");
const metrics = @import("../../support/alloc_metrics.zig");
const Scope = f.hosting.ReadScope;
const interfaces = [_]Scope.Interface{
    .{ .methods = &.{ .{ .verb = "reader", .results = &.{1} }, .{ .verb = "unexpected" } } },
    .{ .methods = &.{ .{ .verb = "read" }, .{ .verb = "self", .results = &.{ 1, 1 } } } },
};

const Admission = struct {
    allowed: bool = true,
    fn invoke(call: *f.hosting.Call, _: f.loam.core.RecordView, verb: []const u8, args: []const f.driver.Value) !f.driver.Value {
        const self: *Admission = @ptrCast(@alignCast(call.context.?));
        if (!self.allowed) return error.SourcePaused;
        try std.testing.expectEqualStrings("history", verb);
        try std.testing.expectEqualStrings("original-conversation", args[0].string);
        const dispatch = call.dispatch.?;
        call.forward = .{ .target = call.dependent_target.?, .verb = dispatch.verb, .args = dispatch.args };
        call.requireDisclosedReply();
        return .{ .void = {} };
    }
};
const Target = struct {
    ref: *f.driver.Capability,
    calls: *usize,
    pub fn handle(self: *Target, turn: *f.driver.HostTurn, verb: []const u8, args: []const f.driver.Value) !f.driver.Value {
        defer turn.releaseValues(args);
        self.calls.* += 1;
        if (std.mem.eql(u8, verb, "read")) return .{ .string = "chunk" };
        if (std.mem.eql(u8, verb, "self")) {
            const items = try turn.turn.arena.alloc(f.driver.Value, 2);
            @memset(items, .{ .capability = self.ref.* });
            const entries = try turn.turn.arena.alloc(f.driver.Value.StructEntry, 1);
            entries[0] = .{ .key = "nested", .value = .{ .list = items } };
            return .{ .@"struct" = entries };
        }
        return .{ .capability = self.ref.* };
    }
};

fn scope(fixture: *f.Fixture, declaration: []const Scope.Interface) !*Scope {
    const lease = try records.load(&fixture.data.store, &fixture.data.backend, fixture.id);
    defer fixture.data.store.release(lease) catch unreachable;
    var memory: f.hosting.Call.Memory = undefined;
    memory.init(std.testing.allocator, 4096);
    defer memory.deinit();
    var call: f.hosting.Call = .{ .memory = &memory, .attachment = fixture.attached, .view = try fixture.data.store.currentView(lease) };
    defer call.release();
    return Scope.createCopying(&call, .{ .verb = "history", .args = &.{.{ .string = "original-conversation" }} }, declaration);
}

test "loam read scope recursively preserves exact identity and refuses undeclared verbs and results" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    defer fixture.drain() catch unreachable;
    var admission: Admission = .{};
    const behaviors = [_]f.hosting.Behavior{.{ .schema = 7, .invoke = Admission.invoke, .context = &admission }};
    fixture.attached.behaviors = &behaviors;
    var target: f.driver.Capability = undefined;
    var calls: usize = 0;
    const actor = try fixture.host.vat.spawn(f.driver.Hosting(Target), .{ .inner = .{ .ref = &target, .calls = &calls } });
    target = try fixture.host.liftLocalActor(actor);
    defer fixture.host.releaseCapabilityTerminal(target, null);
    const owner = try scope(&fixture, &interfaces);
    var owned = true;
    defer if (owned) owner.release();
    const root = try owner.project(target, 0);
    var root_owned = true;
    defer if (root_owned) fixture.host.releaseCapabilityTerminal(root, null);
    const acquire = try fixture.host.callLocalCapability(std.testing.allocator, root, "reader", &.{}, 4096);
    defer acquire.deinit();
    try fixture.drain();
    const reader = acquire.result().ready.capability;
    try std.testing.expect(!reader.eql(target));
    const repeated = try owner.project(target, 1);
    defer fixture.host.releaseCapabilityTerminal(repeated, null);
    try std.testing.expect(reader.eql(repeated));
    owner.release();
    owned = false;
    fixture.host.releaseCapabilityTerminal(root, null);
    root_owned = false;
    try fixture.drain();
    const nested = try fixture.host.callLocalCapability(std.testing.allocator, reader, "self", &.{}, 4096);
    defer nested.deinit();
    try fixture.drain();
    if (nested.result() == .failed) {
        std.debug.print("nested reader refused: {s}\n", .{nested.result().failed.message});
        return error.UnexpectedRefusal;
    }
    for (nested.result().ready.@"struct"[0].value.list) |item| try std.testing.expect(item.capability.eql(reader));
    const read = try fixture.host.callLocalCapability(std.testing.allocator, reader, "read", &.{}, 4096);
    defer read.deinit();
    try fixture.drain();
    try std.testing.expectEqualStrings("chunk", read.result().ready.string);
    const before = calls;
    const write = try fixture.host.callLocalCapability(std.testing.allocator, reader, "write", &.{}, 4096);
    defer write.deinit();
    try fixture.drain();
    try std.testing.expectEqualStrings("NoSuchMethod", write.result().failed.message);
    try std.testing.expectEqual(before, calls);
    admission.allowed = false;
    const paused = try fixture.host.callLocalCapability(std.testing.allocator, reader, "read", &.{}, 4096);
    defer paused.deinit();
    try fixture.drain();
    try std.testing.expectEqualStrings("SourcePaused", paused.result().failed.message);
    try std.testing.expectEqual(before, calls);
    admission.allowed = true;
    const another = try scope(&fixture, &interfaces);
    defer another.release();
    const other_root = try another.project(target, 0);
    defer fixture.host.releaseCapabilityTerminal(other_root, null);
    const unexpected = try fixture.host.callLocalCapability(std.testing.allocator, other_root, "unexpected", &.{}, 4096);
    defer unexpected.deinit();
    try fixture.drain();
    try std.testing.expectEqualStrings("UndeclaredDisclosure", unexpected.result().failed.message);
}

test "loam passive read facade survives physical close only as unavailable routing" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    var closed = false;
    defer if (!closed) fixture.deinit() else {
        fixture.host.releaseCapabilityTerminal(fixture.root, null);
        fixture.host.deinit();
        fixture.data.deinit();
    };
    var admission: Admission = .{};
    const behaviors = [_]f.hosting.Behavior{.{ .schema = 7, .invoke = Admission.invoke, .context = &admission }};
    fixture.attached.behaviors = &behaviors;
    var target: f.driver.Capability = undefined;
    var calls: usize = 0;
    const actor = try fixture.host.vat.spawn(f.driver.Hosting(Target), .{ .inner = .{ .ref = &target, .calls = &calls } });
    target = try fixture.host.liftLocalActor(actor);
    defer fixture.host.releaseCapabilityTerminal(target, null);
    const owner = try scope(&fixture, &interfaces);
    const reader = try owner.project(target, 1);
    owner.release();
    defer fixture.host.releaseCapabilityTerminal(reader, null);
    try fixture.drain();
    try std.testing.expectEqual(@as(usize, 1), fixture.attached.continuations);
    try fixture.attached.destroy();
    closed = true;
    const read = try fixture.host.callLocalCapability(std.testing.allocator, reader, "read", &.{}, 4096);
    defer read.deinit();
    _ = try fixture.host.vat.driveIngressBudgeted(.local, 64);
    try std.testing.expect(read.result() == .failed);
    try std.testing.expectEqualStrings("AttachmentClosed", read.result().failed.message);
    try std.testing.expectEqual(@as(usize, 0), calls);
}

fn allocationRefusal(allocator: std.mem.Allocator) !void {
    var fixture: f.Fixture = undefined;
    const bytes = try Scope.sizeBound(.{ .values = 1, .bytes = 21 }, 7, .{ .interfaces = 2, .methods = 4, .verb_bytes = 24, .result_roles = 3, .targets = 1 });
    try fixture.init(.{ .max_continuations = 1, .max_continuation_targets = 1, .continuation_bytes = bytes });
    defer fixture.deinit();
    const original = fixture.attached.allocator;
    fixture.attached.allocator = allocator;
    defer fixture.attached.allocator = original;
    const before = fixture.host.capabilities.retainCount(fixture.root).?;
    defer {
        fixture.drain() catch unreachable;
        std.debug.assert(fixture.attached.continuations == 0);
        std.debug.assert(fixture.host.capabilities.retainCount(fixture.root).? == before);
    }
    const reader_scope = try scope(&fixture, &interfaces);
    defer reader_scope.release();
    try std.testing.expectError(error.ContinuationCapacity, scope(&fixture, &interfaces));
    const front = try reader_scope.project(fixture.root, 0);
    try std.testing.expectError(error.ContinuationCapacity, reader_scope.project(fixture.root, 1));
    fixture.host.releaseCapabilityTerminal(front, null);
    try fixture.drain();
}

test "loam read scope allocation refusal and bounded cache release all custody" {
    var traffic: metrics.AllocationTraffic(f.hosting.references.AllocationBound) = .{ .backing = std.testing.allocator };
    try allocationRefusal(traffic.allocator());
    try std.testing.expect(traffic.demand.bytes <= try Scope.sizeBound(.{ .values = 1, .bytes = 21 }, 7, .{ .interfaces = 2, .methods = 4, .verb_bytes = 24, .result_roles = 3, .targets = 1 }));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationRefusal, .{});
    try std.testing.expectError(error.Overflow, Scope.sizeBound(.{}, 7, .{ .interfaces = 1, .methods = std.math.maxInt(usize), .verb_bytes = 1, .result_roles = 0, .targets = 1 }));
}

fn endpointRefusal(fail_index: usize) !usize {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{ .max_continuation_targets = 1 });
    defer fixture.deinit();
    const reader_scope = try scope(&fixture, &interfaces);
    defer reader_scope.release();
    // Warm Host/Vat tables so the measured allocations belong to the facade.
    const warm = try reader_scope.project(fixture.root, 0);
    fixture.host.releaseCapabilityTerminal(warm, null);
    try fixture.drain();
    const before = fixture.host.capabilities.retainCount(fixture.root).?;
    const actors_before = fixture.host.vat.actors.count();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
    const original_host = fixture.host.allocator;
    const original_vat = fixture.host.vat.allocator;
    fixture.host.allocator = failing.allocator();
    fixture.host.vat.allocator = failing.allocator();
    defer {
        fixture.host.allocator = original_host;
        fixture.host.vat.allocator = original_vat;
    }
    const result = reader_scope.project(fixture.root, 0);
    const allocations = failing.alloc_index;
    failing.fail_index = std.math.maxInt(usize);
    if (result) |front| {
        fixture.host.releaseCapabilityTerminal(front, null);
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        // A failed box allocation, registration or lift must release its entry
        // synchronously. Retry before driving any retirement boundary.
        try std.testing.expectEqual(before, fixture.host.capabilities.retainCount(fixture.root).?);
        try std.testing.expectEqual(actors_before, fixture.host.vat.actors.count());
        const front = try reader_scope.project(fixture.root, 0);
        fixture.host.releaseCapabilityTerminal(front, null);
    }
    try fixture.drain();
    try std.testing.expectEqual(before, fixture.host.capabilities.retainCount(fixture.root).?);
    try std.testing.expectEqual(actors_before, fixture.host.vat.actors.count());
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    return allocations;
}

test "loam read scope facade constructor refusal releases cache entries before retry" {
    const allocations = try endpointRefusal(std.math.maxInt(usize));
    try std.testing.expect(allocations > 0);
    for (0..allocations) |index| _ = try endpointRefusal(index);
}

test "loam read scope mediates foreign recursive results and preserves identity across settlement retry" {
    const host_support = @import("../../support/core_host.zig");
    const pairs = @import("../../support/host_pair.zig");
    const CapturedRef = @import("../../support/capture.zig").CapturedRef;
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    var admission: Admission = .{};
    const behaviors = [_]f.hosting.Behavior{.{ .schema = 7, .invoke = Admission.invoke, .context = &admission }};
    fixture.attached.behaviors = &behaviors;
    var exporter = host_support.init(std.testing.allocator, @splat(0x73), f.driver.Host.Options.withFrameCap(4096));
    defer exporter.deinit();
    defer fixture.drain() catch unreachable;
    var target: f.driver.Capability = undefined;
    var calls: usize = 0;
    const actor = try exporter.vat.spawn(f.driver.Hosting(Target), .{ .inner = .{ .ref = &target, .calls = &calls } });
    target = try exporter.liftLocalActor(actor);
    defer exporter.releaseCapabilityTerminal(target, null);
    const swiss = try exporter.publishDurableCapability(@splat(0x39), target);
    const pair = try pairs.openPair(&fixture.host, &exporter, "127.0.0.1:9750");
    defer fixture.host.releaseSession(pair.a) catch unreachable;
    var fetched: CapturedRef = .{};
    try fixture.host.vowOn(try fixture.host.fetch(pair.a, swiss.slice()), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pairs.pumpToQuiescence(&.{pair});
    const held = try fixture.host.liftCapability(pair.a, try fetched.require());
    defer fixture.host.releaseCapabilityTerminal(held, null);
    const reader_scope = try scope(&fixture, &interfaces);
    defer reader_scope.release();
    const reader = try reader_scope.project(held, 1);
    defer fixture.host.releaseCapabilityTerminal(reader, null);
    const reader_swiss = try fixture.host.publishDurableCapability(@splat(0x40), reader);
    defer fixture.host.removeDurable(reader_swiss.slice()) catch unreachable;
    var fetched_reader: CapturedRef = .{};
    try exporter.vowOn(try exporter.fetch(pair.b, reader_swiss.slice()), .{ .ctx = &fetched_reader, .func = CapturedRef.record });
    try pairs.pumpToQuiescence(&.{pair});
    const remote_reader = try exporter.liftCapability(pair.b, try fetched_reader.require());
    defer exporter.releaseCapabilityTerminal(remote_reader, null);
    const result = try exporter.callCapability(std.testing.allocator, pair.b, remote_reader, "self", &.{}, 4096);
    defer result.deinit();
    // Stop after the wire result arrives, before the shared source recheck and
    // resolver settlement. The original reply remains under immutable custody.
    var completed = false;
    for (0..64) |_| {
        while (try exporter.nextAction()) |_| {}
        while (try fixture.host.nextAction()) |_| {}
        _ = try fixture.host.vat.driveIngressBudgeted(.local, 64);
        try fixture.attached.advance();
        while (try fixture.attached.nextWork()) |work| switch (work) {
            .read => |request| try fixture.attached.completeRead(request.ticket, fixture.data.backend.read(request)),
            .lookup => |request| try fixture.attached.completeLookup(request.ticket, fixture.data.backend.lookup(request)),
            .write => return error.UnexpectedWrite,
        };
        try fixture.host.flushSession(pair.a);
        try exporter.flushSession(pair.b);
        try pairs.pumpToQuiescence(&.{pair});
        for (fixture.attached.operations) |*op| if (op.phase == .forwarded and op.forwarded.poll() == .ready) {
            completed = true;
            break;
        };
        if (completed) break;
    }
    if (!completed) {
        std.debug.print("reader wire calls={d}, outer={s}\n", .{ calls, @tagName(result.result()) });
        for (fixture.attached.operations) |op| if (op.phase != .free) std.debug.print("reader operation={s}\n", .{@tagName(op.phase)});
    }
    try std.testing.expect(completed);
    try std.testing.expectEqual(@as(usize, 1), calls);
    const original = fixture.attached.allocator;
    var failing = std.testing.FailingAllocator.init(original, .{ .fail_index = 0 });
    fixture.attached.allocator = failing.allocator();
    defer fixture.attached.allocator = original;
    var refused = false;
    for (0..64) |_| {
        _ = try fixture.host.vat.driveIngressBudgeted(.local, 64);
        fixture.attached.advance() catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            refused = true;
            break;
        };
        while (try fixture.attached.nextWork()) |work| switch (work) {
            .read => |request| try fixture.attached.completeRead(request.ticket, fixture.data.backend.read(request)),
            .lookup => |request| try fixture.attached.completeLookup(request.ticket, fixture.data.backend.lookup(request)),
            .write => return error.UnexpectedWrite,
        };
    }
    try std.testing.expect(refused);
    try std.testing.expect(result.result() == .pending);
    failing.fail_index = std.math.maxInt(usize);
    try fixture.drain();
    try pairs.pumpToQuiescence(&.{pair});
    const reply = result.result().ready.@"struct"[0].value.list;
    for (reply) |item| try std.testing.expect(item.capability.eql(remote_reader));
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}
