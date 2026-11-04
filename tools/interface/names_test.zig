//! Adversarial exports compiled by the authoring source proof, plus refusal tests.
const std = @import("std");
const calls = @import("calls.zig");
const rust = @import("callbacks.zig");
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
    var model = try Model.init(try description.read(a, @embedFile("contract")));
    const call = try calls.read(a, &model, "fixture.Reader", "read");
    const duplicate = calls.Named{ .api = "same", .call = call };
    inline for (.{ rust, ts }) |emitter| {
        try std.testing.expectError(error.ExportCollision, emitter.emit(a, &.{ duplicate, duplicate }));
        try std.testing.expectError(error.ExportCollision, emitter.emit(a, &.{.{ .api = "Pending", .call = call }}));
    }
    for ([_][]const u8{ "Error", "Observation" }) |api| {
        try std.testing.expectError(error.ExportCollision, rust.emit(a, &.{.{ .api = api, .call = call }}));
    }
    const reference = try calls.read(a, &model, "fixture.Sink", "push");
    try std.testing.expectError(error.ExportCollision, rust.emit(a, &.{.{ .api = "Reference", .call = reference }}));
    const receipt = try calls.read(a, &model, "fixture.Prepared", "accept");
    try std.testing.expectError(error.ExportCollision, rust.emit(a, &.{.{ .api = "PreparedMutation", .call = receipt }}));
    const creation = try model.creation("tasks.TaskList", "add");
    for ([_][]const u8{ "add", "prepare_add" }) |api| {
        try std.testing.expectError(error.ExportCollision, @import("rust.zig").emit(a, creation, &.{.{ .api = api, .call = call }}));
    }
}
