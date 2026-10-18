//! Local adapter payloads use the Vat's queue and transactional turn boundary.
const std = @import("std");
const glowcap = @import("glowcap");
const actors = glowcap.actors;
const model = glowcap.ocapn.model;

const Trace = struct {
    copies: usize = 0,
    retired: usize = 0,
    calls: usize = 0,
    settlements: usize = 0,
    broken: bool = false,
    reason: [32]u8 = undefined,
    reason_len: usize = 0,
    retirement_reason: [32]u8 = undefined,
    retirement_reason_len: usize = 0,
    order: [8]u8 = undefined,
    len: usize = 0,

    fn settle(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *Trace = @ptrCast(@alignCast(ctx.?));
        self.settlements += 1;
        self.broken = resolution == .broken;
        if (resolution == .broken) {
            self.reason_len = @min(self.reason.len, resolution.broken.len);
            @memcpy(self.reason[0..self.reason_len], resolution.broken[0..self.reason_len]);
        }
        // The queue releases external payload custody before the observer runs.
        std.debug.assert(self.retired == self.copies);
    }

    fn listener(self: *Trace) actors.Listener {
        return .{ .ctx = self, .func = settle };
    }
};

const Input = struct {
    trace: *Trace,
    bytes: []const u8,
    nested: bool = false,
    fail: bool = false,
    dynamic_break: bool = false,
    copy_turn: ?struct { vat: *actors.Vat, target: actors.Ref, ingress: actors.IngressId } = null,
    teardown_probe: ?struct { vat: *actors.Vat, target: actors.Ref } = null,
    copy_vow: ?actors.Vow = null,
    retire_turn: ?struct { vat: *actors.Vat, target: actors.Ref } = null,

    const vtable: actors.OpaqueMessage.VTable = .{ .copy = copy, .retire = retire };

    fn message(self: *Input) actors.OpaqueMessage {
        return .{ .ctx = self, .vtable = &vtable, .owned_bytes = @sizeOf(Input) + self.bytes.len };
    }

    fn copy(ctx: *anyopaque, allocator: std.mem.Allocator) actors.OpaqueMessage.CopyResult {
        return .{ .copied = copyOwned(ctx, allocator) catch return .{ .refused = .out_of_memory } };
    }

    fn copyOwned(ctx: *anyopaque, allocator: std.mem.Allocator) actors.Error!actors.OpaqueMessage {
        const self: *Input = @ptrCast(@alignCast(ctx));
        if (self.copy_turn) |attempt| {
            std.testing.expectError(error.ReenteredAdmission, attempt.vat.near(attempt.target, .{ .verb = "scribble" })) catch unreachable;
            std.testing.expectError(error.ReenteredAdmission, attempt.vat.tell(attempt.target, .{ .verb = "scribble" })) catch unreachable;
            std.testing.expectError(error.ReenteredAdmission, attempt.vat.drive()) catch unreachable;
            std.testing.expectError(error.ReenteredAdmission, attempt.vat.closeIngress(attempt.ingress)) catch unreachable;
            std.testing.expectError(error.ReenteredAdmission, attempt.vat.cancelIngress(attempt.ingress, "copy")) catch unreachable;
        }
        if (self.copy_turn) |attempt| {
            std.testing.expectError(error.ReenteredAdmission, attempt.vat.spawnVow()) catch unreachable;
            if (self.copy_vow) |vow|
                std.testing.expectError(error.ReenteredAdmission, attempt.vat.on(vow, self.trace.listener())) catch unreachable;
        }
        const owned = try allocator.create(Input);
        const bytes = try allocator.dupe(u8, self.bytes);
        owned.* = self.*;
        owned.bytes = bytes;
        self.trace.copies += 1;
        return owned.message();
    }

    fn retire(ctx: *anyopaque, reason: ?[]const u8) void {
        const self: *Input = @ptrCast(@alignCast(ctx));
        self.trace.retired += 1;
        if (reason) |text| {
            self.trace.retirement_reason_len = @min(text.len, self.trace.retirement_reason.len);
            @memcpy(self.trace.retirement_reason[0..self.trace.retirement_reason_len], text[0..self.trace.retirement_reason_len]);
        }
        if (self.teardown_probe) |probe| {
            std.testing.expectError(error.VatReleased, probe.vat.near(probe.target, .{ .verb = "scribble" })) catch unreachable;
            std.testing.expectError(error.VatReleased, probe.vat.drive()) catch unreachable;
            std.testing.expectError(error.VatReleased, probe.vat.spawnVow()) catch unreachable;
        }
        if (self.retire_turn) |next| {
            _ = next.vat.near(next.target, .{ .verb = "scribble" }) catch unreachable;
            std.debug.assert(std.mem.eql(u8, reason.?, "diagnostic"));
        }
    }
};

const Receiver = struct {
    trace: *Trace,

    pub fn handle(self: *Receiver, _: *actors.Turn, msg: actors.Delivery) !model.Argument {
        self.trace.order[self.trace.len] = @intCast(try msg.argInt(0));
        self.trace.len += 1;
        return .{ .void = {} };
    }

    pub fn handleOpaque(self: *Receiver, turn: *actors.Turn, msg: actors.OpaqueMessage) !void {
        try std.testing.expect(msg.vtable == &Input.vtable);
        try std.testing.expect(turn.opaque_message.?.ctx == msg.ctx);
        try std.testing.expect(turn.origin == .eventual);
        const input: *Input = @ptrCast(@alignCast(msg.ctx));
        self.trace.calls += 1;
        try std.testing.expectEqualStrings("held", input.bytes);
        self.trace.order[self.trace.len] = 2;
        self.trace.len += 1;
        if (input.nested) {
            try turn.vat.drive();
            // A nested drive exhausted the chunk, but this active row still
            // owns the borrowed payload until the original handler returns.
            try std.testing.expectEqual(@as(usize, 0), self.trace.retired);
            try std.testing.expectEqualStrings("held", input.bytes);
        }
        if (input.dynamic_break) {
            const reason = try turn.arena.dupe(u8, "diagnostic");
            try turn.breakWith(reason);
        }
        if (input.fail) return error.Refused;
    }
};

const Stager = struct {
    target: actors.Ref,
    input: *Input,

    pub fn handle(self: *Stager, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        _ = try turn.vat.sendOpaqueFromIngress(turn.ingress(), self.target, self.input.message(), self.input.trace.listener());
        try turn.vat.drive();
        try std.testing.expectEqual(@as(usize, 0), self.input.trace.calls);
        if (std.mem.eql(u8, msg.verb, "fail")) return error.Refused;
        return .{ .void = {} };
    }
};

const Plain = struct {
    pub fn handle(_: *Plain, _: *actors.Turn, _: actors.Delivery) !model.Argument {
        return error.MustNotRun;
    }
};

test "an answerless forwarded turn preserves refusal for payload retirement" {
    const Forwarder = struct {
        target: actors.Ref,
        fail: bool,

        pub fn handle(_: *@This(), _: *actors.Turn, _: actors.Delivery) !model.Argument {
            return error.MustNotRun;
        }

        pub fn handleOpaque(self: *@This(), turn: *actors.Turn, _: actors.OpaqueMessage) !void {
            _ = try turn.forward(self.target, .{ .verb = "record", .args = .fromOwnedSlice(&.{.{ .integer = 7 }}) });
            if (self.fail) return error.Refused;
        }
    };
    for ([_]bool{ false, true }) |fail| {
        var vat = actors.Vat.init(std.testing.allocator);
        defer vat.deinit();
        var trace: Trace = .{};
        var input: Input = .{ .trace = &trace, .bytes = "held" };
        const target = try vat.spawn(Receiver, .{ .trace = &trace });
        const actor = try vat.spawn(Forwarder, .{ .target = target, .fail = fail });
        try vat.tellOpaqueFromIngress(.local, actor, input.message());
        try vat.drive();
        try std.testing.expectEqual(@as(usize, if (fail) 0 else 1), trace.len);
        try std.testing.expectEqual(@as(usize, 1), trace.copies);
        try std.testing.expectEqual(@as(usize, 1), trace.retired);
        try std.testing.expectEqualStrings(if (fail) "Refused" else "", trace.retirement_reason[0..trace.retirement_reason_len]);
        try std.testing.expectEqual(@as(usize, 0), vat.pending_local_vows.count());
    }
}

test "vat opaque input shares FIFO and survives a nested drive of its chunk" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    var trace: Trace = .{};
    var bytes = [_]u8{ 'h', 'e', 'l', 'd' };
    var input: Input = .{ .trace = &trace, .bytes = &bytes, .nested = true };
    const target = try vat.spawn(Receiver, .{ .trace = &trace });
    try vat.tell(target, .{ .verb = "record", .args = &.{.{ .integer = 1 }} });
    _ = try vat.sendOpaqueFromIngress(.local, target, input.message(), trace.listener());
    @memset(&bytes, 'x');
    try vat.tell(target, .{ .verb = "record", .args = &.{.{ .integer = 3 }} });
    try vat.drive();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, trace.order[0..trace.len]);
    try std.testing.expectEqual(@as(usize, 1), trace.retired);
    try std.testing.expectEqual(@as(usize, 1), trace.settlements);
    try std.testing.expect(!trace.broken);
}

test "vat opaque input staged by a failed outer turn retires without invocation" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    var trace: Trace = .{};
    var input: Input = .{ .trace = &trace, .bytes = "held" };
    const target = try vat.spawn(Receiver, .{ .trace = &trace });
    const stager = try vat.spawn(Stager, .{ .target = target, .input = &input });
    try std.testing.expectError(error.Refused, vat.near(stager, .{ .verb = "fail" }));
    try std.testing.expectEqual(@as(usize, 1), trace.retired);
    try std.testing.expectEqual(@as(usize, 1), trace.settlements);
    try std.testing.expect(trace.broken);
    try vat.drive();
    try std.testing.expectEqual(@as(usize, 0), trace.calls);
    trace = .{};
    _ = try vat.near(stager, .{ .verb = "ok" });
    try vat.drive();
    try std.testing.expectEqual(@as(usize, 1), trace.calls);
    try std.testing.expectEqual(@as(usize, 1), trace.retired);
}

test "vat opaque input retires on handler refusal and plain actors refuse it" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    var trace: Trace = .{};
    var input: Input = .{ .trace = &trace, .bytes = "held", .fail = true };
    const target = try vat.spawn(Receiver, .{ .trace = &trace });
    _ = try vat.sendOpaqueFromIngress(.local, target, input.message(), trace.listener());
    try vat.drive();
    try std.testing.expect(trace.broken);
    try std.testing.expectEqual(@as(usize, 1), trace.retired);
    trace = .{};
    const plain = try vat.spawn(Plain, .{});
    _ = try vat.sendOpaqueFromIngress(.local, plain, input.message(), trace.listener());
    try vat.drive();
    try std.testing.expect(trace.broken);
    try std.testing.expectEqual(@as(usize, 0), trace.calls);
    try std.testing.expectEqual(@as(usize, 1), trace.retired);
}

test "vat opaque admission refuses before copying and ingress cancellation retires" {
    var vat = actors.Vat.initWithOptions(std.testing.allocator, .{ .queue_limits = .{ .max_pending_turns = 1 } });
    defer vat.deinit();
    var trace: Trace = .{};
    var input: Input = .{ .trace = &trace, .bytes = "held" };
    const target = try vat.spawn(Receiver, .{ .trace = &trace });
    const ingress = try vat.openIngress();
    _ = try vat.sendOpaqueFromIngress(ingress, target, input.message(), trace.listener());
    try std.testing.expectError(error.ResourceExhausted, vat.sendOpaqueFromIngress(ingress, target, input.message(), trace.listener()));
    try std.testing.expectEqual(@as(usize, 1), trace.copies);
    try vat.cancelIngress(ingress, "closed");
    try std.testing.expectEqual(@as(usize, 1), trace.retired);
    try std.testing.expect(trace.broken);
    try std.testing.expectEqual(@as(usize, 0), trace.calls);
}

test "vat opaque payload retirement during teardown is independent of an observer" {
    var trace: Trace = .{};
    var input: Input = .{ .trace = &trace, .bytes = "held" };
    var vat = actors.Vat.init(std.testing.allocator);
    const target = try vat.spawn(Receiver, .{ .trace = &trace });
    input.teardown_probe = .{ .vat = &vat, .target = target };
    _ = try vat.sendOpaqueFromIngress(.local, target, input.message(), trace.listener());
    vat.deinit();
    try std.testing.expectEqual(@as(usize, 1), trace.retired);
    try std.testing.expectEqual(@as(usize, 0), trace.calls);
    try std.testing.expectEqual(@as(usize, 0), trace.settlements);
}

const Scribbler = struct {
    pub fn handle(_: *Scribbler, turn: *actors.Turn, _: actors.Delivery) !model.Argument {
        const bytes = try turn.arena.alloc(u8, 4096);
        @memset(bytes, 'x');
        return .{ .void = {} };
    }
};

test "vat opaque retirement reentry preserves a dynamic break diagnostic" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    var trace: Trace = .{};
    const scribbler = try vat.spawn(Scribbler, .{});
    var input: Input = .{ .trace = &trace, .bytes = "held", .dynamic_break = true, .retire_turn = .{ .vat = &vat, .target = scribbler } };
    const target = try vat.spawn(Receiver, .{ .trace = &trace });
    _ = try vat.sendOpaqueFromIngress(.local, target, input.message(), trace.listener());
    try vat.drive();
    try std.testing.expectEqualStrings("diagnostic", trace.reason[0..trace.reason_len]);
    try std.testing.expectEqual(@as(usize, 1), trace.retired);
}

fn allocationRefusal(allocator: std.mem.Allocator) !void {
    var trace: Trace = .{};
    var vat = actors.Vat.init(allocator);
    defer {
        vat.deinit();
        std.debug.assert(trace.copies == trace.retired);
    }
    var input: Input = .{ .trace = &trace, .bytes = "held" };
    const target = try vat.spawn(Receiver, .{ .trace = &trace });
    _ = try vat.sendOpaqueFromIngress(.local, target, input.message(), trace.listener());
    try vat.drive();
    try std.testing.expectEqual(@as(usize, 1), trace.calls);
}

test "vat opaque allocation refusal never strands external payload custody" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationRefusal, .{});
}

test "vat opaque observer cancellation leaves queued input and the admitted effect alive" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    var trace: Trace = .{};
    var input: Input = .{ .trace = &trace, .bytes = "held" };
    const target = try vat.spawn(Receiver, .{ .trace = &trace });
    const vow = try vat.sendOpaqueFromIngress(.local, target, input.message(), trace.listener());
    const listener = vat.takeListener(vow).?;
    try std.testing.expect(listener.ctx == @as(?*anyopaque, &trace));
    try vat.drive();
    try std.testing.expectEqual(@as(usize, 1), trace.calls);
    try std.testing.expectEqual(@as(usize, 1), trace.retired);
    try std.testing.expectEqual(@as(usize, 0), trace.settlements);
}

test "vat opaque copying cannot invalidate unpublished queue admission by reentry" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    var trace: Trace = .{};
    const target = try vat.spawn(Receiver, .{ .trace = &trace });
    const ingress = try vat.openIngress();
    defer vat.closeIngress(ingress) catch unreachable;
    var input: Input = .{ .trace = &trace, .bytes = "held", .copy_turn = .{ .vat = &vat, .target = target, .ingress = ingress } };
    const pair = try vat.spawnVow();
    input.copy_vow = pair.vow;
    _ = try vat.sendOpaqueFromIngress(ingress, target, input.message(), trace.listener());
    try vat.drive();
    try vat.breakVow(pair.resolver, "finished");
    try std.testing.expectEqual(@as(usize, 1), trace.calls);
    try std.testing.expectEqual(@as(usize, 1), trace.retired);
}

const CancelReentry = struct {
    vat: *actors.Vat,
    target: actors.Ref,
    settled: usize = 0,

    fn settle(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *CancelReentry = @ptrCast(@alignCast(ctx.?));
        std.debug.assert(resolution == .broken and std.mem.eql(u8, resolution.broken, "cancelled"));
        self.settled += 1;
        self.vat.tell(self.target, .{ .verb = "ordinary", .args = &.{.{ .integer = 7 }} }) catch unreachable;
        self.vat.drive() catch unreachable;
    }
};

test "vat opaque local cancellation detaches its custody before listener enqueue and nested drive" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    var trace: Trace = .{};
    const target = try vat.spawn(Receiver, .{ .trace = &trace });
    var callback: CancelReentry = .{ .vat = &vat, .target = target };
    var input: Input = .{ .trace = &trace, .bytes = "held" };
    for (0..2) |_| _ = try vat.sendOpaqueFromIngress(.local, target, input.message(), .{ .ctx = &callback, .func = CancelReentry.settle });
    try vat.cancelLocalIngress("cancelled");
    try std.testing.expectEqual(@as(usize, 2), callback.settled);
    try std.testing.expectEqual(@as(usize, 2), trace.retired);
    try std.testing.expectEqual(@as(usize, 0), trace.calls);
    try std.testing.expectEqualSlices(u8, &.{ 7, 7 }, trace.order[0..trace.len]);
    try std.testing.expectEqual(@as(usize, 0), vat.pending_local_vows.count());
    try std.testing.expectEqual(@as(usize, 0), vat.listeners.count());
    try std.testing.expectEqual(@as(u32, 0), vat.local_ingress.pending_turns);
    try std.testing.expectEqual(@as(u32, 0), vat.local_ingress.pending_bytes);
}
