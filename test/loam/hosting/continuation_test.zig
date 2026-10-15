//! Independent receipt reservation cost and every allocation refusal edge.
const std = @import("std");
const f = @import("fixture.zig");
const records = @import("../core/fixture.zig");
const metrics = @import("../../support/alloc_metrics.zig");
const Continuation = f.hosting.Continuation;
const shape: f.hosting.ValueBounds = .{ .values = 6, .struct_entries = 1, .bytes = 518, .capabilities = 2 };

const Owner = struct {
    cancelled: usize = 0,
    fn activate(_: ?*anyopaque, _: *Continuation) void {
        @panic("uncommitted reservation activated");
    }
    fn cancel(context: ?*anyopaque) void {
        const self: *Owner = @ptrCast(@alignCast(context.?));
        self.cancelled += 1;
    }
};

fn reservation(allocator: std.mem.Allocator) !void {
    const bytes = try Continuation.sizeBound(shape, 7, 2);
    var fixture: f.Fixture = undefined;
    try fixture.init(.{ .continuation_bytes = bytes, .max_continuations = 1, .max_continuation_targets = 2 });
    defer fixture.deinit();
    const lease = try records.load(&fixture.data.store, &fixture.data.backend, fixture.id);
    defer fixture.data.store.release(lease) catch unreachable;
    const original_allocator = fixture.attached.allocator;
    fixture.attached.allocator = allocator;
    defer fixture.attached.allocator = original_allocator;
    const before = fixture.host.capabilities.retainCount(fixture.root).?;
    defer std.debug.assert(fixture.host.capabilities.retainCount(fixture.root).? == before);
    defer std.debug.assert(fixture.attached.continuations == 0);
    var memory: f.hosting.Call.Memory = undefined;
    memory.init(std.testing.allocator, 4096);
    defer memory.deinit();
    var call: f.hosting.Call = .{ .memory = &memory, .attachment = fixture.attached, .view = try fixture.data.store.currentView(lease) };
    defer call.release();
    var owner: Owner = .{};
    const args = [_]f.driver.Value{.{ .list = &.{
        .{ .bytes = &@as([513]u8, @splat(0xa5)) },
        .{ .capability = fixture.root },
        .{ .@"struct" = &.{.{ .key = "label", .value = .{ .capability = fixture.root } }} },
        .{ .boolean = true },
    } }};
    const held = try Continuation.reserveCopying(&call, .{ .verb = "reserve", .args = &args }, &.{ fixture.root, fixture.root }, .{ .context = &owner, .activate = Owner.activate, .cancel = Owner.cancel });
    try std.testing.expect(held.source().eql(fixture.root));
    try std.testing.expect((try held.target(1)).eql(fixture.root));
    try std.testing.expectEqual(before + 5, fixture.host.capabilities.retainCount(fixture.root).?);
    try std.testing.expectError(error.DuplicateContinuation, Continuation.reserveCopying(&call, .{ .verb = "reserve", .args = &args }, &.{}, .{ .context = &owner, .activate = Owner.activate, .cancel = Owner.cancel }));
    call.release();
    try std.testing.expectEqual(@as(usize, 1), owner.cancelled);
}

test "loam continuation sizing admits observed reservation traffic and every allocation refusal retires custody" {
    const Bound = f.hosting.references.AllocationBound;
    var traffic: metrics.AllocationTraffic(Bound) = .{ .backing = std.testing.allocator };
    try reservation(traffic.allocator());
    try std.testing.expect(traffic.demand.bytes <= try Continuation.sizeBound(shape, 7, 2));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, reservation, .{});
    try std.testing.expectError(error.Overflow, Continuation.sizeBound(.{ .values = std.math.maxInt(usize) }, 7, 2));
}

const Activated = struct {
    continuation: ?*Continuation = null,
    fn activate(context: ?*anyopaque, value: *Continuation) void {
        const self: *Activated = @ptrCast(@alignCast(context.?));
        self.continuation = value;
    }
    fn cancel(_: ?*anyopaque) void {
        @panic("confirmed reservation cancelled");
    }
};

fn confirmed(fixture: *f.Fixture, owner: *Activated, targets: []const f.driver.Capability) !*Continuation {
    return confirmedIntent(fixture, owner, targets, .{ .verb = "get", .args = &.{} });
}

fn confirmedIntent(fixture: *f.Fixture, owner: *Activated, targets: []const f.driver.Capability, intent: f.hosting.Call.Intent) !*Continuation {
    const lease = try records.load(&fixture.data.store, &fixture.data.backend, fixture.id);
    defer fixture.data.store.release(lease) catch unreachable;
    var memory: f.hosting.Call.Memory = undefined;
    memory.init(std.testing.allocator, 4096);
    defer memory.deinit();
    var call: f.hosting.Call = .{ .memory = &memory, .attachment = fixture.attached, .view = try fixture.data.store.currentView(lease) };
    defer call.release();
    _ = try Continuation.reserveCopying(&call, intent, targets, .{ .context = owner, .activate = Activated.activate, .cancel = Activated.cancel });
    // These CPU fixtures drive activation directly. Hosted scenarios establish
    // the receipt commit and recovery precondition independently.
    const confirmation = call.confirmation.?;
    call.confirmation = null;
    confirmation.apply(confirmation.context);
    return owner.continuation.?;
}

fn executeRefusal(fail_index: usize, cancel: bool) !usize {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    var owner: Activated = .{};
    const active = try confirmed(&fixture, &owner, &.{fixture.root});
    defer active.release();
    // Warm persistent queue/index storage before measuring only constructor
    // refusal. The wrapper remains the allocator until owned metadata frees.
    const warm = try active.execute(std.testing.allocator, 0, "get", &.{}, 4096);
    warm.deinit();
    try fixture.drain();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
    const allocator = failing.allocator();
    const original_host = fixture.host.allocator;
    const original_vat = fixture.host.vat.allocator;
    fixture.host.allocator = allocator;
    fixture.host.vat.allocator = allocator;
    defer {
        fixture.host.allocator = original_host;
        fixture.host.vat.allocator = original_vat;
    }
    const result = active.execute(allocator, 0, "get", &.{}, 4096) catch |err| {
        failing.fail_index = std.math.maxInt(usize);
        try fixture.attached.advance();
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        return err;
    };
    const constructor_allocations = failing.alloc_index;
    failing.fail_index = std.math.maxInt(usize);
    if (cancel) result.deinit();
    var observed = !cancel;
    defer if (observed) result.deinit();
    try fixture.drain();
    if (!cancel) {
        // Generic source behavior cannot claim target completion without
        // forwarding the private executor's exact selected request.
        try std.testing.expect(result.result() == .unsent);
        try std.testing.expectEqualStrings("InvalidContinuationDispatch", result.result().unsent.message);
    }
    try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
    try std.testing.expectEqual(@as(usize, 0), fixture.host.pending_operations);
    try std.testing.expectEqual(@as(usize, 0), fixture.host.vows.count());
    try std.testing.expectEqual(@as(usize, 0), fixture.host.resolver_index.count());
    if (observed) {
        result.deinit();
        observed = false;
    }
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    return constructor_allocations;
}

test "loam continuation private execution refuses non-forward completion and retires every constructor allocation refusal" {
    _ = try executeRefusal(std.math.maxInt(usize), false);
    const allocations = try executeRefusal(std.math.maxInt(usize), true);
    for (0..allocations) |index| try std.testing.expectError(error.OutOfMemory, executeRefusal(index, true));
    if (@sizeOf(usize) == 8) try std.testing.expectEqual(@as(usize, 32), f.hosting.Execution.metadataBytes());
    try std.testing.expectEqual(try f.driver.Host.Call.sizeBound(4096), try f.hosting.Execution.sizeBound(4096));
}

const Selection = struct {
    mode: enum { rewrite, target, verb },
    selected: f.driver.Capability,
    other: f.driver.Capability,
    fn invoke(call: *f.hosting.Call, _: f.loam.core.RecordView, _: []const u8, _: []const f.driver.Value) !f.driver.Value {
        const self: *Selection = @ptrCast(@alignCast(call.context.?));
        call.forward = .{
            .target = if (self.mode == .target) self.other else self.selected,
            .verb = if (self.mode == .verb) "rewritten" else "target",
            .args = &.{.{ .string = "rewritten" }},
        };
        return .{ .void = {} };
    }
};

const ExactRequest = struct {
    calls: *usize,
    pub fn handle(self: *ExactRequest, turn: *f.driver.HostTurn, verb: []const u8, args: f.driver.Args) !f.driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        self.calls.* += 1;
        try std.testing.expectEqualStrings("target", verb);
        try std.testing.expectEqualStrings("original", arg_values[0].string);
        return arg_values[0];
    }
};

test "loam continuation private execution dispatches immutable arguments and refuses target or verb redirection" {
    for ([_]@FieldType(Selection, "mode"){ .rewrite, .target, .verb }) |mode| {
        var fixture: f.Fixture = undefined;
        try fixture.init(.{});
        defer fixture.deinit();
        var calls: usize = 0;
        const actor = try fixture.host.vat.spawn(f.driver.Hosting(ExactRequest), .{ .inner = .{ .calls = &calls } });
        const target = try fixture.host.liftLocalActor(actor);
        defer fixture.host.releaseCapabilityTerminal(target, null);
        var selection: Selection = .{ .mode = mode, .selected = target, .other = fixture.root };
        const behaviors = [_]f.hosting.Behavior{.{ .schema = 7, .invoke = Selection.invoke, .context = &selection }};
        fixture.attached.behaviors = &behaviors;
        var owner: Activated = .{};
        const active = try confirmed(&fixture, &owner, &.{target});
        defer active.release();
        const result = try active.execute(std.testing.allocator, 0, "target", &.{.{ .string = "original" }}, 4096);
        defer result.deinit();
        try fixture.drain();
        if (mode == .rewrite) {
            try std.testing.expectEqualStrings("original", result.result().ready.string);
            try std.testing.expectEqual(@as(usize, 1), calls);
        } else {
            try std.testing.expectEqualStrings("InvalidContinuationDispatch", result.result().unsent.message);
            try std.testing.expectEqual(@as(usize, 0), calls);
        }
        try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
        try std.testing.expectEqual(@as(usize, 0), fixture.host.pending_operations);
    }
}

const ReadAdmission = struct {
    allowed: bool = true,
    fn invoke(call: *f.hosting.Call, _: f.loam.core.RecordView, verb: []const u8, args: []const f.driver.Value) !f.driver.Value {
        const self: *ReadAdmission = @ptrCast(@alignCast(call.context.?));
        if (!self.allowed) return error.SourcePaused;
        try std.testing.expectEqualStrings("get", verb);
        try std.testing.expectEqualStrings("immutable-original", args[0].string);
        const dispatch = call.dispatch.?;
        call.forward = .{ .target = call.dependent_target.?, .verb = dispatch.verb, .args = dispatch.args };
        return .{ .void = {} };
    }
};
const ReadTarget = struct {
    calls: *usize,
    target: *f.driver.Capability,
    pub fn handle(self: *ReadTarget, turn: *f.driver.HostTurn, verb: []const u8, args: f.driver.Args) !f.driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        self.calls.* += 1;
        return if (std.mem.eql(u8, verb, "read")) .{ .string = "chunk" } else .{ .capability = self.target.* };
    }
};

fn retainedReads(allocator: std.mem.Allocator) !void {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{ .max_continuations = 2, .max_continuation_targets = 1 });
    defer fixture.deinit();
    var admission: ReadAdmission = .{};
    const behaviors = [_]f.hosting.Behavior{.{ .schema = 7, .invoke = ReadAdmission.invoke, .context = &admission }};
    fixture.attached.behaviors = &behaviors;
    var calls: usize = 0;
    var target: f.driver.Capability = undefined;
    const actor = try fixture.host.vat.spawn(f.driver.Hosting(ReadTarget), .{ .inner = .{ .calls = &calls, .target = &target } });
    target = try fixture.host.liftLocalActor(actor);
    defer fixture.host.releaseCapabilityTerminal(target, null);
    var activated: Activated = .{};
    const active = try confirmedIntent(&fixture, &activated, &.{target}, .{ .verb = "get", .args = &.{.{ .string = "immutable-original" }} });
    var active_owned = true;
    defer if (active_owned) active.release();
    const before = fixture.host.capabilities.retainCount(fixture.root).?;
    const original = fixture.attached.allocator;
    fixture.attached.allocator = allocator;
    defer fixture.attached.allocator = original;
    const interfaces = [_]f.hosting.ReadScope.Interface{.{ .methods = &.{ .{ .verb = "read" }, .{ .verb = "unexpected" } } }};
    const scope = try f.hosting.ReadScope.createRetaining(active, &interfaces);
    var scope_owned = true;
    defer if (scope_owned) scope.release();
    try std.testing.expectEqual(before, fixture.host.capabilities.retainCount(fixture.root).?);
    try std.testing.expect(scope.intent.args.ptr == (try active.admission()).intent.args.ptr);
    const reader = try scope.project(target, 0);
    defer {
        fixture.host.releaseCapabilityTerminal(reader, null);
        fixture.drain() catch unreachable;
    }
    // This witness injects scope construction, not unrelated forwarded calls.
    // The scope's own allocator remains live through its final retirement.
    fixture.attached.allocator = original;
    active.release();
    active_owned = false;
    scope.release();
    scope_owned = false;
    try std.testing.expectEqual(@as(usize, 2), fixture.attached.continuations);
    const read = try fixture.host.callLocalCapability(std.testing.allocator, reader, "read", &.{}, 4096);
    defer read.deinit();
    try fixture.drain();
    try std.testing.expectEqualStrings("chunk", read.result().ready.string);
    const write = try fixture.host.callLocalCapability(std.testing.allocator, reader, "write", &.{}, 4096);
    defer write.deinit();
    try fixture.drain();
    try std.testing.expectEqualStrings("NoSuchMethod", write.result().failed.message);
    try std.testing.expectEqual(@as(usize, 1), calls);
    const unexpected = try fixture.host.callLocalCapability(std.testing.allocator, reader, "unexpected", &.{}, 4096);
    defer unexpected.deinit();
    try fixture.drain();
    try std.testing.expectEqualStrings("UndeclaredDisclosure", unexpected.result().failed.message);
    admission.allowed = false;
    const paused = try fixture.host.callLocalCapability(std.testing.allocator, reader, "read", &.{}, 4096);
    defer paused.deinit();
    try fixture.drain();
    try std.testing.expectEqualStrings("SourcePaused", paused.result().failed.message);
    try std.testing.expectEqual(@as(usize, 2), calls);
}

test "loam continuation read scopes share original custody after executor release and refuse every allocation failure" {
    try retainedReads(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, retainedReads, .{});
}

test "loam continuation permits close with passive readers but refuses executor and dispatch custody" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    var calls: usize = 0;
    var target: f.driver.Capability = undefined;
    const actor = try fixture.host.vat.spawn(f.driver.Hosting(ReadTarget), .{ .inner = .{ .calls = &calls, .target = &target } });
    target = try fixture.host.liftLocalActor(actor);
    var activated: Activated = .{};
    const active = try confirmed(&fixture, &activated, &.{target});
    const interfaces = [_]f.hosting.ReadScope.Interface{.{ .methods = &.{.{ .verb = "read" }} }};
    const scope = try f.hosting.ReadScope.createRetaining(active, &interfaces);
    const reader = try scope.project(target, 0);
    scope.release();
    const second_scope = try f.hosting.ReadScope.createRetaining(active, &interfaces);
    const second_reader = try second_scope.project(target, 0);
    second_scope.release();
    try std.testing.expectError(error.Busy, fixture.attached.destroy());
    const dispatch = try active.project(0);
    active.release();
    try std.testing.expectError(error.Busy, fixture.attached.destroy());
    fixture.host.releaseCapabilityTerminal(dispatch, null);
    try fixture.drain();
    try std.testing.expectEqual(@as(usize, 0), fixture.attached.effect_continuations);
    try std.testing.expectEqual(@as(usize, 3), fixture.attached.continuations);
    // Acquiring a new executor retain from passive custody restores the close
    // barrier. Releasing it makes the same original readers passive again.
    try active.retain();
    try std.testing.expectError(error.Busy, fixture.attached.destroy());
    active.release();
    try fixture.attached.destroy();
    fixture.data.deinit();
    const read = try fixture.host.callLocalCapability(std.testing.allocator, reader, "read", &.{}, 4096);
    _ = try fixture.host.vat.driveIngressBudgeted(.local, 64);
    try std.testing.expectEqualStrings("AttachmentClosed", read.result().failed.message);
    read.deinit();
    try std.testing.expectEqual(@as(usize, 0), calls);
    fixture.host.releaseCapabilityTerminal(reader, null);
    fixture.host.releaseCapabilityTerminal(second_reader, null);
    fixture.host.releaseCapabilityTerminal(target, null);
    fixture.host.releaseCapabilityTerminal(fixture.root, null);
    fixture.host.deinit();
}
