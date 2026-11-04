//! Bounded read projections preserve constraints or refuse the target explicitly.
const std = @import("std");
const calls = @import("calls.zig");
const description = @import("description.zig");
const Model = @import("model.zig").Model;
const rust = @import("callbacks.zig");
const ts = @import("typescript.zig");

test "unmigrated TypeScript refuses bounded text and integer inputs and replies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model = try Model.init(a, try description.read(a, @embedFile("contract")));
    for ([_]struct { []const u8, []const u8 }{
        .{ "tasks.Board", "list" },     .{ "tasks.TaskList", "name" },
        .{ "tasks.TaskList", "count" }, .{ "tasks.Task", "text" },
    }) |method| {
        const call = try calls.read(&model, method[0], method[1]);
        try std.testing.expectError(error.UnsupportedTarget, ts.emit(a, &.{.{ .api = "read", .call = call }}));
    }
    const call = try calls.read(&model, "fixture.Reader", "read");
    const source = try ts.emit(a, &.{.{ .api = "read", .call = call }});
    try std.testing.expect(std.mem.indexOf(u8, source, "Pending<string>") != null);
}

test "Rust refuses bare and partial integer projections without narrowing them" {
    for ([_]calls.Type{
        .{ .integer = .{} }, .{ .integer = .{ .min = 0 } }, .{ .integer = .{ .max = 256 } },
    }) |integer| {
        const call: calls.Call = .{ .wire_name = "read", .parameters = &.{}, .required_parameters = 0, .result = integer, .effect = .call };
        try std.testing.expectError(error.UnsupportedTarget, rust.emit(std.testing.allocator, &.{.{ .api = "read", .call = call }}, &.{}));
    }
}

test "bounded reply helpers deduplicate normalized types and name signed extrema" {
    const call: calls.Call = .{
        .wire_name = "read",
        .parameters = &.{},
        .required_parameters = 0,
        .result = .{ .integer = .{ .min = std.math.minInt(i64), .max = std.math.maxInt(i64) } },
        .effect = .call,
    };
    const source = try rust.emit(std.testing.allocator, &.{ .{ .api = "first", .call = call }, .{ .api = "second", .call = call } }, &.{});
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "fn integer_m9223372036854775808_p9223372036854775807("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "fn integer(value:"));
}
