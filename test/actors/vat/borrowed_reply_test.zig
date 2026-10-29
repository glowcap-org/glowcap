//! Borrowed handler replies survive replacement, interception and answer retention.
const std = @import("std");
const glowcap = @import("glowcap");
const actors = glowcap.actors;
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const fixture = @import("../../support/peer_fixture.zig");
const poison = @import("../../support/poison.zig");

const Replacement = struct {
    pub fn handle(_: *@This(), _: *actors.Turn, _: actors.Delivery) !model.Argument {
        return .{ .string = "replacement" };
    }
};

const Borrowed = struct {
    label: [8]u8 = "old-name".*,
    freed: *bool,
    source: *?[*]const u8,

    pub fn handle(self: *@This(), turn: *actors.Turn, msg: actors.Delivery) !actors.HostedActor.Result {
        self.source.* = &self.label;
        const entries = try turn.arena.alloc(model.view.StructEntry, 1);
        entries[0] = .{ .key = "label", .value = .{ .bytes = &self.label } };
        try turn.become(Replacement, .{});
        if (msg.is("fail")) return error.Refused;
        return .{ .viewed = .{ .@"struct" = .fromViews(entries) } };
    }

    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        self.freed.* = true;
        @memset(&self.label, 0xdd);
    }
};

fn expectReply(value: model.Argument) !void {
    try std.testing.expectEqualStrings("label", value.@"struct"[0].key);
    try std.testing.expectEqualStrings("old-name", value.@"struct"[0].value.bytes);
}

fn exerciseNear(backing: std.mem.Allocator) !void {
    var wrapper: poison.PoisonOnFree = .{ .inner = backing };
    var vat = actors.Vat.init(wrapper.allocator());
    defer vat.deinit();
    var freed = false;
    var source: ?[*]const u8 = null;
    const actor = try vat.spawn(Borrowed, .{ .freed = &freed, .source = &source });
    const result = try vat.near(actor, .{ .verb = "reply" });
    try expectReply(result);
    try std.testing.expect(result.@"struct"[0].value.bytes.ptr != source.?);
    _ = try vat.near(actor, .{ .verb = "reset-turn" });
    try std.testing.expect(freed);
}

test "borrowed reply: near materialization survives actor replacement" {
    try exerciseNear(std.testing.allocator);
}

test "borrowed reply: near materialization failure releases every owner" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseNear, .{});
}

test "borrowed reply: failed handler discards replacement" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    var freed = false;
    var source: ?[*]const u8 = null;
    const actor = try vat.spawn(Borrowed, .{ .freed = &freed, .source = &source });
    try std.testing.expectError(error.Refused, vat.near(actor, .{ .verb = "fail" }));
    try std.testing.expect(!freed);
    try expectReply(try vat.near(actor, .{ .verb = "reply" }));
}

const Reenter = struct {
    vat: *actors.Vat,
    actor: actors.Ref,
    calls: usize = 0,

    fn intercept(ctx: ?*anyopaque, _: engine.AnswerTarget, value: model.view.Argument) anyerror!actors.InterceptOutcome {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        _ = try self.vat.near(self.actor, .{ .verb = "nested" });
        const entry = try value.@"struct".at(0);
        try std.testing.expectEqualStrings("old-name", entry.value.bytes);
        self.calls += 1;
        return .{ .resolve = value };
    }
};

fn exerciseServed(backing: std.mem.Allocator) !void {
    var wrapper: poison.PoisonOnFree = .{ .inner = backing };
    const allocator = wrapper.allocator();
    var peer = fixture.openPeer(allocator);
    defer peer.deinit();
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var port = actors.Port.init(allocator, &peer);
    defer port.deinit(&vat);
    var freed = false;
    var source: ?[*]const u8 = null;
    const actor = try vat.spawn(Borrowed, .{ .freed = &freed, .source = &source });
    try port.bindExport(&vat, actor, 7);
    try peer.exportObject(7);
    var hook = Reenter{ .vat = &vat, .actor = try vat.spawn(Replacement, .{}) };
    port.setResolveInterceptor(.{ .ctx = &hook, .func = Reenter.intercept });
    try peer.recvBorrowed(.{ .bytes = "<10'op:deliver<11'desc:export7+>[5'reply]1+<18'desc:import-object0+>1+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expect(try port.serve(&vat, &event));
    }
    try std.testing.expectEqual(@as(usize, 1), hook.calls);
    _ = try vat.near(hook.actor, .{ .verb = "reset-turn" });
    try std.testing.expect(freed);
    const retained = peer.session_state.peekResolutionNamed(.fromWire(.from(1))).?;
    try expectReply(retained.fulfill);
    const bytes = try fixture.drainOutbound(&peer, allocator);
    defer allocator.free(bytes);
    try expectReply(peer.session_state.peekResolutionNamed(.fromWire(.from(1))).?.fulfill);
}

test "borrowed reply: interception reentry and frame retirement leave an owned answer" {
    try exerciseServed(std.testing.allocator);
}

test "borrowed reply: allocation failures release every owner" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseServed, .{});
}

test "borrowed reply: adapter preserves an infallible persistent model handler" {
    const Plain = struct {
        pub const snapshot_persistent = true;
        pub fn handle(_: *const @This(), _: *actors.Turn, _: actors.Delivery) model.Argument {
            return .{ .integer = 7 };
        }
    };
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    const actor = try vat.spawn(Plain, .{});
    try std.testing.expectEqual(@as(i64, 7), (try vat.near(actor, .{ .verb = "get" })).integer);
}

const Malformed = struct {
    const Args = model.view.Args;
    const table: Args.VTable = .{ .len = len, .at = at, .next = next, .tail = tail };
    fn len(_: Args.Ctx) model.view.ProjectError!usize {
        return error.MalformedView;
    }
    fn at(_: Args.Ctx, _: usize) model.view.ProjectError!Args.Elem {
        return error.MalformedView;
    }
    fn next(_: Args.Ctx, _: *u64, _: *Args.Elem) model.view.ProjectError!bool {
        return error.MalformedView;
    }
    fn tail(_: Args.Ctx, _: usize) model.view.ProjectError!Args.Ctx {
        return error.MalformedView;
    }
};

test "borrowed reply: forwarding ignores an unused malformed result" {
    const Counter = struct {
        count: *i64,
        pub fn handle(self: *@This(), _: *actors.Turn, _: actors.Delivery) model.Argument {
            self.count.* += 1;
            return .{ .integer = self.count.* };
        }
    };
    const Forward = struct {
        target: actors.Ref,
        pub fn handle(self: *@This(), turn: *actors.Turn, msg: actors.Delivery) !actors.HostedActor.Result {
            if (msg.is("tell")) {
                try turn.tell(self.target, .{ .verb = "increment" });
                turn.forwardNoAnswer();
            } else {
                try turn.forwardVow(try turn.send(self.target, .{ .verb = "increment" }));
            }
            return .{ .viewed = .{ .list = .fromBacking(.{}, &Malformed.table) } };
        }
    };
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    var count: i64 = 0;
    const counter = try vat.spawn(Counter, .{ .count = &count });
    const forwarder = try vat.spawn(Forward, .{ .target = counter });
    try vat.tell(forwarder, .{ .verb = "tell" });
    try vat.drive();
    try std.testing.expectEqual(@as(i64, 1), count);
    const answer = try vat.send(forwarder, .{ .verb = "send" });
    var result: i64 = 0;
    try vat.on(answer, .{ .ctx = &result, .func = @import("../../support/capture.zig").captureInt });
    try vat.drive();
    try std.testing.expectEqual(@as(i64, 2), count);
    try std.testing.expectEqual(count, result);
}

test "borrowed reply: frame-backed echo survives input retirement" {
    const Echo = struct {
        source: *?[*]const u8,
        pub fn handle(self: *@This(), _: *actors.Turn, msg: actors.Delivery) !actors.HostedActor.Result {
            const value = try msg.arg(0);
            self.source.* = (try value.list.at(0)).string.ptr;
            return .{ .viewed = value };
        }
    };
    var wrapper: poison.PoisonOnFree = .{ .inner = std.testing.allocator };
    const allocator = wrapper.allocator();
    var peer = fixture.openPeer(allocator);
    defer peer.deinit();
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var port = actors.Port.init(allocator, &peer);
    defer port.deinit(&vat);
    var source: ?[*]const u8 = null;
    const actor = try vat.spawn(Echo, .{ .source = &source });
    try port.bindExport(&vat, actor, 7);
    try peer.exportObject(7);
    try peer.recvBorrowed(.{ .bytes = "<10'op:deliver<11'desc:export7+>[4'echo[8\"borrowed]]1+<18'desc:import-object0+>1+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expect(try port.serve(&vat, &event));
    }
    const other = try vat.spawn(Replacement, .{});
    _ = try vat.near(other, .{ .verb = "reset-turn" });
    const retained = peer.session_state.peekResolutionNamed(.fromWire(.from(1))).?.fulfill;
    try std.testing.expect(retained.list[0].string.ptr != source.?);
    try std.testing.expectEqualStrings("borrowed", retained.list[0].string);
    const bytes = try fixture.drainOutbound(&peer, allocator);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("borrowed", retained.list[0].string);
}

const ResourceProbe = struct {
    released: *usize,
    nested: ?actors.Ref = null,

    const Lease = struct {
        released: *usize,
        fn release(self: *@This()) void {
            self.released.* += 1;
        }
    };

    pub fn handle(self: *@This(), turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        if (msg.is("noop")) return .{ .void = {} };
        const before = self.released.*;
        _ = try turn.allocResource(Lease, .{ .released = self.released }, Lease.release);
        if (self.nested) |nested| _ = try turn.near(nested, .{ .verb = "lease" });
        try std.testing.expectEqual(before, self.released.*);
        if (msg.is("refuse")) return error.Refused;
        return .{ .void = {} };
    }
};

test "borrowed turn resources survive nested frames and release on reset, refusal and teardown" {
    var released: usize = 0;
    {
        var vat = actors.Vat.init(std.testing.allocator);
        defer vat.deinit();
        const child = try vat.spawn(ResourceProbe, .{ .released = &released });
        const parent = try vat.spawn(ResourceProbe, .{ .released = &released, .nested = child });
        _ = try vat.near(parent, .{ .verb = "lease" });
        try std.testing.expectEqual(@as(usize, 0), released);
        _ = try vat.near(child, .{ .verb = "noop" });
        try std.testing.expectEqual(@as(usize, 2), released);
        try std.testing.expectError(error.Refused, vat.near(child, .{ .verb = "refuse" }));
        _ = try vat.near(child, .{ .verb = "noop" });
        try std.testing.expectEqual(@as(usize, 3), released);
        _ = try vat.near(child, .{ .verb = "lease" });
    }
    try std.testing.expectEqual(@as(usize, 4), released);
}

const RetiringProbe = struct {
    vat: *actors.Vat,
    child: actors.Ref,

    pub fn handle(_: *@This(), _: *actors.Turn, _: actors.Delivery) !model.Argument {
        return .{ .void = {} };
    }

    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        _ = self.vat.near(self.child, .{ .verb = "lease" }) catch unreachable;
    }
};

test "retired actor destructor reply custody is reclaimed before arena reset" {
    var released: usize = 0;
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    const child = try vat.spawn(ResourceProbe, .{ .released = &released });
    const retiring = try vat.spawn(RetiringProbe, .{ .vat = &vat, .child = child });
    vat.releaseActor(retiring.local);
    _ = try vat.near(child, .{ .verb = "noop" });
    try std.testing.expectEqual(@as(usize, 1), released);
}
