//! Sleep, activation, and durable visibility use the ordinary Vat call path.
const std = @import("std");
const f = @import("fixture.zig");

test "loam attachment creation refuses an unsubmitted transaction without consuming it" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    try fixture.data.store.begin();
    try std.testing.expectError(error.Busy, f.hosting.Attachment.create(std.testing.allocator, &fixture.host, &fixture.data.store, &f.behaviors, .{}));
    try std.testing.expect(fixture.data.store.phase == .staging);
    try fixture.data.store.abort();
    const sibling = try f.hosting.Attachment.create(std.testing.allocator, &fixture.host, &fixture.data.store, &f.behaviors, .{});
    try sibling.destroy();
}

const ForwardTarget = struct {
    calls: *usize,
    pub fn handle(self: *ForwardTarget, turn: *f.driver.HostTurn, _: []const u8, args: []const f.driver.Value) !f.driver.Value {
        defer turn.releaseValues(args);
        self.calls.* += 1;
        return args[0];
    }
};

const GenericForward = struct {
    target: f.driver.Capability,
    calls: usize = 0,
    fn invoke(call: *f.hosting.Call, _: f.loam.core.RecordView, verb: []const u8, args: []const f.driver.Value) !f.driver.Value {
        const self: *@This() = @ptrCast(@alignCast(call.context.?));
        self.calls += 1;
        call.forward = .{ .target = self.target, .verb = verb, .args = args };
        return .{ .void = {} };
    }
};

test "loam generic forwarded calls retain exact owning results through preparation retirement" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    var effects: usize = 0;
    const actor = try fixture.host.vat.spawn(f.driver.Hosting(ForwardTarget), .{ .inner = .{ .calls = &effects } });
    const target = try fixture.host.liftLocalActor(actor);
    defer fixture.host.releaseCapabilityTerminal(target, null);
    var source: GenericForward = .{ .target = target };
    const behaviors = [_]f.hosting.Behavior{.{ .schema = 7, .context = &source, .invoke = GenericForward.invoke }};
    fixture.attached.behaviors = &behaviors;
    const call = try fixture.host.callLocalCapability(std.testing.allocator, fixture.root, "echo", &.{.{ .list = &.{ .{ .capability = target }, .{ .capability = target } } }}, 4096);
    defer call.deinit();
    try fixture.drain();
    try std.testing.expectEqual(target, call.result().ready.list[0].capability);
    try std.testing.expectEqual(target, call.result().ready.list[1].capability);
    try std.testing.expectEqual(@as(usize, 1), effects);
    try std.testing.expectEqual(@as(usize, 1), source.calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
    for (fixture.data.store.cache.pins) |pin| try std.testing.expectEqual(@as(u64, 0), pin.sequence);
}

test "loam near forwarding refuses without losing the eventual effect" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    var effects: usize = 0;
    const actor = try fixture.host.vat.spawn(f.driver.Hosting(ForwardTarget), .{ .inner = .{ .calls = &effects } });
    const target = try fixture.host.liftLocalActor(actor);
    defer fixture.host.releaseCapabilityTerminal(target, null);
    var source: GenericForward = .{ .target = target };
    const behaviors = [_]f.hosting.Behavior{.{ .schema = 7, .context = &source, .invoke = GenericForward.invoke }};
    fixture.attached.behaviors = &behaviors;
    const near = fixture.host.localActorFor(fixture.root).?;
    try std.testing.expectError(error.DurableTurnRequired, fixture.host.vat.near(near, .{ .verb = "echo", .args = &.{.{ .integer = 42 }} }));
    try std.testing.expectEqual(@as(usize, 0), effects);
    try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
    const call = try fixture.host.callLocalCapability(std.testing.allocator, fixture.root, "echo", &.{.{ .integer = 42 }}, 4096);
    defer call.deinit();
    try fixture.drain();
    try std.testing.expectEqual(@as(i64, 42), call.result().ready.integer);
    try std.testing.expectEqual(@as(usize, 1), effects);
    try std.testing.expectEqual(@as(u64, 1), fixture.data.store.metadata.revision);
    for (fixture.data.store.cache.pins) |pin| try std.testing.expectEqual(@as(u64, 0), pin.sequence);
}

test "loam near calls bound copied inputs and preserve composite replies beyond call storage" {
    const Echo = struct {
        invocations: usize = 0,
        input: []const u8 = "",
        output: []const u8 = "",

        fn invoke(call: *f.hosting.Call, _: f.loam.core.RecordView, _: []const u8, args: []const f.driver.Value) !f.driver.Value {
            const self: *@This() = @ptrCast(@alignCast(call.context.?));
            self.invocations += 1;
            self.input = args[0].bytes;
            const fields = try call.arena().alloc(f.driver.Value, 2);
            self.output = try call.arena().dupe(u8, args[0].bytes);
            fields[0] = .{ .bytes = self.output };
            fields[1] = .{ .bytes = args[0].bytes };
            return .{ .list = fields };
        }
    };
    var fixture: f.Fixture = undefined;
    try fixture.init(.{ .call_bytes = 1024, .pending_bytes = 1024 });
    defer fixture.deinit();
    var echo: Echo = .{};
    const behaviors = [_]f.hosting.Behavior{.{ .schema = 7, .context = &echo, .invoke = Echo.invoke }};
    fixture.attached.behaviors = &behaviors;
    const near = fixture.host.localActorFor(fixture.root).?;
    const input = "reply remains after call retirement";
    const reply = try fixture.host.vat.near(near, .{ .verb = "echo", .args = &.{.{ .bytes = input }} });
    try std.testing.expect(echo.input.ptr != input.ptr);
    try std.testing.expect(reply.list[0].bytes.ptr != echo.output.ptr);
    try std.testing.expect(reply.list[1].bytes.ptr != echo.input.ptr);
    try std.testing.expectEqualStrings(input, reply.list[0].bytes);
    try std.testing.expectEqualStrings(input, reply.list[1].bytes);
    try std.testing.expectError(error.OutOfMemory, fixture.host.vat.near(near, .{ .verb = "echo", .args = &.{.{ .bytes = &@as([2048]u8, @splat(0xab)) }} }));
    try std.testing.expectEqual(@as(usize, 1), echo.invocations);
    const retry = try fixture.host.vat.near(near, .{ .verb = "echo", .args = &.{.{ .bytes = "retry" }} });
    try std.testing.expectEqualStrings("retry", retry.list[0].bytes);
    try std.testing.expectEqual(@as(usize, 2), echo.invocations);
    try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
    try std.testing.expectEqual(@as(u64, 1), fixture.data.store.metadata.revision);
}

test "loam actor keeps its near identity across sleep wake and committed turns" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const near = fixture.host.localActorFor(fixture.root).?;
    try fixture.attached.sleep(fixture.root);
    try std.testing.expectError(error.ResidencyRequired, fixture.host.vat.near(near, .{ .verb = "get", .args = &.{} }));
    try std.testing.expectEqual(@as(u64, 0), fixture.attached.stats.loads);
    for (0..3) |i| {
        var capture: f.Capture = .{};
        try fixture.send("add", &.{.{ .integer = 1 }}, &capture);
        try fixture.drain();
        try std.testing.expectEqual(@as(?i64, @intCast(i + 1)), capture.value);
        try std.testing.expectEqual(near, fixture.host.localActorFor(fixture.root).?);
        try std.testing.expectEqual(@as(i64, @intCast(i + 1)), (try fixture.host.vat.near(near, .{ .verb = "get", .args = &.{} })).integer);
        try fixture.attached.sleep(fixture.root);
    }
    try std.testing.expectEqual(@as(usize, 0), fixture.data.store.cache.allocated_bytes);
}

test "loam actor coalesces cold callers and preserves invocation order" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    try fixture.attached.sleep(fixture.root);
    var captures: [8]f.Capture = @splat(.{});
    for (&captures) |*capture| try fixture.send("add", &.{.{ .integer = 1 }}, capture);
    try fixture.host.vat.drive();
    try fixture.attached.advance();
    const read = (try fixture.attached.nextWork()).?.read;
    try std.testing.expect((try fixture.attached.nextWork()) == null);
    try std.testing.expectEqual(@as(u64, 1), fixture.attached.stats.loads);
    try std.testing.expectError(error.Busy, fixture.attached.destroy());
    try fixture.attached.completeRead(read.ticket, fixture.data.backend.read(read));
    try fixture.drain();
    for (captures, 0..) |capture, i| try std.testing.expectEqual(@as(?i64, @intCast(i + 1)), capture.value);
}

test "loam actor retained cold work respects cancellation before source invocation" {
    for ([_]enum { cold_cancel, scheduled_cancel, finish }{ .cold_cancel, .scheduled_cancel, .finish }) |boundary| {
        var fixture: f.Fixture = undefined;
        try fixture.init(.{});
        defer fixture.deinit();
        try fixture.attached.sleep(fixture.root);
        const call = try fixture.host.callLocalCapability(std.testing.allocator, fixture.root, "add", &.{.{ .integer = 4 }}, 4096);
        defer call.deinit();
        try fixture.host.vat.drive();
        try fixture.attached.advance();
        const read = (try fixture.attached.nextWork()).?.read;
        if (boundary == .scheduled_cancel) {
            try fixture.attached.completeRead(read.ticket, fixture.data.backend.read(read));
            try fixture.attached.advance();
            try std.testing.expect(fixture.attached.operations[0].phase == .scheduled);
        }
        fixture.host.beginClose(if (boundary == .finish) .{ .finish = .unbounded } else .cancel, 0);
        if (boundary == .cold_cancel) try fixture.host.progressClose(0);
        if (boundary != .scheduled_cancel) try fixture.attached.completeRead(read.ticket, fixture.data.backend.read(read));
        try fixture.drain();
        const expected: u64 = if (boundary == .finish) 1 else 0;
        try std.testing.expectEqual(expected, fixture.attached.stats.invocations);
        try std.testing.expectEqual(@as(u64, 1) + expected, fixture.data.store.metadata.revision);
        if (boundary == .finish) {
            try std.testing.expectEqual(@as(i64, 4), call.result().ready.integer);
        } else try std.testing.expect(call.result() == .failed);
        try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
        try std.testing.expectEqual(@as(usize, 0), fixture.host.pending_operations);
        try std.testing.expect((try fixture.attached.nextWork()) == null);
        for (fixture.data.store.cache.pins) |pin| try std.testing.expectEqual(@as(u64, 0), pin.sequence);
    }
}

test "loam actor reply waits for commit and unknown outcome recovery" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    var capture: f.Capture = .{};
    try fixture.send("add", &.{.{ .integer = 4 }}, &capture);
    try fixture.host.vat.drive();
    try fixture.attached.advance();
    try fixture.host.vat.drive();
    const batch = (try fixture.attached.nextWork()).?.write;
    const op = &fixture.attached.operations[0];
    const acquired = op.memory.backing.used;
    try std.testing.expect(acquired > 0 and acquired < fixture.attached.options.call_bytes);
    try std.testing.expect(capture.value == null);
    try std.testing.expect(fixture.data.backend.commit(batch) == .committed);
    try fixture.attached.completeWrite(batch.ticket, .unknown);
    try fixture.attached.advance();
    try std.testing.expect(capture.value == null);
    try std.testing.expectEqual(acquired, op.memory.backing.used);
    try std.testing.expectError(error.RecoveryRequired, fixture.attached.pin(fixture.root));
    const recovery = try fixture.attached.recoveryBatch();
    try fixture.attached.resolve(batch.ticket, try fixture.data.backend.recover(recovery));
    try fixture.attached.advance();
    try std.testing.expectEqual(@as(?i64, 4), capture.value);
    try std.testing.expectEqual(@as(u64, 1), fixture.attached.stats.invocations);
    try std.testing.expect(op.phase == .free);
    try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
}

test "loam actor cancellation preserves submitted write custody through every outcome" {
    const Boundary = enum { committed, unchanged, unknown_committed, unknown_absent };
    for (std.enums.values(Boundary)) |boundary| {
        var fixture: f.Fixture = undefined;
        try fixture.init(.{});
        defer fixture.deinit();
        const call = try fixture.host.callLocalCapability(std.testing.allocator, fixture.root, "add", &.{.{ .integer = 4 }}, 4096);
        defer call.deinit();
        try fixture.host.vat.drive();
        try fixture.attached.advance();
        try fixture.host.vat.drive();
        const batch = (try fixture.attached.nextWork()).?.write;
        fixture.host.beginClose(.cancel, 0);
        try fixture.host.progressClose(0);
        try std.testing.expect(call.result() == .failed);
        try std.testing.expectError(error.Busy, fixture.attached.destroy());
        const committed = boundary == .committed or boundary == .unknown_committed;
        const outcome: f.loam.core.Outcome = if (committed)
            fixture.data.backend.commit(batch)
        else
            .{ .unchanged = error.InjectedWriteRefusal };
        if (committed) try std.testing.expect(outcome == .committed);
        if (boundary == .unknown_committed or boundary == .unknown_absent) {
            try fixture.attached.completeWrite(batch.ticket, .unknown);
            try fixture.attached.advance();
            try std.testing.expect(fixture.attached.operations[0].phase == .writing);
            try std.testing.expect(fixture.attached.pending_bytes > 0);
            try std.testing.expectError(error.Busy, fixture.attached.destroy());
            const recovery = try fixture.attached.recoveryBatch();
            const resolution = try fixture.data.backend.recover(recovery);
            try std.testing.expectEqual(committed, resolution == .committed);
            try fixture.attached.resolve(batch.ticket, resolution);
        } else try fixture.attached.completeWrite(batch.ticket, outcome);
        try fixture.attached.advance();
        try std.testing.expectEqual(@as(u64, 1), fixture.attached.stats.invocations);
        try std.testing.expectEqual(@as(u64, if (committed) 2 else 1), fixture.data.store.metadata.revision);
        const records = @import("../core/fixture.zig");
        const lease = try records.load(&fixture.data.store, &fixture.data.backend, fixture.id);
        defer fixture.data.store.release(lease) catch unreachable;
        const view = try fixture.data.store.currentView(lease);
        try std.testing.expectEqual(@as(i64, if (committed) 4 else 0), std.mem.readInt(i64, view.payload[0..8], .little));
        try std.testing.expect(call.result() == .failed);
        try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
        try std.testing.expectEqual(@as(usize, 0), fixture.host.pending_operations);
        try std.testing.expect((try fixture.attached.nextWork()) == null);
        try std.testing.expectError(error.StaleCompletion, fixture.attached.completeWrite(batch.ticket, outcome));
    }
}

test "loam actor retains one reply backing through delayed commit recovery and settlement" {
    const Reply = struct {
        source: []const f.driver.Value = &.{},
        number: ?i64 = null,

        fn invoke(call: *f.hosting.Call, _: f.loam.core.RecordView, _: []const u8, _: []const f.driver.Value) !f.driver.Value {
            const self: *@This() = @ptrCast(@alignCast(call.context.?));
            const bytes = try call.arena().alloc(u8, 8);
            std.mem.writeInt(i64, bytes[0..8], 7, .little);
            call.replace(bytes);
            const fields = try call.arena().alloc(f.driver.Value, 1);
            fields[0] = .{ .bytes = bytes };
            self.source = fields;
            return .{ .list = fields };
        }
        fn record(context: ?*anyopaque, result: f.actors.Resolution) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (result == .fulfilled) self.number = std.mem.readInt(i64, result.fulfilled.list[0].bytes[0..8], .little);
        }
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var fixture: f.Fixture = undefined;
    try fixture.initAllocator(failing.allocator(), .{});
    defer fixture.deinit();
    var reply: Reply = .{};
    const behaviors = [_]f.hosting.Behavior{.{ .schema = 7, .context = &reply, .invoke = Reply.invoke }};
    fixture.attached.behaviors = &behaviors;
    _ = try fixture.host.vat.sendObservedFromIngress(.local, fixture.host.localActorFor(fixture.root).?, .{ .verb = "set", .args = &.{} }, .{ .ctx = &reply, .func = Reply.record });
    try fixture.host.vat.drive();
    try fixture.attached.advance();
    try fixture.host.vat.drive();
    const batch = (try fixture.attached.nextWork()).?.write;
    const op = &fixture.attached.operations[0];
    try std.testing.expect(op.reply.list.ptr == reply.source.ptr);
    try std.testing.expect(op.reply.list[0].bytes.ptr == reply.source[0].bytes.ptr);
    const acquired = op.memory.backing.used;
    try std.testing.expect(fixture.data.backend.commit(batch) == .committed);
    try fixture.attached.completeWrite(batch.ticket, .unknown);
    try fixture.attached.advance();
    try std.testing.expectEqual(acquired, op.memory.backing.used);
    try std.testing.expectEqual(@as(?i64, null), reply.number);
    const recovery = try fixture.attached.recoveryBatch();
    try fixture.attached.resolve(batch.ticket, try fixture.data.backend.recover(recovery));
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, fixture.attached.advance());
    try std.testing.expect(op.phase == .settling);
    try std.testing.expectEqual(acquired, op.memory.backing.used);
    try std.testing.expect(op.reply.list.ptr == reply.source.ptr);
    try std.testing.expectEqual(@as(i64, 7), std.mem.readInt(i64, op.reply.list[0].bytes[0..8], .little));
    try std.testing.expectEqual(@as(?i64, null), reply.number);
    failing.fail_index = std.math.maxInt(usize);
    try fixture.attached.advance();
    try std.testing.expectEqual(@as(?i64, 7), reply.number);
    try std.testing.expectEqual(@as(u64, 1), fixture.attached.stats.invocations);
    try std.testing.expectEqual(@as(u64, 2), fixture.data.store.metadata.revision);
    try std.testing.expect(op.phase == .free);
}

test "loam actor failed state replacement is not installed and pins prevent sleep" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const pin = try fixture.attached.pin(fixture.root);
    try std.testing.expectError(error.Busy, fixture.attached.sleep(fixture.root));
    try fixture.data.store.release(pin);
    var capture: f.Capture = .{};
    try fixture.send("fail", &.{.{ .integer = 8 }}, &capture);
    try fixture.drain();
    try std.testing.expect(capture.broken);
    try std.testing.expectEqual(@as(u64, 1), fixture.data.store.metadata.revision);
    const near = fixture.host.localActorFor(fixture.root).?;
    try std.testing.expectEqual(@as(i64, 0), (try fixture.host.vat.near(near, .{ .verb = "get", .args = &.{} })).integer);
    try std.testing.expectError(error.DurableTurnRequired, fixture.host.vat.near(near, .{ .verb = "add", .args = &.{.{ .integer = 9 }} }));
}

test "loam actor cancellation retires a scheduled activation pin" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const ingress = try fixture.host.vat.openIngress();
    var capture: f.Capture = .{};
    const near = fixture.host.localActorFor(fixture.root).?;
    _ = try fixture.host.vat.sendObservedFromIngress(ingress, near, .{ .verb = "get", .args = &.{} }, .{ .ctx = &capture, .func = f.Capture.record });
    _ = try fixture.host.vat.driveBudgeted(1);
    try fixture.attached.advance();
    try fixture.host.vat.cancelIngress(ingress, "closed");
    try fixture.attached.advance();
    try std.testing.expect(capture.broken);
    try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
    try fixture.attached.sleep(fixture.root);
}

test "loam actor slow storage and bounded pending calls preserve unrelated Vat progress" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{ .max_calls = 2, .call_bytes = 2048, .pending_bytes = 4096 });
    defer fixture.deinit();
    try fixture.attached.sleep(fixture.root);
    var captures: [3]f.Capture = @splat(.{});
    for (&captures) |*capture| try fixture.send("get", &.{}, capture);
    try fixture.host.vat.drive();
    try std.testing.expect(captures[2].broken);
    try std.testing.expectEqual(@as(usize, 4096), fixture.attached.pending_bytes);
    const Other = struct {
        pub fn handle(_: *@This(), _: *f.actors.Turn, _: f.actors.Message) !@import("glowcap").ocapn.model.Argument {
            return .{ .integer = 77 };
        }
    };
    const other = try fixture.host.vat.spawn(Other, .{});
    defer fixture.host.vat.releaseActor(other.local);
    var independent: f.Capture = .{};
    _ = try fixture.host.vat.sendObservedFromIngress(.local, other, .{ .verb = "get", .args = &.{} }, .{ .ctx = &independent, .func = f.Capture.record });
    try fixture.attached.advance();
    const read = (try fixture.attached.nextWork()).?.read;
    try fixture.host.vat.drive();
    try std.testing.expectEqual(@as(?i64, 77), independent.value);
    try std.testing.expect(captures[0].value == null);
    try fixture.attached.completeRead(read.ticket, fixture.data.backend.read(read));
    try fixture.drain();
}

test "loam actor storage corruption breaks waiters without fresh actor fallback" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    try fixture.attached.sleep(fixture.root);
    var capture: f.Capture = .{};
    try fixture.send("get", &.{}, &capture);
    try fixture.host.vat.drive();
    try fixture.attached.advance();
    const read = (try fixture.attached.nextWork()).?.read;
    const result = fixture.data.backend.read(read);
    read.buffer[0] ^= 1;
    try std.testing.expectError(error.Corrupt, fixture.attached.completeRead(read.ticket, result));
    try fixture.attached.advance();
    try std.testing.expect(capture.broken);
    try std.testing.expectEqual(@as(u64, 0), fixture.attached.stats.invocations);
    try std.testing.expectError(error.StaleCompletion, fixture.attached.completeRead(read.ticket, result));
}

test "loam actor attachment closes while held endpoints refuse without touching freed storage" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    const near = fixture.host.localActorFor(fixture.root).?;
    try fixture.attached.destroy();
    fixture.data.deinit();
    try std.testing.expectError(error.AttachmentClosed, fixture.host.vat.near(near, .{ .verb = "get", .args = &.{} }));
    try fixture.host.releaseCapability(fixture.root, 1);
    fixture.host.deinit();
}

test "loam actor allocation refusal unwinds or finishes exactly one mutation" {
    var refusals: usize = 0;
    var successes: usize = 0;
    for (0..96) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var fixture: f.Fixture = undefined;
        try fixture.initAllocator(failing.allocator(), .{});
        defer fixture.deinit();
        try fixture.attached.sleep(fixture.root);
        failing.fail_index = failing.alloc_index + offset;
        var answer: f.Capture = .{};
        fixture.send("add", &.{.{ .integer = 1 }}, &answer) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        };
        fixture.drain() catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        };
        if (failing.has_induced_failure) refusals += 1;
        failing.fail_index = std.math.maxInt(usize);
        try fixture.drain();
        try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
        try std.testing.expect(fixture.attached.stats.invocations <= 1);
        if (answer.value) |number| {
            try std.testing.expectEqual(@as(i64, 1), number);
            try std.testing.expectEqual(@as(u64, 2), fixture.data.store.metadata.revision);
            successes += 1;
        } else try std.testing.expectEqual(@as(u64, 1), fixture.data.store.metadata.revision);
    }
    try std.testing.expect(refusals > 5 and successes > 0);
}

test "loam actor call-memory refusal before and after admission leaves no mutation" {
    const Greedy = struct {
        fn invoke(call: *f.hosting.Call, view: f.loam.core.RecordView, verb: []const u8, args: []const f.driver.Value) !f.driver.Value {
            if (!std.mem.eql(u8, verb, "greedy")) return f.counter(call, view, verb, args);
            call.replace(&@as([8]u8, @splat(1)));
            _ = try call.arena().alloc(u8, 1024);
            return .{ .integer = 1 };
        }
    };
    const behaviors = [_]f.hosting.Behavior{.{ .schema = 7, .invoke = Greedy.invoke }};
    for ([_]bool{ false, true }) |input| {
        var fixture: f.Fixture = undefined;
        try fixture.init(.{ .call_bytes = 512, .pending_bytes = 512 });
        defer fixture.deinit();
        fixture.attached.behaviors = &behaviors;
        var answer: f.Capture = .{};
        try fixture.send("greedy", if (input) &.{.{ .bytes = &@as([1024]u8, @splat(1)) }} else &.{}, &answer);
        try fixture.drain();
        try std.testing.expect(answer.broken);
        try std.testing.expectEqual(@as(u64, if (input) 0 else 1), fixture.attached.stats.invocations);
        try std.testing.expectEqual(@as(u64, 1), fixture.data.store.metadata.revision);
        try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
        for (fixture.attached.operations) |op| try std.testing.expect(op.phase == .free);
        var retry: f.Capture = .{};
        try fixture.send("get", &.{}, &retry);
        try fixture.drain();
        try std.testing.expectEqual(@as(?i64, 0), retry.value);
    }
}

test "loam actor cold object growth does not create endpoints or cache allocations" {
    const records = @import("../core/fixture.zig");
    var fixture: f.Fixture = undefined;
    try fixture.init(.{ .max_endpoints = 2 });
    defer fixture.deinit();
    try fixture.attached.sleep(fixture.root);
    for (0..128) |_| {
        try fixture.data.store.begin();
        for (0..8) |_| {
            var record = records.record(try fixture.data.store.allocateId(), &@as([8]u8, @splat(0)));
            record.rooted = true;
            try fixture.data.store.putCopying(record, null);
        }
        try records.commit(&fixture.data.store, &fixture.data.backend);
    }
    try std.testing.expectEqual(@as(u64, 1025), fixture.data.store.metadata.objects);
    try std.testing.expectEqual(@as(usize, 0), fixture.data.store.cache.allocated_bytes);
    var endpoints: usize = 0;
    for (fixture.attached.entries) |entry| if (entry.actor != null) {
        endpoints += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), endpoints);
    var answer: f.Capture = .{};
    try fixture.send("get", &.{}, &answer);
    try fixture.drain();
    try std.testing.expectEqual(@as(?i64, 0), answer.value);
    try std.testing.expectEqual(@as(u64, 1), fixture.attached.stats.loads);
}

test "loam actor attachment creation unwinds each allocation refusal" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, createAndRelease, .{});
}

test "loam actor held capability retains a sleeping unrooted record through collection" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    var held = true;
    defer {
        if (held) fixture.host.releaseCapability(fixture.root, 1) catch unreachable;
        fixture.attached.destroy() catch unreachable;
        fixture.host.deinit();
        fixture.data.deinit();
    }
    const store = &fixture.data.store;
    const records = @import("../core/fixture.zig");
    const lease = try records.load(store, &fixture.data.backend, fixture.id);
    const portrait = try store.view(lease);
    try store.begin();
    var r = records.record(fixture.id, portrait.payload);
    r.rooted = false;
    try store.putCopying(r, portrait.revision);
    try store.release(lease);
    try records.commit(store, &fixture.data.backend);
    try fixture.attached.sleep(fixture.root);
    try records.collect(store, &fixture.data.backend);
    try std.testing.expectEqual(@as(u64, 1), store.metadata.objects);
    try std.testing.expectEqual(@as(u64, 0), fixture.attached.stats.loads);
    var capture: f.Capture = .{};
    try fixture.send("get", &.{}, &capture);
    try fixture.drain();
    try std.testing.expectEqual(@as(?i64, 0), capture.value);
    try fixture.host.releaseCapability(fixture.root, 1);
    held = false;
    // Idle owner progress reclaims released endpoint state without a new call.
    try fixture.attached.advance();
    try records.collect(store, &fixture.data.backend);
    try std.testing.expectEqual(@as(u64, 0), store.metadata.objects);
}

fn createAndRelease(allocator: std.mem.Allocator) !void {
    var fixture: f.Fixture = undefined;
    try fixture.initAllocator(allocator, .{});
    fixture.deinit();
}

test "loam idle progress reclaims the sole endpoint slot after final release" {
    const records = @import("../core/fixture.zig");
    var fixture: f.Fixture = undefined;
    try fixture.init(.{ .max_endpoints = 1 });
    defer fixture.deinit();
    try fixture.data.store.begin();
    const next = try fixture.data.store.allocateId();
    var record = records.record(next, &@as([8]u8, @splat(0)));
    record.rooted = true;
    try fixture.data.store.putCopying(record, null);
    try records.commit(&fixture.data.store, &fixture.data.backend);
    const lease = try records.load(&fixture.data.store, &fixture.data.backend, next);
    defer fixture.data.store.release(lease) catch unreachable;

    try fixture.host.releaseCapability(fixture.root, 1);
    try std.testing.expect(fixture.host.vat.hasRetiredState());
    try std.testing.expect(try fixture.attached.advanceProgress());
    try std.testing.expect(!try fixture.attached.advanceProgress());
    fixture.root = try fixture.attached.restore(lease);
    try std.testing.expectEqual(next, (try fixture.attached.capture(fixture.root)).target);
}
