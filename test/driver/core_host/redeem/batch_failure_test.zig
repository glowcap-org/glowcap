//! Signed gives cross Host dial completion while the recipient's allocator
//! fails. The replay covers batch admission, public vow outcomes and session
//! closure over byte-fed peers. It fails if a terminal batch outcome is
//! dropped or a consumed withdrawal stays live. Physical dial and storage
//! faults are out of reach.
const std = @import("std");
const glowcap = @import("glowcap");
const h = @import("../harness.zig");
const support = @import("../../../support/core_host.zig");
const Host = glowcap.driver.core.Host;
const model = glowcap.ocapn.model;
const a = std.testing.allocator;

const Capture = struct {
    calls: usize = 0,
    result: h.CapturedRef = .{},

    fn fire(context: ?*anyopaque, resolution: glowcap.actors.Resolution) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        h.CapturedRef.record(&self.result, resolution);
    }
};

// The replay key is (profile, codec, close-introducer, allocation offset).
// The search stops once it has seen a preflight refusal and a partially
// committed batch, so it does not try every allocation failure in the Host
// pump after commit.
test "core host: signed handoff batch replay settles once across allocation failure and introducer close" {
    for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| {
        for ([_]model.CodecId{ .syrup, .capnp }) |codec| {
            for ([_]bool{ false, true }) |close_introducer| {
                const clean = try replayBatch(profile, codec, close_introducer, std.math.maxInt(usize));
                try std.testing.expect(!clean.induced);
                var saw_preflight = false;
                var saw_partial = false;
                for (0..128) |offset| {
                    const outcome = try replayBatch(profile, codec, close_introducer, offset);
                    saw_preflight = saw_preflight or outcome.preflight;
                    saw_partial = saw_partial or outcome.partial;
                    if (saw_preflight and saw_partial) break;
                } else return error.RequiredFailureStatesNotReached;
                try std.testing.expect(saw_preflight);
                try std.testing.expect(saw_partial);
            }
        }
    }
}

const Outcome = struct { induced: bool, preflight: bool, partial: bool };

fn replayBatch(profile: model.CaptpVersion, codec: model.CodecId, close_introducer: bool, offset: usize) !Outcome {
    var failing = std.testing.FailingAllocator.init(a, .{});
    var options = Host.Options.withFrameCap(h.frame_cap);
    options.captp_version = profile;
    options.codec = codec;
    options.features = model.FeatureSet.full().forCaptpVersion(profile);
    var exporter = support.init(a, @splat(0x71), options);
    defer exporter.deinit();
    var gifter = support.init(a, @splat(0x72), options);
    defer gifter.deinit();
    var recipient = support.init(failing.allocator(), @splat(0x73), options);
    defer recipient.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer {
        for (dials.items) |dial| a.free(dial.designator);
        dials.deinit(a);
    }
    const hosts = [_]*Host{ &exporter, &gifter, &recipient };
    const ge = try h.openPair(a, &gifter, &exporter, "127.0.0.1:7941", &dials);
    _ = try ge.b.served.publish(&exporter.vat, "widget", h.Widget, .{});
    var widget: h.CapturedRef = .{};
    try gifter.vowOn(try gifter.fetch(ge.a, "widget"), .{ .ctx = &widget, .func = h.CapturedRef.record });
    try h.pumpToQuiescence(a, &hosts, &.{ge}, &dials);
    const rg = try h.openPair(a, &recipient, &gifter, "127.0.0.1:7942", &dials);
    _ = try rg.b.served.publish(&gifter.vat, "introducer", h.Introducer, .{ .widget = try widget.require() });
    var introducer: h.CapturedRef = .{};
    const fetched = try recipient.fetch(rg.a, "introducer");
    try recipient.vowOn(fetched, .{ .ctx = &introducer, .func = h.CapturedRef.record });
    try h.pumpToQuiescence(a, &hosts, &.{ ge, rg }, &dials);
    var captures: [3]Capture = @splat(.{});
    var vows: [3]u64 = undefined;
    for (&captures, &vows) |*capture, *vow| {
        vow.* = try recipient.send(rg.a, try introducer.require(), .{ .verb = "introduce" });
        try recipient.vowOn(vow.*, .{ .ctx = capture, .func = Capture.fire });
    }
    try std.testing.expect(try h.shuttle(rg));
    var gifts: u8 = 0;
    while (try gifter.nextAction()) |action| switch (action) {
        .need_gift_id => |needed| {
            const gift_id: [32]u8 = @splat(0x80 + gifts);
            try gifter.provideGiftId(needed.ticket, &gift_id);
            gifts += 1;
        },
        .flush => {},
        else => return error.UnexpectedAction,
    };
    try std.testing.expectEqual(@as(u8, 3), gifts);
    try h.pumpToQuiescence(a, &hosts, &.{ ge, rg }, &dials);
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    const dial = dials.items[0];
    const accepted = try h.publishAndOpenAccepted(&exporter, "tcp", "127.0.0.1:7941", &.{});
    const dialed = (try recipient.openPendingDial(dial.ticket, dial.route_index)).?;
    const re: h.Pair = .{ .ah = &recipient, .a = dialed, .bh = &exporter, .b = accepted };
    try h.pumpToQuiescence(a, &hosts, &.{ ge, rg, re }, &dials);
    failing.fail_index = if (offset == std.math.maxInt(usize)) offset else failing.alloc_index + offset;
    const completed = recipient.exporterDialed(dial.ticket, dial.route_index, dialed);
    const induced = failing.has_induced_failure;
    failing.fail_index = std.math.maxInt(usize);
    var preflight = false;
    const adopted = completed catch |err| blk: {
        try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expect(induced);
        try std.testing.expect(recipient.pendingDial(dial.ticket, dial.route_index) != null);
        for (captures) |capture| try std.testing.expectEqual(@as(usize, 0), capture.calls);
        preflight = true;
        break :blk try recipient.exporterDialed(dial.ticket, dial.route_index, dialed);
    };
    try std.testing.expect(adopted);
    const withdrawals = recipient.node.redeems.withdrawals.rows.count();
    const partial = withdrawals > 0 and withdrawals < captures.len;
    if (partial) {
        try std.testing.expect(induced);
        try std.testing.expect(!preflight);
    }
    if (close_introducer) {
        try recipient.releaseSession(rg.a);
        try gifter.releaseSession(rg.b);
        try h.pumpToQuiescence(a, &hosts, &.{ ge, re }, &dials);
    } else try h.pumpToQuiescence(a, &hosts, &.{ ge, rg, re }, &dials);
    var successes: usize = 0;
    for (captures) |capture| {
        try std.testing.expectEqual(@as(usize, 1), capture.calls);
        if (capture.result.broken) {
            const reason = capture.result.reason_buf[0..capture.result.reason_len];
            if (std.mem.eql(u8, reason, "connection released")) {
                try std.testing.expect(close_introducer);
            } else {
                try std.testing.expect(induced);
                try std.testing.expectEqualStrings("handoff redeem failed: local allocation failure", reason);
            }
        } else {
            try std.testing.expect(!close_introducer);
            successes += 1;
            var reply: h.CapturedString = .{};
            try recipient.vowOn(try recipient.send(dialed, try capture.result.require(), .{ .verb = "poke" }), .{ .ctx = &reply, .func = h.CapturedString.record });
            try h.pumpToQuiescence(a, &hosts, &.{ ge, rg, re }, &dials);
            try std.testing.expectEqualStrings("poked over fed bytes", reply.text());
        }
    }
    if (!close_introducer) try std.testing.expectEqual(withdrawals, successes);
    for (vows) |vow| if (recipient.vows.contains(vow)) try recipient.vowRelease(vow);
    if (recipient.vows.contains(fetched)) try recipient.vowRelease(fetched);
    if (close_introducer) try h.pumpToQuiescence(a, &hosts, &.{ ge, re }, &dials) else try h.pumpToQuiescence(a, &hosts, &.{ ge, rg, re }, &dials);
    try std.testing.expectEqual(@as(usize, 0), recipient.node.pendingDialCount());
    try std.testing.expectEqual(@as(usize, 0), recipient.node.redeems.withdrawals.rows.count());
    try std.testing.expectEqual(@as(usize, 0), recipient.pendingVowCount());
    for (captures) |capture| try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(usize, 0), recipient.pending_operations);
    return .{ .induced = induced, .preflight = preflight, .partial = partial };
}
