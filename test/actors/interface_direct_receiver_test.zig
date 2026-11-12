//! A generated direct receiver meets raw lists over both negotiated profiles.
const std = @import("std");
const glowcap = @import("glowcap");
const generated = @import("../interface/generated/direct_receiver.zig");
const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const engine = glowcap.ocapn.engine;
const pump = @import("../support/cross_peer.zig").pumpAll;
const a = std.testing.allocator;

fn expectValue(expected: model.Argument, actual: model.view.Argument) !void {
    try std.testing.expectEqualStrings(@tagName(expected), @tagName(actual));
    switch (expected) {
        .symbol => |value| try std.testing.expectEqualStrings(value, actual.symbol),
        .string => |value| try std.testing.expectEqualStrings(value, actual.string),
        .integer => |value| try std.testing.expectEqual(value, actual.integer),
        .boolean => |value| try std.testing.expectEqual(value, actual.boolean),
        .void => {},
        else => unreachable,
    }
}

const Receiver = struct {
    expected: []const model.Argument,
    calls: usize = 0,
    fail: bool = false,
    borrowed: ?[*]const u8 = null,

    pub fn invoke(self: *Receiver, left: model.view.Argument, right: model.view.Argument) !void {
        try expectValue(self.expected[0], left);
        try expectValue(self.expected[1], right);
        if (self.borrowed) |bytes| try std.testing.expectEqual(bytes, left.string.ptr);
        self.calls += 1;
        if (self.fail) return error.ApplicationRejected;
    }
};
const Direct = struct {
    receiver: *Receiver,
    pub fn handle(self: *Direct, _: *actors.Turn, delivery: actors.Delivery) !model.Argument {
        return generated.receive(self.receiver, delivery);
    }
};
const Named = struct {
    calls: *usize,
    pub fn handle(self: *Named, _: *actors.Turn, delivery: actors.Delivery) !model.Argument {
        if (!delivery.is("call") or try delivery.args.len() != 1) return error.InvalidArguments;
        if (try delivery.argInt(0) != 37) return error.InvalidArguments;
        self.calls.* += 1;
        return .{ .void = {} };
    }
};
const Outcome = struct {
    called: bool = false,
    void_reply: bool = false,
    reason: [96]u8 = undefined,
    reason_len: usize = 0,
    fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *Outcome = @ptrCast(@alignCast(ctx.?));
        std.debug.assert(!self.called);
        self.called = true;
        switch (resolution) {
            .fulfilled => |value| self.void_reply = value == .void,
            .broken => |failure| {
                const reason = failure.detail;
                self.reason_len = @min(reason.len, self.reason.len);
                @memcpy(self.reason[0..self.reason_len], reason[0..self.reason_len]);
            },
            .give => {},
        }
    }
    fn broken(self: *const Outcome, expected: []const u8) !void {
        try std.testing.expect(self.called and !self.void_reply);
        try std.testing.expectEqualStrings(expected, self.reason[0..self.reason_len]);
    }
};

const Harness = struct {
    pair: *engine.pairing.Pair,
    server_vat: *actors.Vat,
    server: *actors.Port,
    caller_vat: *actors.Vat,
    caller: *actors.Port,

    fn call(self: Harness, target: u64, wire: []const model.Argument) !Outcome {
        // This raw caller contributes no selector. The authored list is authoritative.
        const vow = try self.caller.send(self.caller_vat, .{ .far = model.FarRef.object(target) }, .{ .args = wire });
        var outcome: Outcome = .{};
        try self.caller.on(self.caller_vat, vow, .{ .ctx = &outcome, .func = Outcome.record });
        try pump(&self.pair.p1, &self.pair.p2);
        while (self.pair.p2.pollEvent()) |event| {
            var incoming = event;
            defer incoming.deinit();
            if (incoming.kind() == .deliver) {
                const args = incoming.view().deliver.args;
                try std.testing.expectEqual(wire.len, try args.len());
                for (wire, 0..) |value, i| try expectValue(value, try args.at(i));
            }
            _ = try self.server.serve(self.server_vat, &incoming);
        }
        try pump(&self.pair.p2, &self.pair.p1);
        while (self.pair.p1.pollEvent()) |event| {
            var reply = event;
            defer reply.deinit();
            _ = try self.caller.serve(self.caller_vat, &reply);
        }
        try std.testing.expect(outcome.called);
        return outcome;
    }
};

test "generated direct receiver preserves raw lists and refusals on both profiles" {
    const valid = [_][]const model.Argument{
        &.{ .{ .symbol = "" }, .{ .integer = 37 } },
        &.{ .{ .symbol = "call" }, .{ .integer = 37 } },
        &.{ .{ .string = "call" }, .{ .integer = 37 } },
        &.{ .{ .integer = 37 }, .{ .symbol = "tail" } },
        &.{ .{ .void = {} }, .{ .boolean = true } },
    };
    for ([_]bool{ false, true }) |interop| {
        var pair = if (interop) try engine.pairing.pairedV1_0Syrup(a) else try engine.pairing.paired(a);
        defer pair.deinit();
        try std.testing.expectEqual(if (interop) model.CaptpVersion.v1_0 else model.CaptpVersion.next, pair.p1.session_state.captp_version);
        try std.testing.expectEqual(if (interop) model.CodecId.syrup else model.CodecId.capnp, pair.p1.session_state.codec);
        var server_vat = actors.Vat.init(a);
        defer server_vat.deinit();
        var server = actors.Port.init(a, &pair.p2);
        defer server.deinit(&server_vat);
        var receiver: Receiver = .{ .expected = valid[0] };
        var named_calls: usize = 0;
        const direct = try server_vat.spawn(Direct, .{ .receiver = &receiver });
        const named = try server_vat.spawn(Named, .{ .calls = &named_calls });
        try server.bindExport(&server_vat, direct, 5);
        try server.bindExport(&server_vat, named, 6);
        try pair.p2.exportObject(5);
        try pair.p2.exportObject(6);
        try pair.p1.importObject(5);
        try pair.p1.importObject(6);
        var caller_vat = actors.Vat.init(a);
        defer caller_vat.deinit();
        var caller = actors.Port.init(a, &pair.p1);
        defer caller.deinit(&caller_vat);
        const harness: Harness = .{ .pair = &pair, .server_vat = &server_vat, .server = &server, .caller_vat = &caller_vat, .caller = &caller };
        for (valid, 0..) |wire, i| {
            receiver.expected = wire;
            try std.testing.expect((try harness.call(5, wire)).void_reply);
            try std.testing.expectEqual(i + 1, receiver.calls);
        }
        // The same list selects a named method at the separately declared receiver.
        try std.testing.expect((try harness.call(6, valid[1])).void_reply);
        try std.testing.expectEqual(@as(usize, 1), named_calls);
        const admitted = receiver.calls;
        for ([_][]const model.Argument{
            &.{},                                                                &.{.{ .symbol = "call" }},                                        &.{.{ .integer = 37 }},
            &.{ .{ .symbol = "call" }, .{ .integer = 37 }, .{ .integer = 38 } }, &.{ .{ .integer = 36 }, .{ .integer = 37 }, .{ .integer = 38 } },
        }) |wire| {
            try (try harness.call(5, wire)).broken("InvalidArguments");
            try std.testing.expectEqual(admitted, receiver.calls);
        }
        receiver.expected = valid[1];
        receiver.fail = true;
        try (try harness.call(5, valid[1])).broken("ApplicationRejected");
        receiver.fail = false;
        try std.testing.expect((try harness.call(5, valid[1])).void_reply);
        try std.testing.expectEqual(admitted + 2, receiver.calls);
    }
}

const Malformed = struct {
    const table: model.view.Args.VTable = .{ .len = len, .at = at, .next = next, .tail = tail };
    fn len(_: model.view.Args.Ctx) model.view.ProjectError!usize {
        return 2;
    }
    fn at(_: model.view.Args.Ctx, i: usize) model.view.ProjectError!model.view.Argument {
        if (i == 0) return .{ .integer = 37 };
        return error.MalformedView;
    }
    fn next(_: model.view.Args.Ctx, _: *u64, _: *model.view.Argument) model.view.ProjectError!bool {
        return error.MalformedView;
    }
    fn tail(_: model.view.Args.Ctx, _: usize) model.view.ProjectError!model.view.Args.Ctx {
        return error.MalformedView;
    }
};

test "generated direct receiver borrows payloads and projects before handler entry" {
    var payload: [4096]u8 = @splat('x');
    const wire = [_]model.Argument{ .{ .string = &payload }, .{ .integer = 37 } };
    var receiver: Receiver = .{ .expected = &wire, .borrowed = &payload };
    const near = (actors.Message{ .args = &wire }).delivery();
    try std.testing.expect((try generated.receive(&receiver, near)) == .void);
    try std.testing.expectEqual(@as(usize, 1), receiver.calls);
    try std.testing.expectError(error.MalformedView, generated.receive(&receiver, .{ .args = .fromBacking(.{}, &Malformed.table) }));
    try std.testing.expectEqual(@as(usize, 1), receiver.calls);
}
