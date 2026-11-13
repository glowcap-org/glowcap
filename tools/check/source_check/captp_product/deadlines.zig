//! CapTP waits are bounded: `.unbounded` stays out of cli/ and examples/zig.

const std = @import("std");
const source_tree = @import("../source_tree.zig");
const text_match = @import("../text_match.zig");
const violation_log = @import("../violation_log.zig");

const appendViolation = violation_log.appendViolation;

/// Product CLI CapTP waits must be finite (ADR-0030). An `.unbounded` budget
/// parks forever on a silent peer, the hang that wedged `cli-test` and left
/// zombie test binaries.
pub fn checkCliCaptpDeadlines(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try checkTree(io, gpa, root, violations, "cli", "an unbounded CapTP budget parks forever on a silent peer; name a finite `.{ .ms = N }` (cli/ has `sessionOpts()`)");
}

/// A teaching surface must not demonstrate the unbounded wait. The compiler
/// refuses an omitted budget (`SessionOptions` has no default), and a `.ms` of
/// zero or less times out immediately, so `.unbounded` is the one spelling
/// left that waits forever. A reader copies an example, so it must not be the
/// place that spelling is learned.
pub fn checkExampleCaptpDeadlines(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try checkTree(io, gpa, root, violations, "examples/zig", "an unbounded CapTP budget waits forever on a silent peer, and a reader copies this line; name a finite `.{ .ms = N }`");
}

/// Report every uncommented `.handshake = .unbounded` or `.settle = .unbounded`
/// in the Zig files under `tree`, with `message` after the location.
fn checkTree(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    tree: []const u8,
    message: []const u8,
) !void {
    const Sink = struct {
        gpa: std.mem.Allocator,
        violations: *std.ArrayList([]const u8),
        message: []const u8,

        fn visit(self: @This(), path: []const u8, contents: []u8) std.mem.Allocator.Error!void {
            text_match.blankComments(contents);
            var line_no: usize = 1;
            var lines = std.mem.splitScalar(u8, contents, '\n');
            while (lines.next()) |line| : (line_no += 1) {
                if (std.mem.find(u8, line, ".handshake = .unbounded") != null or
                    std.mem.find(u8, line, ".settle = .unbounded") != null)
                {
                    try appendViolation(self.gpa, self.violations, "{s}:{d}: {s}", .{ path, line_no, self.message });
                }
            }
        }
    };
    try source_tree.visitSourceFiles(io, gpa, root, violations, "CapTP-deadline", tree, &source_tree.isZigPath, Sink{ .gpa = gpa, .violations = violations, .message = message }, Sink.visit);
}

test "an unbounded CapTP wait is caught on its line, and a commented one is not" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "cli/sub");
    try tmp.dir.createDirPath(std.testing.io, "examples/zig");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "cli/sub/dial.zig",
        .data = "const a = .{ .handshake = .{ .ms = 5 } };\n// .settle = .unbounded reads as prose here\nconst b = .{ .settle = .unbounded };\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "examples/zig/hello.zig",
        .data = "const options = .{ .handshake = .unbounded, .settle = .{ .ms = 5 } };\n",
    });
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |message| gpa.free(message);
        violations.deinit(gpa);
    }
    try checkCliCaptpDeadlines(std.testing.io, gpa, tmp.dir, &violations);
    try checkExampleCaptpDeadlines(std.testing.io, gpa, tmp.dir, &violations);
    try std.testing.expectEqual(@as(usize, 2), violations.items.len);
    try std.testing.expect(std.mem.startsWith(u8, violations.items[0], "cli/sub/dial.zig:3: "));
    try std.testing.expect(std.mem.startsWith(u8, violations.items[1], "examples/zig/hello.zig:1: "));
}
