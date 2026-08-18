//! The resolver vow (ADR-0102): a local vow minted without a send, whose
//! settle authority is a separate resolver id. These units pin the pair's
//! contract — one-shot settle, top-level only, read side never settles — and
//! the headline: a served behavior defers its wire answer onto a resolver vow
//! and the partner hears the settle only when the resolver fires later, as
//! its own top-level event.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const Turn = actors.Turn;
const Message = actors.Message;
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
    // An id never minted refuses the same way.
    try std.testing.expectError(actors.Error.AlreadySettled, vat.breakVow(9999, "unminted"));
    // The settled vow refuses a late listener, like any settled local vow.
    try std.testing.expectError(actors.Error.AlreadySettled, vat.on(pair.vow, .{ .ctx = &captured, .func = Capture.listener }));
}

test "resolver fulfillment OOM leaves the same settle authority retryable" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var vat = actors.Vat.init(failing.allocator());
    defer {
        failing.fail_index = std.math.maxInt(usize);
        vat.deinit();
    }

    const pair = try vat.spawnVow();
    var captured = Capture{};
    try vat.on(pair.vow, .{ .ctx = &captured, .func = Capture.listener });

    // Fulfilled bytes need an owned settle-arena copy before the listener can
    // run. Refusing that allocation must consume neither side of the pair.
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        vat.fulfillVow(pair.resolver, .{ .bytes = "retryable" }),
    );
    try std.testing.expect(!captured.fulfilled);

    failing.fail_index = std.math.maxInt(usize);
    try vat.fulfillVow(pair.resolver, .{ .bytes = "retryable" });
    try std.testing.expect(captured.fulfilled);
    try std.testing.expectEqualStrings("retryable", captured.buf[0..captured.len]);
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
    var pair = try pancake.ocapn.engine.pairing.paired(allocator);
    defer pair.deinit();
    const host_peer = &pair.p1;
    const caller_peer = &pair.p2;

    var host_vat = actors.Vat.init(allocator);
    defer host_vat.deinit();
    var host_port = actors.Port.init(allocator, host_peer);
    defer host_port.deinit(&host_vat);

    // The behavior mints the pair inside its turn (that is the primary use),
    // defers its answer, and parks the resolver for the "worker" — here the
    // test body, which settles it later from the top level.
    const Deferring = struct {
        resolver: u64 = 0,
        fn handle(ctx: *anyopaque, turn: *Turn, msg: Message) anyerror!model.Argument {
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
    var pair = try pancake.ocapn.engine.pairing.paired(allocator);
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
        fn handle(ctx: *anyopaque, turn: *Turn, msg: Message) anyerror!model.Argument {
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
            fn handle(ctx: *anyopaque, turn: *Turn, msg: Message) anyerror!model.Argument {
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
        var pair = try pancake.ocapn.engine.pairing.paired(allocator);
        defer pair.deinit();
        var host_vat = actors.Vat.init(allocator);
        defer host_vat.deinit();
        var host_port = actors.Port.init(allocator, &pair.p1);
        defer host_port.deinit(&host_vat);

        const Deferring = struct {
            fn handle(ctx: *anyopaque, turn: *Turn, msg: Message) anyerror!model.Argument {
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
    var peers = try pancake.ocapn.engine.pairing.paired(allocator);
    defer peers.deinit();
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var port = actors.Port.init(allocator, &peers.p1);
    defer port.deinit(&vat);

    const settled = try vat.spawnVow();
    try vat.breakVow(settled.resolver, "finished");
    var settled_turn = Turn{
        .vat = &vat,
        .port = &port,
        .self_ref = .{ .local = 0 },
        .ingress = .local,
        .arena = allocator,
        .origin = .{ .served = .fromWire(.from(1)) },
    };
    try std.testing.expectError(actors.Error.AlreadySettled, settled_turn.forwardVow(settled.vow));
    try std.testing.expect(!settled_turn.forwarded);

    const observed = try vat.spawnVow();
    var captured = Capture{};
    try vat.on(observed.vow, .{ .ctx = &captured, .func = Capture.listener });
    var observed_turn = Turn{
        .vat = &vat,
        .port = &port,
        .self_ref = .{ .local = 0 },
        .ingress = .local,
        .arena = allocator,
        .origin = .{ .served = .fromWire(.from(2)) },
    };
    try std.testing.expectError(actors.Error.AlreadyListening, observed_turn.forwardVow(observed.vow));
    try std.testing.expect(!observed_turn.forwarded);
}
