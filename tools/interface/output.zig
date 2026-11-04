//! CLI-owned output publication. Loaded source names are never output names.
//! Atomic replacement preserves other hardlinks and avoids partial output.
const std = @import("std");

pub fn write(a: std.mem.Allocator, io: std.Io, inputs: []const []const u8, output: []const u8, bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var directory = try cwd.openDir(io, std.fs.path.dirname(output) orelse ".", .{});
    defer directory.close(io);
    const name = std.fs.path.basename(output);
    var parent_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const parent = parent_buffer[0..try directory.realPath(io, &parent_buffer)];
    const destination = try std.fs.path.join(a, &.{ parent, name });
    // Check the loaded name as well as a resolved symlink. Replacement never
    // follows the destination symlink, but refusing its source alias avoids
    // silently replacing an input-facing name with generated code.
    const resolved = directory.realPathFileAlloc(io, name, a) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    for (inputs) |input| {
        if (std.mem.eql(u8, input, destination) or (resolved != null and std.mem.eql(u8, input, resolved.?))) return error.OutputIsInput;
    }
    const previous = directory.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const permissions: ?std.Io.File.Permissions = if (previous) |stat| if (stat.kind == .file) stat.permissions else null else null;
    var atomic = try directory.createFileAtomic(io, name, .{ .replace = true, .permissions = permissions orelse .default_file });
    defer atomic.deinit(io);
    // Creation applies umask. Preserve a regular output's exact permissions,
    // while symlink entries and new names retain ordinary creation policy.
    if (permissions) |mode| try atomic.file.setPermissions(io, mode);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    writer.interface.writeAll(bytes) catch return writer.err.?;
    try writer.flush();
    try atomic.replace(io);
}
