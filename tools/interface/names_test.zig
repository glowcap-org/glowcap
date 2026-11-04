//! Adversarial exports compiled by the authoring source proof, plus refusal tests.
const std = @import("std");
const calls = @import("calls.zig");
const rust = @import("rust.zig");
const ts = @import("typescript.zig");
const Model = @import("model.zig").Model;
const description = @import("description.zig");

const common = .{
    .{ "fixture.Reader", "read", "text" },
    .{ "fixture.Reader", "read", "__glowcap" },
    .{ "fixture.Reader", "read", "__glowcap_1" },
    .{ "fixture.Reader", "read", "call_0" },
    .{ "fixture.Reader", "read", "Session" },
    .{ "fixture.Reader", "read", "Ref" },
    .{ "fixture.Factory", "open", "capability" },
    .{ "fixture.Sink", "push", "nothing" },
};

pub const rust_selections = common ++ .{
    .{ "tasks.Task", "text", "text_1_4096" },
    .{ "tasks.TaskList", "count", "integer_p0_p256" },
};
pub const typescript_selections = common ++ .{.{ "fixture.Reader", "read", "Observation" }};

test "emitters refuse duplicate APIs and their actual public support exports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model = try Model.init(a, try description.read(a, @embedFile("contract")));
    const call = try calls.read(&model, "fixture.Reader", "read");
    const duplicate = calls.Named{ .api = "same", .call = call };
    inline for (.{ rust, ts }) |emitter| {
        try std.testing.expectError(error.ExportCollision, if (emitter == ts) emitter.emit(a, &.{ duplicate, duplicate }) else emitter.emit(a, &.{ duplicate, duplicate }, &.{}));
        try std.testing.expectError(error.ExportCollision, if (emitter == ts) emitter.emit(a, &.{.{ .api = "Pending", .call = call }}) else emitter.emit(a, &.{.{ .api = "Pending", .call = call }}, &.{}));
    }
    for ([_][]const u8{ "Error", "Observation" }) |api| {
        try std.testing.expectError(error.ExportCollision, rust.emit(a, &.{.{ .api = api, .call = call }}, &.{}));
    }
    const reference = try calls.read(&model, "fixture.Sink", "push");
    try std.testing.expectError(error.ExportCollision, rust.emit(a, &.{.{ .api = "Reference", .call = reference }}, &.{}));
    const receipt = try calls.read(&model, "fixture.Prepared", "accept");
    try std.testing.expectError(error.ExportCollision, rust.emit(a, &.{.{ .api = "PreparedMutation", .call = receipt }}, &.{}));
}

test "Rust one-shot receipt names share the public export namespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model = try Model.init(a, try description.read(a, @embedFile("contract")));
    const ordinary = try calls.read(&model, "fixture.Reader", "read");
    const receipt = try calls.read(&model, "loam.Observable", "observe");
    for ([_][]const u8{ "prepare", "read", "Error", "Pending", "Observation", "PreparedMutation" }) |api| {
        try std.testing.expectError(error.ExportCollision, rust.emit(a, &.{
            .{ .api = "prepare", .one_shot_api = api, .call = receipt },
            .{ .api = "read", .call = ordinary },
        }, &.{}));
    }
    try std.testing.expectError(error.ExportCollision, rust.emit(a, &.{
        .{ .api = "first", .one_shot_api = "once", .call = receipt },
        .{ .api = "second", .one_shot_api = "once", .call = receipt },
    }, &.{}));
    try std.testing.expectError(error.ExportCollision, rust.emit(a, &.{
        .{ .api = "prepare", .one_shot_api = "Registration", .call = receipt },
    }, &.{.{ .api = "Registration", .kind = receipt.result }}));
    try std.testing.expectError(error.InvalidIdentifier, rust.emit(a, &.{
        .{ .api = "prepare", .one_shot_api = "move", .call = receipt },
    }, &.{}));
    try std.testing.expectError(error.UnsupportedProjection, rust.emit(a, &.{
        .{ .api = "read", .one_shot_api = "once", .call = ordinary },
    }, &.{}));
}

test "TypeScript tell exports reserve only emitted support" {
    const a = std.testing.allocator;
    const code = try ts.emit(a, &.{.{ .api = "Pending", .call = .{
        .wire_name = "notice",
        .parameters = &.{.symbol},
        .required_parameters = 1,
        .result = .nothing,
        .effect = .tell,
    } }});
    defer a.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "class Pending") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "function nothing") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "import { Sym }") != null);
}
