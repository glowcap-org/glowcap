//! The resolver vow (ADR-0014): a local vow minted without a send, whose
//! settle authority is a separate resolver id. These units pin the pair's
//! contract, one-shot settle, top-level only, read side never settles, and
//! the headline: a served behavior defers its wire answer onto a resolver vow
//! and the partner hears the settle only when the resolver fires later, as
//! its own top-level event.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const Turn = actors.Turn;
const Message = actors.Message;
const Delivery = actors.Delivery;
const cross_peer = @import("../support/cross_peer.zig");

const Capture = struct {
    fulfilled: bool = false,
    broke: bool = false,
    buf: [64]u8 = undefined,
    len: usize = 0,

    fn listener(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .fulfilled => |value| {
                self.fulfilled = true;
                switch (value) {
                    .bytes => |bytes| {
                        @memcpy(self.buf[0..bytes.len], bytes);
                        self.len = bytes.len;
                    },
                    else => {},
                }
            },
            .broken => |message| {
                self.broke = true;
                @memcpy(self.buf[0..message.len], message);
                self.len = message.len;
            },
            .give => {},
        }
    }
};

test "resolver pair id exhaustion refuses before publishing either side" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    vat.vow_ids.next = std.math.maxInt(u64);
    try std.testing.expectError(actors.Error.ResourceExhausted, vat.spawnVow());
    try std.testing.expectEqual(@as(usize, 0), vat.pending_local_vows.count());
    try std.testing.expectEqual(@as(usize, 0), vat.resolver_vows.count());

    vat.vow_ids.next = 1;
    vat.resolver_ids.next = std.math.maxInt(u64);
    try std.testing.expectError(actors.Error.ResourceExhausted, vat.spawnVow());
    try std.testing.expectEqual(@as(usize, 0), vat.pending_local_vows.count());
    try std.testing.expectEqual(@as(usize, 0), vat.resolver_vows.count());
}

test "a resolver pair settles its listener once, and every second path refuses" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const pair = try vat.spawnVow();
    var captured = Capture{};
    try vat.on(pair.vow, .{ .ctx = &captured, .func = Capture.listener });

    try vat.fulfillVow(pair.resolver, .{ .bytes = "done" });
    try std.testing.expect(captured.fulfilled);
    try std.testing.expectEqualStrings("done", captured.buf[0..captured.len]);

    // The resolver is consumed: a second settle refuses, either arm.
    try std.testing.expectError(actors.Error.AlreadySettled, vat.fulfillVow(pair.resolver, .{ .void = {} }));
    try std.testing.expectError(actors.Error.AlreadySettled, vat.breakVow(pair.resolver, "late"));
    // An id never minted is distinct from a consumed settle authority.
    for ([_]u64{ 0, vat.resolver_ids.next, std.math.maxInt(u64) }) |id| {
        try std.testing.expectError(error.NoSuchResolver, vat.breakVow(id, "unminted"));
        try std.testing.expectError(error.NoSuchResolver, vat.fulfillVow(id, .{ .void = {} }));
    }
    // The settled vow refuses a late listener, like any settled local vow.
    try std.testing.expectError(actors.Error.AlreadySettled, vat.on(pair.vow, .{ .ctx = &captured, .func = Capture.listener }));
}

test "unminted local vows cannot capture a future operation's listener" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    var captured = Capture{};
    const listener = actors.Listener{ .ctx = &captured, .func = Capture.listener };
    for ([_]u64{ vat.vow_ids.next, 0, std.math.maxInt(u64) }) |id| {
        try std.testing.expectError(error.NoSuchVow, vat.on(.{ .local = id }, listener));
        try std.testing.expectEqual(@as(usize, 0), vat.listeners.count());
    }

    const real = try vat.spawnVow();
    try vat.on(real.vow, listener);
    try vat.fulfillVow(real.resolver, .{ .bytes = "real answer" });
    try std.testing.expectEqualStrings("real answer", captured.buf[0..captured.len]);
    try std.testing.expectEqual(@as(usize, 0), vat.listeners.count());
    try std.testing.expectError(error.AlreadySettled, vat.on(real.vow, listener));
}

test "resolver fulfillment and break OOM preserve the same settle authority" {
    inline for (.{ false, true }) |breaking| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var vat = actors.Vat.init(failing.allocator());
        defer {
            failing.fail_index = std.math.maxInt(usize);
            vat.deinit();
        }
        const pair = try vat.spawnVow();
        var captured = Capture{};
        try vat.on(pair.vow, .{ .ctx = &captured, .func = Capture.listener });
        failing.fail_index = failing.alloc_index;
        const refused = if (breaking) vat.breakVow(pair.resolver, "retryable") else vat.fulfillVow(pair.resolver, .{ .bytes = "retryable" });
        try std.testing.expectError(error.OutOfMemory, refused);
        try std.testing.expect(!captured.fulfilled and !captured.broke);
        failing.fail_index = std.math.maxInt(usize);
        if (breaking) try vat.breakVow(pair.resolver, "retryable") else try vat.fulfillVow(pair.resolver, .{ .bytes = "retryable" });
        try std.testing.expect(if (breaking) captured.broke else captured.fulfilled);
        try std.testing.expectEqualStrings("retryable", captured.buf[0..captured.len]);
    }
}

test "breakVow fires the listener broken with the caller's reason, borrowed" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const pair = try vat.spawnVow();
    var captured = Capture{};
    try vat.on(pair.vow, .{ .ctx = &captured, .func = Capture.listener });

    // A dynamic reason, freed right after the call: the listener fires within
    // the settle, retaining nothing.
    const reason = try allocator.dupe(u8, "worker failed");
    vat.breakVow(pair.resolver, reason) catch |err| {
        allocator.free(reason);
        return err;
    };
    allocator.free(reason);

    try std.testing.expect(captured.broke);
    try std.testing.expectEqualStrings("worker failed", captured.buf[0..captured.len]);
}

test "a served behavior defers its answer onto a resolver vow; the partner hears the later settle" {
    const allocator = std.testing.allocator;
    var pair = try glowcap.ocapn.engine.pairing.paired(allocator);
    defer pair.deinit();
    const host_peer = &pair.p1;
    const caller_peer = &pair.p2;

    var host_vat = actors.Vat.init(allocator);
    defer host_vat.deinit();
    var host_port = actors.Port.init(allocator, host_peer);
    defer host_port.deinit(&host_vat);

    // The behavior mints the pair inside its turn (that is the primary use),
    // defers its answer, and parks the resolver for the "worker", here the
    // test body, which settles it later from the top level.
    const Deferring = struct {
        resolver: u64 = 0,
        fn handle(ctx: *anyopaque, turn: *Turn, msg: Delivery) actors.HostedActor.Result {
            return actors.HostedActor.Result.fromResult(handleOwned(ctx, turn, msg));
        }
        fn handleOwned(ctx: *anyopaque, turn: *Turn, msg: Delivery) anyerror!model.Argument {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = msg;
            const minted = try turn.vat.spawnVow();
            try turn.forwardVow(minted.vow);
            self.resolver = minted.resolver;
            return .{ .void = {} };
        }
    };
    var deferring = Deferring{};
    const worker = try host_vat.spawnHosted(.{ .ctx = &deferring, .handle = Deferring.handle, .free = null });
    try host_port.bindExport(&host_vat, worker, 5);
    try host_peer.exportObject(5);

    try caller_peer.importObject(5);
    var caller_vat = actors.Vat.init(allocator);
    defer caller_vat.deinit();
    var caller_port = actors.Port.init(allocator, caller_peer);
    defer caller_port.deinit(&caller_vat);

    const vow = try caller_port.send(&caller_vat, .{ .far = model.FarRef.object(5) }, .{ .verb = "work" });
    var captured = Capture{};
    try caller_port.on(&caller_vat, vow, .{ .ctx = &captured, .func = Capture.listener });

    try cross_peer.pumpAll(caller_peer, host_peer);
    while (host_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = try host_port.serve(&host_vat, &e);
    }
    try cross_peer.pumpAll(host_peer, caller_peer);
    while (caller_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = try caller_port.serve(&caller_vat, &e);
    }

    // The turn returned, the pumps drained, and the answer is still open:
    // the deferral held it for the resolver.
    try std.testing.expect(deferring.resolver != 0);
    try std.testing.expect(!captured.fulfilled and !captured.broke);

    // The "worker" completes: the settle re-enters at the top level and the
    // wire answer resolves.
    try host_vat.fulfillVow(deferring.resolver, .{ .bytes = "computed" });
    try cross_peer.pumpAll(host_peer, caller_peer);
    while (caller_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = try caller_port.serve(&caller_vat, &e);
    }

    try std.testing.expect(captured.fulfilled);
    try std.testing.expectEqualStrings("computed", captured.buf[0..captured.len]);
}

test "a settle from inside a turn refuses, and the refusal crosses the wire as the handler's break" {
    const allocator = std.testing.allocator;
    var pair = try glowcap.ocapn.engine.pairing.paired(allocator);
    defer pair.deinit();
    const host_peer = &pair.p1;
    const caller_peer = &pair.p2;

    var host_vat = actors.Vat.init(allocator);
    defer host_vat.deinit();
    var host_port = actors.Port.init(allocator, host_peer);
    defer host_port.deinit(&host_vat);

    // A behavior that mints and immediately tries to settle inside its own
    // turn: the settle must refuse (the listener could open a nested drive
    // mid-turn), and returning the error breaks the answer with its name.
    const Impatient = struct {
        fn handle(ctx: *anyopaque, turn: *Turn, msg: Delivery) actors.HostedActor.Result {
            return actors.HostedActor.Result.fromResult(handleOwned(ctx, turn, msg));
        }
        fn handleOwned(ctx: *anyopaque, turn: *Turn, msg: Delivery) anyerror!model.Argument {
            _ = ctx;
            _ = msg;
            const minted = try turn.vat.spawnVow();
            try turn.vat.fulfillVow(minted.resolver, .{ .void = {} });
            return .{ .void = {} };
        }
    };
    var unused: u8 = 0;
    const impatient = try host_vat.spawnHosted(.{ .ctx = &unused, .handle = Impatient.handle, .free = null });
    try host_port.bindExport(&host_vat, impatient, 5);
    try host_peer.exportObject(5);

    try caller_peer.importObject(5);
    var caller_vat = actors.Vat.init(allocator);
    defer caller_vat.deinit();
    var caller_port = actors.Port.init(allocator, caller_peer);
    defer caller_port.deinit(&caller_vat);

    const vow = try caller_port.send(&caller_vat, .{ .far = model.FarRef.object(5) }, .{ .verb = "poke" });
    var captured = Capture{};
    try caller_port.on(&caller_vat, vow, .{ .ctx = &captured, .func = Capture.listener });

    try cross_peer.pumpAll(caller_peer, host_peer);
    while (host_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = try host_port.serve(&host_vat, &e);
    }
    try cross_peer.pumpAll(host_peer, caller_peer);
    while (caller_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = try caller_port.serve(&caller_vat, &e);
    }

    try std.testing.expect(captured.broke);
    try std.testing.expectEqualStrings("SettleInTurn", captured.buf[0..captured.len]);
}

test "forwardVow refuses a local frame, and an unsettled deferral leaks nothing at teardown" {
    const allocator = std.testing.allocator;

    {
        // A local near-call's caller consumes the return directly; a deferred
        // answer has nowhere to land.
        var vat = actors.Vat.init(allocator);
        defer vat.deinit();
        const Local = struct {
            fn handle(ctx: *anyopaque, turn: *Turn, msg: Delivery) actors.HostedActor.Result {
                return actors.HostedActor.Result.fromResult(handleOwned(ctx, turn, msg));
            }
            fn handleOwned(ctx: *anyopaque, turn: *Turn, msg: Delivery) anyerror!model.Argument {
                _ = ctx;
                _ = msg;
                const minted = try turn.vat.spawnVow();
                try turn.forwardVow(minted.vow);
                return .{ .void = {} };
            }
        };
        var unused: u8 = 0;
        const local = try vat.spawnHosted(.{ .ctx = &unused, .handle = Local.handle, .free = null });
        try std.testing.expectError(actors.Error.NotLocal, vat.near(local, .{ .verb = "poke" }));
    }

    {
        // A served deferral that never settles: the forward context and the
        // resolver row are reclaimed at teardown (std.testing.allocator
        // fails the test on any leak).
        var pair = try glowcap.ocapn.engine.pairing.paired(allocator);
        defer pair.deinit();
        var host_vat = actors.Vat.init(allocator);
        defer host_vat.deinit();
        var host_port = actors.Port.init(allocator, &pair.p1);
        defer host_port.deinit(&host_vat);

        const Deferring = struct {
            fn handle(ctx: *anyopaque, turn: *Turn, msg: Delivery) actors.HostedActor.Result {
                return actors.HostedActor.Result.fromResult(handleOwned(ctx, turn, msg));
            }
            fn handleOwned(ctx: *anyopaque, turn: *Turn, msg: Delivery) anyerror!model.Argument {
                _ = ctx;
                _ = msg;
                const minted = try turn.vat.spawnVow();
                try turn.forwardVow(minted.vow);
                return .{ .void = {} };
            }
        };
        var unused: u8 = 0;
        const worker = try host_vat.spawnHosted(.{ .ctx = &unused, .handle = Deferring.handle, .free = null });
        try host_port.bindExport(&host_vat, worker, 5);
        try pair.p1.exportObject(5);
        try pair.p2.importObject(5);

        var caller_vat = actors.Vat.init(allocator);
        defer caller_vat.deinit();
        var caller_port = actors.Port.init(allocator, &pair.p2);
        defer caller_port.deinit(&caller_vat);

        _ = try caller_port.send(&caller_vat, .{ .far = model.FarRef.object(5) }, .{ .verb = "work" });
        _ = try pair.p2.step();
        while (pair.p2.takeOutbound()) |frame| try pair.p1.feedOwned(frame);
        _ = try pair.p1.step();
        while (pair.p1.pollEvent()) |ev| {
            var e = ev;
            defer e.deinit();
            _ = try host_port.serve(&host_vat, &e);
        }
        // Teardown with the deferral still parked: the defers above reclaim.
    }
}

test "forwardVow checks vows that are settled or already observed" {
    const allocator = std.testing.allocator;
    var peers = try glowcap.ocapn.engine.pairing.paired(allocator);
    defer peers.deinit();
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var port = actors.Port.init(allocator, &peers.p1);
    defer port.deinit(&vat);

    const settled = try vat.spawnVow();
    try vat.breakVow(settled.resolver, "finished");
    var settled_turn = Turn{
        .vat = &vat,
        .source = .{ .port = &port },
        .self_id = 0,
        .arena = allocator,
        .origin = .{ .served = .{ .name = .fromWire(.from(1)), .row_id = 1 } },
    };
    try std.testing.expectError(actors.Error.AlreadySettled, settled_turn.forwardVow(settled.vow));
    try std.testing.expect(!settled_turn.forwarded);

    const observed = try vat.spawnVow();
    var captured = Capture{};
    try vat.on(observed.vow, .{ .ctx = &captured, .func = Capture.listener });
    var observed_turn = Turn{
        .vat = &vat,
        .source = .{ .port = &port },
        .self_id = 0,
        .arena = allocator,
        .origin = .{ .served = .{ .name = .fromWire(.from(2)), .row_id = 2 } },
    };
    try std.testing.expectError(actors.Error.AlreadyListening, observed_turn.forwardVow(observed.vow));
    try std.testing.expect(!observed_turn.forwarded);
}

test "a failed turn retracts forwarding to an existing vow" {
    try forwardingFailure(std.testing.allocator);
}

test "forwardVow allocation refusal leaves the source unobserved" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, forwardingFailure, .{});
}

const ForwardThenFail = struct {
    vow: actors.Vow,
    pub fn handle(self: *@This(), turn: *Turn, _: Delivery) !model.Argument {
        try turn.forwardVow(self.vow);
        return error.Refused;
    }
};

fn forwardingFailure(allocator: std.mem.Allocator) !void {
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    const source = try vat.spawnVow();
    const actor = try vat.spawn(ForwardThenFail, .{ .vow = source.vow });
    const result = try vat.send(actor, .{ .verb = "fail" });
    var captured = Capture{};
    try vat.on(result, .{ .ctx = &captured, .func = Capture.listener });
    try vat.drive();
    try std.testing.expect(captured.broke);
    try std.testing.expect(!vat.listeners.contains(source.vow.local));
    if (std.mem.eql(u8, "OutOfMemory", captured.buf[0..captured.len])) return error.OutOfMemory;
    try std.testing.expectEqualStrings("Refused", captured.buf[0..captured.len]);
    // The source still has independent settlement authority. Its next observer
    // must not inherit the failed turn's forwarding continuation.
    var later = Capture{};
    try vat.on(source.vow, .{ .ctx = &later, .func = Capture.listener });
    try vat.fulfillVow(source.resolver, .{ .bytes = "independent" });
    try std.testing.expect(later.fulfilled);
    try std.testing.expect(!captured.fulfilled);
    try std.testing.expectEqual(@as(usize, 0), vat.pending_local_vows.count());
    try std.testing.expectEqual(@as(usize, 0), vat.listeners.count());
}

test "a failed served turn retracts local and far forwarding without a second reply" {
    const engine = glowcap.ocapn.engine;
    const allocator = std.testing.allocator;
    for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| {
        for ([_]bool{ false, true }) |far| {
            var pair = switch (profile) {
                .v1_0 => try engine.pairing.pairedV1_0Syrup(allocator),
                .next => try engine.pairing.paired(allocator),
            };
            defer pair.deinit();
            var host = actors.Vat.init(allocator);
            defer host.deinit();
            var host_port = actors.Port.init(allocator, &pair.p1);
            defer host_port.deinit(&host);
            var caller = actors.Vat.init(allocator);
            defer caller.deinit();
            var caller_port = actors.Port.init(allocator, &pair.p2);
            defer caller_port.deinit(&caller);
            const Echo = struct {
                pub fn handle(_: *@This(), _: *Turn, _: Delivery) !model.Argument {
                    return .{ .bytes = "independent" };
                }
            };
            const echo = try caller.spawn(Echo, .{});
            try caller_port.bindExport(&caller, echo, 7);
            try pair.p2.exportObject(7);
            try pair.p1.importObject(7);
            const local = if (far) null else try host.spawnVow();
            const source = if (local) |held| held.vow else try host_port.send(&host, .{
                .far = model.FarRef.object(7),
            }, .{ .verb = "source" });
            const worker = try host.spawn(ForwardThenFail, .{ .vow = source });
            try host_port.bindExport(&host, worker, 5);
            try pair.p1.exportObject(5);
            try pair.p2.importObject(5);
            const result = try caller_port.send(&caller, .{ .far = model.FarRef.object(5) }, .{ .verb = "fail" });
            var captured = Capture{};
            try caller_port.on(&caller, result, .{ .ctx = &captured, .func = Capture.listener });
            try cross_peer.pumpAll(&pair.p2, &pair.p1);
            try servePending(&host_port, &host);
            var later = Capture{};
            try host_port.on(&host, source, .{ .ctx = &later, .func = Capture.listener });
            if (local) |held| try host.fulfillVow(held.resolver, .{ .bytes = "independent" });
            try cross_peer.pumpAll(&pair.p1, &pair.p2);
            try servePending(&caller_port, &caller);
            try cross_peer.pumpAll(&pair.p2, &pair.p1);
            try servePending(&host_port, &host);
            try std.testing.expect(captured.broke and !captured.fulfilled);
            try std.testing.expectEqualStrings("Refused", captured.buf[0..captured.len]);
            try std.testing.expect(later.fulfilled and !later.broke);
            try std.testing.expectEqualStrings("independent", later.buf[0..later.len]);
            try std.testing.expect(pair.p1.sessionIsOpen() and pair.p2.sessionIsOpen());
            try std.testing.expectEqual(@as(usize, 0), host.listeners.count());
            try std.testing.expectEqual(@as(usize, 0), host_port.far_listeners.count());
        }
    }
}

fn servePending(port: *actors.Port, vat: *actors.Vat) !void {
    while (port.peer.pollEvent()) |event| {
        var owned = event;
        defer owned.deinit();
        _ = try port.serve(vat, &owned);
    }
}

test "a queued local answer can defer and preserves a dynamic break across listener reentry" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    const pair = try vat.spawnVow();
    const Deferred = struct {
        vow: actors.Vow,
        pub fn handle(self: *@This(), turn: *Turn, _: Delivery) !model.Argument {
            try turn.forwardVow(self.vow);
            return .{ .boolean = false }; // deferral owns the answer
        }
    };
    const actor = try vat.spawn(Deferred, .{ .vow = pair.vow });
    const sent = try vat.send(actor, .{ .verb = "wait" });
    var result = Capture{};
    try vat.on(sent, .{ .ctx = &result, .func = Capture.listener });
    try vat.drive();
    try std.testing.expect(!result.fulfilled and !result.broke);
    try vat.fulfillVow(pair.resolver, .{ .bytes = "later" });
    try std.testing.expect(result.fulfilled);
    try std.testing.expectEqualStrings("later", result.buf[0..result.len]);

    const Refuser = struct {
        pub fn handle(_: *@This(), turn: *Turn, msg: Delivery) !model.Argument {
            if (msg.is("reset")) {
                @memset(try turn.arena.alloc(u8, 2048), 0xcc);
            } else {
                var text = [_]u8{ 'e', 'x', 'a', 'c', 't' };
                try turn.breakWith(&text);
                @memset(&text, 0xaa);
            }
            return .{ .void = {} };
        }
    };
    const refuser = try vat.spawn(Refuser, .{});
    const Reentrant = struct {
        vat: *actors.Vat,
        target: actors.Ref,
        capture: Capture = .{},
        fn listen(ctx: ?*anyopaque, resolution: actors.Resolution) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = self.vat.near(self.target, .{ .verb = "reset" }) catch unreachable;
            Capture.listener(&self.capture, resolution);
        }
    };
    var reentrant = Reentrant{ .vat = &vat, .target = refuser };
    const broken = try vat.send(refuser, .{ .verb = "refuse" });
    try vat.on(broken, .{ .ctx = &reentrant, .func = Reentrant.listen });
    try vat.drive();
    try std.testing.expect(reentrant.capture.broke);
    try std.testing.expectEqualStrings("exact", reentrant.capture.buf[0..reentrant.capture.len]);
    try std.testing.expectEqual(@as(usize, 0), vat.pending_local_vows.count());
}
