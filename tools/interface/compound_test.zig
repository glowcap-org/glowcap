//! Normalized compound graph identity, resource bounds, and explicit refusal.
const std = @import("std");
const description = @import("description.zig");
const Model = @import("model.zig").Model;
const calls = @import("calls.zig");
const rust = @import("callbacks.zig");
const ts = @import("typescript.zig");

test "Observation graph preserves positional tag and schema bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model = try Model.init(a, try description.read(a, @embedFile("contract")));
    const call = try calls.read(&model, "loam.Receiver", "poll");
    const again = try calls.read(&model, "loam.Receiver", "receive");
    try std.testing.expect(call.result.record == again.result.record);
    const record = call.result.record;
    try std.testing.expectEqualStrings("access:observation", record.tag);
    try std.testing.expectEqual(@as(usize, 5), record.fields.len);
    try std.testing.expectEqual(@as(u64, 56), record.fields[0].bytes.min);
    try std.testing.expectEqual(@as(?u64, 56), record.fields[0].bytes.max);
    try std.testing.expect(record.fields[1] == .value and record.fields[2] == .boolean and record.fields[3] == .boolean);
    try std.testing.expect(record.fields[4].list.element == .symbol);
    try std.testing.expectEqual(@as(?u64, null), record.fields[4].list.max_items);
    try std.testing.expectError(error.UnsupportedProjection, ts.emit(a, &.{.{ .api = "poll", .call = call }}));
    for ([_][]const u8{ "Session", "Ref", "Argument", "DecodeBudget" }) |name| {
        const code = try rust.emit(a, &.{.{ .api = "poll", .call = call }}, &.{.{ .api = name, .kind = call.result }});
        try std.testing.expect(std.mem.indexOf(u8, code, "pub struct ProjectedType0(") != null);
    }
    for ([_][]const u8{ "Pending", "poll", "Error" }) |name| {
        try std.testing.expectError(error.ExportCollision, rust.emit(a, &.{.{ .api = "poll", .call = call }}, &.{.{ .api = name, .kind = call.result }}));
    }
}

test "productive copied recursion is validated but refused for projection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model = try Model.init(a, try description.read(a, "<17'glowcap:interface1+{14\"glowcap.values1+}{1\"A<4'type<4'list<3'ref1\"A>>>}>"));
    try std.testing.expectError(error.UnsupportedProjection, model.callType(try description.read(a, "<3'ref1\"A>")));
    try std.testing.expectError(error.InvalidDescription, Model.init(a, try description.read(a, "<17'glowcap:interface1+{14\"glowcap.values1+}{1\"A<4'type<3'ref1\"B>>1\"B<4'type<3'ref1\"A>>}>")));
}

test "normalization budgets aliases and memoizes repeated copied structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Node = description.Node;
    var model = try doublingModel(a, 70);
    const definitions = model.definitions.children;
    const reference: Node = .{ .kind = .record, .bytes = "ref", .children = definitions[40..41] };
    const kind = try model.callType(reference);
    try std.testing.expect(kind.tuple.fields[0].tuple == kind.tuple.fields[1].tuple);
    const deep: Node = .{ .kind = .record, .bytes = "ref", .children = definitions[138..139] };
    try std.testing.expectError(error.ResourceLimit, model.callType(deep));
    model.remaining = 0;
    try std.testing.expectError(error.ResourceLimit, model.callType(reference));
}

fn doublingModel(a: std.mem.Allocator, count: usize) !Model {
    const Node = description.Node;
    const definitions = try a.alloc(Node, 2 * count);
    for (0..count) |i| {
        definitions[2 * i] = .{ .kind = .string, .bytes = try std.fmt.allocPrint(a, "T{d}", .{i}) };
        const expression: Node = if (i == 0) .{ .kind = .symbol, .bytes = "bool" } else blk: {
            const fields = try a.alloc(Node, 1);
            fields[0] = definitions[2 * (i - 1)];
            const reference: Node = .{ .kind = .record, .bytes = "ref", .children = fields };
            const members = try a.dupe(Node, &.{ reference, reference });
            const list = try a.dupe(Node, &.{.{ .kind = .list, .children = members }});
            break :blk .{ .kind = .record, .bytes = "tuple", .children = list };
        };
        definitions[2 * i + 1] = .{ .kind = .record, .bytes = "type", .children = try a.dupe(Node, &.{expression}) };
    }
    const profiles: Node = .{ .kind = .dictionary, .children = &.{ .{ .kind = .string, .bytes = "glowcap.values" }, .{ .kind = .integer, .integer = 1 } } };
    const root: Node = .{ .kind = .record, .bytes = "glowcap:interface", .children = &.{ .{ .kind = .integer, .integer = 1 }, profiles, .{ .kind = .dictionary, .children = definitions } } };
    return Model.init(a, root);
}

test "Rust refuses compact aliases with excessive inline structure before emission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model = try doublingModel(a, 31);
    const kind = try model.callType(try description.read(a, "<3'ref3\"T30>"));
    const call: calls.Call = .{ .wire_name = "read", .parameters = &.{}, .required_parameters = 0, .result = kind, .effect = .call };
    try std.testing.expectError(error.ResourceLimit, rust.emit(a, &.{.{ .api = "read", .call = call }}, &.{}));
}

test "Rust inline structure admission includes the container and every emitted list element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const types = @import("call_type.zig");
    const maximum = @import("compound_graph.zig").max_inline_structure;
    const fields = try a.alloc(calls.Type, maximum);
    @memset(fields, .boolean);
    for ([_]usize{ maximum - 1, maximum }) |count| {
        const tuple = try a.create(types.Tuple);
        tuple.* = .{ .fields = fields[0..count] };
        const record = try a.create(types.Record);
        record.* = .{ .tag = "exact:record", .fields = fields[0..count] };
        for ([_]calls.Type{ .{ .tuple = tuple }, .{ .record = record } }) |kind| {
            const list = try a.create(types.List);
            list.* = .{ .element = kind };
            for ([_]calls.Type{ kind, .{ .list = list } }) |result| {
                const call: calls.Call = .{ .wire_name = "read", .parameters = &.{}, .required_parameters = 0, .result = result, .effect = .call };
                if (count == maximum - 1) {
                    _ = try rust.emit(a, &.{.{ .api = "read", .call = call }}, &.{});
                } else try std.testing.expectError(error.ResourceLimit, rust.emit(a, &.{.{ .api = "read", .call = call }}, &.{}));
            }
        }
    }
}
