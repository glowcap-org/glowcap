//! The authoring CLI owns rooted filesystem access and one read per real file.
//! Pure translation and shared validation receive only cached source bytes.
const std = @import("std");
const builtin = @import("builtin");
const text = @import("text.zig");
const description = @import("description.zig");

fn openSource(io: std.Io, path: []const u8) !std.Io.File {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return std.Io.Dir.cwd().openFile(io, path, .{});
    // Io's ordinary POSIX opener can wait for a FIFO writer before stat.
    // O_NONBLOCK lets the existing descriptor-kind check reject it first.
    var flags: std.posix.O = .{ .ACCMODE = .RDONLY, .NONBLOCK = true };
    if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "NOCTTY")) flags.NOCTTY = true;
    const handle = try std.posix.openat(std.posix.AT.FDCWD, path, flags, 0);
    return .{ .handle = handle, .flags = .{ .nonblocking = true } };
}

/// The caller owns a compilation arena lasting through emission and diagnostics.
/// Sources, cached paths, intermediate nodes and the result all belong to it.
pub fn translate(a: std.mem.Allocator, io: std.Io, input: []const u8, root_option: ?[]const u8, diagnostic: *text.Diagnostic) ![]u8 {
    diagnostic.* = .{};
    const cwd = std.Io.Dir.cwd();
    const root = try cwd.realPathFileAlloc(io, root_option orelse std.fs.path.dirname(input) orelse ".", a);
    var loader: Loader = .{ .a = a, .io = io, .root = root, .bundle = .{ .a = a, .diagnostic = diagnostic } };
    _ = loader.load(input, 0) catch |err| {
        if (diagnostic.message.len == 0) diagnostic.* = .{ .path = input, .message = @errorName(err) };
        return err;
    };
    return loader.bundle.translate();
}

const Loader = struct {
    a: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    bundle: text.Bundle,
    paths: std.ArrayList([]const u8) = .empty,

    fn relative(self: Loader, path: []const u8) ![]const u8 {
        if (std.mem.eql(u8, self.root, std.fs.path.sep_str)) return path[1..];
        if (!std.mem.startsWith(u8, path, self.root) or path.len <= self.root.len or path[self.root.len] != std.fs.path.sep) return error.ImportOutsideRoot;
        return path[self.root.len + 1 ..];
    }

    fn load(self: *Loader, input: []const u8, depth: usize) !usize {
        const real = try std.Io.Dir.cwd().realPathFileAlloc(self.io, input, self.a);
        return self.loadResolved(real, depth);
    }

    fn loadResolved(self: *Loader, real: []const u8, depth: usize) !usize {
        const cwd = std.Io.Dir.cwd();
        const relative_path = try self.relative(real);
        for (self.paths.items, 0..) |previous, i| if (std.mem.eql(u8, previous, real)) return i;
        if (depth > text.max_import_depth or self.paths.items.len == text.max_files) return error.ResourceLimit;
        var file = try openSource(self.io, real);
        defer file.close(self.io);
        // Check the opened identity, rather than trusting a pathname checked
        // before a symlink or directory could change.
        var identity_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const identity_length = try file.realPath(self.io, &identity_buffer);
        const identity = identity_buffer[0..identity_length];
        _ = try self.relative(identity);
        if (!std.mem.eql(u8, identity, real)) return error.SourceChanged;
        if ((try file.stat(self.io)).kind != .file) return error.InvalidImportPath;
        var reader = file.reader(self.io, &.{});
        const source = reader.interface.allocRemaining(self.a, .limited(description.max_input_bytes - self.bundle.input_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.ResourceLimit,
            error.ReadFailed => return reader.err.?,
            else => return err,
        };
        const index = try self.bundle.add(.{ .path = relative_path, .bytes = source });
        try self.paths.append(self.a, real);
        const imports = self.bundle.modules.items[index].header.imports;
        const order = try self.a.alloc(usize, imports.len);
        for (order, 0..) |*at, i| at.* = i;
        std.mem.sort(usize, order, imports, struct {
            fn less(items: []@import("text_parser.zig").Import, left: usize, right: usize) bool {
                return std.mem.order(u8, items[left].path, items[right].path) == .lt;
            }
        }.less);
        const Dependency = struct { path: []const u8, import_index: usize };
        const dependencies = try self.a.alloc(Dependency, imports.len);
        for (order, dependencies) |at, *dependency| {
            const import = imports[at];
            errdefer if (self.bundle.diagnostic.message.len == 0) self.bundle.diagnostic.set(.{ .path = relative_path, .bytes = source }, import.offset, "import could not be loaded");
            if (import.path.len == 0 or std.fs.path.isAbsolute(import.path) or std.mem.indexOfScalar(u8, import.path, ':') != null or std.mem.indexOfScalar(u8, import.path, '\\') != null) return error.InvalidImportPath;
            const path = try std.fs.path.join(self.a, &.{ std.fs.path.dirname(real).?, import.path });
            const resolved = try cwd.realPathFileAlloc(self.io, path, self.a);
            _ = try self.relative(resolved);
            dependency.* = .{ .path = resolved, .import_index = at };
        }
        // All dependencies share the same root prefix, so canonical path order
        // is root-relative order even when an import uses a symlink alias.
        std.mem.sort(Dependency, dependencies, {}, struct {
            fn less(_: void, left: Dependency, right: Dependency) bool {
                return std.mem.order(u8, left.path, right.path) == .lt;
            }
        }.less);
        for (dependencies) |dependency| {
            const import = imports[dependency.import_index];
            errdefer if (self.bundle.diagnostic.message.len == 0) self.bundle.diagnostic.set(.{ .path = relative_path, .bytes = source }, import.offset, "import could not be loaded");
            imports[dependency.import_index].target = try self.loadResolved(dependency.path, depth + 1);
        }
        return index;
    }
};
