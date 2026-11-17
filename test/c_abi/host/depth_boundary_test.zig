//! The C boundary holds the nesting ceiling on every path a partner or the
//! application reaches: far send, send to a pending promise, and an inbound
//! deliver validated before the callback. A failure means a path admits or
//! refuses a depth the one counting rule (`model.max_value_depth`) does not.

const std = @import("std");
const c = @import("c_abi");
const cd = @import("c_abi_host");
const glowcap = @import("glowcap");
const h = @import("harness.zig");
const rig_owner = @import("capability_free_deliver_test.zig");

const model = glowcap.ocapn.model;
const Arg = c.GlowcapArgument;
const argInt = h.argInt;
const argBase = h.argBase;
const Rig = rig_owner.Rig;
const listOf = rig_owner.listOf;

const DepthShape = struct { name: []const u8, leaf: bool };
const depth_shapes = [_]DepthShape{
    .{ .name = "integer", .leaf = true },
    .{ .name = "run", .leaf = false },
    .{ .name = "empty run", .leaf = false },
    .{ .name = "list", .leaf = false },
    .{ .name = "empty list", .leaf = false },
    .{ .name = "struct", .leaf = false },
    .{ .name = "empty struct", .leaf = false },
};

/// `containers` lists around the shape's innermost node, which sits at that
/// depth. The words and entries live in the arena.
fn nestedArg(arena: std.mem.Allocator, shape: usize, containers: usize) !Arg {
    const words = try arena.dupe(i64, &.{7});
    const one = try arena.dupe(Arg, &.{argInt(7)});
    const entries = try arena.dupe(Arg, &.{ h.argStr("k"), argInt(7) });
    var tree = switch (shape) {
        0 => argInt(7),
        1, 2 => blk: {
            var run = argBase();
            run.kind = c.GLOWCAP_ARG_INTEGERS;
            run.bytes = @ptrCast(words.ptr);
            run.bytes_len = if (shape == 1) @sizeOf(i64) else 0;
            break :blk run;
        },
        3, 4 => try listOf(arena, c.GLOWCAP_ARG_LIST, if (shape == 3) one else &.{}),
        else => try listOf(arena, c.GLOWCAP_ARG_STRUCT, if (shape == 5) entries else &.{}),
    };
    for (0..containers) |_| tree = try listOf(arena, c.GLOWCAP_ARG_LIST, &.{tree});
    return tree;
}

fn expectNoOutbound(session: ?*cd.GlowcapHostSession) !void {
    var frame: c.GlowcapManagedFrame = undefined;
    try std.testing.expectEqual(c.GLOWCAP_ERR_WOULD_BLOCK, h.takeOutbound(session, &frame));
}

test "a C far send admits a leaf at the ceiling and refuses every container there, an empty one included, with nothing queued" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (depth_shapes, 0..) |shape, index| {
        for ([_]usize{ model.max_value_depth - 1, model.max_value_depth, model.max_value_depth + 1 }) |depth| {
            var rig: Rig = undefined;
            try rig.open(c.GLOWCAP_CODEC_SYRUP, 0x50, "127.0.0.1:7985", .forward);
            defer rig.deinit();
            const tree = try nestedArg(arena, index, depth);
            const admitted = if (shape.leaf) depth <= model.max_value_depth else depth < model.max_value_depth;
            var vow: u64 = std.math.maxInt(u64);
            const code = cd.glowcap_host_session_send(rig.pair.a, &rig.target, "call", 4, &[_]Arg{tree}, 1, &vow);
            if (admitted) {
                try h.expectOk(code);
                var frame: c.GlowcapManagedFrame = undefined;
                try h.expectOk(h.takeOutbound(rig.pair.a, &frame));
                c.glowcap_managed_frame_release(&frame);
            } else {
                try std.testing.expectEqual(@as(c_int, c.GLOWCAP_ERR_INVALID_ARGUMENT), code);
                // The code is coarse, so the cause is the last error's.
                var message: [64]u8 = undefined;
                const length = c.glowcap_last_error(&message, message.len);
                try std.testing.expectEqualStrings("host: ValueTooDeep", message[0..length]);
                try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), vow);
                try expectNoOutbound(rig.pair.a);
            }
        }
    }
}

/// A valid deliver frame with its single argument, the integer 1, rewritten to
/// sit `depth` lists down. The local send refuses a deeper tree at the call, so
/// only a rewritten wire frame lets validation see what a partner could send.
fn deepenedFrame(out: []u8, frame: []const u8, depth: usize) ![]const u8 {
    const prefix = "[4'call";
    const at = (std.mem.find(u8, frame, prefix ++ "1+]") orelse return error.FrameShapeChanged) + prefix.len;
    var len: usize = 0;
    @memcpy(out[len..][0..at], frame[0..at]);
    len += at;
    @memset(out[len..][0..depth], '[');
    len += depth;
    @memcpy(out[len..][0..2], "1+");
    len += 2;
    @memset(out[len..][0..depth], ']');
    len += depth;
    const rest = frame[at + 2 ..];
    @memcpy(out[len..][0..rest.len], rest);
    return out[0 .. len + rest.len];
}

test "a C host refuses an inbound deliver past the ceiling at validation, before the callback, and runs one at the ceiling" {
    for (model.max_value_depth - 1..model.max_value_depth + 2) |depth| {
        var rig: Rig = undefined;
        try rig.open(c.GLOWCAP_CODEC_SYRUP, 0x52, "127.0.0.1:7987", .forward);
        defer rig.deinit();
        var vow: u64 = undefined;
        try h.expectOk(cd.glowcap_host_session_send(rig.pair.a, &rig.target, "call", 4, &[_]Arg{argInt(1)}, 1, &vow));
        var frame: c.GlowcapManagedFrame = undefined;
        try h.expectOk(h.takeOutbound(rig.pair.a, &frame));
        defer c.glowcap_managed_frame_release(&frame);
        var buffer: [1024]u8 = undefined;
        const bytes = try deepenedFrame(&buffer, frame.bytes.?[0..frame.len], depth);
        const crafted: c.GlowcapFrame = .{ .bytes = bytes.ptr, .len = bytes.len, .shape = frame.shape };
        const code = cd.glowcap_host_session_feed(rig.pair.b, &crafted);
        if (depth <= model.max_value_depth) {
            try h.expectOk(code);
            try h.pump(&rig.hosts, &.{rig.pair}, &rig.dials, &rig.watches);
            try std.testing.expectEqual(@as(usize, 1), rig.tap.delivers);
        } else {
            try std.testing.expect(code != c.GLOWCAP_OK);
            try std.testing.expectEqual(@as(usize, 0), rig.tap.delivers);
            try std.testing.expectEqual(@as(usize, 0), rig.probe.calls);
        }
    }
}

/// The server's `make` verb answers with the tap, so a call pipelined on the
/// answer of `make` reaches the tap once `make` resolves.
fn makeBehavior(
    ctx: ?*anyopaque,
    _: ?*cd.GlowcapHostTurn,
    _: ?[*]const u8,
    _: usize,
    _: ?[*]const Arg,
    _: usize,
    out_reply: *Arg,
) callconv(.c) i32 {
    const tap: *const c.GlowcapReference = @ptrCast(@alignCast(ctx.?));
    out_reply.* = h.argRef(tap.*);
    return c.GLOWCAP_OK;
}

test "a C send to a pending promise admits a leaf at the ceiling and refuses every container there at the call" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (depth_shapes, 0..) |shape, index| {
        for ([_]usize{ model.max_value_depth - 1, model.max_value_depth, model.max_value_depth + 1 }) |depth| {
            var rig: Rig = undefined;
            try rig.open(c.GLOWCAP_CODEC_SYRUP, 0x51, "127.0.0.1:7986", .forward);
            defer rig.deinit();
            var make_local: c.GlowcapReference = undefined;
            try h.expectOk(cd.glowcap_host_session_publish(rig.pair.b, "make", 4, makeBehavior, &rig.tap_local, null, &make_local));
            var fetched = h.CapturedSettle{};
            var ticket: u64 = undefined;
            try h.expectOk(cd.glowcap_host_session_fetch(rig.pair.a, "make", 4, &ticket));
            rig.watches.add(rig.client(), ticket, &fetched);
            try h.pump(&rig.hosts, &.{rig.pair}, &rig.dials, &rig.watches);
            const make = try fetched.requireRef();
            // The first call is still unanswered when the second is sent, so
            // `first` is the pending promise the second pipelines on.
            var first: u64 = undefined;
            var first_settled = h.CapturedSettle{};
            try h.expectOk(cd.glowcap_host_session_send(rig.pair.a, &make, "make", 4, null, 0, &first));
            rig.watches.add(rig.client(), first, &first_settled);
            const tree = try nestedArg(arena, index, depth);
            const admitted = if (shape.leaf) depth <= model.max_value_depth else depth < model.max_value_depth;
            var second: u64 = std.math.maxInt(u64);
            const code = cd.glowcap_host_vow_send(rig.client(), first, "call", 4, &[_]Arg{tree}, 1, &second);
            if (admitted) {
                try h.expectOk(code);
                try std.testing.expect(second != std.math.maxInt(u64));
            } else {
                try std.testing.expectEqual(@as(c_int, c.GLOWCAP_ERR_INVALID_ARGUMENT), code);
                try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), second);
            }
            // Let `make` resolve to the tap. An admitted second send reaches it
            // once, and a refused one left nothing queued to reach it later.
            try h.pump(&rig.hosts, &.{rig.pair}, &rig.dials, &rig.watches);
            try std.testing.expect(first_settled.fired);
            try std.testing.expectEqual(.fulfilled, first_settled.kind);
            try std.testing.expectEqual(@as(usize, @intFromBool(admitted)), rig.tap.delivers);
            try expectNoOutbound(rig.pair.a);
        }
    }
}
