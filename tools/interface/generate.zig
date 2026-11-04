//! First interface generation slice: one checked Syrup description feeds the
//! Tasks creation projections (the Zig server check and the Rust
//! retained-request client), the fixture callbacks in Rust and TypeScript, and
//! the Rust message expectations.
const std = @import("std");
const Output = @import("output").Output;
const description = @import("description.zig");
const Model = @import("model.zig").Model;
const creation_method = @import("model.zig").creation_method;
const rust = @import("rust.zig");
const zig = @import("zig.zig");
const calls = @import("calls.zig");
const selected = .{
    .{ "fixture.Introducer", "get-greeter", "introducer_get_greeter" },
    .{ "fixture.Factory", "open", "factory_open" },
    .{ "fixture.Factory", "accept", "factory_accept" },
    .{ "fixture.Sink", "push", "sink_push" },
    .{ "fixture.Sink", "changed", "sink_changed" },
    .{ "fixture.Reader", "read", "reader_read" },
    .{ "fixture.Reader", "then", "reader_then" },
    .{ "fixture.Direct", @as(?[]const u8, null), "invoke_direct" },
    .{ "fixture.Notify", @as(?[]const u8, null), "notify_direct" },
    .{ "fixture.Hostile", "", "invoke_empty" },
    .{ "fixture.Hostile", "then", "invoke_named" },
    .{ "fixture.Presence", "required", "presence_required" },
    .{ "fixture.Presence", "optional", "presence_optional" },
    .{ "fixture.Presence", "suffix", "presence_suffix" },
    .{ "fixture.Presence", "pair", "presence_pair" },
    .{ "fixture.Presence", "references", "presence_references" },
    .{ "fixture.Presence", "value", "presence_value" },
    .{ "fixture.Presence", "notify", "presence_notify" },
};
const prepared = .{.{ "fixture.Prepared", "accept", "prepare_accept" }};

pub const step_name = "gen-interface-fixtures";
pub const outputs = [_]Output{
    .{ .path = "test/interface/generated/callbacks.ts", .generate = generateTypeScript },
    .{ .path = "test/interface/generated/callbacks.rs", .generate = generateCallbacks },
    .{ .path = "test/interface/generated/expected.rs", .generate = @import("expectations.zig").generate },
    .{ .path = "test/interface/generated/expected.ts", .generate = @import("expectations.zig").generateTypeScript },
    .{ .path = "test/interface/generated/authoring_text.ts", .generate = generateAuthoringText },
    .{ .path = "apps/tasks/zig/interface.zig", .generate = generateZig },
    .{ .path = "apps/tasks/rust/interface.rs", .generate = generateRust },
};

fn generate(a: std.mem.Allocator, comptime emitter: type) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var model = try Model.init(try description.read(arena.allocator(), @embedFile("contract")));
    const method = try model.creation("tasks.TaskList", creation_method);
    return emitter.emit(a, method);
}

fn generateCalls(a: std.mem.Allocator, comptime emitter: type, comptime selections: anytype) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var model = try Model.init(try description.read(arena.allocator(), @embedFile("contract")));
    var methods: [selections.len]calls.Named = undefined;
    inline for (selections, 0..) |method, i| {
        methods[i] = .{ .api = method[2], .call = try calls.read(arena.allocator(), &model, method[0], method[1]) };
    }
    return emitter.emit(a, &methods);
}

fn generateCallbacks(a: std.mem.Allocator) ![]u8 {
    return generateCalls(a, @import("callbacks.zig"), selected ++ prepared);
}
fn generateTypeScript(a: std.mem.Allocator) ![]u8 {
    return generateCalls(a, @import("typescript.zig"), selected);
}

fn generateZig(a: std.mem.Allocator) ![]u8 {
    return generate(a, zig);
}
fn generateRust(a: std.mem.Allocator) ![]u8 {
    return generate(a, rust);
}

test "authored contract selects creation and rejects another method shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var model = try Model.init(try description.read(arena.allocator(), @embedFile("contract")));
    const method = try model.creation("tasks.TaskList", "add");
    try std.testing.expectEqualStrings("add", method.wire_name);
    try std.testing.expectEqual(@as(usize, 1), method.minimum);
    try std.testing.expectEqual(@as(usize, 4096), method.maximum);
    const other = try model.creation("tasks.Board", "add-list");
    try std.testing.expectEqual(@as(usize, 64), other.maximum);
    // The templates spell `add`, so they refuse to name another method's request.
    try std.testing.expectError(error.UnsupportedProjection, rust.emit(std.testing.allocator, other));
    try std.testing.expectError(error.UnsupportedProjection, zig.emit(std.testing.allocator, other));
    try std.testing.expectError(error.UnsupportedProjection, model.creation("tasks.TaskList", "move"));
}

test "generation releases every allocation on failure" {
    // In-place growth depends on backing-allocator address reuse. Force the
    // allocate/copy path so each injected index names the same allocation.
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), generateOutputs, .{});
}

fn generateOutputs(a: std.mem.Allocator) !void {
    for (outputs) |output| {
        const bytes = try output.generate(a);
        a.free(bytes);
    }
}

test {
    _ = description;
    _ = @import("literal.zig");
}

test "every truncated description fails before emission" {
    const bytes = @embedFile("contract");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (0..bytes.len) |end| {
        try std.testing.expectError(error.InvalidDescription, description.read(arena.allocator(), bytes[0..end]));
        _ = arena.reset(.retain_capacity);
    }
}

test "description versions and missing references are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var root = try description.read(arena.allocator(), @embedFile("contract"));
    const fields = try arena.allocator().dupe(description.Node, root.children);
    root.children = fields;
    fields[0].integer = 2;
    try std.testing.expectError(error.InvalidDescription, Model.init(root));
    fields[0].integer = 1;
    // A well-formed declaration names a definition absent from the graph.
    fields[2].children = &.{
        .{ .kind = .string, .bytes = "Only" },
        .{ .kind = .record, .bytes = "type", .children = &.{
            .{ .kind = .record, .bytes = "ref", .children = &.{.{ .kind = .string, .bytes = "Missing" }} },
        } },
    };
    try std.testing.expectError(error.InvalidDescription, Model.init(root));
}

test "empty bounds validate their base and reject unproductive recursion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const prefix = "<17'glowcap:interface1+{12\"loam.receipt1+14\"glowcap.values1+}{1\"A<4'type";
    const suffix = ">}>";
    for ([_][]const u8{
        prefix ++ "<7'bounded<3'ref1\"A>{}>" ++ suffix,
        prefix ++ "<7'bounded4'bool{}>" ++ suffix,
    }) |bytes| {
        const root = try description.read(arena.allocator(), bytes);
        try std.testing.expectError(error.InvalidDescription, Model.init(root));
    }
    // A list supplies copied structure, so its recursive reference is productive.
    for ([_][]const u8{
        prefix ++ "<7'bounded7'integer{}>" ++ suffix,
        prefix ++ "<7'bounded6'string{}>" ++ suffix,
        prefix ++ "<7'bounded<4'list7'integer>{}>" ++ suffix,
        prefix ++ "<7'bounded<4'list<3'ref1\"A>>{}>" ++ suffix,
    }) |bytes| {
        _ = try Model.init(try description.read(arena.allocator(), bytes));
    }
}

test "call projections admit present undefined and optional arguments but refuse contract null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var model = try Model.init(try description.read(arena.allocator(), @embedFile("contract")));
    for ([_][]const u8{ "required", "optional", "suffix", "pair", "references", "value", "notify" }) |name| {
        const call = try calls.read(arena.allocator(), &model, "fixture.Presence", name);
        const methods = [_]calls.Named{.{ .api = "presence", .call = call }};
        const rust_source = try @import("callbacks.zig").emit(std.testing.allocator, &methods);
        defer std.testing.allocator.free(rust_source);
        const ts_source = try @import("typescript.zig").emit(std.testing.allocator, &methods);
        defer std.testing.allocator.free(ts_source);
    }
    const required = try calls.read(arena.allocator(), &model, "fixture.Presence", "required");
    const optional = try calls.read(arena.allocator(), &model, "fixture.Presence", "optional");
    const suffix = try calls.read(arena.allocator(), &model, "fixture.Presence", "suffix");
    try std.testing.expectEqual(@as(usize, 1), required.required_parameters);
    try std.testing.expectEqual(@as(usize, 0), optional.required_parameters);
    try std.testing.expectEqual(@as(usize, 1), suffix.required_parameters);
    for ([_][]const u8{ "null-input", "null-result" }) |name| {
        try std.testing.expectError(error.UnsupportedTarget, calls.read(arena.allocator(), &model, "fixture.Presence", name));
    }
}

test "prepared receipt emitters refuse unqualified shapes" {
    for ([_]calls.Kind{ .text, .target, .pending_target, .nothing, .value }) |kind| {
        const methods = [_]calls.Named{.{ .api = "prepare_test", .call = .{
            .wire_name = "accept",
            .parameters = &.{kind},
            .required_parameters = 1,
            .result = .nothing,
            .effect = .receipt,
        } }};
        try std.testing.expectError(error.UnsupportedProjection, @import("callbacks.zig").emit(std.testing.allocator, &methods));
    }
    for ([_]calls.Kind{ .text, .target, .pending_target, .pending_value, .value }) |kind| {
        const methods = [_]calls.Named{.{ .api = "prepare_test", .call = .{
            .wire_name = "accept",
            .parameters = &.{.pending_value},
            .required_parameters = 1,
            .result = kind,
            .effect = .receipt,
        } }};
        try std.testing.expectError(error.UnsupportedProjection, @import("callbacks.zig").emit(std.testing.allocator, &methods));
    }
    const methods = [_]calls.Named{.{ .api = "prepare_test", .call = .{
        .wire_name = "accept",
        .parameters = &.{.pending_value},
        .required_parameters = 1,
        .result = .nothing,
        .effect = .receipt,
    } }};
    try std.testing.expectError(error.UnsupportedProjection, @import("typescript.zig").emit(std.testing.allocator, &methods));
}

test "checked call selection preserves positional, empty, and named methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var model = try Model.init(try description.read(arena.allocator(), @embedFile("contract")));
    const direct = try calls.read(arena.allocator(), &model, "fixture.Direct", null);
    try std.testing.expect(direct.wire_name == null);
    const empty = try calls.read(arena.allocator(), &model, "fixture.Hostile", "");
    try std.testing.expectEqualStrings("", empty.wire_name.?);
    const named = try calls.read(arena.allocator(), &model, "fixture.Hostile", "then");
    try std.testing.expectEqualStrings("then", named.wire_name.?);
    try std.testing.expectError(error.InvalidDescription, calls.read(arena.allocator(), &model, "fixture.Direct", ""));
    try std.testing.expectError(error.InvalidDescription, calls.read(arena.allocator(), &model, "fixture.Hostile", null));
}

test "call presence keeps the Models trailing optional rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "<17'glowcap:interface1+{12\"loam.receipt1+14\"glowcap.values1+}{1\"A<9'interface{1\"m<6'method[<9'parameter1\"a6'stringt><9'parameter1\"b6'stringf>]9'undefined4'call>}>}>";
    try std.testing.expectError(error.InvalidDescription, Model.init(try description.read(arena.allocator(), source)));
    const methods = [_]calls.Named{.{ .api = "optional_receipt", .call = .{
        .wire_name = "accept",
        .parameters = &.{.pending_value},
        .required_parameters = 0,
        .result = .nothing,
        .effect = .receipt,
    } }};
    try std.testing.expectError(error.UnsupportedProjection, @import("callbacks.zig").emit(std.testing.allocator, &methods));
}

test {
    _ = @import("authoring_test.zig");
    _ = @import("profiles_test.zig");
}

fn generateAuthoringText(a: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var diagnostic: @import("text.zig").Diagnostic = .{};
    const bytes = try @import("text.zig").translate(scratch, @embedFile("authoring_text"), &diagnostic);
    var model = try Model.init(try description.read(scratch, bytes));
    return @import("typescript.zig").emit(a, &.{
        .{ .api = "invoke_text", .call = try calls.read(scratch, &model, "comparison.Direct", null) },
        .{ .api = "accept_text", .call = try calls.read(scratch, &model, "comparison.Factory", "accept") },
    });
}
