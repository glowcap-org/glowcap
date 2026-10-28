//! First interface generation slice: one checked Syrup description feeds the
//! Tasks creation server projection and its Rust retained-request client.
const std = @import("std");
const Output = @import("output").Output;
const description = @import("description.zig");
const Model = @import("model.zig").Model;
const rust = @import("rust.zig");
const zig = @import("zig.zig");
const calls = @import("calls.zig");
const selected = .{
    .{ "fixture.Factory", "open", "factory_open" },
    .{ "fixture.Factory", "accept", "factory_accept" },
    .{ "fixture.Sink", "push", "sink_push" },
    .{ "fixture.Sink", "changed", "sink_changed" },
    .{ "fixture.Reader", "read", "reader_read" },
    .{ "fixture.Reader", "then", "reader_then" },
};

pub const step_name = "gen-interface-fixtures";
pub const outputs = [_]Output{
    .{ .path = "test/interface/generated/callbacks.ts", .generate = generateTypeScript },
    .{ .path = "test/interface/generated/callbacks.rs", .generate = generateCallbacks },
    .{ .path = "test/interface/generated/expected.rs", .generate = @import("expectations.zig").generate },
    .{ .path = "apps/tasks/zig/interface.zig", .generate = generateZig },
    .{ .path = "apps/tasks/rust/interface.rs", .generate = generateRust },
};

fn generate(a: std.mem.Allocator, comptime emitter: type) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var model = try Model.init(try description.read(arena.allocator(), @embedFile("contract")));
    const method = try model.creation("tasks.TaskList", "add");
    return emitter.emit(a, method);
}

fn generateCalls(a: std.mem.Allocator, comptime emitter: type) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var model = try Model.init(try description.read(arena.allocator(), @embedFile("contract")));
    var methods: [selected.len]calls.Named = undefined;
    inline for (selected, 0..) |method, i| {
        methods[i] = .{ .api = method[2], .call = try calls.read(arena.allocator(), &model, method[0], method[1]) };
    }
    return emitter.emit(a, &methods);
}

fn generateCallbacks(a: std.mem.Allocator) ![]u8 {
    return generateCalls(a, @import("callbacks.zig"));
}
fn generateTypeScript(a: std.mem.Allocator) ![]u8 {
    return generateCalls(a, @import("typescript.zig"));
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

test "TypeScript projection refuses void parameters and accepts void results" {
    const typescript = @import("typescript.zig");
    for ([_]bool{ false, true }) |tell| {
        const methods = [_]calls.Named{.{ .api = "void_argument", .call = .{
            .wire_name = "void-argument",
            .parameters = &.{.nothing},
            .result = .nothing,
            .tell = tell,
        } }};
        try std.testing.expectError(error.UnsupportedProjection, typescript.emit(std.testing.allocator, &methods));
    }
    const methods = [_]calls.Named{.{ .api = "void_result", .call = .{
        .wire_name = "void-result",
        .parameters = &.{},
        .result = .nothing,
        .tell = false,
    } }};
    const source = try typescript.emit(std.testing.allocator, &methods);
    defer std.testing.allocator.free(source);
}
