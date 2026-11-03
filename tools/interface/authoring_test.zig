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
    try std.testing.expectEqual(calls.Kind.nothing, direct.parameters[0]);
    for ([_][]const u8{ "", "then", "a-b" }) |selector| {
        const call = try calls.read(a, &model, "comparison.Named", selector);
        try std.testing.expectEqualStrings(selector, call.wire_name.?);
    }
    const required = try calls.read(a, &model, "comparison.Named", "required");
    try std.testing.expectEqual(@as(usize, 1), required.required_parameters);
    const optional = try calls.read(a, &model, "comparison.Named", "optional");
    try std.testing.expectEqual(@as(usize, 0), optional.required_parameters);
    const pending = try calls.read(a, &model, "comparison.Factory", "accept");
    try std.testing.expectEqualSlices(calls.Kind, &.{ .target, .pending_target }, pending.parameters);
    const prepared = try calls.read(a, &model, "comparison.Prepared", "accept");
    try std.testing.expectEqual(calls.Effect.receipt, prepared.effect);
    try std.testing.expectEqual(calls.Kind.pending_value, prepared.parameters[0]);
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
    try std.testing.expectEqual(calls.Kind.nothing, reply.result);
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
    }) |invalid| try std.testing.expectError(error.InvalidDescription, text.translate(a, invalid, &diagnostic));
    for ([_][]const u8{
        "module comparison\ninterface Reader { read() -> string read() -> string }",
        "module comparison\ninterface Reader { () -> string read() -> string }",
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
