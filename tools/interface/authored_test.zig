//! Complete authored contracts match independent bytes and feed checked consumers.
const std = @import("std");
const authored = @import("authored.zig");
const text = @import("text.zig");
const calls = @import("calls.zig");
const expected = @embedFile("contract");

test "complete authored Tasks Loam and qualification bundle equals independent Syrup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diagnostic: text.Diagnostic = .{};
    var compiled = try authored.compile(a, &diagnostic, authored.sources);
    try std.testing.expectEqualStrings(expected, compiled.bytes);
    try std.testing.expectEqual(@as(usize, 28), compiled.model.definitions.children.len / 2);
    const signature = try compiled.model.method("tasks.Task", "text");
    const source = signature[1].source;
    const begin = @intFromPtr(authored.sources[1].bytes.ptr);
    // The checked model borrows the parsed source, not a redecoded byte copy.
    try std.testing.expect(@intFromPtr(source.ptr) >= begin);
    try std.testing.expect(@intFromPtr(source.ptr) - begin < authored.sources[1].bytes.len);
    const rest = try compiled.model.method("fixture.AnyReceiver", null);
    try std.testing.expectEqualStrings("rest", rest[0].children[0].bytes);
    try std.testing.expectError(error.UnsupportedProjection, calls.read(&compiled.model, "fixture.AnyReceiver", null));
}

test "actual imported bound reply and method edits reach generated consumers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diagnostic: text.Diagnostic = .{};
    var inputs = authored.sources;
    inputs[1].bytes = try std.mem.replaceOwned(u8, a, inputs[1].bytes, "max_bytes: 4096", "max_bytes: 2048");
    var bound = try authored.compile(a, &diagnostic, inputs);
    const creation = try bound.model.creation("tasks.TaskList", "add");
    try std.testing.expectEqual(@as(usize, 2048), creation.maximum);
    const zig = try @import("zig.zig").emit(a, creation);
    try std.testing.expect(std.mem.indexOf(u8, zig, "2048") != null);

    inputs = authored.sources;
    inputs[1].bytes = try std.mem.replaceOwned(u8, a, inputs[1].bytes, "text() -> Text", "text() -> Name");
    var reply = try authored.compile(a, &diagnostic, inputs);
    const call = try calls.read(&reply.model, "tasks.Task", "text");
    try std.testing.expectEqual(@as(?u64, 64), call.result.text.max);

    inputs = authored.sources;
    inputs[1].bytes = try std.mem.replaceOwned(u8, a, inputs[1].bytes, "text() -> Text", "content() -> Text");
    var method = try authored.compile(a, &diagnostic, inputs);
    try std.testing.expectError(error.InvalidDescription, method.model.method("tasks.Task", "text"));
    const renamed = try calls.read(&method.model, "tasks.Task", "content");
    const rust = try @import("rust.zig").emit(a, &.{.{ .api = "content", .call = renamed }}, &.{});
    try std.testing.expect(std.mem.indexOf(u8, rust, "\"content\"") != null);
}

test "complete authored bundle reports imported semantic and duplicate errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { before: []const u8, after: []const u8, marker: []const u8 }{
        .{ .before = "type Text = string(min_bytes: 1", .after = "type Text = string(min_bytes: 5000", .marker = "string(min_bytes: 5000" },
        .{ .before = "text() -> Text", .after = "text() -> Missing", .marker = "Missing" },
    }) |case| {
        var inputs = authored.sources;
        inputs[1].bytes = try std.mem.replaceOwned(u8, a, inputs[1].bytes, case.before, case.after);
        var diagnostic: text.Diagnostic = .{};
        try std.testing.expectError(error.InvalidDescription, authored.compile(a, &diagnostic, inputs));
        try std.testing.expectEqualStrings("tasks.interface", diagnostic.path);
        try std.testing.expectEqual(std.mem.indexOf(u8, inputs[1].bytes, case.marker).?, diagnostic.offset);
    }
    var inputs = authored.sources;
    inputs[1].bytes = try std.mem.concat(a, u8, &.{ inputs[1].bytes, "\ntype Name = string\n" });
    var diagnostic: text.Diagnostic = .{};
    try std.testing.expectError(error.InvalidText, authored.compile(a, &diagnostic, inputs));
    try std.testing.expectEqualStrings("tasks.interface", diagnostic.path);
}

test "rest grammar preserves Model placement restrictions and explicit generator refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "module M\ninterface R { (first?: value, ...tail: value) -> value }",
        "module M\ninterface R { (...tail: value, last: value) -> value }",
        "module M\ninterface R { (...tail: value, ...tail: value) -> value }",
    }) |invalid| {
        var diagnostic: text.Diagnostic = .{};
        try std.testing.expectError(error.InvalidDescription, text.compile(a, invalid, &diagnostic));
    }
    for ([_][]const u8{
        "module M\ninterface R { (..tail: value) -> value }",
        "module M\ninterface R { (...tail?: value) -> value }",
    }) |invalid| {
        var diagnostic: text.Diagnostic = .{};
        try std.testing.expectError(error.InvalidText, text.compile(a, invalid, &diagnostic));
    }
}

fn allocationCase(a: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostic: text.Diagnostic = .{};
    var compiled = try authored.compile(arena.allocator(), &diagnostic, authored.sources);
    try std.testing.expectEqualStrings(expected, compiled.bytes);
    _ = try calls.read(&compiled.model, "loam.Receiver", "poll");
}

test "complete compiled bundle releases all allocation failures through selection" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}

test "successful canonical encoding stays within the independent reader depth ceiling" {
    const description = @import("description.zig");
    const Encoder = @import("text_encode.zig").Encoder;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..description.max_depth + 2) |depth| {
        var node: description.Node = .{ .kind = .record, .bytes = "x" };
        for (0..depth) |_| {
            const children = try a.dupe(description.Node, &.{node});
            node = .{ .kind = .list, .children = children };
        }
        var encoder: Encoder = .{ .a = a };
        if (encoder.node(node, 0)) |_| {
            _ = try description.read(a, encoder.bytes.items);
        } else |err| try std.testing.expectEqual(error.ResourceLimit, err);
    }
}

test "canonical record labels consume the independent reader node budget" {
    const description = @import("description.zig");
    const Encoder = @import("text_encode.zig").Encoder;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]usize{ description.max_nodes - 2, description.max_nodes - 1 }) |count| {
        const children = try a.alloc(description.Node, count);
        @memset(children, .{ .kind = .boolean });
        children[count - 1] = .{ .kind = .record, .bytes = "x" };
        var encoder: Encoder = .{ .a = a };
        if (encoder.node(.{ .kind = .list, .children = children }, 0)) |_| {
            _ = try description.read(a, encoder.bytes.items);
        } else |err| try std.testing.expectEqual(error.ResourceLimit, err);
    }
}
