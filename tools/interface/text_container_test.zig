//! Frontend grammar and shared-model refusal boundaries for copied containers.
const std = @import("std");
const text = @import("text.zig");
const description = @import("description.zig");
const Model = @import("model.zig").Model;

test "container source keeps exact tags empty shapes and nested tuple payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diagnostic: text.Diagnostic = .{};
    const actual = try text.translate(a, "module M\ntype T = tagged<\"tag\", tuple<integer, string>>\ntype R = record<\"tag\", integer, string>\ntype E = record<\"\">\ntype L = list<tuple<>>", &diagnostic);
    const expected = "<17'glowcap:interface1+{14\"glowcap.values1+}{3\"M.E<4'type<6'record0\"[]>>3\"M.L<4'type<4'list<5'tuple[]>>>3\"M.R<4'type<6'record3\"tag[7'integer6'string]>>3\"M.T<4'type<6'tagged3\"tag<5'tuple[7'integer6'string]>>>}>";
    try std.testing.expectEqualStrings(expected, actual);
    const quoted = try text.translate(a, "module M\ntype T = record<\"a\\\"\\n雪\", string>", &diagnostic);
    var model = try Model.init(a, try description.read(a, quoted));
    const kind = try model.callType(try description.read(a, "<3'ref3\"M.T>"));
    try std.testing.expectEqualStrings("a\"\n雪", kind.record.tag);
}

test "container punctuation and payload counts are grammar errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "list<>",              "list<integer, bool>", "tuple<integer,>",                "record<integer>",
        "record<\"tag\",>",    "tagged<\"tag\">",     "tagged<\"tag\", integer, bool>", "tagged<\"tag\",>",
        "record<\"\\ud800\">",
    }) |expression| {
        var diagnostic: text.Diagnostic = .{};
        const input = try a.print("module M\ntype T = {s}", .{expression});
        try std.testing.expectError(error.InvalidText, text.translate(a, input, &diagnostic));
        try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    }
    for ([_][]const u8{
        "struct Data { value: string }", "record Data { value: string }",
        "type T = map<string, value>",   "type T = string | bool",
    }) |declaration| {
        var diagnostic: text.Diagnostic = .{};
        const input = try a.print("module M\n{s}", .{declaration});
        try std.testing.expectError(error.UnsupportedSyntax, text.translate(a, input, &diagnostic));
    }
}

test "container bounds are validated at the shared model boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "list<symbol>(max_items: -1)",   "list<symbol>(min_items: 1)",
        "list<symbol>(max_bytes: 1)",    "tuple<>(max_items: 1)",
        "record<\"tag\">(max_items: 1)", "tagged<\"tag\", string>(max_items: 1)",
    }) |expression| {
        var diagnostic: text.Diagnostic = .{};
        const input = try a.print("module M\ntype T = {s}", .{expression});
        try std.testing.expectError(error.InvalidDescription, text.translate(a, input, &diagnostic));
        try std.testing.expectEqualStrings("description rejected by checked model", diagnostic.message);
    }
    for ([_][]const u8{
        "<6'tagged3\"tag>", "<6'tagged3\"tag7'integer4'bool>", "<6'tagged1+7'integer>",
    }) |expression| {
        const bytes = try a.print("<17'glowcap:interface1+{{14\"glowcap.values1+}}{{1\"T<4'type{s}>}}>", .{expression});
        try std.testing.expectError(error.InvalidDescription, Model.init(a, try description.read(a, bytes)));
    }
}

test "nested container parsing stays within the existing depth budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var input: std.ArrayList(u8) = .empty;
    try input.appendSlice(a, "module M\ntype T = ");
    for (0..description.max_depth + 1) |_| try input.appendSlice(a, "list<");
    try input.appendSlice(a, "string");
    try input.appendNTimes(a, '>', description.max_depth + 1);
    var diagnostic: text.Diagnostic = .{};
    try std.testing.expectError(error.ResourceLimit, text.translate(a, input.items, &diagnostic));
}
