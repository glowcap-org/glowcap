//! Contributor comparison command. Inputs are build artifacts, never session schemas.
const std = @import("std");
const description = @import("description.zig");
const Model = @import("model.zig").Model;
const calls = @import("calls.zig");
const text = @import("text.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const first = args.next() orelse return error.InvalidArguments;
    const root = if (std.mem.eql(u8, first, "--root")) args.next() orelse return error.InvalidArguments else null;
    const format = if (root != null) args.next() orelse return error.InvalidArguments else first;
    const input = args.next() orelse return error.InvalidArguments;
    const cwd = std.Io.Dir.cwd();
    var diagnostic: text.Diagnostic = .{};
    var compiled = if (std.mem.eql(u8, format, "text")) @import("text_loader.zig").compile(a, init.io, input, root, &diagnostic) catch |err| {
        std.debug.print("{s}:{d}:{d}: {s} ({s})\n", .{ if (diagnostic.path.len == 0) input else diagnostic.path, diagnostic.line, diagnostic.column, diagnostic.message, @errorName(err) });
        return err;
    } else if (std.mem.eql(u8, format, "syrup") and root == null) raw: {
        const bytes = try cwd.readFileAlloc(init.io, input, a, .limited(description.max_input_bytes));
        break :raw text.Compiled{ .bytes = bytes, .model = try Model.init(a, try description.read(a, bytes)) };
    } else return error.InvalidArguments;
    const model = &compiled.model;
    const emitter = args.next() orelse return; // Check-only invocation.
    const receiver = args.next() orelse return error.InvalidArguments;
    const selector_kind = args.next() orelse return error.InvalidArguments;
    const selector: ?[]const u8 = if (std.mem.eql(u8, selector_kind, "--direct")) null else if (std.mem.eql(u8, selector_kind, "--named"))
        args.next() orelse return error.InvalidArguments
    else
        return error.InvalidArguments;
    const api = args.next() orelse return error.InvalidArguments;
    const output = args.next() orelse return error.InvalidArguments;
    if (args.next() != null) return error.InvalidArguments;
    const generated = if (std.mem.eql(u8, emitter, "description")) compiled.bytes else generated: {
        if (std.mem.eql(u8, emitter, "zig")) break :generated try @import("zig.zig").emit(a, try model.creation(receiver, selector orelse return error.InvalidArguments));
        const call: calls.Named = .{ .api = api, .call = try calls.read(model, receiver, selector) };
        if (std.mem.eql(u8, emitter, "rust")) break :generated try @import("callbacks.zig").emit(a, &.{call}, &.{});
        if (std.mem.eql(u8, emitter, "ts")) break :generated try @import("typescript.zig").emit(a, &.{call});
        return error.InvalidArguments;
    };
    try cwd.writeFile(init.io, .{ .sub_path = output, .data = generated });
}
