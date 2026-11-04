//! Preloaded-module scenarios compare independent descriptions and source errors.
const std = @import("std");
const text = @import("text.zig");
const source = @embedFile("imported_text");
const shared = @embedFile("imported_shared");
const expected = @embedFile("imported_expected");

fn bundle(a: std.mem.Allocator, diagnostic: *text.Diagnostic, root: []const u8, library: []const u8, reverse: bool) !text.Bundle {
    var result: text.Bundle = .{ .a = a, .diagnostic = diagnostic };
    const first = if (reverse) library else root;
    const second = if (reverse) root else library;
    _ = try result.add(.{ .path = if (reverse) "shared/loam.interface" else "board.interface", .bytes = first });
    _ = try result.add(.{ .path = if (reverse) "board.interface" else "shared/loam.interface", .bytes = second });
    for (result.modules.items, 0..) |module, i| {
        for (module.header.imports) |*import| import.target = 1 - i;
    }
    return result;
}

test "imported headers bind aliases to declared module IDs and allow cached cycles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |reverse| {
        var diagnostic: text.Diagnostic = .{};
        var input = try bundle(arena.allocator(), &diagnostic, source, shared, reverse);
        try std.testing.expectEqualStrings(expected, try input.translate());
    }
}

test "imported bound and unresolved type diagnostics preserve the innermost source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { before: []const u8, after: []const u8, line: usize, column: usize }{
        .{ .before = "min_bytes: 1", .after = "min_bytes: 65", .line = 4, .column = 13 },
        .{ .before = "read() -> Name", .after = "read() -> Missing", .line = 8, .column = 13 },
        .{ .before = "min_bytes: 1", .after = "max_items: 1", .line = 4, .column = 20 },
    }) |case| {
        const invalid = try std.mem.replaceOwned(u8, a, shared, case.before, case.after);
        var diagnostic: text.Diagnostic = .{};
        var input = try bundle(a, &diagnostic, source, invalid, false);
        try std.testing.expectError(error.InvalidDescription, input.translate());
        try std.testing.expectEqualStrings("shared/loam.interface", diagnostic.path);
        try std.testing.expectEqual(case.line, diagnostic.line);
        try std.testing.expectEqual(case.column, diagnostic.column);
    }
}

test "bundle refuses duplicate aliases modules declarations and missing preload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diagnostic: text.Diagnostic = .{};
    var input: text.Bundle = .{ .a = a, .diagnostic = &diagnostic };
    try std.testing.expectError(error.InvalidText, input.add(.{ .path = "invalid", .bytes = "module M..N" }));
    input = .{ .a = a, .diagnostic = &diagnostic };
    try std.testing.expectError(error.InvalidText, input.add(.{ .path = "root", .bytes = "module M\nimport \"a\" as a\nimport \"b\" as a" }));
    try std.testing.expectEqualStrings("root", diagnostic.path);
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);
    input = .{ .a = a, .diagnostic = &diagnostic };
    _ = try input.add(.{ .path = "a", .bytes = "module M" });
    try std.testing.expectError(error.InvalidText, input.add(.{ .path = "b", .bytes = "module M" }));
    try std.testing.expectEqualStrings("b", diagnostic.path);
    input = .{ .a = a, .diagnostic = &diagnostic };
    _ = try input.add(.{ .path = "a", .bytes = "module M\ntype T = string\ntype T = bool" });
    try std.testing.expectError(error.InvalidText, input.translate());
    try std.testing.expectEqualStrings("a", diagnostic.path);
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);
    try std.testing.expectError(error.MissingImport, text.translate(a, "module M\nimport \"a\" as a", &diagnostic));
}

test "module input and token budgets cover the aggregate compilation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diagnostic: text.Diagnostic = .{};
    var input: text.Bundle = .{ .a = a, .diagnostic = &diagnostic };
    const large = try a.alloc(u8, @import("description.zig").max_input_bytes / 2 + 1);
    @memset(large, ' ');
    @memcpy(large[0..8], "module A");
    _ = try input.add(.{ .path = "a", .bytes = large });
    try std.testing.expectError(error.ResourceLimit, input.add(.{ .path = "b", .bytes = large }));
    input = .{ .a = a, .diagnostic = &diagnostic };
    for (0..text.max_files) |i| _ = try input.add(.{ .path = "a", .bytes = try std.fmt.allocPrint(a, "module M{d}", .{i}) });
    try std.testing.expectError(error.ResourceLimit, input.add(.{ .path = "b", .bytes = "module Extra" }));
    input = .{ .a = a, .diagnostic = &diagnostic };
    _ = try input.add(.{ .path = "a", .bytes = "module A\ntype T = string" });
    input.budget.tokens = 0;
    try std.testing.expectError(error.ResourceLimit, input.translate());
}

fn allocationCase(a: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostic: text.Diagnostic = .{};
    var input = try bundle(arena.allocator(), &diagnostic, source, shared, false);
    try std.testing.expectEqualStrings(expected, try input.translate());
}

test "imported bundle allocation failures release parser encoder and model scratch" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
