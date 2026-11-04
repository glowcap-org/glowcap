//! First interface generation slice: one checked authored bundle feeds the
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
const authored = @import("authored.zig");
const text = @import("text.zig");
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
const task_reads = .{
    .{ "tasks.Board", "list", "board_list" },
    .{ "tasks.TaskList", "name", "list_name" },
    .{ "tasks.TaskList", "count", "list_count" },
    .{ "tasks.TaskList", "task", "list_task" },
    .{ "tasks.Task", "text", "task_text" },
};

pub const step_name = "gen-interface-fixtures";
pub const outputs = [_]Output{
    .{ .path = "test/interface/generated/compounds.rs", .generate = generateCompounds },
    .{ .path = "test/interface/generated/scalars.rs", .generate = generateScalarRust },
    .{ .path = "test/interface/generated/scalars.ts", .generate = generateScalarTypeScript },
    .{ .path = "test/interface/generated/callbacks.ts", .generate = generateTypeScript },
    .{ .path = "test/interface/generated/callbacks.rs", .generate = generateCallbacks },
    .{ .path = "test/interface/generated/expected.rs", .generate = @import("expectations.zig").generate },
    .{ .path = "test/interface/generated/expected.ts", .generate = @import("expectations.zig").generateTypeScript },
    .{ .path = "test/interface/generated/authoring_text.ts", .generate = generateAuthoringText },
    .{ .path = "test/interface/generated/direct_receiver.zig", .generate = generateDirectReceiver },
    .{ .path = "test/interface/generated/names.rs", .generate = generateRustNames },
    .{ .path = "test/interface/generated/names.ts", .generate = generateTypeScriptNames },
    .{ .path = "apps/tasks/zig/interface.zig", .generate = generateZig },
    .{ .path = "apps/tasks/rust/interface.rs", .generate = generateRust },
};

fn generateZig(a: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostic: text.Diagnostic = .{};
    var model = (try authored.compile(arena.allocator(), &diagnostic, authored.sources)).model;
    const method = try model.creation("tasks.TaskList", creation_method);
    const reads = try serverReads(&model);
    return zig.emitServer(a, method, &reads);
}

fn serverReads(model: *Model) ![6]calls.Named {
    const selections = task_reads ++ .{.{ "tasks.Board", "lists", "board_lists" }};
    var reads: [selections.len]calls.Named = undefined;
    inline for (selections, 0..) |selected_method, i| {
        reads[i] = .{ .api = selected_method[2], .call = try calls.read(model, selected_method[0], selected_method[1]) };
    }
    return reads;
}

fn generateCalls(a: std.mem.Allocator, comptime emitter: type, comptime selections: anytype) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostic: text.Diagnostic = .{};
    var model = (try authored.compile(arena.allocator(), &diagnostic, authored.sources)).model;
    var methods: [selections.len]calls.Named = undefined;
    inline for (selections, 0..) |method, i| {
        methods[i] = .{ .api = method[2], .call = try calls.read(&model, method[0], method[1]) };
    }
    return if (emitter == @import("typescript.zig")) emitter.emit(a, &methods) else emitter.emit(a, &methods, &.{});
}

fn generateCallbacks(a: std.mem.Allocator) ![]u8 {
    return generateCalls(a, @import("callbacks.zig"), selected ++ prepared);
}
fn generateTypeScript(a: std.mem.Allocator) ![]u8 {
    return generateCalls(a, @import("typescript.zig"), selected);
}

fn generateRustNames(a: std.mem.Allocator) ![]u8 {
    return generateCalls(a, @import("callbacks.zig"), @import("names_test.zig").rust_selections);
}

fn generateTypeScriptNames(a: std.mem.Allocator) ![]u8 {
    return generateCalls(a, @import("typescript.zig"), @import("names_test.zig").typescript_selections);
}

fn generateRust(a: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var diagnostic: text.Diagnostic = .{};
    var model = (try authored.compile(scratch, &diagnostic, authored.sources)).model;
    const creation = try model.creation("tasks.TaskList", creation_method);
    const selections = task_reads ++ .{.{ "loam.Receiver", "poll", "receiver_poll" }};
    var reads: [selections.len]calls.Named = undefined;
    inline for (selections, 0..) |method, i| {
        reads[i] = .{ .api = method[2], .call = try calls.read(&model, method[0], method[1]) };
    }
    const observation = try model.callType(.{ .kind = .record, .bytes = "ref", .children = &.{.{ .kind = .string, .bytes = "loam.Observation" }} });
    return rust.emit(a, creation, &reads, &.{.{ .api = "LoamObservation", .kind = observation }});
}

test "authored contract selects creation and rejects another method shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var model = try Model.init(arena.allocator(), try description.read(arena.allocator(), @embedFile("contract")));
    const method = try model.creation("tasks.TaskList", "add");
    try std.testing.expectEqualStrings("add", method.wire_name);
    try std.testing.expectEqual(@as(usize, 1), method.minimum);
    try std.testing.expectEqual(@as(usize, 4096), method.maximum);
    const other = try model.creation("tasks.Board", "add-list");
    try std.testing.expectEqual(@as(usize, 64), other.maximum);
    // The templates spell `add`, so they refuse to name another method's request.
    try std.testing.expectError(error.UnsupportedProjection, rust.emit(std.testing.allocator, other, &.{}, &.{}));
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
    _ = @import("compound_test.zig");
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
    try std.testing.expectError(error.InvalidDescription, Model.init(arena.allocator(), root));
    fields[0].integer = 1;
    // A well-formed declaration names a definition absent from the graph.
    fields[2].children = &.{
        .{ .kind = .string, .bytes = "Only" },
        .{ .kind = .record, .bytes = "type", .children = &.{
            .{ .kind = .record, .bytes = "ref", .children = &.{.{ .kind = .string, .bytes = "Missing" }} },
        } },
    };
    try std.testing.expectError(error.InvalidDescription, Model.init(arena.allocator(), root));
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
        try std.testing.expectError(error.InvalidDescription, Model.init(arena.allocator(), root));
    }
    // A list supplies copied structure, so its recursive reference is productive.
    for ([_][]const u8{
        prefix ++ "<7'bounded7'integer{}>" ++ suffix,
        prefix ++ "<7'bounded6'string{}>" ++ suffix,
        prefix ++ "<7'bounded<4'list7'integer>{}>" ++ suffix,
        prefix ++ "<7'bounded<4'list<3'ref1\"A>>{}>" ++ suffix,
    }) |bytes| {
        _ = try Model.init(arena.allocator(), try description.read(arena.allocator(), bytes));
    }
}

test "call projections admit present undefined and optional arguments but refuse contract null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var model = try Model.init(arena.allocator(), try description.read(arena.allocator(), @embedFile("contract")));
    for ([_][]const u8{ "required", "optional", "suffix", "pair", "references", "value", "notify" }) |name| {
        const call = try calls.read(&model, "fixture.Presence", name);
        const methods = [_]calls.Named{.{ .api = "presence", .call = call }};
        const rust_source = try @import("callbacks.zig").emit(std.testing.allocator, &methods, &.{});
        defer std.testing.allocator.free(rust_source);
        const ts_source = try @import("typescript.zig").emit(std.testing.allocator, &methods);
        defer std.testing.allocator.free(ts_source);
    }
    const required = try calls.read(&model, "fixture.Presence", "required");
    const optional = try calls.read(&model, "fixture.Presence", "optional");
    const suffix = try calls.read(&model, "fixture.Presence", "suffix");
    try std.testing.expectEqual(@as(usize, 1), required.required_parameters);
    try std.testing.expectEqual(@as(usize, 0), optional.required_parameters);
    try std.testing.expectEqual(@as(usize, 1), suffix.required_parameters);
    for ([_][]const u8{ "null-input", "null-result" }) |name| {
        try std.testing.expectError(error.UnsupportedTarget, calls.read(&model, "fixture.Presence", name));
    }
}

test "prepared receipt emitters refuse unqualified shapes" {
    for ([_]calls.Type{ .{ .text = .{} }, .target, .pending_target, .nothing, .value }) |kind| {
        const methods = [_]calls.Named{.{ .api = "prepare_test", .call = .{
            .wire_name = "accept",
            .parameters = &.{kind},
            .required_parameters = 1,
            .result = .nothing,
            .effect = .receipt,
        } }};
        try std.testing.expectError(error.UnsupportedProjection, @import("callbacks.zig").emit(std.testing.allocator, &methods, &.{}));
    }
    for ([_]calls.Type{ .{ .text = .{} }, .target, .pending_target, .pending_value, .value }) |kind| {
        const methods = [_]calls.Named{.{ .api = "prepare_test", .call = .{
            .wire_name = "accept",
            .parameters = &.{.pending_value},
            .required_parameters = 1,
            .result = kind,
            .effect = .receipt,
        } }};
        try std.testing.expectError(error.UnsupportedProjection, @import("callbacks.zig").emit(std.testing.allocator, &methods, &.{}));
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
    var model = try Model.init(arena.allocator(), try description.read(arena.allocator(), @embedFile("contract")));
    const direct = try calls.read(&model, "fixture.Direct", null);
    try std.testing.expect(direct.wire_name == null);
    const empty = try calls.read(&model, "fixture.Hostile", "");
    try std.testing.expectEqualStrings("", empty.wire_name.?);
    const named = try calls.read(&model, "fixture.Hostile", "then");
    try std.testing.expectEqualStrings("then", named.wire_name.?);
    try std.testing.expectError(error.InvalidDescription, calls.read(&model, "fixture.Direct", ""));
    try std.testing.expectError(error.InvalidDescription, calls.read(&model, "fixture.Hostile", null));
}

test "call presence keeps the Models trailing optional rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "<17'glowcap:interface1+{12\"loam.receipt1+14\"glowcap.values1+}{1\"A<9'interface{1\"m<6'method[<9'parameter1\"a6'stringt><9'parameter1\"b6'stringf>]9'undefined4'call>}>}>";
    try std.testing.expectError(error.InvalidDescription, Model.init(arena.allocator(), try description.read(arena.allocator(), source)));
    const methods = [_]calls.Named{.{ .api = "optional_receipt", .call = .{
        .wire_name = "accept",
        .parameters = &.{.pending_value},
        .required_parameters = 0,
        .result = .nothing,
        .effect = .receipt,
    } }};
    try std.testing.expectError(error.UnsupportedProjection, @import("callbacks.zig").emit(std.testing.allocator, &methods, &.{}));
}

test {
    _ = @import("authoring_test.zig");
    _ = @import("text_bundle_test.zig");
    _ = @import("text_container_test.zig");
    _ = @import("authored_test.zig");
    _ = @import("profiles_test.zig");
    _ = @import("read_test.zig");
    _ = @import("names_test.zig");
}

fn generateAuthoringText(a: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var diagnostic: @import("text.zig").Diagnostic = .{};
    var compiled = try text.compile(scratch, @embedFile("authoring_text"), &diagnostic);
    const model = &compiled.model;
    return @import("typescript.zig").emit(a, &.{
        .{ .api = "invoke_text", .call = try calls.read(model, "comparison.Direct", null) },
        .{ .api = "accept_text", .call = try calls.read(model, "comparison.Factory", "accept") },
    });
}

fn generateDirectReceiver(a: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostic: text.Diagnostic = .{};
    var checked = (try authored.compile(arena.allocator(), &diagnostic, authored.sources)).model;
    return zig.emitDirect(a, try calls.read(&checked, "fixture.DirectPair", null));
}

test "direct receiver projection refuses unqualified call shapes" {
    var call: calls.Call = .{ .wire_name = null, .parameters = &.{ .value, .value }, .required_parameters = 2, .result = .nothing, .effect = .call };
    const code = try zig.emitDirect(std.testing.allocator, call);
    defer std.testing.allocator.free(code);
    call.wire_name = "";
    try std.testing.expectError(error.UnsupportedProjection, zig.emitDirect(std.testing.allocator, call));
    call.wire_name = null;
    call.required_parameters = 1;
    try std.testing.expectError(error.UnsupportedProjection, zig.emitDirect(std.testing.allocator, call));
    call.required_parameters = 2;
    call.parameters = &.{ .{ .text = .{} }, .value };
    try std.testing.expectError(error.UnsupportedProjection, zig.emitDirect(std.testing.allocator, call));
    call.parameters = &.{ .value, .value };
    call.result = .{ .text = .{} };
    try std.testing.expectError(error.UnsupportedProjection, zig.emitDirect(std.testing.allocator, call));
    call.result = .nothing;
    call.effect = .tell;
    try std.testing.expectError(error.UnsupportedProjection, zig.emitDirect(std.testing.allocator, call));
}

test "server read emitter keeps edited constraints and rejects unsupported shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model = try Model.init(a, try description.read(a, @embedFile("contract")));
    const creation = try model.creation("tasks.TaskList", creation_method);
    const original = try serverReads(&model);
    var edited = original;
    edited[1].call.result = .{ .text = .{ .min = 2, .max = 32 } };
    edited[2].call.result = .{ .integer = .{ .min = 1, .max = 12 } };
    edited[5].call.result = .{ .integer = .{ .min = 0, .max = 8 } };
    edited[0].call.wire_name = "renamed-list";
    const source = try zig.emitServer(a, creation, &edited);
    for ([_][]const u8{
        "pub const max_name_bytes: u64 = 32;",
        "pub const max_tasks: u64 = 12;",
        "pub const max_lists: u64 = 8;",
        "@as(u128, bytes.len) < 2 or @as(u128, bytes.len) > 32",
        "@as(u128, count) < 1 or @as(u128, count) > 12",
        "pub const board_list_verb = \"renamed-list\";",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, source, needle) != null);
    // Full-width schema maxima stay u64. Storage owns its separate usize cast.
    edited = original;
    edited[1].call.result = .{ .text = .{ .max = std.math.maxInt(u64) } };
    const wide = try zig.emitServer(a, creation, &edited);
    try std.testing.expect(std.mem.indexOf(u8, wide, "pub const max_name_bytes: u64 = 18446744073709551615;") != null);
    for (0..7) |case| {
        edited = original;
        switch (case) {
            0 => edited[1].call.result = .{ .text = .{} },
            1 => edited[2].call.result = .{ .integer = .{ .min = -1, .max = 12 } },
            2 => edited[2].call.result = .{ .integer = .{ .min = 0 } },
            3 => edited[3].call.parameters = &.{.{ .integer = .{ .min = 0, .max = 16 } }},
            4 => edited[0].call.parameters = &.{.{ .integer = .{ .min = 0 } }},
            5 => edited[1].call.parameters = &.{.{ .text = .{} }},
            6 => edited[1].call.result = .value,
            else => unreachable,
        }
        try std.testing.expectError(error.UnsupportedProjection, zig.emitServer(a, creation, &edited));
    }
}

fn scalarMethods(model: *Model) ![24]calls.Named {
    var methods: [24]calls.Named = undefined;
    var index: usize = 0;
    inline for (.{ "bool", "bytes", "bounded", "symbol", "float", "error" }) |kind| {
        inline for (.{ "call", "optional", "tell", "optional_tell" }) |shape| {
            const name = kind ++ "_" ++ shape;
            methods[index] = .{ .api = name, .call = try calls.read(model, "scalars.Scalars", name) };
            index += 1;
        }
    }
    return methods;
}
fn scalarSource(a: std.mem.Allocator, comptime emitter: type) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var diagnostic: @import("text.zig").Diagnostic = .{};
    var compiled = try text.compile(scratch, @embedFile("scalar_text"), &diagnostic);
    const methods = try scalarMethods(&compiled.model);
    return if (emitter == @import("typescript.zig")) emitter.emit(a, &methods) else emitter.emit(a, &methods, &.{});
}
fn generateScalarRust(a: std.mem.Allocator) ![]u8 {
    return scalarSource(a, @import("callbacks.zig"));
}
fn generateScalarTypeScript(a: std.mem.Allocator) ![]u8 {
    return scalarSource(a, @import("typescript.zig"));
}

test "scalar projections accept exact native representations and bounded bytes" {
    const rust_source = try generateScalarRust(std.testing.allocator);
    defer std.testing.allocator.free(rust_source);
    const ts_source = try generateScalarTypeScript(std.testing.allocator);
    defer std.testing.allocator.free(ts_source);
}

fn generateCompounds(a: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var model = try Model.init(arena.allocator(), try description.read(arena.allocator(), @embedFile("compound_contract")));
    var methods: [5]calls.Named = undefined;
    for ([_][]const u8{ "list", "limited", "tuple", "zero", "nested" }, &methods) |name, *method| {
        method.* = .{ .api = name, .call = try calls.read(&model, "compound.Source", name) };
    }
    return @import("callbacks.zig").emit(a, &methods, &.{});
}
