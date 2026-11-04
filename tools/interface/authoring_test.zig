//! Independent expected descriptions qualify frontend mappings, not runtime support.
const std = @import("std");
const text = @import("text.zig");
const description = @import("description.zig");
const Model = @import("model.zig").Model;
const calls = @import("calls.zig");
const source = @embedFile("authoring_text");
const expected = @embedFile("authoring_expected");

test "proposed text equals independent canonical description and retains exact mappings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diagnostic: text.Diagnostic = .{};
    const actual = try text.translate(a, source, &diagnostic);
    try std.testing.expectEqualStrings(expected, actual);
    var model = try Model.init(try description.read(a, actual));
    const creation = try model.creation("comparison.Factory", "add");
    try std.testing.expectEqual(@as(usize, 1), creation.minimum);
    try std.testing.expectEqual(@as(usize, 64), creation.maximum);
    const direct = try calls.read(a, &model, "comparison.Direct", null);
    try std.testing.expectEqual(@as(?[]const u8, null), direct.wire_name);
    try std.testing.expectEqual(@as(usize, 0), direct.required_parameters);
    try std.testing.expect(direct.parameters[0] == .nothing);
    for ([_][]const u8{ "", "then", "a-b" }) |selector| {
        const call = try calls.read(a, &model, "comparison.Named", selector);
        try std.testing.expectEqualStrings(selector, call.wire_name.?);
    }
    const required = try calls.read(a, &model, "comparison.Named", "required");
    try std.testing.expectEqual(@as(usize, 1), required.required_parameters);
    const optional = try calls.read(a, &model, "comparison.Named", "optional");
    try std.testing.expectEqual(@as(usize, 0), optional.required_parameters);
    const pending = try calls.read(a, &model, "comparison.Factory", "accept");
    try std.testing.expectEqual(calls.Kind.target, std.meta.activeTag(pending.parameters[0]));
    try std.testing.expectEqual(calls.Kind.pending_target, std.meta.activeTag(pending.parameters[1]));
    const prepared = try calls.read(a, &model, "comparison.Prepared", "accept");
    try std.testing.expectEqual(calls.Effect.receipt, prepared.effect);
    try std.testing.expect(prepared.parameters[0] == .pending_value);
    const prepared_rust = try @import("callbacks.zig").emit(a, &.{.{ .api = "prepared_text", .call = prepared }});
    try std.testing.expect(std.mem.indexOf(u8, prepared_rust, "pub fn prepared_text(") != null);
    for ([_][]const u8{ "null-input", "null-result" }) |selector| {
        try std.testing.expectError(error.UnsupportedTarget, calls.read(a, &model, "comparison.Named", selector));
    }
}

fn edited(a: std.mem.Allocator, before: []const u8, after: []const u8) ![]u8 {
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, before));
    return std.mem.replaceOwned(u8, a, source, before, after);
}

test "bound reply and exact method edits change checked consumers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diagnostic: text.Diagnostic = .{};
    const changed_bound = try text.translate(a, try edited(a, "max_bytes: 64", "max_bytes: 32"), &diagnostic);
    var model = try Model.init(try description.read(a, changed_bound));
    const creation = try model.creation("comparison.Factory", "add");
    try std.testing.expectEqual(@as(usize, 32), creation.maximum);
    const zig = try @import("zig.zig").emit(a, creation);
    try std.testing.expect(std.mem.indexOf(u8, zig, "32") != null);
    const changed_reply = try text.translate(a, try edited(a, "read() -> string", "read() -> undefined"), &diagnostic);
    model = try Model.init(try description.read(a, changed_reply));
    const reply = try calls.read(a, &model, "comparison.Reader", "read");
    try std.testing.expect(reply.result == .nothing);
    const ts = try @import("typescript.zig").emit(a, &.{.{ .api = "read", .call = reply }});
    try std.testing.expect(std.mem.indexOf(u8, ts, "): Pending<void>") != null);
    const changed_method = try text.translate(a, try edited(a, "\"a-b\"()", "\"renamed\"()"), &diagnostic);
    model = try Model.init(try description.read(a, changed_method));
    try std.testing.expectError(error.InvalidDescription, model.method("comparison.Named", "a-b"));
    const renamed = try calls.read(a, &model, "comparison.Named", "renamed");
    const rust = try @import("callbacks.zig").emit(a, &.{.{ .api = "renamed", .call = renamed }});
    try std.testing.expect(std.mem.indexOf(u8, rust, "\"renamed\"") != null);
}

test "text diagnostics refuse unsupported constructs and invalid checked contracts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diagnostic: text.Diagnostic = .{};
    try std.testing.expectError(error.UnsupportedSyntax, text.translate(a, "module comparison\ninterface Reader { read() -> string throws Failure }", &diagnostic));
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expect(diagnostic.column > 1);
    try std.testing.expectEqualStrings("throws", "module comparison\ninterface Reader { read() -> string throws Failure }"[diagnostic.offset..][0..6]);
    for ([_][]const u8{
        "module comparison\nimport \"other\" as other",
        "module comparison\nrecord Data { name: string }",
    }) |unsupported| try std.testing.expectError(error.UnsupportedSyntax, text.translate(a, unsupported, &diagnostic));
    for ([_][]const u8{
        "module comparison\ninterface Reader { read(value?: string, later: string) -> string }",
        "module comparison\ntype Name = string(min_bytes: 65, max_bytes: 64)",
        "module comparison\ninterface Reader { read() -> Missing }",
        "module comparison\ninterface Reader { () -> string read() -> string }",
    }) |invalid| try std.testing.expectError(error.InvalidDescription, text.translate(a, invalid, &diagnostic));
    for ([_][]const u8{
        "module comparison\ninterface Reader { read() -> string read() -> string }",
        "module comparison\ntype Name = string(max_bytes: 64, max_bytes: 32)",
        "module comparison\ninterface Reader { \"\\ud800\"() -> string }",
        "module comparison\ninterface Reader { read( -> string }",
    }) |invalid| try std.testing.expectError(error.InvalidText, text.translate(a, invalid, &diagnostic));
}

fn allocationCase(a: std.mem.Allocator) !void {
    var diagnostic: text.Diagnostic = .{};
    const actual = try text.translate(a, source, &diagnostic);
    defer a.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "text adapter allocation failures release compilation scratch" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}

fn expandedNames(a: std.mem.Allocator, references: usize) ![]u8 {
    var input: std.ArrayList(u8) = .empty;
    errdefer input.deinit(a);
    try input.appendSlice(a, "module ");
    try input.appendNTimes(a, 'm', 4096);
    try input.appendSlice(a, "\ninterface Reader { read() -> string }\ninterface Factory {\n");
    for (0..references) |i| try input.print(a, "f{d}(value: Reader) -> undefined\n", .{i});
    try input.appendSlice(a, "}\n");
    return input.toOwnedSlice(a);
}

test "expanded qualified names refuse before allocation grows with impossible output" {
    const valid = try expandedNames(std.testing.allocator, 1);
    defer std.testing.allocator.free(valid);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var valid_diagnostic: text.Diagnostic = .{};
    const bytes = try text.translate(a, valid, &valid_diagnostic);
    var model = try Model.init(try description.read(a, bytes));
    const factory = try std.fmt.allocPrint(a, "{s}.Factory", .{valid[7..][0..4096]});
    _ = try model.method(factory, "f0");
    var allocated: [2]usize = undefined;
    for ([_]usize{ 512, 2048 }, 0..) |references, i| {
        const input = try expandedNames(std.testing.allocator, references);
        defer std.testing.allocator.free(input);
        try std.testing.expect(input.len < description.max_input_bytes);
        // Hold backing allocation growth policy constant across the two inputs.
        var meter = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
        var diagnostic: text.Diagnostic = .{};
        try std.testing.expectError(error.ResourceLimit, text.translate(meter.allocator(), input, &diagnostic));
        try std.testing.expectEqual(meter.allocated_bytes, meter.freed_bytes);
        allocated[i] = meter.allocated_bytes;
    }
    // Extra input after the existing output budget is exhausted acquires no scratch.
    try std.testing.expectEqual(allocated[0], allocated[1]);
}

test "canonical descriptions admit direct or named methods and refuse their mixture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const prefix = "<17'glowcap:interface1+{12\"loam.receipt1+14\"glowcap.values1+}{1\"I<9'interface";
    const suffix = ">}>";
    const method = "<6'method[]9'undefined4'call>";
    var direct = try Model.init(try description.read(allocator, prefix ++ "{f" ++ method ++ "}" ++ suffix));
    _ = try direct.method("I", null);
    var named = try Model.init(try description.read(allocator, prefix ++ "{0\"" ++ method ++ "1\"m" ++ method ++ "}" ++ suffix));
    _ = try named.method("I", "");
    _ = try named.method("I", "m");
    const mixed = try description.read(allocator, prefix ++ "{0\"" ++ method ++ "f" ++ method ++ "}" ++ suffix);
    try std.testing.expectError(error.InvalidDescription, Model.init(mixed));
}

test "text mixed invocation uses the shared checked-model diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "module comparison\ninterface Reader { () -> string read() -> string }",
    }) |input| {
        var diagnostic: text.Diagnostic = .{};
        try std.testing.expectError(error.InvalidDescription, text.translate(arena.allocator(), input, &diagnostic));
        try std.testing.expectEqualStrings("description rejected by checked model", diagnostic.message);
    }
}
