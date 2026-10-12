//! A Rooms session access is asked what it may do, never which rung it is.
//!
//! The access a link carries is a ladder, none, observe, interact, admin, and
//! code that reads it by comparing against one rung is code that will be wrong
//! the next time a rung is added. That is not hypothetical here. `observe` was
//! once the bottom, so "not observe" meant "more than an observer"; adding a
//! suspended rung below it silently promoted a link carrying nothing above an
//! observer in three places at once, and its lines came back editable. The
//! answer was `mayInteract`, which asks the authority by name.
//!
//! The same shape then appeared from the other end. A suspended link was found
//! by `=== "none"` in the guard that refuses its verbs, in the bar that says
//! why, and in the composer's line, so a rung added between none and observe
//! would have walked through every one of them, and through the verb guard,
//! that is every verb the session has. The answer is `mayObserve`, asked the
//! same way.
//!
//! So this bans the spellings, not the idea. Asking whether an access is the
//! top rung is safe by construction, because a rung above admin would be denied
//! by `=== "admin"` rather than admitted; it is naming the bottom that admits
//! what nobody has considered. Tests may still compare, because a test asserting
//! that a suspended grant reports "none" is asserting exactly that.
//!
//! Validated by putting each banned spelling back: every one is caught.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

/// Where a session access is read to decide something. Tests live outside these,
/// under `apps/rooms/test`, and are not held to this.
const decided_in = [_][]const u8{
    "apps/rooms/web/ui",
    "apps/rooms/lib",
};

/// Naming the bottom rung. Both directions, because `!== "none"` is the same
/// mistake wearing the other sign: it admits an unconsidered rung to whatever
/// the true arm does.
const banned = [_][]const u8{
    "access === \"none\"",
    "access !== \"none\"",
    "rights === \"none\"",
    "rights !== \"none\"",
};

fn isSource(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".tsx");
}

/// The browser bundle is a build artifact that happens to sit in the tree, and
/// it carries whatever the sources said in minified form.
fn isGenerated(path: []const u8) bool {
    return std.mem.endsWith(u8, path, "page.js");
}

pub fn checkRoomsSessionAccess(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (decided_in) |tree| {
        var dir = root.openDir(io, tree, .{ .iterate = true }) catch {
            try appendViolation(gpa, violations, "{s}: could not open for the session-access ban", .{tree});
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !isSource(entry.path) or isGenerated(entry.path)) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ tree, entry.path });
            defer gpa.free(path);
            const source = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch {
                try appendViolation(gpa, violations, "{s}: could not read for the session-access ban", .{path});
                continue;
            };
            defer gpa.free(source);
            for (banned) |needle| {
                if (std.mem.indexOf(u8, source, needle) == null) continue;
                try appendViolation(
                    gpa,
                    violations,
                    "{s} compares a session access with `{s}`: ask what the access may do — `mayObserve` for whether it may be shown the session at all, `mayInteract` for whether it may act — so a rung added to the ladder is answered for rather than admitted",
                    .{ path, needle },
                );
            }
        }
    }
}
