//! The violation sink every source check appends to. The driver prints the
//! collected list and fails the step, so a check never fails it directly.

const std = @import("std");

/// Record one violation. The driver prints the collected list and fails the
/// step when it is non-empty. A check never fails the step directly, so one
/// run reports every violation at once.
pub fn appendViolation(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try violations.append(gpa, try std.fmt.allocPrint(gpa, fmt, args));
}
