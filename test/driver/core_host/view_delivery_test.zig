//! A Value-shaped Host behavior reads a wire deliver as the frame's views
//! when the deliver carries no capability, and as lifted values when it
//! does (ADR-0063). The accessors answer the same on both backings.
const std = @import("std");
const glowcap = @import("glowcap");
const core = glowcap.driver.core;
const h = @import("harness.zig");
const test_host = @import("../../support/core_host.zig");
const a = std.testing.allocator;

const Backing = std.meta.Tag(core.Args.Inner);

/// Answers `report(label, samples, at)` with the sum of `samples`, and
/// records which backing each delivery arrived on and whether the samples
/// were read where the frame holds them.
const Probe = struct {
    seen: *?Backing,
    in_place: *?bool,

    pub fn handle(self: *Probe, turn: *core.HostTurn, verb: []const u8, args: core.Args) !core.Value {
        self.seen.* = std.meta.activeTag(args.inner);
        if (!std.mem.eql(u8, verb, "report")) return error.NoSuchMethod;
        if ((try args.len()) != 3) return error.BadArguments;
        try std.testing.expectEqualStrings("readings", try args.string(0));
        try std.testing.expectEqual(@as(i64, 7), try args.int(2));
        try std.testing.expectError(error.WrongArgumentType, args.int(0));
        try std.testing.expectError(error.MissingArgument, args.int(3));
        const samples = try args.list(1);
        self.in_place.* = samples.inner == .views and samples.inner.views.args.typedRun() != null;
        var sum: i64 = 0;
        if (args.integers(1)) |run| {
            for (run) |sample| sum += sample;
        } else |err| switch (err) {
            // A capability among the samples only ever arrives lifted, and
            // the handler reads around it element by element.
            error.WrongArgumentType => for (0..try samples.len()) |i| {
                sum += samples.int(i) catch |inner| switch (inner) {
                    error.WrongArgumentType => blk: {
                        _ = try samples.capability(i);
                        break :blk 0;
                    },
                    else => return inner,
                };
            },
            else => return err,
        }
        if (args.inner == .values) turn.releaseValues(args.inner.values.items);
        return .{ .integer = sum };
    }
};

/// Shuttle the call and its reply across the pair without the harness
/// drain, which would consume the settled action this reads.
fn settledInteger(client: *core.Host, pair: h.Pair, vow: u64) !i64 {
    for (0..64) |_| {
        if (!try h.shuttleAll(&.{pair})) break;
    } else return error.PumpDidNotQuiesce;
    const action = while (try client.takeAction()) |action| {
        if (action == .settled and action.settled.vow_id == vow) break action;
        client.freeAction(action);
    } else return error.CompletionLost;
    defer client.freeAction(action);
    try client.vowRelease(vow);
    return action.settled.value.integer;
}

test "core host: a Value-shaped behavior reads a plain deliver as views and a capability deliver as values" {
    var client = test_host.init(a, @splat(0x71), core.Host.Options.withFrameCap(h.frame_cap));
    defer client.deinit();
    var server = test_host.init(a, @splat(0x72), core.Host.Options.withFrameCap(h.frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer dials.deinit(a);
    const pair = try h.openPair(a, &client, &server, "127.0.0.1:7931", &dials);
    var seen: ?Backing = null;
    var in_place: ?bool = null;
    _ = try pair.b.served.publish(&server.vat, "probe", core.Hosting(Probe), .{ .inner = .{ .seen = &seen, .in_place = &in_place } });
    const target = try client.enlivenCapability(a, h.tcpSturdyref("127.0.0.1:7931", "probe"));
    defer target.deinit();
    try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
    const probe = target.result().ready.capability;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var samples: [64]core.Value = undefined;
    for (&samples, 1..) |*sample, n| sample.* = .{ .integer = @intCast(n) };
    const plain = [_]core.Value{ .{ .string = "readings" }, .{ .list = &samples }, .{ .integer = 7 } };
    const first = try client.sendValues(pair.a, probe, "report", &plain, arena.allocator());
    try std.testing.expectEqual(@as(i64, 64 * 65 / 2), try settledInteger(&client, pair, first));
    try std.testing.expectEqual(Backing.views, seen.?);
    // Syrup's parsed batch fits a word run in the frame's existing head.
    try std.testing.expectEqual(@import("builtin").cpu.arch.endian() == .little, in_place.?);

    // The same call with a capability among the samples lifts the delivery
    // whole, so the capability arrives as one Host identity and every other
    // accessor answers as it did on the views.
    seen = null;
    var with_capability: [65]core.Value = undefined;
    @memcpy(with_capability[0..64], &samples);
    with_capability[64] = .{ .capability = probe };
    const carrying = [_]core.Value{ .{ .string = "readings" }, .{ .list = &with_capability }, .{ .integer = 7 } };
    const second = try client.sendValues(pair.a, probe, "report", &carrying, arena.allocator());
    try std.testing.expectEqual(@as(i64, 64 * 65 / 2), try settledInteger(&client, pair, second));
    try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expectEqual(Backing.values, seen.?);
}

test "core host: over the Cap'n Proto codec a list of integers is read where the frame holds it" {
    var opts = core.Host.Options.withFrameCap(h.frame_cap);
    opts.codec = .capnp;
    var client = test_host.init(a, @splat(0x73), opts);
    defer client.deinit();
    var server = test_host.init(a, @splat(0x74), opts);
    defer server.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer dials.deinit(a);
    const pair = try h.openPair(a, &client, &server, "127.0.0.1:7932", &dials);
    var seen: ?Backing = null;
    var in_place: ?bool = null;
    _ = try pair.b.served.publish(&server.vat, "probe", core.Hosting(Probe), .{ .inner = .{ .seen = &seen, .in_place = &in_place } });
    const target = try client.enlivenCapability(a, h.tcpSturdyref("127.0.0.1:7932", "probe"));
    defer target.deinit();
    try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
    const probe = target.result().ready.capability;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var samples: [64]core.Value = undefined;
    for (&samples, 1..) |*sample, n| sample.* = .{ .integer = @intCast(n) };
    const plain = [_]core.Value{ .{ .string = "readings" }, .{ .list = &samples }, .{ .integer = 7 } };
    const vow = try client.sendValues(pair.a, probe, "report", &plain, arena.allocator());
    try std.testing.expectEqual(@as(i64, 64 * 65 / 2), try settledInteger(&client, pair, vow));
    try std.testing.expectEqual(Backing.views, seen.?);
    try std.testing.expectEqual(true, in_place.?);
}

test "Args over owned values answers each accessor by arm" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const numbers = [_]core.Value{ .{ .integer = 4 }, .{ .integer = -5 } };
    const items = [_]core.Value{ .{ .integer = 3 }, .{ .list = &.{ .{ .string = "x" }, .{ .boolean = true } } }, .{ .bytes = "raw" }, .{ .list = &numbers } };
    const args: core.Args = .fromValues(&items, arena.allocator());
    try std.testing.expectEqual(@as(usize, 4), try args.len());
    try std.testing.expectEqual(@as(i64, 3), try args.int(0));
    try std.testing.expectEqualStrings("raw", try args.bytes(2));
    try std.testing.expectError(error.WrongArgumentType, args.string(0));
    try std.testing.expectError(error.WrongArgumentType, args.capability(0));
    try std.testing.expectError(error.MissingArgument, args.int(4));
    const inner = try args.list(1);
    try std.testing.expectEqualStrings("x", try inner.string(0));
    try std.testing.expect(try inner.boolean(1));
    try std.testing.expectError(error.WrongArgumentType, args.set(1));
    try std.testing.expectEqualSlices(i64, &.{ 4, -5 }, try args.integers(3));
    try std.testing.expectError(error.WrongArgumentType, args.integers(1));
    try std.testing.expectEqualSlices(core.Value, &items, try args.values());
    try std.testing.expectEqual(@as(i64, 3), (try args.value(0)).integer);
}
