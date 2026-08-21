//! Test compile-root wiring and separate build-family registration.

const std = @import("std");
const appendViolation = @import("util.zig").appendViolation;

const suite_roots = [_][]const u8{ "test/all_test.zig", "test/oracle_check.zig" };

const Separate = struct {
    test_path: []const u8,
    owner_path: []const u8,
};

/// Optional module graphs are compile roots owned by their build-family module.
/// Naming that owner keeps this audit valid as `build.zig` is split by subject.
const separately_registered = [_]Separate{
    .{ .test_path = "net/completion_loop_deadlines_test.zig", .owner_path = "tools/build/gates.zig" },
    .{ .test_path = "onion_loop_test.zig", .owner_path = "tools/build/gates.zig" },
    .{ .test_path = "net/iroh_locator_test.zig", .owner_path = "tools/build/iroh.zig" },
    .{ .test_path = "net/iroh_resident_internal_test.zig", .owner_path = "tools/build/iroh.zig" },
    .{ .test_path = "net/iroh_sidecar_internal_test.zig", .owner_path = "tools/build/iroh.zig" },
    .{ .test_path = "net/mbedtls_engine_test.zig", .owner_path = "tools/build/mbedtls.zig" },
    .{ .test_path = "net/webrtc_internal_test.zig", .owner_path = "tools/build/webrtc.zig" },
};

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var root_contents: [suite_roots.len][]const u8 = undefined;
    var loaded: usize = 0;
    defer for (root_contents[0..loaded]) |contents| gpa.free(contents);
    for (suite_roots, 0..) |path, i| {
        root_contents[i] = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for test-suite wiring check with {s}", .{ path, @errorName(err) });
            return;
        };
        loaded = i + 1;
    }

    var test_dir = root.openDir(io, "test", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "test: failed to open for test-suite wiring check with {s}", .{@errorName(err)});
        return;
    };
    defer test_dir.close(io);
    var walker = try test_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, "_test.zig")) continue;
        if (std.mem.eql(u8, entry.path, "all_test.zig")) continue;

        var needle_buf: [192]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "@import(\"{s}\")", .{entry.path}) catch {
            try appendViolation(gpa, violations, "test/{s}: path too long for test-suite wiring check", .{entry.path});
            continue;
        };
        var imported = false;
        for (root_contents) |contents|
            imported = imported or std.mem.indexOf(u8, contents, needle) != null;
        if (!imported) imported = try separatelyRegistered(io, gpa, root, entry.path, violations);
        if (!imported) try appendViolation(
            gpa,
            violations,
            "test/{s}: not imported by a suite root or its named build-family owner, its tests silently never run",
            .{entry.path},
        );
    }

    for (suite_roots, root_contents) |path, contents| {
        var rest = contents;
        while (std.mem.indexOf(u8, rest, "@import(\"")) |start| {
            const after = rest[start + "@import(\"".len ..];
            const end = std.mem.indexOfScalar(u8, after, '"') orelse break;
            const target = after[0..end];
            rest = after[end..];
            if (!std.mem.endsWith(u8, target, "_test.zig")) continue;
            var target_buf: [192]u8 = undefined;
            const target_path = std.fmt.bufPrint(&target_buf, "test/{s}", .{target}) catch continue;
            root.access(io, target_path, .{}) catch |err| try appendViolation(
                gpa,
                violations,
                "{s}: imports `{s}` but `{s}` is not accessible ({s})",
                .{ path, target, target_path, @errorName(err) },
            );
        }
    }
}

fn separatelyRegistered(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    test_path: []const u8,
    violations: *std.ArrayList([]const u8),
) !bool {
    for (separately_registered) |row| {
        if (!std.mem.eql(u8, test_path, row.test_path)) continue;
        const owner = root.readFileAlloc(io, row.owner_path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read separate test owner with {s}", .{ row.owner_path, @errorName(err) });
            return false;
        };
        defer gpa.free(owner);
        var needle_buf: [224]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "\"test/{s}\"", .{test_path}) catch return false;
        return std.mem.indexOf(u8, owner, needle) != null;
    }
    return false;
}
