//! Literals one file owns and others carry verbatim: a browser storage key,
//! a page mark, a default address. Each row names the owner and its mirrors,
//! so a change to the owner that leaves a mirror behind fails here instead of
//! at run time, where a mismatched key or mark fails quietly.

const std = @import("std");
const violation_log = @import("violation_log.zig");

const appendViolation = violation_log.appendViolation;

pub const Pin = struct {
    /// What the literal means, said in the violation.
    what: []const u8,
    literal: []const u8,
    /// The file that defines the literal, where a change to it starts.
    owner: []const u8,
    /// The files that repeat it because they cannot import the owner.
    mirrors: []const []const u8,
};

pub const pins = [_]Pin{
    .{
        .what = "the browser key the website and the Rooms page keep the theme under",
        .literal = "\"glowcap-theme\"",
        .owner = "apps/rooms/web/ui/view_preferences.ts",
        .mirrors = &.{ "apps/rooms/web/ui/page.html", "site/layouts/templates/base.shtml" },
    },
    .{
        .what = "the mark an exported Rooms page carries",
        .literal = "name=\"rooms-host\"",
        .owner = "apps/rooms/rust/services/src/web/export.rs",
        .mirrors = &.{ "apps/rooms/web/ui/page_base.ts", "tools/check/site_pages.ts", "tools/gen/site_normalize.py" },
    },
    .{
        .what = "the Rooms page the website publishes, the one a server admits by default",
        .literal = "https://glowcap.org/rooms/app/",
        .owner = "apps/rooms/rust/services/src/web/relay/limits.rs",
        .mirrors = &.{ "cli/app/rooms/commands.zig", "apps/rooms/web/deploy/docker-compose.yml" },
    },
    .{
        .what = "the listener transports a Rooms peer announces, as every help names them",
        .literal = "tcp, keyed-tcp, noise-tcp, iroh (default), keyed-relay, noise-relay, or onion",
        .owner = "apps/rooms/rust/services/src/server/config.rs",
        .mirrors = &.{
            "apps/rooms/rust/services/src/session/config.rs",
            "apps/rooms/rust/services/src/web/config.rs",
            "apps/rooms/rust/services/src/archive/peer/config.rs",
            "cli/app/rooms/commands.zig",
        },
    },
};

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try checkPins(io, gpa, root, violations, &pins);
}

fn checkPins(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    rows: []const Pin,
) !void {
    for (rows) |pin| {
        const owner = root.readFileAlloc(io, pin.owner, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for the literal pin of {s} with {s}", .{ pin.owner, pin.what, @errorName(err) });
            continue;
        };
        defer gpa.free(owner);
        if (std.mem.indexOf(u8, owner, pin.literal) == null) {
            try appendViolation(gpa, violations, "{s}: no longer holds `{s}`, {s}; move the pin's owner with the literal", .{ pin.owner, pin.literal, pin.what });
            continue;
        }
        for (pin.mirrors) |mirror| {
            const contents = root.readFileAlloc(io, mirror, gpa, .limited(1 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for the literal pin of {s} with {s}", .{ mirror, pin.what, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, pin.literal) == null) {
                try appendViolation(gpa, violations, "{s}: does not carry `{s}` ({s}), which {s} owns", .{ mirror, pin.literal, pin.what, pin.owner });
            }
        }
    }
}

test "a mirror or owner that drops the pinned literal is a violation naming the owner" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const rows = [_]Pin{.{ .what = "a key", .literal = "\"k\"", .owner = "owner.ts", .mirrors = &.{"mirror.html"} }};
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |message| gpa.free(message);
        violations.deinit(gpa);
    }
    for ([_]struct { owner: []const u8, mirror: []const u8, count: usize, names: []const u8 }{
        .{ .owner = "const K = \"k\";", .mirror = "getItem(\"k\")", .count = 0, .names = "" },
        .{ .owner = "const K = \"k\";", .mirror = "getItem(\"key\")", .count = 1, .names = "which owner.ts owns" },
        .{ .owner = "const K = \"key\";", .mirror = "getItem(\"k\")", .count = 1, .names = "move the pin's owner" },
    }) |fixture| {
        for (violations.items) |message| gpa.free(message);
        violations.clearRetainingCapacity();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "owner.ts", .data = fixture.owner });
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "mirror.html", .data = fixture.mirror });
        try checkPins(std.testing.io, gpa, tmp.dir, &violations, &rows);
        try std.testing.expectEqual(fixture.count, violations.items.len);
        for (violations.items) |message| try std.testing.expect(std.mem.indexOf(u8, message, fixture.names) != null);
    }
}
