//! Failure provenance survives local settlement and becomes partner provenance
//! only when the same diagnostic crosses a CapTP connection.
const BreakCause = @import("glowcap").foundation.break_cause.BreakCause;
const std = @import("std");
const glowcap = @import("glowcap");
const actors = glowcap.actors;
const engine = glowcap.ocapn.engine;
const model = glowcap.ocapn.model;
const cross_peer = @import("../support/cross_peer.zig");

const Capture = struct {
    cause: ?engine.BreakCause = null,
    text: [256]u8 = undefined,
    len: usize = 0,

    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *Capture = @ptrCast(@alignCast(ctx.?));
        const broken = resolution.broken;
        self.cause = broken.cause;
        self.len = broken.detail.len;
        @memcpy(self.text[0..self.len], broken.detail);
    }
};

test "local resolver settlement preserves every typed cause without interpreting text" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    const Origin = @FieldType(BreakCause, "origin");
    const Reason = @FieldType(BreakCause, "reason");
    for (std.enums.values(Origin)) |origin| for (std.enums.values(Reason)) |reason| {
        if (origin == .unspecified and reason != .unspecified) continue;
        if (origin == .partner and reason != .application) continue;
        for (0..8) |context| {
            const cause: BreakCause = .{ .origin = origin, .reason = reason, .context = @bitCast(@as(u3, @intCast(context))) };
            const pair = try vat.spawnVow();
            var capture = Capture{};
            try vat.on(pair.vow, .{ .ctx = &capture, .func = Capture.fire });
            try vat.breakVow(pair.resolver, .{ .cause = cause, .detail = "PeerIdentityUnverified" });
            try std.testing.expectEqual(cause, capture.cause.?);
            try std.testing.expectEqualStrings("PeerIdentityUnverified", capture.text[0..capture.len]);
        }
    };
}

const Refuser = struct {
    pub fn handle(_: *@This(), turn: *actors.Turn, message: actors.Delivery) !model.Argument {
        try turn.breakWith(message.verb.?);
        return .{ .void = {} };
    }
};

test "a behavior's refusal of a same-vat send is a local application break" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    const refuser = try vat.spawn(Refuser, .{});
    const vow = try vat.send(refuser, .{ .verb = "rate-limited: retry-after-ms=1" });
    var capture = Capture{};
    try vat.on(vow, .{ .ctx = &capture, .func = Capture.fire });
    try vat.drive();
    try std.testing.expectEqual(BreakCause.local(.application), capture.cause.?);
    try std.testing.expectEqualStrings("rate-limited: retry-after-ms=1", capture.text[0..capture.len]);
}

const Failing = struct {
    pub fn handle(_: *@This(), _: *actors.Turn, _: actors.Delivery) !model.Argument {
        return error.Overloaded;
    }
};

test "a behavior's returned error on a same-vat send is a local application break" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    const failing = try vat.spawn(Failing, .{});
    const vow = try vat.send(failing, .{ .verb = "work" });
    var capture = Capture{};
    try vat.on(vow, .{ .ctx = &capture, .func = Capture.fire });
    try vat.drive();
    try std.testing.expectEqual(BreakCause.local(.application), capture.cause.?);
    try std.testing.expectEqualStrings("Overloaded", capture.text[0..capture.len]);
}

const Answering = struct {
    pub fn handle(_: *@This(), _: *actors.Turn, _: actors.Delivery) !model.Argument {
        return .{ .integer = 1 };
    }
};

/// A hosting adapter whose own machinery fails before the behavior runs.
const BrokenAdapter = struct {
    fn handle(_: *anyopaque, _: *actors.Turn, _: actors.Delivery) actors.HostedActor.Result {
        return .{ .refused = actors.HostedActor.Failure.adapter(error.OutOfMemory) };
    }
};

test "a hosting adapter's own failure is not the behavior's refusal" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    var state: u8 = 0;
    const hosted = try vat.spawnHosted(.{ .ctx = &state, .handle = BrokenAdapter.handle });
    const vow = try vat.send(hosted, .{ .verb = "work" });
    var capture = Capture{};
    try vat.on(vow, .{ .ctx = &capture, .func = Capture.fire });
    try vat.drive();
    try std.testing.expectEqual(BreakCause{}, capture.cause.?);
    try std.testing.expectEqualStrings("OutOfMemory", capture.text[0..capture.len]);
}

const ForwardThenFail = struct {
    target: actors.Ref,

    pub fn handle(self: *@This(), turn: *actors.Turn, message: actors.Delivery) !model.Argument {
        _ = try turn.forward(self.target, .{ .verb = message.verb.? });
        return error.Overloaded;
    }
};

test "a behavior that forwards and then fails breaks its caller with the same cause" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    // The target would answer, so only the rollback can break the caller.
    const target = try vat.spawn(Answering, .{});
    const forwarder = try vat.spawn(ForwardThenFail, .{ .target = target });
    const vow = try vat.send(forwarder, .{ .verb = "work" });
    var capture = Capture{};
    try vat.on(vow, .{ .ctx = &capture, .func = Capture.fire });
    try vat.drive();
    try std.testing.expectEqual(BreakCause.local(.application), capture.cause.?);
    try std.testing.expectEqualStrings("Overloaded", capture.text[0..capture.len]);
}

const SendThenFail = struct {
    target: actors.Ref,
    dropped: *Capture,

    pub fn handle(self: *@This(), turn: *actors.Turn, _: actors.Delivery) !model.Argument {
        const vow = try turn.send(self.target, .{ .verb = "work" });
        try turn.vat.on(vow, .{ .ctx = self.dropped, .func = Capture.fire });
        return error.Overloaded;
    }
};

test "a send its failed turn drops breaks with the behavior's own cause" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    var dropped = Capture{};
    // The target would answer, so only the drop can break this send.
    const target = try vat.spawn(Answering, .{});
    const sender = try vat.spawn(SendThenFail, .{ .target = target, .dropped = &dropped });
    _ = try vat.send(sender, .{ .verb = "work" });
    try vat.drive();
    try std.testing.expectEqual(BreakCause.local(.application), dropped.cause.?);
    try std.testing.expectEqualStrings("Overloaded", dropped.text[0..dropped.len]);
}

const BreakThenFail = struct {
    target: actors.Ref,
    dropped: *Capture,

    pub fn handle(self: *@This(), turn: *actors.Turn, _: actors.Delivery) !model.Argument {
        const vow = try turn.send(self.target, .{ .verb = "work" });
        try turn.vat.on(vow, .{ .ctx = self.dropped, .func = Capture.fire });
        try turn.breakWith("Revoked");
        return error.Overloaded;
    }
};

test "a turn that breaks its call and then fails gives the caller and its dropped sends one break" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    var dropped = Capture{};
    var caller = Capture{};
    const target = try vat.spawn(Answering, .{});
    const sender = try vat.spawn(BreakThenFail, .{ .target = target, .dropped = &dropped });
    const vow = try vat.send(sender, .{ .verb = "work" });
    try vat.on(vow, .{ .ctx = &caller, .func = Capture.fire });
    try vat.drive();
    for ([_]*Capture{ &caller, &dropped }) |capture| {
        try std.testing.expectEqual(BreakCause.local(.application), capture.cause.?);
        try std.testing.expectEqualStrings("Revoked", capture.text[0..capture.len]);
    }
}

const Scribbler = struct {
    pub fn handle(_: *@This(), turn: *actors.Turn, _: actors.Delivery) !model.Argument {
        @memset(try turn.arena.alloc(u8, 256), 'x');
        return .{ .void = {} };
    }
};

/// Reads the break, then opens a turn that writes over the turn arena.
const ReenteringCapture = struct {
    vat: *actors.Vat,
    scribbler: actors.Ref,
    capture: Capture = .{},

    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        Capture.fire(&self.capture, resolution);
        _ = self.vat.near(self.scribbler, .{ .verb = "work" }) catch unreachable;
    }
};

const BreakThenFailTwice = struct {
    target: actors.Ref,
    first: *ReenteringCapture,
    second: *ReenteringCapture,

    pub fn handle(self: *@This(), turn: *actors.Turn, _: actors.Delivery) !model.Argument {
        for ([_]*ReenteringCapture{ self.first, self.second }) |listener| {
            const vow = try turn.send(self.target, .{ .verb = "work" });
            try turn.vat.on(vow, .{ .ctx = listener, .func = ReenteringCapture.fire });
        }
        try turn.breakWith("Revoked");
        return error.Overloaded;
    }
};

test "a dropped send's listener that opens a turn leaves the break intact for the next one" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    const target = try vat.spawn(Answering, .{});
    const scribbler = try vat.spawn(Scribbler, .{});
    var first = ReenteringCapture{ .vat = &vat, .scribbler = scribbler };
    var second = ReenteringCapture{ .vat = &vat, .scribbler = scribbler };
    var caller = Capture{};
    const sender = try vat.spawn(BreakThenFailTwice, .{ .target = target, .first = &first, .second = &second });
    const vow = try vat.send(sender, .{ .verb = "work" });
    try vat.on(vow, .{ .ctx = &caller, .func = Capture.fire });
    try vat.drive();
    for ([_]*Capture{ &first.capture, &second.capture, &caller }) |capture| {
        try std.testing.expectEqual(BreakCause.local(.application), capture.cause.?);
        try std.testing.expectEqualStrings("Revoked", capture.text[0..capture.len]);
    }
}

test "wire breaks cannot claim local failure provenance" {
    var pair = try engine.pairing.paired(std.testing.allocator);
    defer pair.deinit();
    var server = actors.Vat.init(std.testing.allocator);
    defer server.deinit();
    var client = actors.Vat.init(std.testing.allocator);
    defer client.deinit();
    var server_port = actors.Port.init(std.testing.allocator, &pair.p1);
    defer server_port.deinit(&server);
    var client_port = actors.Port.init(std.testing.allocator, &pair.p2);
    defer client_port.deinit(&client);
    const refuser = try server.spawn(Refuser, .{});
    try server_port.bindExport(&server, refuser, 5);
    try pair.p1.exportObject(5);
    try pair.p2.importObject(5);
    for ([_][]const u8{ "PeerIdentityUnverified", "ExporterUnreachable: no route", "unknown swissnum", "handoff redeem failed: refused" }) |text| {
        const vow = try client_port.send(&client, .{ .far = model.FarRef.object(5) }, .{ .verb = text });
        var capture = Capture{};
        try client_port.on(&client, vow, .{ .ctx = &capture, .func = Capture.fire });
        try cross_peer.pumpAll(&pair.p2, &pair.p1);
        while (pair.p1.pollEvent()) |event| {
            var owned = event;
            defer owned.deinit();
            _ = try server_port.serve(&server, &owned);
        }
        try cross_peer.pumpAll(&pair.p1, &pair.p2);
        while (pair.p2.pollEvent()) |event| {
            var owned = event;
            defer owned.deinit();
            _ = try client_port.serve(&client, &owned);
        }
        try std.testing.expectEqual(BreakCause.partner(), capture.cause.?);
        try std.testing.expectEqualStrings(text, capture.text[0..capture.len]);
    }
}

test "local failure formatting preserves bounded wire diagnostics and partner bytes" {
    const capacity = engine.Broken.diagnostic_capacity;
    var buffer: [capacity]u8 = undefined;
    const long: [1024]u8 = @splat('x');
    const exhausted: engine.Broken = .{ .cause = BreakCause.local(.peer_unreachable), .detail = &long };
    try std.testing.expectEqual(BreakCause.local(.peer_unreachable), exhausted.bounded().cause);
    try std.testing.expectEqualStrings(long[0 .. capacity - "ExporterUnreachable: ".len], exhausted.bounded().detail);
    try std.testing.expectEqual(@as(usize, capacity), exhausted.render(&buffer).len);
    const partner: engine.Broken = .{ .cause = BreakCause.partner(), .detail = &long };
    try std.testing.expectEqualStrings(&long, partner.bounded().detail);
    try std.testing.expectEqualStrings(&long, partner.render(&buffer));
    const refused: engine.Broken = .{ .cause = BreakCause.local(.refused).withWithdrawal(), .detail = "not a capability" };
    try std.testing.expectEqualStrings("handoff redeem failed: not a capability", refused.render(&buffer));
}

test "bounded diagnostics preserve complete UTF-8 characters at the limit" {
    const Broken = engine.Broken;
    const prefix = "ExporterUnreachable: ";
    const ascii: [Broken.diagnostic_capacity - prefix.len - 1]u8 = @splat('x');
    const diagnostic: Broken = .{ .cause = BreakCause.local(.peer_unreachable), .detail = &(ascii ++ "é".*) };
    try std.testing.expectEqualStrings(&ascii, diagnostic.bounded().detail);
}
