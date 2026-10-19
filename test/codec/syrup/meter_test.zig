//! The Syrup meter sizes an outbound tree where the session walks it, and
//! an encode given that size fills the bytes the measured encode fills
//! (ADR-0064). A size off by one is refused before any frame exists.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const syrup = glowcap.ocapn.codec.syrup;
const view = model.view;
const meter = syrup.meter.?;
const a = std.testing.allocator;

/// Size `message` as admission does: the walk's measure, each listed mention
/// after lowering, and the freight, then hold the sized encode to the
/// measured one.
fn expectSizedEqualsMeasured(message: model.Message, freight: ?view.Args) !void {
    var s = session.Session.init(a);
    defer s.deinit();
    const inventory = try s.inventoryMessage(message, meter);
    defer inventory.deinit(a);
    const root: ?*const model.Argument = if (message == .resolve and message.resolve.resolution == .fulfill)
        &message.resolve.resolution.fulfill
    else
        null;
    var values = inventory.wire_bytes;
    for (inventory.slots) |slot| values += try meter.mention(a, slot.read(root));
    var body = view.Body.fromOwned(&message);
    if (freight) |args| {
        values += (try s.certifyFreight(args, meter)).wire_bytes;
        body.deliver.args = args;
    }
    var measured = try syrup.encodeBodyForProfile(a, .v1_0, &body, null);
    defer measured.deinit();
    var sized = try syrup.encodeBodyForProfile(a, .v1_0, &body, values);
    defer sized.deinit();
    try std.testing.expectEqualSlices(u8, measured.bytes(), sized.bytes());
    try std.testing.expectError(error.EncoderInvariantViolation, syrup.encodeBodyForProfile(a, .v1_0, &body, values + 1));
    if (values > 0)
        try std.testing.expectError(error.EncoderInvariantViolation, syrup.encodeBodyForProfile(a, .v1_0, &body, values - 1));
}

test "a sized encode of every argument arm fills what the measured encode fills" {
    var set_items = [_]model.Argument{ .{ .integer = 9 }, .{ .integer = -12345 } };
    var entries = [_]model.StructEntry{
        .{ .key = "a", .value = .{ .set = &set_items } },
        .{ .key = "bb", .value = .{ .string = "héllo" } },
    };
    var tagged_items = [_]model.Argument{ .{ .boolean = true }, .{ .float64 = 1.5 }, .void, .{ .keyword = "k" } };
    var list_items = [_]model.Argument{
        .{ .@"struct" = &entries },
        .{ .bytes = &.{ 1, 2, 3 } },
        .{ .tagged = .{ .tag = "t", .value = &tagged_items } },
        .{ .@"error" = .{ .message = "boom" } },
        .{ .big_integer = .{ .negative = true, .digits = "123456789012345678901234567890" } },
        .{ .reference = .{ .near = .{ .export_position = .from(12) } } },
    };
    var args = [_]model.Argument{
        .{ .list = &list_items },
        .{ .reference = .{ .far = .{ .import_position = .from(7) } } },
        .{ .reference = .{ .promise = .{ .answer_position = .from(300) } } },
        .{ .symbol = "greet" },
        .{ .string = "" },
        .{ .list = &.{} },
    };
    const target: model.Reference = .{ .far = .{ .import_position = .from(1) } };
    try expectSizedEqualsMeasured(.{ .deliver = .{ .target = target, .args = &args, .answer = .from(4) } }, null);
    try expectSizedEqualsMeasured(.{ .deliver = .{ .target = target, .args = &.{} } }, null);
    try expectSizedEqualsMeasured(.{ .resolve = .{ .answer = .from(2), .resolution = .{ .fulfill = .{ .list = &args } } } }, null);
    try expectSizedEqualsMeasured(.{ .resolve = .{ .answer = .from(2), .resolution = .{ .fulfill = .{ .reference = .{ .far = .{ .import_position = .from(9) } } } } } }, null);
    try expectSizedEqualsMeasured(.{ .resolve = .{ .answer = .from(3), .resolution = .{ .@"break" = .{ .message = "no" } } } }, null);
}

test "a sized encode of freight fills what the measured encode fills" {
    const target: model.Reference = .{ .far = .{ .import_position = .from(1) } };
    var inner = [_]view.Argument{ .{ .integer = -7 }, .{ .string = "x" } };
    var struct_entries = [_]view.StructEntry{.{ .key = "key", .value = .{ .list = .fromViews(&inner) } }};
    var views = [_]view.Argument{
        .{ .symbol = "s" },
        .{ .@"struct" = .fromViews(&struct_entries) },
        .{ .set = .fromViews(&inner) },
        .{ .tagged = .{ .tag = "tag", .value = .fromViews(&inner) } },
        .{ .bytes = "raw" },
        .{ .keyword = "kw" },
        .{ .float64 = -0.25 },
        .void,
    };
    try expectSizedEqualsMeasured(.{ .deliver = .{ .target = target, .args = &.{} } }, .fromViews(&views));
    var run: [24]u8 align(8) = undefined;
    for ([_]i64{ 0, -1, 1_000_000_000_000 }, 0..) |word, i| std.mem.writeInt(i64, run[i * 8 ..][0..8], word, .little);
    try expectSizedEqualsMeasured(.{ .deliver = .{ .target = target, .args = &.{} } }, .fromRun(&run));
}
