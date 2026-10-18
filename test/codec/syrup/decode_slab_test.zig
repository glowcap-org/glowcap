//! What Syrup decode does with room lent for the argument tree (ADR-0222,
//! ADR-0231): a sequence that fits is parsed once into the views, nested
//! sequences included, a longer one drops what it pushed and stays
//! wire-backed, and a malformed element is refused the same way either way.
//! The views and the wire backing read the same message.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const view = model.view;
const syrup = glowcap.ocapn.codec.syrup;
const messagesEqual = @import("../../support/message_equality.zig").messagesEqual;

const three_args = "<10'op:deliver<11'desc:export7+>[5'greet5\"world3+]11+f>";
const five_args = "<10'op:deliver<11'desc:export7+>[5'greet5\"world3+tf]11+f>";
const nested_args = "<10'op:deliver<11'desc:export7+>[5'greet[1+t]{3\"key5\"value}]11+f>";

fn expectSameMessage(bytes: []const u8, slab: *view.ValueSlab) !void {
    const allocator = std.testing.allocator;
    const plain = try (try syrup.decodeBody(.{ .bytes = bytes, .shape = .byte })).toOwned(allocator);
    defer model.freeMessage(allocator, plain);
    var lent_body: view.Body = undefined;
    try syrup.decodeBodyInto(.v1_0, .{ .bytes = bytes, .shape = .byte }, slab, &lent_body);
    const lent = try lent_body.toOwned(allocator);
    defer model.freeMessage(allocator, lent);
    try std.testing.expect(messagesEqual(plain, lent));
}

test "an argument list that fits the room is parsed once into the views" {
    var views: [4]view.Argument = undefined;
    var slab = view.ValueSlab.init(std.mem.sliceAsBytes(&views));
    var body: view.Body = undefined;
    try syrup.decodeBodyInto(.v1_0, .{ .bytes = three_args, .shape = .byte }, &slab, &body);
    try std.testing.expectEqual(@as(usize, 3) * @sizeOf(model.view.Argument), slab.used);
    try std.testing.expectEqual(@as(usize, 3), try body.deliver.args.len());
    // The views are the list's backing: the first element is the view written
    // to the slab, not a fresh parse of the bytes.
    try std.testing.expectEqualStrings("greet", (try body.deliver.args.at(0)).symbol);
    try std.testing.expectEqualStrings("greet", views[0].symbol);
    try std.testing.expectEqual(@as(i64, 3), (try body.deliver.args.at(2)).integer);
    try expectSameMessage(three_args, &slab);
}

test "an argument list longer than the room stays wire-backed and reads the same" {
    var views: [4]view.Argument = undefined;
    var slab = view.ValueSlab.init(std.mem.sliceAsBytes(&views));
    var body: view.Body = undefined;
    try syrup.decodeBodyInto(.v1_0, .{ .bytes = five_args, .shape = .byte }, &slab, &body);
    try std.testing.expectEqual(@as(usize, 0) * @sizeOf(model.view.Argument), slab.used);
    try std.testing.expectEqual(@as(usize, 5), try body.deliver.args.len());
    try std.testing.expect((try body.deliver.args.at(4)).boolean == false);
    try expectSameMessage(five_args, &slab);
}

test "a second list on the same slab takes the room the first left" {
    var views: [4]view.Argument = undefined;
    var slab = view.ValueSlab.init(std.mem.sliceAsBytes(&views));
    var taken: view.Body = undefined;
    try syrup.decodeBodyInto(.v1_0, .{ .bytes = three_args, .shape = .byte }, &slab, &taken);
    try std.testing.expectEqual(@as(usize, 3) * @sizeOf(model.view.Argument), slab.used);
    // Three views are taken, one is left, so a three-element list no longer fits.
    var again: view.Body = undefined;
    try syrup.decodeBodyInto(.v1_0, .{ .bytes = three_args, .shape = .byte }, &slab, &again);
    try std.testing.expectEqual(@as(usize, 3) * @sizeOf(model.view.Argument), slab.used);
    try std.testing.expectEqual(@as(usize, 3), try again.deliver.args.len());
    try std.testing.expectEqualStrings("world", (try again.deliver.args.at(1)).string);
}

test "nested lists and structs settle into views below their parent" {
    var views: [8]view.Argument = undefined;
    var slab = view.ValueSlab.init(std.mem.sliceAsBytes(&views));
    var body: view.Body = undefined;
    try syrup.decodeBodyInto(.v1_0, .{ .bytes = nested_args, .shape = .byte }, &slab, &body);
    // Two inner values, one struct entry, and three outer values.
    try std.testing.expectEqual(@as(usize, 5) * @sizeOf(model.view.Argument) + @sizeOf(view.StructEntry), slab.used);
    try std.testing.expectEqual(@as(usize, 8) * @sizeOf(model.view.Argument), slab.open);
    try std.testing.expect(body.deliver.args.backingViews() != null);
    const inner = (try body.deliver.args.at(1)).list;
    try std.testing.expect(inner.backingViews() != null);
    try std.testing.expectEqual(@as(usize, 2), try inner.len());
    try std.testing.expectEqual(@as(i64, 1), (try inner.at(0)).integer);
    try std.testing.expect((try inner.at(1)).boolean);
    try std.testing.expect((try body.deliver.args.at(2)).@"struct".backingViews() != null);
    try expectSameMessage(nested_args, &slab);
}

test "a nested list the room cannot hold leaves its parent wire-backed too" {
    // Four views: the outer list pushes `greet`, the inner list settles two,
    // the outer pushes the inner's view, and the struct finds no room.
    var views: [4]view.Argument = undefined;
    var slab = view.ValueSlab.init(std.mem.sliceAsBytes(&views));
    var body: view.Body = undefined;
    try syrup.decodeBodyInto(.v1_0, .{ .bytes = nested_args, .shape = .byte }, &slab, &body);
    try std.testing.expect(body.deliver.args.backingViews() == null);
    try std.testing.expectEqual(@as(usize, 3), try body.deliver.args.len());
    try std.testing.expect((try (try body.deliver.args.at(1)).list.at(1)).boolean);
    // The abandoned inner views and the collection stack are reclaimed.
    try std.testing.expectEqual(@as(usize, 0), slab.used);
    try std.testing.expectEqual(@as(usize, 4) * @sizeOf(model.view.Argument), slab.open);
    try expectSameMessage(nested_args, &slab);
}

test "a list that exactly fills the room settles in push order" {
    var views: [3]view.Argument = undefined;
    var slab = view.ValueSlab.init(std.mem.sliceAsBytes(&views));
    var body: view.Body = undefined;
    try syrup.decodeBodyInto(.v1_0, .{ .bytes = three_args, .shape = .byte }, &slab, &body);
    try std.testing.expect(body.deliver.args.backingViews() != null);
    try std.testing.expectEqual(@as(usize, 3) * @sizeOf(model.view.Argument), slab.used);
    try std.testing.expectEqual(@as(usize, 3) * @sizeOf(model.view.Argument), slab.open);
    try std.testing.expectEqualStrings("greet", views[0].symbol);
    try std.testing.expectEqualStrings("world", views[1].string);
    try std.testing.expectEqual(@as(i64, 3), views[2].integer);
    try expectSameMessage(three_args, &slab);
}

test "a set and a tagged value settle into views and keep their order check" {
    const set_and_tagged = "<10'op:deliver<11'desc:export7+>[#1+2+$<11'user-record3'tag[1+t]>]11+f>";
    var views: [8]view.Argument = undefined;
    var slab = view.ValueSlab.init(std.mem.sliceAsBytes(&views));
    var body: view.Body = undefined;
    try syrup.decodeBodyInto(.v1_0, .{ .bytes = set_and_tagged, .shape = .byte }, &slab, &body);
    try std.testing.expectEqual(@as(usize, 6) * @sizeOf(model.view.Argument), slab.used);
    const set = (try body.deliver.args.at(0)).set;
    try std.testing.expect(set.backingViews() != null);
    try std.testing.expectEqual(@as(i64, 2), (try set.at(1)).integer);
    const tagged = (try body.deliver.args.at(1)).tagged;
    try std.testing.expectEqualStrings("tag", tagged.tag);
    try std.testing.expect(tagged.value.backingViews() != null);
    try std.testing.expect((try tagged.value.at(1)).boolean);
    try expectSameMessage(set_and_tagged, &slab);

    const unordered = "<10'op:deliver<11'desc:export7+>[#2+1+$]11+f>";
    var again = view.ValueSlab.init(std.mem.sliceAsBytes(&views));
    var refused: view.Body = undefined;
    try std.testing.expectError(error.MalformedFrame, syrup.decodeBodyInto(.v1_0, .{ .bytes = unordered, .shape = .byte }, &again, &refused));
}

test "a malformed element is refused the same way with and without room" {
    // The string's length runs over the closing bracket, so the next byte
    // the walk sees is not an argument.
    const malformed = "<10'op:deliver<11'desc:export7+>[5'greet5\"wor]11+f>";
    var views: [4]view.Argument = undefined;
    var slab = view.ValueSlab.init(std.mem.sliceAsBytes(&views));
    const plain = syrup.decodeBody(.{ .bytes = malformed, .shape = .byte });
    var lent_body: view.Body = undefined;
    const lent = syrup.decodeBodyInto(.v1_0, .{ .bytes = malformed, .shape = .byte }, &slab, &lent_body);
    try std.testing.expectError(error.UnsupportedArgument, plain);
    try std.testing.expectError(error.UnsupportedArgument, lent);
    try std.testing.expectEqual(@as(usize, 0) * @sizeOf(model.view.Argument), slab.used);
}

test "an empty slab lends nothing and every list stays wire-backed" {
    var slab = view.ValueSlab.empty;
    var body: view.Body = undefined;
    try syrup.decodeBodyInto(.v1_0, .{ .bytes = three_args, .shape = .byte }, &slab, &body);
    try std.testing.expectEqual(@as(usize, 0) * @sizeOf(model.view.Argument), slab.used);
    try std.testing.expectEqual(@as(usize, 3), try body.deliver.args.len());
}

test "a decoded integer batch lends bounded word storage without changing its value" {
    const wire = "<10'op:deliver<11'desc:export7+>[[0+1+2+3+4+5+6+7+8+9+9223372036854775808-9223372036854775807+]]ff>";
    for (0..18) |capacity| {
        var views: [17]view.Argument = undefined;
        var slab = view.ValueSlab.init(std.mem.sliceAsBytes(views[0..capacity]));
        var body: view.Body = undefined;
        try syrup.decodeBodyInto(.v1_0, .{ .bytes = wire, .shape = .byte }, &slab, &body);
        const list = (try body.deliver.args.at(0)).list;
        if (capacity >= 3) try std.testing.expect(list.wordRun() != null);
        try std.testing.expectEqual(@as(usize, 12), try list.len());
        try std.testing.expectEqual(std.math.minInt(i64), (try list.at(10)).integer);
        try std.testing.expectEqual(std.math.maxInt(i64), (try list.at(11)).integer);
        try std.testing.expectEqual(capacity * @sizeOf(view.Argument), slab.open);
        try std.testing.expect(slab.used <= capacity * @sizeOf(view.Argument));
        var fresh = view.ValueSlab.init(std.mem.sliceAsBytes(views[0..capacity]));
        try expectSameMessage(wire, &fresh);
    }
}

test "decoding integers leaves a live parent and a mixed sibling intact" {
    const wire = "<10'op:deliver<11'desc:export7+>[4'keep[0+1+2+3+4+5+6+7+8+9+10+11+][0+1+2+3+4+5+6+7+8+9+f]4'done]ff>";
    for (0..41) |capacity| {
        var views: [40]view.Argument = undefined;
        var slab = view.ValueSlab.init(std.mem.sliceAsBytes(views[0..capacity]));
        var body: view.Body = undefined;
        try syrup.decodeBodyInto(.v1_0, .{ .bytes = wire, .shape = .byte }, &slab, &body);
        try std.testing.expectEqualStrings("keep", (try body.deliver.args.at(0)).symbol);
        if (capacity == views.len) try std.testing.expect((try body.deliver.args.at(1)).list.wordRun() != null);
        const mixed = (try body.deliver.args.at(2)).list;
        try std.testing.expect(mixed.wordRun() == null);
        try std.testing.expect(!(try mixed.at(10)).boolean);
        try std.testing.expectEqualStrings("done", (try body.deliver.args.at(3)).symbol);
        var fresh = view.ValueSlab.init(std.mem.sliceAsBytes(views[0..capacity]));
        try expectSameMessage(wire, &fresh);
    }
}

test "an integer run attempt preserves big integers and malformed refusal" {
    const prefix = "<10'op:deliver<11'desc:export7+>[[0+1+2+3+4+5+6+7+8+9+";
    const valid = prefix ++ "18446744073709551616+]]ff>";
    var views: [32]view.Argument = undefined;
    var slab = view.ValueSlab.init(std.mem.sliceAsBytes(&views));
    try expectSameMessage(valid, &slab);
    const bad = [_][]const u8{
        prefix ++ "00+]]ff>",
        prefix ++ "0-]]ff>",
        prefix ++ "1x]]ff>",
        prefix ++ "9223372036854775808-",
        prefix ++ "]]ff",
    };
    for (bad) |wire| {
        var fresh = view.ValueSlab.init(std.mem.sliceAsBytes(&views));
        const plain = syrup.decodeBody(.{ .bytes = wire, .shape = .byte });
        var lent_body: view.Body = undefined;
        const lent = syrup.decodeBodyInto(.v1_0, .{ .bytes = wire, .shape = .byte }, &fresh, &lent_body);
        if (plain) |_| return error.TestUnexpectedResult else |err| {
            try std.testing.expectError(err, lent);
        }
        try std.testing.expect(fresh.used <= fresh.open);
    }
}

test "short integer lists use the same word storage as larger batches" {
    var integers: [12]model.Argument = undefined;
    for (&integers, 0..) |*arg, i| arg.* = .{ .integer = @intCast(i) };
    for (1..integers.len + 1) |count| {
        const args = [_]model.Argument{.{ .list = integers[0..count] }};
        var frame = try syrup.encodeMessage(std.testing.allocator, .{ .deliver = .{
            .target = .{ .far = model.FarRef.object(7) },
            .args = &args,
        } });
        defer frame.deinit();
        var views: [16]view.Argument = undefined;
        var slab = view.ValueSlab.init(std.mem.sliceAsBytes(&views));
        var body: view.Body = undefined;
        try syrup.decodeBodyInto(.v1_0, frame.view(), &slab, &body);
        const run = (try body.deliver.args.at(0)).list;
        try std.testing.expect(run.wordRun() != null);
        try std.testing.expectEqual(count, try run.len());
        for (0..count) |i| try std.testing.expectEqual(@as(i64, @intCast(i)), (try run.at(i)).integer);
    }
}

test "abandoned child storage is reclaimed without touching earlier or later siblings" {
    const bodies = [_][]const u8{
        "[[0+1+]tftftftf]",
        "{1\"a[0+1+]1\"bt1\"cf1\"dt}",
    };
    for (bodies) |middle| {
        const wire = try std.fmt.allocPrint(std.testing.allocator, "<10'op:deliver<11'desc:export7+>[[tf]{s}[ft]]ff>", .{middle});
        defer std.testing.allocator.free(wire);
        var storage: [7]view.Argument = undefined;
        var slab = view.ValueSlab.init(std.mem.sliceAsBytes(&storage));
        var body: view.Body = undefined;
        try syrup.decodeBodyInto(.v1_0, .{ .bytes = wire, .shape = .byte }, &slab, &body);
        const args = body.deliver.args;
        try std.testing.expect(args.backingViews() != null);
        const first = (try args.at(0)).list;
        const abandoned = try args.at(1);
        const last = (try args.at(2)).list;
        try std.testing.expect(first.backingViews() != null);
        try std.testing.expect(last.backingViews() != null);
        try std.testing.expect((try first.at(0)).boolean);
        try std.testing.expect(!(try first.at(1)).boolean);
        try std.testing.expect(!(try last.at(0)).boolean);
        try std.testing.expect((try last.at(1)).boolean);
        switch (abandoned) {
            .list => |items| try std.testing.expect(items.backingViews() == null),
            .@"struct" => |items| try std.testing.expect(items.backingViews() == null),
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(@sizeOf(@TypeOf(storage)), slab.used);
        var fresh = view.ValueSlab.init(std.mem.sliceAsBytes(&storage));
        try expectSameMessage(wire, &fresh);
    }
}
