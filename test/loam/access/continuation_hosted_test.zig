//! Receipt confirmation transfers effect custody outside the callback lifetime.
const std = @import("std");
const h = @import("hosting_fixture.zig");
const Continuation = h.loam.hosting.Continuation;
const pairs = @import("../../support/host_pair.zig");
const CapturedRef = @import("../../support/capture.zig").CapturedRef;

const App = struct {
    active: ?*Continuation = null,
    activated: usize = 0,
    cancelled: usize = 0,
    dispatched: usize = 0,
    expected_source: h.driver.Capability,
    target_override: ?h.driver.Capability = null,
    retry_mode: h.access.RetryMode = .receipt,
    replace_content: bool = true,

    fn behavior(self: *App) h.access.ContentBehavior {
        return .{ .schema = 7, .context = self, .requirement = requirement, .retry = retry, .invoke = invoke };
    }
    fn from(context: ?*anyopaque) *App {
        return @ptrCast(@alignCast(context.?));
    }
    fn requirement(_: ?*anyopaque, _: std.mem.Allocator, input: h.access.ContentInvocation) !h.c.core.Policy.Requirement {
        if (std.mem.eql(u8, input.verb, "reserve")) return .{ .permissions = &.{h.f.vocabulary.read} };
        if (std.mem.eql(u8, input.verb, "target")) return .{ .permissions = &.{h.f.vocabulary.post} };
        return error.NoSuchMethod;
    }
    fn retry(context: ?*anyopaque, verb: []const u8, _: []const h.driver.Value) !h.access.RetryMode {
        return if (std.mem.eql(u8, verb, "reserve")) from(context).retry_mode else .read_only;
    }
    fn invoke(context: ?*anyopaque, call: *h.access.ContentCall, input: h.access.ContentInvocation) !h.driver.Value {
        const self = from(context);
        if (std.mem.eql(u8, input.verb, "target")) {
            self.dispatched += 1;
            return .{ .integer = 7 };
        }
        const target = self.target_override orelse try call.reference(0);
        const reservation = try call.reserveContinuationCopying(&.{target}, .{ .context = self, .activate = activate, .cancel = cancel });
        try std.testing.expect(reservation.source().eql(self.expected_source));
        try std.testing.expect((try reservation.target(0)).eql(target));
        if (!self.replace_content) return .{ .boolean = true };
        const payload = try call.allocator().alloc(u8, 8);
        @memcpy(payload, input.content.payload);
        payload[0] += 1;
        call.replace(payload);
        return .{ .boolean = true };
    }
    fn activate(context: ?*anyopaque, continuation: *Continuation) void {
        const self = from(context);
        std.debug.assert(self.active == null);
        self.active = continuation;
        self.activated += 1;
    }
    fn cancel(context: ?*anyopaque) void {
        from(context).cancelled += 1;
    }
};

test "loam idempotent continuation requires confirmed application mutation and refuses read-only reservation" {
    for ([_]h.access.RetryMode{ .idempotent, .read_only }) |mode| {
        for ([_]bool{ false, true }) |replace| {
            var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
            defer backend.deinit();
            var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
            defer store.deinit() catch unreachable;
            const data = try h.seedIndependentTarget(&store, &backend);
            var host: h.Hosted = undefined;
            try host.initOptions(&store, &backend, data, .{ .sleep_policy = .every_turn });
            defer host.deinit();
            var app: App = .{ .expected_source = host.use, .retry_mode = mode, .replace_content = replace };
            const registration = [_]h.access.ContentBehavior{app.behavior()};
            host.service.contents = &registration;
            var answer: h.Answer = .{};
            try host.send(host.use, "reserve", &.{}, &answer);
            if (mode == .idempotent and replace) {
                const write = try host.untilWrite(&backend);
                try std.testing.expect(app.active == null);
                try std.testing.expectEqual(@as(usize, 1), host.attached.continuations);
                try host.attached.completeWrite(write.ticket, backend.commit(write));
            }
            try host.drain(&backend);
            if (mode == .idempotent and replace) {
                const active = app.active.?;
                try std.testing.expectEqual(@as(usize, 1), app.activated);
                try std.testing.expectEqual(@as(?bool, true), answer.changed);
                active.release();
            } else {
                try std.testing.expect(app.active == null);
                try std.testing.expectEqual(@as(usize, 0), app.activated);
                try std.testing.expectEqualStrings(if (mode == .read_only) "RetryRequired" else "ReceiptRequired", answer.reason());
                try std.testing.expectEqual(@as(usize, if (mode == .idempotent) 1 else 0), app.cancelled);
            }
            try std.testing.expectEqual(@as(usize, 0), host.attached.continuations);
            try std.testing.expectEqual(@as(usize, 0), host.attached.pending_bytes);
        }
    }
}

const WaitingTarget = struct {
    const State = struct { resolver: ?u64 = null, calls: usize = 0 };
    state: *State,

    pub fn handle(self: *WaitingTarget, turn: *h.driver.HostTurn, _: ?[]const u8, args: h.driver.Args) !h.driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        self.state.resolver = try turn.deferAnswer();
        self.state.calls += 1;
        return .{ .void = {} };
    }
};

const WaitingWireTarget = struct {
    state: *WaitingTarget.State,
    pub fn handle(self: *WaitingWireTarget, turn: *h.driver.HostTurn, _: ?[]const u8, args: h.driver.Args) !h.driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        self.state.resolver = try turn.deferAnswer();
        self.state.calls += 1;
        return .{ .void = {} };
    }
};

test "loam continuation refuses protected wire completion after source loss without redispatch" {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seedIndependentTarget(&store, &backend);
    var host: h.Hosted = undefined;
    try host.initOptions(&store, &backend, data, .{ .sleep_policy = .every_turn });
    defer host.deinit();
    var exporter = h.host_support.init(h.a, @splat(0x65), h.driver.Host.Options.withFrameCap(4096));
    defer exporter.deinit();
    var target_state: WaitingTarget.State = .{};
    const actor = try exporter.vat.spawn(h.driver.Hosting(WaitingWireTarget), .{ .inner = .{ .state = &target_state } });
    const local = try exporter.liftLocalActor(actor);
    defer exporter.releaseCapabilityTerminal(local, null);
    const swiss = try exporter.publishDurableCapability(@splat(0x37), local);
    const pair = try pairs.openPair(&host.host, &exporter, "127.0.0.1:9744");
    var fetched: CapturedRef = .{};
    try host.host.vowOn(try host.host.fetch(pair.a, swiss.slice()), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pairs.pumpToQuiescence(&.{pair});
    const held = try host.host.liftCapability(pair.a, try fetched.require());
    defer host.host.releaseCapabilityTerminal(held, null);
    var app: App = .{ .expected_source = host.use, .target_override = held };
    const registration = [_]h.access.ContentBehavior{app.behavior()};
    host.service.contents = &registration;
    var receipt: h.Answer = .{};
    try host.mutate(host.use, 1, "reserve", &.{}, &receipt);
    try host.drain(&backend);
    const active = app.active.?;
    defer active.release();
    const front = try active.project(0);
    defer {
        host.host.releaseCapabilityTerminal(front, null);
        host.attached.advance() catch unreachable;
    }
    const protected = try host.host.callCapability(h.a, pair.a, front, "target", &.{}, 4096);
    defer protected.deinit();
    for (0..64) |_| {
        try host.host.flushSession(pair.a);
        try pairs.pumpToQuiescence(&.{pair});
        try host.attached.advance();
        try std.testing.expect(try host.reads(&backend) == null);
        if (target_state.resolver != null) break;
    }
    try std.testing.expect(target_state.resolver != null);
    try std.testing.expect(protected.result() == .pending);
    for (store.cache.pins) |pin| try std.testing.expectEqual(@as(u64, 0), pin.sequence);
    _ = try h.f.change(&store, &backend, data.owner, .{ .pause = data.grant });
    var arena = std.heap.ArenaAllocator.init(h.a);
    defer arena.deinit();
    // The completed result carries exact capability custody as well as data;
    // loss of source admission must not disclose either leaf.
    try exporter.resolverFulfillValue(target_state.resolver.?, .{ .list = &.{ .{ .integer = 91 }, .{ .capability = local } } }, arena.allocator());
    for (0..64) |_| {
        try host.host.flushSession(pair.a);
        try pairs.pumpToQuiescence(&.{pair});
        try host.attached.advance();
        try std.testing.expect(try host.reads(&backend) == null);
        if (protected.result() != .pending) break;
    }
    try std.testing.expect(protected.result() == .failed);
    try std.testing.expectEqualStrings("Paused", protected.result().failed.message);
    try std.testing.expectEqual(@as(usize, 1), target_state.calls);
    try std.testing.expectEqual(@as(usize, 0), host.attached.pending_bytes);
}

test "loam continuation refuses protected local completion after source loss without redispatch" {
    try localCompletion(false, .pause);
}

test "loam continuation private executor retains the exact applied result after source pause" {
    try localCompletion(true, .pause);
}

test "loam continuation private executor retains the exact applied result after source revocation" {
    try localCompletion(true, .revoke);
}

test "loam continuation private executor cancellation keeps admitted custody before delivery and during target wait" {
    try localCompletion(true, .cancel_before);
    try localCompletion(true, .cancel_wait);
}

test "loam continuation private executor finishes work queued before the Host barrier" {
    try localCompletion(true, .finish_before);
    try localCompletion(true, .finish_forward);
    try localCompletion(true, .finish_wait);
    try localCompletion(true, .cancel_finish_before);
    try localCompletion(true, .cancel_finish_wait);
}

test "loam continuation private executor finishes retained wire children and respects independent cancellation" {
    for ([_]FailureCase{ .finish_before, .finish_forward, .finish_wait, .cancel_forward, .session_finish }) |mode| try privateFailure(mode);
}

test "loam continuation private executor preserves target break and closure separately" {
    for ([_]FailureCase{ .broken, .closed, .retired, .projection, .outer_capacity, .ready_retired, .heap_retry }) |mode| try privateFailure(mode);
}

const FailureCase = enum { broken, closed, retired, projection, outer_capacity, ready_retired, heap_retry, finish_before, finish_forward, finish_wait, cancel_forward, session_finish };

fn privateFailure(mode: FailureCase) !void {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seedIndependentTarget(&store, &backend);
    var host: h.Hosted = undefined;
    try host.initOptions(&store, &backend, data, .{ .sleep_policy = .every_turn, .forward_reply_bytes = if (mode == .projection) 1 else 4096 });
    defer host.deinit();
    var exporter = h.host_support.init(h.a, @splat(0x66), h.driver.Host.Options.withFrameCap(4096));
    defer exporter.deinit();
    var target_state: WaitingTarget.State = .{};
    const actor = try exporter.vat.spawn(h.driver.Hosting(WaitingWireTarget), .{ .inner = .{ .state = &target_state } });
    const local = try exporter.liftLocalActor(actor);
    defer exporter.releaseCapabilityTerminal(local, null);
    const swiss = try exporter.publishDurableCapability(@splat(0x38), local);
    const pair = try pairs.openPair(&host.host, &exporter, "127.0.0.1:9745");
    var fetched: CapturedRef = .{};
    try host.host.vowOn(try host.host.fetch(pair.a, swiss.slice()), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pairs.pumpToQuiescence(&.{pair});
    const held = try host.host.liftCapability(pair.a, try fetched.require());
    defer host.host.releaseCapabilityTerminal(held, null);
    var app: App = .{ .expected_source = host.use, .target_override = held };
    const registration = [_]h.access.ContentBehavior{app.behavior()};
    host.service.contents = &registration;
    var committed: h.Answer = .{};
    try host.mutate(host.use, 1, "reserve", &.{}, &committed);
    try host.drain(&backend);
    const active = app.active.?;
    defer active.release();
    const result = try active.execute(h.a, 0, "target", &.{}, if (mode == .outer_capacity or mode == .heap_retry) 1 else 4096);
    defer result.deinit();
    if (mode == .retired) {
        try host.host.releaseSession(pair.a);
        try host.drain(&backend);
        try std.testing.expect(result.result() == .unsent);
        try std.testing.expectEqual(@as(usize, 0), target_state.calls);
        try std.testing.expectEqual(@as(usize, 0), host.attached.pending_bytes);
        return;
    }
    const finishing = mode == .finish_before or mode == .finish_forward or mode == .finish_wait;
    if (mode == .finish_forward or mode == .cancel_forward or mode == .session_finish) try beforeForward(&host, &backend);
    if (mode == .session_finish) {
        try host.host.beginSessionClose(pair.a, .{ .finish = .unbounded }, 0);
        try host.attached.advance();
        try host.drain(&backend);
        try std.testing.expectEqualStrings("SessionClosing", result.result().unsent.message);
        try std.testing.expectEqual(@as(usize, 0), target_state.calls);
        try std.testing.expectEqual(@as(usize, 0), host.attached.pending_bytes);
        try std.testing.expectEqual(@as(usize, 0), host.host.pending_operations);
        return;
    }
    if (mode == .cancel_forward) {
        host.host.beginClose(.cancel, 0);
        while (try host.host.nextAction()) |_| {}
        try host.drain(&backend);
        try std.testing.expect(result.result() == .unsent);
        try std.testing.expectEqual(@as(usize, 0), target_state.calls);
        try std.testing.expectEqual(@as(usize, 0), host.attached.pending_bytes);
        try std.testing.expectEqual(@as(usize, 0), host.host.pending_operations);
        return;
    }
    if (finishing and mode != .finish_wait) host.host.beginClose(.{ .finish = .unbounded }, 0);
    if (finishing and mode != .finish_wait) try std.testing.expectError(error.HostClosing, active.execute(h.a, 0, "target", &.{}, 4096));
    for (0..64) |_| {
        while (try host.host.nextAction()) |_| {}
        try host.attached.advance();
        try host.host.flushSession(pair.a);
        try pairs.pumpToQuiescence(&.{pair});
        try std.testing.expect(try host.reads(&backend) == null);
        if (target_state.resolver != null) break;
    }
    try std.testing.expect(target_state.resolver != null);
    if (mode == .finish_wait) {
        host.host.beginClose(.{ .finish = .unbounded }, 0);
        try std.testing.expectError(error.HostClosing, active.execute(h.a, 0, "target", &.{}, 4096));
    }
    if (mode == .closed) {
        try host.host.releaseSession(pair.a);
    } else {
        if (finishing or mode == .projection or mode == .outer_capacity or mode == .ready_retired or mode == .heap_retry) {
            var arena = std.heap.ArenaAllocator.init(h.a);
            defer arena.deinit();
            try exporter.resolverFulfillValue(target_state.resolver.?, .{ .list = &.{ .{ .integer = 91 }, .{ .capability = local }, .{ .capability = local } } }, arena.allocator());
        } else try exporter.resolverBreak(target_state.resolver.?, "TargetRefused");
        try pairs.pumpToQuiescence(&.{pair});
        // Retire the home only after the inner owning result is ready, before
        // Loam can project it into the outer observer's independent custody.
        if (mode == .ready_retired) try host.host.releaseSession(pair.a);
    }
    if (mode == .heap_retry) {
        // Broken settlement owns its diagnostic before consuming the resolver.
        // Refuse that actual heap allocation after the inner reply is ready.
        var failing = std.testing.FailingAllocator.init(h.a, .{ .fail_index = 0 });
        host.host.vat.settle_arena.deinit();
        host.host.vat.settle_arena = .init(failing.allocator());
        defer {
            host.host.vat.settle_arena.deinit();
            host.host.vat.settle_arena = .init(h.a);
        }
        try std.testing.expectError(error.OutOfMemory, host.attached.advance());
        try std.testing.expect(result.result() == .pending);
        try std.testing.expect(host.attached.pending_bytes != 0);
        try std.testing.expectEqual(@as(usize, 1), target_state.calls);
        failing.fail_index = std.math.maxInt(usize);
        try host.drain(&backend);
    } else try host.drain(&backend);
    if (finishing) {
        const reply = result.result().ready.list;
        try std.testing.expectEqual(@as(i64, 91), reply[0].integer);
        try std.testing.expectEqual(held, reply[1].capability);
        try std.testing.expectEqual(held, reply[2].capability);
        try std.testing.expectEqual(@as(usize, 1), target_state.calls);
        try std.testing.expectEqual(@as(usize, 0), host.attached.pending_bytes);
        try std.testing.expectEqual(@as(usize, 0), host.host.pending_operations);
        return;
    }
    const failed = result.result().unknown;
    try std.testing.expectEqual(@as(h.driver.VowFailure, if (mode == .closed) .closed else .broken), failed.kind);
    if (mode != .closed) try std.testing.expectEqualStrings(switch (mode) {
        .projection => "ReplyCapacity",
        .outer_capacity, .heap_retry => "ReplyCapacity",
        .ready_retired => "UnknownCapability",
        else => "TargetRefused",
    }, failed.message);
    try std.testing.expectEqual(@as(usize, 1), target_state.calls);
    try std.testing.expectEqual(@as(usize, 0), host.attached.pending_bytes);
    try std.testing.expectEqual(@as(usize, 0), host.host.pending_operations);
}

fn beforeForward(host: *h.Hosted, backend: *h.loam.Volatile) !void {
    for (0..64) |_| {
        _ = try host.host.vat.driveIngressBudgeted(.local, 1);
        for (host.attached.operations) |op| if (op.phase == .forwarding) {
            try std.testing.expectEqual(@as(usize, 2), host.host.pending_operations);
            return;
        };
        try host.attached.advance();
        try std.testing.expect(try host.reads(backend) == null);
    }
    return error.DidNotForward;
}

const LocalCase = enum { pause, revoke, cancel_before, cancel_wait, finish_before, finish_forward, finish_wait, cancel_finish_before, cancel_finish_wait };

fn localCompletion(comptime receipt: bool, comptime mode: LocalCase) !void {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seedIndependentTarget(&store, &backend);
    var host: h.Hosted = undefined;
    try host.initOptions(&store, &backend, data, .{ .sleep_policy = .every_turn });
    defer host.deinit();
    var target_state: WaitingTarget.State = .{};
    const actor = try host.host.vat.spawn(h.driver.Hosting(WaitingTarget), .{ .inner = .{ .state = &target_state } });
    const held = try host.host.liftLocalActor(actor);
    defer host.host.releaseCapabilityTerminal(held, null);
    var app: App = .{ .expected_source = host.use, .target_override = held };
    const registration = [_]h.access.ContentBehavior{app.behavior()};
    host.service.contents = &registration;
    var committed: h.Answer = .{};
    try host.mutate(host.use, 1, "reserve", &.{}, &committed);
    try host.drain(&backend);
    const active = app.active.?;
    defer active.release();
    const front: ?h.driver.Capability = if (receipt) null else try active.project(0);
    defer {
        if (front) |ref| host.host.releaseCapabilityTerminal(ref, null);
        host.attached.advance() catch unreachable;
    }
    const result = if (receipt)
        try active.execute(h.a, 0, "target", &.{}, 4096)
    else
        try host.host.callLocalCapability(h.a, front.?, "target", &.{}, 4096);
    const cancelled = mode == .cancel_before or mode == .cancel_wait or mode == .cancel_finish_before or mode == .cancel_finish_wait;
    const finishing = mode == .finish_before or mode == .finish_forward or mode == .finish_wait or mode == .cancel_finish_before or mode == .cancel_finish_wait;
    defer if (!cancelled) result.deinit();
    if (mode == .cancel_before or mode == .cancel_finish_before) result.deinit();
    if (mode == .finish_forward) try beforeForward(&host, &backend);
    if (finishing and mode != .finish_wait and mode != .cancel_finish_wait) {
        if (mode != .finish_forward) try std.testing.expectEqual(@as(usize, 1), host.host.pending_operations);
        host.host.beginClose(.{ .finish = .unbounded }, 0);
        try std.testing.expectError(error.HostClosing, active.execute(h.a, 0, "target", &.{}, 4096));
    }
    for (0..64) |_| {
        while (try host.host.nextAction()) |_| {}
        try host.attached.advance();
        try std.testing.expect(try host.reads(&backend) == null);
        if (target_state.resolver != null) break;
    }
    try std.testing.expect(target_state.resolver != null);
    if (mode != .cancel_before and mode != .cancel_finish_before) try std.testing.expect(result.result() == .pending);
    if (mode == .cancel_wait or mode == .cancel_finish_wait) result.deinit();
    if (mode == .finish_wait or mode == .cancel_finish_wait) {
        try std.testing.expectEqual(@as(usize, 3), host.host.pending_operations);
        host.host.beginClose(.{ .finish = .unbounded }, 0);
        try std.testing.expectError(error.HostClosing, active.execute(h.a, 0, "target", &.{}, 4096));
    }
    for (store.cache.pins) |pin| try std.testing.expectEqual(@as(u64, 0), pin.sequence);
    if (!finishing) _ = try h.f.change(&store, &backend, data.owner, if (mode == .revoke) .{ .revoke = data.grant } else .{ .pause = data.grant });
    var arena = std.heap.ArenaAllocator.init(h.a);
    defer arena.deinit();
    try host.host.resolverFulfillValue(target_state.resolver.?, .{ .list = &.{ .{ .integer = 91 }, .{ .capability = held }, .{ .capability = held } } }, arena.allocator());
    try host.drain(&backend);
    if (cancelled) {
        try std.testing.expectEqual(@as(usize, 0), host.host.pending_operations);
    } else if (receipt) {
        const reply = result.result().ready.list;
        try std.testing.expectEqual(@as(i64, 91), reply[0].integer);
        try std.testing.expectEqual(held, reply[1].capability);
        try std.testing.expectEqual(held, reply[2].capability);
        // A new dispatch still needs current source admission, even though
        // internal settlement preserved an already-applied exact result.
        if (!finishing) {
            const denied = try active.execute(h.a, 0, "target", &.{}, 4096);
            defer denied.deinit();
            try host.drain(&backend);
            try std.testing.expect(denied.result() == .unsent);
        }
    } else {
        try std.testing.expectEqualStrings("Paused", result.result().failed.message);
    }
    try std.testing.expectEqual(@as(usize, 1), target_state.calls);
    try std.testing.expectEqual(@as(usize, 0), host.attached.pending_bytes);
}

test "loam continuation activates after confirmed recovery and separates source from target admission" {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seedIndependentTarget(&store, &backend);
    _ = try h.f.change(&store, &backend, data.owner, .{ .set_policy = .{
        .grant = data.grant,
        .terms = try h.f.vocabulary.terms(.{ .objects = &.{data.resource} }, &.{h.f.vocabulary.read}, null),
    } });
    var host: h.Hosted = undefined;
    try host.initOptions(&store, &backend, data, .{ .max_continuations = 1, .sleep_policy = .every_turn });
    defer host.deinit();
    var app: App = .{ .expected_source = host.use };
    const registration = [_]h.access.ContentBehavior{app.behavior()};
    host.service.contents = &registration;
    var refused: h.Answer = .{};
    try host.mutate(host.use, 1, "reserve", &.{}, &refused);
    const aborted = try host.untilWrite(&backend);
    try std.testing.expect(app.active == null);
    try std.testing.expectEqual(@as(usize, 1), host.attached.continuations);
    try host.attached.completeWrite(aborted.ticket, .{ .unchanged = error.WriteRefused });
    try host.drain(&backend);
    try std.testing.expect(refused.broken);
    try std.testing.expectEqual(@as(usize, 1), app.cancelled);
    try std.testing.expectEqual(@as(usize, 0), host.attached.continuations);
    var absent: h.Answer = .{};
    try host.mutate(host.use, 1, "reserve", &.{}, &absent);
    const missing = try host.untilWrite(&backend);
    try host.attached.completeWrite(missing.ticket, .unknown);
    try std.testing.expectEqual(@as(usize, 1), host.attached.continuations);
    try std.testing.expect(app.active == null);
    try host.attached.resolve(missing.ticket, .unchanged);
    try host.drain(&backend);
    try std.testing.expect(absent.broken);
    try std.testing.expectEqual(@as(usize, 2), app.cancelled);
    try std.testing.expectEqual(@as(usize, 0), host.attached.continuations);
    var result: h.Answer = .{};
    try host.mutate(host.use, 1, "reserve", &.{}, &result);
    const uncertain = try host.untilWrite(&backend);
    const installed = backend.commit(uncertain);
    try std.testing.expect(installed == .committed);
    try host.attached.completeWrite(uncertain.ticket, .unknown);
    try std.testing.expect(app.active == null);
    try std.testing.expectEqual(@as(usize, 0), app.activated);
    try host.attached.resolve(uncertain.ticket, .{ .committed = installed.committed });
    try host.drain(&backend);
    const active = app.active.?;
    defer active.release();
    try std.testing.expectEqual(@as(?bool, true), result.changed);
    try std.testing.expectEqual(@as(usize, 1), app.activated);
    try std.testing.expectEqual(@as(usize, 0), host.attached.pending_bytes);
    for (store.cache.pins) |pin| try std.testing.expectEqual(@as(u64, 0), pin.sequence);
    var replay: h.Answer = .{};
    try host.mutate(host.use, 1, "reserve", &.{}, &replay);
    try host.drain(&backend);
    try std.testing.expectEqual(@as(?bool, true), replay.changed);
    try std.testing.expectEqual(@as(usize, 1), app.activated);
    var full: h.Answer = .{};
    try host.mutate(host.use, 2, "reserve", &.{}, &full);
    try host.drain(&backend);
    try std.testing.expectEqualStrings("ContinuationCapacity", full.reason());
    const front = try active.project(0);
    defer {
        host.host.releaseCapabilityTerminal(front, null);
        host.attached.advance() catch unreachable;
    }
    var delivered: h.Answer = .{};
    try host.send(front, "target", &.{}, &delivered);
    try host.drain(&backend);
    try std.testing.expectEqual(@as(?i64, 7), delivered.number);
    try std.testing.expectEqual(@as(usize, 1), app.dispatched);
    _ = try h.f.change(&store, &backend, data.owner, .{ .pause = data.grant });
    var paused: h.Answer = .{};
    try host.send(front, "target", &.{}, &paused);
    try host.drain(&backend);
    try std.testing.expect(paused.broken);
    try std.testing.expectEqual(@as(usize, 1), app.dispatched);
    _ = try h.f.change(&store, &backend, data.owner, .{ .resume_access = data.grant });
    _ = try h.f.change(&store, &backend, data.owner, .{ .pause = data.target_grant.? });
    var target_paused: h.Answer = .{};
    try host.send(front, "target", &.{}, &target_paused);
    try host.drain(&backend);
    try std.testing.expect(target_paused.broken);
    try std.testing.expectEqual(@as(usize, 1), app.dispatched);
}
