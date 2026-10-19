//! What a session certifies in a borrowed outbound tree, freight, before
//! the encoder reads it (ADR-0064): the nesting bound the owned inventory
//! applies, set and struct-key uniqueness, the refusal of any reference or
//! handoff, and the measure an owned copy of the tree would retain.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const NoMeter = session.inventory.NoMeter;
const view = model.view;
const a = std.testing.allocator;

fn Mismatched(comptime Sequence: type) type {
    return struct {
        const table: Sequence.VTable = .{ .len = len, .at = at, .next = next, .tail = tail };
        fn len(ctx: Sequence.Ctx) view.ProjectError!usize {
            return @intCast(ctx.w0);
        }
        fn at(_: Sequence.Ctx, _: usize) view.ProjectError!Sequence.Elem {
            return if (Sequence == view.Args) .{ .integer = 1 } else .{ .key = "k", .value = .{ .integer = 1 } };
        }
        fn next(ctx: Sequence.Ctx, cursor: *u64, out: *Sequence.Elem) view.ProjectError!bool {
            if (cursor.* == ctx.w1) return false;
            out.* = try at(ctx, 0);
            cursor.* += 1;
            return true;
        }
        fn tail(_: Sequence.Ctx, _: usize) view.ProjectError!Sequence.Ctx {
            return error.MalformedView;
        }
    };
}

test "freight refuses inconsistent lengths in every nested collection" {
    var s = session.Session.init(a);
    defer s.deinit();
    for ([_][2]u64{ .{ 0, 1 }, .{ 1, 0 }, .{ 1, 2 }, .{ 2, 1 } }) |counts| {
        const ctx: view.Args.Ctx = .{ .w0 = counts[0], .w1 = counts[1] };
        const args = view.Args.fromBacking(ctx, &Mismatched(view.Args).table);
        const entries = view.StructEntries.fromBacking(ctx, &Mismatched(view.StructEntries).table);
        const containers = [_]view.Argument{
            .{ .list = args }, .{ .set = args }, .{ .tagged = .{ .tag = "t", .value = args } }, .{ .@"struct" = entries },
        };
        for (containers) |container| {
            try std.testing.expectError(error.MalformedView, s.certifyFreight(.fromViews(&.{container}), NoMeter));
        }
    }
}

test "freight refuses an overflowing virtual owned run charge without reading words" {
    var s = session.Session.init(a);
    defer s.deinit();
    // Certification measures integer runs without dereferencing their bytes.
    // A synthetic length reaches the overflow on either pointer width without
    // allocating hundreds of megabytes (32-bit) or exabytes (64-bit).
    const count = std.math.maxInt(usize) / @sizeOf(model.Argument) + 1;
    const ptr: [*]const u8 = @ptrFromInt(8);
    const run = view.Args.fromRun(ptr[0 .. count * 8]);
    try std.testing.expectError(error.MalformedView, s.certifyFreight(run, NoMeter));
}

test "freight refuses a reference or handoff anywhere in the tree" {
    var s = session.Session.init(a);
    defer s.deinit();
    const far = [_]view.Argument{.{ .reference = .{ .far = .{ .import_position = .from(3) } } }};
    try std.testing.expectError(session.Error.MalformedMessage, s.certifyFreight(.fromViews(&far), NoMeter));
    const nested = [_]view.Argument{ .{ .integer = 1 }, .{ .list = .fromViews(&far) } };
    try std.testing.expectError(session.Error.MalformedMessage, s.certifyFreight(.fromViews(&nested), NoMeter));
}

test "freight and an owned tree refuse at the same nesting depth" {
    var s = session.Session.initWith(a, .{ .limits = .{ .max_nesting_depth = 3 } });
    defer s.deinit();
    // Four nested lists sit at depths 1 to 4 around the leaf.
    const leaf = [_]model.Argument{.{ .integer = 1 }};
    const d4 = [_]model.Argument{.{ .list = &leaf }};
    const d3 = [_]model.Argument{.{ .list = &d4 }};
    const d2 = [_]model.Argument{.{ .list = &d3 }};
    const d1 = [_]model.Argument{.{ .list = &d2 }};
    const leaf_v = [_]view.Argument{.{ .integer = 1 }};
    const d4_v = [_]view.Argument{.{ .list = .fromViews(&leaf_v) }};
    const d3_v = [_]view.Argument{.{ .list = .fromViews(&d4_v) }};
    const d2_v = [_]view.Argument{.{ .list = .fromViews(&d3_v) }};
    const d1_v = [_]view.Argument{.{ .list = .fromViews(&d2_v) }};

    try std.testing.expectError(session.Error.NestingTooDeep, s.inventoryArguments(&d1, NoMeter));
    try std.testing.expectError(session.Error.NestingTooDeep, s.certifyFreight(.fromViews(&d1_v), NoMeter));
    const ok = try s.inventoryArguments(&d2, NoMeter);
    ok.deinit(a);
    _ = try s.certifyFreight(.fromViews(&d2_v), NoMeter);
}

test "freight refuses a duplicate set element and a duplicate struct key" {
    var s = session.Session.init(a);
    defer s.deinit();
    const twice = [_]view.Argument{ .{ .integer = 7 }, .{ .string = "x" }, .{ .integer = 7 } };
    const set = [_]view.Argument{.{ .set = .fromViews(&twice) }};
    try std.testing.expectError(session.Error.DuplicateSetElement, s.certifyFreight(.fromViews(&set), NoMeter));
    const entries = [_]view.StructEntry{
        .{ .key = "a", .value = .{ .integer = 1 } },
        .{ .key = "b", .value = .{ .integer = 2 } },
        .{ .key = "a", .value = .{ .integer = 3 } },
    };
    const record = [_]view.Argument{.{ .@"struct" = .fromViews(&entries) }};
    try std.testing.expectError(session.Error.DuplicateStructKey, s.certifyFreight(.fromViews(&record), NoMeter));
    const distinct = [_]view.StructEntry{ entries[0], entries[1] };
    const fine = [_]view.Argument{ .{ .set = .fromViews(twice[0..2]) }, .{ .@"struct" = .fromViews(&distinct) } };
    _ = try s.certifyFreight(.fromViews(&fine), NoMeter);
}

test "freight measures what the owned model measures" {
    var s = session.Session.init(a);
    defer s.deinit();
    var set_items = [_]model.Argument{ .{ .integer = 9 }, .{ .bytes = "raw" } };
    var entries = [_]model.StructEntry{
        .{ .key = "a", .value = .{ .set = &set_items } },
        .{ .key = "bb", .value = .{ .string = "hello" } },
    };
    var tagged_items = [_]model.Argument{.{ .keyword = "k" }};
    var list_items = [_]model.Argument{
        .{ .@"struct" = &entries },
        .{ .bytes = &.{ 1, 2, 3 } },
        .{ .tagged = .{ .tag = "t", .value = &tagged_items } },
        .{ .@"error" = .{ .message = "oops" } },
    };
    var args = [_]model.Argument{ .{ .list = &list_items }, .{ .symbol = "greet" }, .{ .float64 = 1.5 } };
    try std.testing.expectEqual(
        try model.measureArgumentSliceOwnedBytes(&args),
        (try s.certifyFreight(.fromOwnedSlice(&args), NoMeter)).owned_bytes,
    );
}
