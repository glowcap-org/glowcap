//! Encoders refuse a borrowed sequence whose length and walk disagree.
const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const dispatch = glowcap.ocapn.codec.dispatch;
const view = model.view;

fn Inconsistent(comptime Sequence: type) type {
    return struct {
        const Ctx = Sequence.Ctx;
        const table: Sequence.VTable = .{ .len = len, .at = at, .next = next, .tail = tail };

        fn len(ctx: Ctx) view.ProjectError!usize {
            return @intCast(ctx.w1);
        }

        fn at(ctx: Ctx, index: usize) view.ProjectError!Sequence.Elem {
            if (index >= ctx.w0) return error.MalformedView;
            return if (Sequence == view.PositionList)
                @intCast(index)
            else if (Sequence == view.Args)
                .{ .integer = @intCast(index) }
            else
                .{ .key = if (index == 0) "a" else "b", .value = .{ .integer = @intCast(index) } };
        }

        fn next(ctx: Ctx, cursor: *u64, out: *Sequence.Elem) view.ProjectError!bool {
            if (cursor.* >= ctx.w0) return false;
            out.* = try at(ctx, @intCast(cursor.*));
            cursor.* += 1;
            return true;
        }

        fn tail(_: Ctx, _: usize) view.ProjectError!Ctx {
            return error.MalformedView;
        }

        fn sequence(actual: usize, advertised: usize) Sequence {
            return .fromBacking(.{ .w0 = actual, .w1 = advertised }, &table);
        }
    };
}

fn expectRefused(codec: model.CodecId, profile: model.CaptpVersion, args: view.Args) !void {
    const body: view.Body = .{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(3) } },
        .args = args,
        .answer = .from(9),
    } };
    return expectBodyRefused(codec, profile, body);
}

fn expectBodyRefused(codec: model.CodecId, profile: model.CaptpVersion, body: view.Body) !void {
    if (dispatch.encodeBodyForProfile(codec, std.testing.allocator, profile, &body)) |encoded| {
        var frame = encoded;
        defer frame.deinit();
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.MalformedView, err);
    }
}

test "encoders refuse inconsistent borrowed sequence lengths" {
    for ([_]model.CodecId{ .capnp, .syrup }) |codec| {
        for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| {
            for (0..3) |actual| {
                for (0..3) |advertised| {
                    if (actual == advertised) continue;
                    const positions = Inconsistent(view.PositionList).sequence(actual, advertised);
                    try expectBodyRefused(codec, profile, .{ .gc_answer = .{ .positions = positions } });
                    try expectBodyRefused(codec, profile, .{ .gc_export = .{ .positions = .fromViews(&.{1}), .deltas = positions } });
                    const args = Inconsistent(view.Args).sequence(actual, advertised);
                    try expectRefused(codec, profile, args);
                    const containers = [_]view.Argument{
                        .{ .list = args },
                        .{ .set = args },
                        .{ .tagged = .{ .tag = "record", .value = args } },
                        .{ .@"struct" = Inconsistent(view.StructEntries).sequence(actual, advertised) },
                    };
                    for (containers) |arg| try expectRefused(codec, profile, .fromViews(&.{arg}));
                }
            }
        }
    }
}
