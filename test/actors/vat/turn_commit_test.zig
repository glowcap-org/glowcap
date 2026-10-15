//! A turn's eventual sends take effect only when the outermost turn returns
//! successfully (ADR-0191): a failed turn drops its local and far sends and
//! their admission charges, an error an outer frame catches keeps the inner
//! frame's sends, and a served turn's far sends reach the wire before its reply.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const Turn = actors.Turn;
const Message = actors.Message;
const Delivery = actors.Delivery;
const promise_capture = @import("../../support/capture.zig");

const harness = @import("harness.zig");
const Counter = harness.Counter;

/// Tells `target` to increment, optionally watches that send's vow, then
/// fails or succeeds as the verb asks.
const SendThen = struct {
    target: actors.Ref,
    broke: ?*bool = null,

    pub fn handle(self: *SendThen, turn: *Turn, msg: Delivery) !model.Argument {
        const vow = try turn.send(self.target, .{ .verb = "increment" });
        if (self.broke) |flag| try turn.vat.on(vow, .{ .ctx = flag, .func = promise_capture.captureBroken });
        try turn.tell(self.target, .{ .verb = "increment" });
        if (std.mem.eql(u8, msg.verb, "fail")) return error.Refused;
        return .{ .void = {} };
    }
};

/// Near-calls `inner` with a failing verb and swallows the error.
const CatchInner = struct {
    inner: actors.Ref,

    pub fn handle(self: *CatchInner, turn: *Turn, msg: Delivery) !model.Argument {
        _ = msg;
        _ = turn.near(self.inner, .{ .verb = "fail" }) catch {};
        return .{ .void = {} };
    }
};

fn count(vat: *actors.Vat, counter: actors.Ref) !i64 {
    return (try vat.near(counter, .{ .verb = "get" })).integer;
}

test "a failed turn sends none of its local messages" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const counter = try vat.spawn(Counter, .{ .n = 0 });
    var broke = false;
    const sender = try vat.spawn(SendThen, .{ .target = counter, .broke = &broke });

    try std.testing.expectError(error.Refused, vat.near(sender, .{ .verb = "fail" }));
    try vat.drive();
    try std.testing.expectEqual(@as(i64, 0), try count(&vat, counter));
    // The dropped send's vow breaks, so a listener the turn registered on it
    // is not left waiting.
    try std.testing.expect(broke);
}

test "a successful turn sends its local messages when it returns" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const counter = try vat.spawn(Counter, .{ .n = 0 });
    const sender = try vat.spawn(SendThen, .{ .target = counter });

    _ = try vat.near(sender, .{ .verb = "ok" });
    try vat.drive();
    try std.testing.expectEqual(@as(i64, 2), try count(&vat, counter));
}

test "an error an outer frame catches keeps the inner frame's sends" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const counter = try vat.spawn(Counter, .{ .n = 0 });
    const inner = try vat.spawn(SendThen, .{ .target = counter });
    const outer = try vat.spawn(CatchInner, .{ .inner = inner });

    _ = try vat.near(outer, .{ .verb = "go" });
    try vat.drive();
    try std.testing.expectEqual(@as(i64, 2), try count(&vat, counter));
}

test "a failed turn releases the queue admission its sends took" {
    const allocator = std.testing.allocator;
    // Room for exactly the two sends one SendThen turn makes.
    var vat = actors.Vat.initWithOptions(allocator, .{ .queue_limits = .{ .max_pending_turns = 2 } });
    defer vat.deinit();

    const counter = try vat.spawn(Counter, .{ .n = 0 });
    const sender = try vat.spawn(SendThen, .{ .target = counter });

    try std.testing.expectError(error.Refused, vat.near(sender, .{ .verb = "fail" }));
    // Had the dropped sends kept their charge, this turn would be refused.
    _ = try vat.near(sender, .{ .verb = "ok" });
    try vat.drive();
    try std.testing.expectEqual(@as(i64, 2), try count(&vat, counter));
}

test "a queued turn that fails drops its sends too" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const counter = try vat.spawn(Counter, .{ .n = 0 });
    const sender = try vat.spawn(SendThen, .{ .target = counter });

    var broke = false;
    const vow = try vat.send(sender, .{ .verb = "fail" });
    try vat.on(vow, .{ .ctx = &broke, .func = promise_capture.captureBroken });
    try vat.drive();
    try std.testing.expect(broke);
    try std.testing.expectEqual(@as(i64, 0), try count(&vat, counter));
}

test "a failed turn detaches all effects before a broken send listener reenters" {
    const Effect = struct {
        commits: usize = 0,
        aborts: usize = 0,
        fn commit(ctx: *anyopaque, _: *actors.Vat) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.commits += 1;
        }
        fn abort(ctx: *anyopaque, _: *actors.Vat, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.aborts += 1;
        }
    };
    const Reenter = struct {
        vat: *actors.Vat,
        target: actors.Ref,
        failed: bool = false,
        fn listen(ctx: ?*anyopaque, _: actors.Resolution) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = self.vat.near(self.target, .{ .verb = "ok" }) catch {
                self.failed = true;
            };
        }
    };
    const Enroll = struct {
        effect: *Effect,
        listener: ?*Reenter = null,
        pub fn handle(self: *@This(), turn: *Turn, _: Delivery) !model.Argument {
            try turn.vat.enrollTurn(.{ .ctx = self.effect, .commit = Effect.commit, .abort = Effect.abort });
            if (self.listener) |listener| {
                const vow = try turn.send(listener.target, .{ .verb = "unused" });
                try turn.vat.on(vow, .{ .ctx = listener, .func = Reenter.listen });
                return error.Refused;
            }
            return .{ .void = {} };
        }
    };
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    var failed: Effect = .{};
    var successful: Effect = .{};
    const nested = try vat.spawn(Enroll, .{ .effect = &successful });
    var listener: Reenter = .{ .vat = &vat, .target = nested };
    const outer = try vat.spawn(Enroll, .{ .effect = &failed, .listener = &listener });
    try std.testing.expectError(error.Refused, vat.near(outer, .{ .verb = "fail" }));
    try std.testing.expect(!listener.failed);
    try std.testing.expectEqual(@as(usize, 0), failed.commits);
    try std.testing.expectEqual(@as(usize, 1), failed.aborts);
    try std.testing.expectEqual(@as(usize, 1), successful.commits);
    try std.testing.expectEqual(@as(usize, 0), successful.aborts);
    try vat.drive();
    try std.testing.expectEqual(@as(usize, 1), successful.commits);
}

test "turn failure notifications follow every participant's rollback" {
    const State = struct { aborted: usize = 0, notified: usize = 0, early: bool = false, order: u32 = 0 };
    const Effect = struct {
        state: *State,
        id: u8,
        fn commit(_: *anyopaque, _: *actors.Vat) void {}
        fn abort(ctx: *anyopaque, _: *actors.Vat, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.state.aborted += 1;
            self.state.order = self.state.order * 10 + self.id;
        }
        fn notify(ctx: *anyopaque, _: *actors.Vat, reason: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.state.early = self.state.early or self.state.aborted != 2 or !std.mem.eql(u8, reason, "Refused");
            self.state.notified += 1;
            self.state.order = self.state.order * 10 + self.id;
        }
    };
    const Enroll = struct {
        effects: *[2]Effect,
        pub fn handle(self: *@This(), turn: *Turn, _: Delivery) !model.Argument {
            for (self.effects) |*effect| try turn.vat.enrollTurn(.{ .ctx = effect, .commit = Effect.commit, .abort = Effect.abort, .abort_notify = Effect.notify });
            return error.Refused;
        }
    };
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    var state: State = .{};
    var effects = [_]Effect{ .{ .state = &state, .id = 1 }, .{ .state = &state, .id = 2 } };
    const actor = try vat.spawn(Enroll, .{ .effects = &effects });
    try std.testing.expectError(error.Refused, vat.near(actor, .{ .verb = "fail" }));
    try std.testing.expect(!state.early);
    try std.testing.expectEqual(@as(usize, 2), state.notified);
    try std.testing.expectEqual(@as(u32, 2121), state.order);
}

test "reply preservation failure retracts the turn before committing sends" {
    const Sender = struct {
        target: actors.Ref,
        failing: *std.testing.FailingAllocator,
        refuse_copy: bool,
        send_broken: *bool,
        bytes: [8192]u8 = @splat('x'),

        pub fn handle(self: *@This(), turn: *Turn, msg: Delivery) !model.Argument {
            if (std.mem.eql(u8, msg.verb, "get")) return .{ .integer = 7 };
            const vow = try turn.send(self.target, .{ .verb = "increment" });
            try turn.vat.on(vow, .{ .ctx = self.send_broken, .func = promise_capture.captureBroken });
            try turn.tell(self.target, .{ .verb = "increment" });
            try turn.become(Counter, .{ .n = 99 });
            if (self.refuse_copy) {
                self.failing.fail_index = self.failing.alloc_index;
                self.failing.resize_fail_index = self.failing.resize_index;
            }
            return .{ .bytes = &self.bytes };
        }
    };
    const Reply = struct {
        settled: usize = 0,
        out_of_memory: bool = false,
        length: usize = 0,
        fn receive(ctx: ?*anyopaque, resolution: actors.Resolution) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.settled += 1;
            switch (resolution) {
                .broken => |reason| self.out_of_memory = std.mem.eql(u8, reason, "OutOfMemory"),
                .fulfilled => |value| self.length = value.bytes.len,
                .give => unreachable,
            }
        }
    };
    for ([_]bool{ false, true }) |queued| for ([_]bool{ false, true }) |refuse_copy| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var vat = actors.Vat.init(failing.allocator());
        defer vat.deinit();
        var send_broken = false;
        const counter = try vat.spawn(Counter, .{ .n = 0 });
        const sender = try vat.spawn(Sender, .{ .target = counter, .failing = &failing, .refuse_copy = refuse_copy, .send_broken = &send_broken });
        var reply: Reply = .{};
        if (queued) {
            _ = try vat.sendObservedFromIngress(.local, sender, .{ .verb = "change" }, .{ .ctx = &reply, .func = Reply.receive });
            // The same refusal also prevents copying the queued failure reason.
            if (refuse_copy) try std.testing.expectError(error.OutOfMemory, vat.drive()) else try vat.drive();
        } else {
            const result = vat.near(sender, .{ .verb = "change" });
            if (refuse_copy) try std.testing.expectError(error.OutOfMemory, result) else try std.testing.expectEqual(@as(usize, 8192), (try result).bytes.len);
        }
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        try std.testing.expectEqual(refuse_copy, send_broken);
        try vat.drive();
        try std.testing.expectEqual(@as(i64, if (refuse_copy) 0 else 2), try count(&vat, counter));
        try std.testing.expectEqual(@as(i64, if (refuse_copy) 7 else 99), try count(&vat, sender));
        if (queued) {
            try std.testing.expectEqual(@as(usize, 1), reply.settled);
            try std.testing.expectEqual(refuse_copy, reply.out_of_memory);
            if (!refuse_copy) try std.testing.expectEqual(@as(usize, 8192), reply.length);
        }
        try std.testing.expectEqual(@as(usize, 0), vat.pending_local_vows.count());
    };
}

test "become promotion publishes replacement before destructor reentry" {
    const Cleanup = struct {
        const Mode = enum { send, grow, reenter };
        vat: *actors.Vat,
        target: actors.Ref,
        drops: *usize,
        mode: Mode,
        subject: ?actors.Ref = null,
        pub fn handle(_: *@This(), _: *Turn, _: Delivery) !model.Argument {
            return error.DiscardedStateRan;
        }
        pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
            self.drops.* += 1;
            if (self.mode == .grow) {
                const capacity = self.vat.actors.capacity();
                while (self.vat.actors.capacity() == capacity)
                    _ = self.vat.spawn(Counter, .{ .n = 0 }) catch unreachable;
            }
            if (self.mode == .reenter)
                _ = self.vat.near(self.subject.?, .{ .verb = "cleanup" }) catch unreachable;
            self.vat.tell(self.target, .{ .verb = "increment" }) catch unreachable;
        }
    };
    const Replace = struct {
        cleanup: Cleanup,
        pub fn handle(self: *@This(), turn: *Turn, msg: Delivery) !model.Argument {
            if (std.mem.eql(u8, msg.verb, "inner")) {
                var cleanup = self.cleanup;
                cleanup.subject = turn.me();
                try turn.become(Cleanup, cleanup);
                return .{ .void = {} };
            }
            if (std.mem.eql(u8, msg.verb, "cleanup")) {
                try turn.become(Counter, .{ .n = 123 });
                return .{ .void = {} };
            }
            try turn.become(Counter, .{ .n = 99 });
            _ = try turn.near(turn.me(), .{ .verb = "inner" });
            return .{ .integer = 7 };
        }
    };
    for ([_]?model.CaptpVersion{ null, .v1_0, .next }) |profile| for (std.enums.values(Cleanup.Mode)) |mode| {
        var vat = actors.Vat.init(std.testing.allocator);
        defer vat.deinit();
        var drops: usize = 0;
        const target = try vat.spawn(Counter, .{ .n = 0 });
        const actor = try vat.spawn(Replace, .{ .cleanup = .{ .vat = &vat, .target = target, .drops = &drops, .mode = mode } });
        if (profile) |wire_profile| {
            const engine = glowcap.ocapn.engine;
            const cross_peer = @import("../../support/cross_peer.zig");
            var pair = switch (wire_profile) {
                .v1_0 => try engine.pairing.pairedV1_0Syrup(std.testing.allocator),
                .next => try engine.pairing.paired(std.testing.allocator),
            };
            defer pair.deinit();
            var port = actors.Port.init(std.testing.allocator, &pair.p2);
            defer port.deinit(&vat);
            try port.bindExport(&vat, actor, 7);
            try pair.p2.exportObject(7);
            try pair.p1.importObject(7);
            var client = actors.Vat.init(std.testing.allocator);
            defer client.deinit();
            var client_port = actors.Port.init(std.testing.allocator, &pair.p1);
            defer client_port.deinit(&client);
            var reply: i64 = 0;
            const vow = try client_port.send(&client, .{ .far = model.FarRef.object(7) }, .{ .verb = "outer" });
            try client_port.on(&client, vow, .{ .ctx = &reply, .func = promise_capture.captureInt });
            try cross_peer.pumpAll(&pair.p1, &pair.p2);
            while (pair.p2.pollEvent()) |incoming| {
                var event = incoming;
                defer event.deinit();
                _ = try port.serve(&vat, &event);
            }
            try cross_peer.pumpAll(&pair.p2, &pair.p1);
            while (pair.p1.pollEvent()) |incoming| {
                var event = incoming;
                defer event.deinit();
                _ = try client_port.serve(&client, &event);
            }
            try std.testing.expectEqual(@as(i64, 7), reply);
        } else try std.testing.expectEqual(@as(i64, 7), (try vat.near(actor, .{ .verb = "outer" })).integer);
        try vat.drive();
        try std.testing.expectEqual(@as(usize, 1), drops);
        try std.testing.expectEqual(@as(i64, 1), try count(&vat, target));
        try std.testing.expectEqual(@as(i64, if (mode == .reenter) 123 else 99), try count(&vat, actor));
    };
}
