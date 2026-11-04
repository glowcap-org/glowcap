//! Contributor comparison command. Inputs are build artifacts, never session schemas.
const std = @import("std");
const description = @import("description.zig");
const Model = @import("model.zig").Model;
const calls = @import("calls.zig");
const text = @import("text.zig");
const loader = @import("text_loader.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var context: Context = .{};
    run(init, a, &context) catch |err| {
        if (!expected(err)) return err;
        context.report(err);
        std.process.exit(1);
    };
}

fn run(init: std.process.Init, a: std.mem.Allocator, context: *Context) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const first = args.next() orelse return error.InvalidArguments;
    const root = if (std.mem.eql(u8, first, "--root")) args.next() orelse return error.InvalidArguments else null;
    const format = if (root != null) args.next() orelse return error.InvalidArguments else first;
    const input = args.next() orelse return error.InvalidArguments;
    context.input = input;
    const cwd = std.Io.Dir.cwd();
    var loaded = if (std.mem.eql(u8, format, "text")) try loader.compile(a, init.io, input, root, &context.diagnostic) else if (std.mem.eql(u8, format, "syrup") and root == null) raw: {
        const bytes = try cwd.readFileAlloc(init.io, input, a, .limited(description.max_input_bytes));
        break :raw loader.Loaded{ .compiled = .{ .bytes = bytes, .model = try Model.init(a, try description.read(a, bytes)) }, .input_paths = try a.dupe([]const u8, &.{try cwd.realPathFileAlloc(init.io, input, a)}) };
    } else return error.InvalidArguments;
    const compiled = &loaded.compiled;
    const model = &compiled.model;
    const emitter = args.next() orelse return; // Check-only invocation.
    context.target = emitter;
    const receiver = args.next() orelse return error.InvalidArguments;
    context.receiver = receiver;
    const selector_kind = args.next() orelse return error.InvalidArguments;
    const selector: ?[]const u8 = if (std.mem.eql(u8, selector_kind, "--direct")) null else if (std.mem.eql(u8, selector_kind, "--named"))
        args.next() orelse return error.InvalidArguments
    else
        return error.InvalidArguments;
    context.selector = selector;
    const api = args.next() orelse return error.InvalidArguments;
    context.api = api;
    const output = args.next() orelse return error.InvalidArguments;
    context.output = output;
    if (args.next() != null) return error.InvalidArguments;
    context.sources = loaded.sources;
    context.paths = loaded.input_paths;
    model.diagnostic = &context.failed;
    defer model.diagnostic = null;
    context.phase = .selection;
    const generated = if (std.mem.eql(u8, emitter, "description")) compiled.bytes else generated: {
        if (std.mem.eql(u8, emitter, "zig")) break :generated try @import("zig.zig").emit(a, try model.creation(receiver, selector orelse return error.InvalidArguments));
        const call: calls.Named = .{ .api = api, .call = try calls.read(model, receiver, selector) };
        context.phase = .emission;
        if (std.mem.eql(u8, emitter, "rust")) break :generated try @import("rust.zig").emit(a, &.{call}, &.{});
        if (std.mem.eql(u8, emitter, "ts")) break :generated try @import("typescript.zig").emit(a, &.{call});
        return error.InvalidArguments;
    };
    context.phase = .output;
    try @import("output.zig").write(a, init.io, loaded.input_paths, output, generated);
}

const Context = struct {
    input: []const u8 = "interface-authoring",
    target: ?[]const u8 = null,
    receiver: []const u8 = "",
    selector: ?[]const u8 = null,
    api: ?[]const u8 = null,
    output: []const u8 = "",
    phase: enum { input, selection, emission, output } = .input,
    diagnostic: text.Diagnostic = .{},
    failed: ?description.Node = null,
    sources: []const text.Module = &.{},
    paths: []const []const u8 = &.{},

    fn report(self: *Context, err: anyerror) void {
        if (self.failed) |node| for (self.sources, 0..) |module, i| {
            if (self.diagnostic.setOrigin(.{ .path = self.paths[i], .bytes = module.source.bytes }, node.source, "")) break;
        };
        const diagnostic = self.diagnostic;
        std.debug.print("{s}:{d}:{d}: ", .{ if (diagnostic.path.len == 0) self.input else diagnostic.path, diagnostic.line, diagnostic.column });
        if (self.target) |target| {
            std.debug.print("cannot generate {s} for {s} ", .{ target, self.receiver });
            if (self.selector) |selector| std.debug.print("named \"{f}\"", .{std.zig.fmtString(selector)}) else std.debug.print("direct invocation", .{});
            if (self.api) |api| std.debug.print(" as \"{f}\"", .{std.zig.fmtString(api)});
            std.debug.print(" (input {s}): ", .{self.input});
        }
        const message = if (diagnostic.message.len != 0) diagnostic.message else switch (err) {
            error.OutputIsInput => "output names a compilation input",
            error.InvalidDescription => if (self.phase == .selection) "no matching interface/method selection" else "invalid interface description",
            error.UnsupportedTarget, error.UnsupportedProjection => "selected declaration is not supported by this target",
            error.InvalidIdentifier => "invalid generated API name",
            error.ExportCollision => "generated API name conflicts with another public export",
            else => @errorName(err),
        };
        std.debug.print("{s} ({s})\n", .{ message, @errorName(err) });
        if (self.phase == .output) std.debug.print("output: {s}\n", .{self.output});
        if (err == error.InvalidArguments) std.debug.print("usage: interface-authoring [--root DIRECTORY] text|syrup INPUT [TARGET RECEIVER --direct|--named NAME API OUTPUT]\n", .{});
    }
};

/// Expected refusals are CLI diagnostics. Unknown faults retain Zig's trace.
fn expected(err: anyerror) bool {
    if (err == error.OutOfMemory or err == error.Unexpected) return false;
    inline for (@typeInfo(text.Error).error_set.error_names.?) |name| {
        if (err == @field(text.Error, name)) return true;
    }
    return switch (err) {
        error.InvalidArguments,
        error.InvalidIdentifier,
        error.ExportCollision,
        error.UnsupportedTarget,
        error.ImportOutsideRoot,
        error.InvalidImportPath,
        error.SourceChanged,
        error.OutputIsInput,
        error.FileNotFound,
        error.PathAlreadyExists,
        error.IsDir,
        error.NotDir,
        error.AccessDenied,
        error.PermissionDenied,
        error.NoSpaceLeft,
        error.DiskQuota,
        error.ReadOnlyFileSystem,
        error.FileTooBig,
        error.NameTooLong,
        error.SymLinkLoop,
        error.StreamTooLong,
        error.InputOutput,
        => true,
        else => false,
    };
}
