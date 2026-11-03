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
    const format = args.next() orelse return error.InvalidArguments;
    const input = args.next() orelse return error.InvalidArguments;
    const cwd = std.Io.Dir.cwd();
    const source = try cwd.readFileAlloc(init.io, input, a, .limited(description.max_input_bytes));
    var diagnostic: text.Diagnostic = .{};
    const bytes = if (std.mem.eql(u8, format, "text")) text.translate(a, source, &diagnostic) catch |err| {
        std.debug.print("{s}:{d}:{d}: {s} ({s})\n", .{ input, diagnostic.line, diagnostic.column, diagnostic.message, @errorName(err) });
        return err;
    } else if (std.mem.eql(u8, format, "syrup")) source else return error.InvalidArguments;
    var model = try Model.init(try description.read(a, bytes));
    const emitter = args.next() orelse return; // Check-only invocation.
    const receiver = args.next() orelse return error.InvalidArguments;
    const selector_arg = args.next() orelse return error.InvalidArguments;
    const api = args.next() orelse return error.InvalidArguments;
    try identifier(api);
    const output = args.next() orelse return error.InvalidArguments;
    if (args.next() != null) return error.InvalidArguments;
    const selector: ?[]const u8 = if (std.mem.eql(u8, selector_arg, "--direct")) null else selector_arg;
    const generated = if (std.mem.eql(u8, emitter, "description")) bytes else generated: {
        if (std.mem.eql(u8, emitter, "zig")) break :generated try @import("zig.zig").emit(a, try model.creation(receiver, selector orelse return error.InvalidArguments));
        const call: calls.Named = .{ .api = api, .call = try calls.read(a, &model, receiver, selector) };
        if (std.mem.eql(u8, emitter, "rust")) break :generated try @import("callbacks.zig").emit(a, &.{call});
        if (std.mem.eql(u8, emitter, "ts")) break :generated try @import("typescript.zig").emit(a, &.{call});
        return error.InvalidArguments;
    };
    try cwd.writeFile(init.io, .{ .sub_path = output, .data = generated });
}

// Dynamic names enter source declarations only through this comparison command.
// Accept the shared ASCII identifier subset and refuse either target's keywords.
fn identifier(name: []const u8) error{InvalidIdentifier}!void {
    if (name.len == 0 or std.mem.eql(u8, name, "_")) return error.InvalidIdentifier;
    for (name, 0..) |c, i| {
        if (!(std.ascii.isAlphabetic(c) or c == '_' or (i != 0 and std.ascii.isDigit(c)))) return error.InvalidIdentifier;
    }
    var keywords = std.mem.tokenizeScalar(
        u8,
        "abstract as async await become bool box break case catch char class const continue crate debugger default defer delete do double dyn else enum export extends extern false final finally float fn for function gen goto if impl implements import in instanceof int interface let long loop macro macro_rules match mod move mut namespace native new null override package priv private protected pub public ref return safe self Self short sizeof static struct super switch synchronized this throw throws trait transient true try type typeof union unsafe unsized use var virtual void volatile where while with yield",
        ' ',
    );
    while (keywords.next()) |keyword| if (std.mem.eql(u8, name, keyword)) return error.InvalidIdentifier;
}
