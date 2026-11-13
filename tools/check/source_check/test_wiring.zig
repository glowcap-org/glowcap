//! Test compile-root wiring and separate build-family registration, for the
//! suites under `test/` and for the checks' own unit tests.

const std = @import("std");
const appendViolation = @import("violation_log.zig").appendViolation;
const blankComments = @import("text_match.zig").blankComments;

const suite_roots = [_][]const u8{ "test/all_test.zig", "test/oracle_check.zig", "test/loam_lmdb_test.zig", "test/loam_sqlite_test.zig" };

const Separate = struct {
    test_path: []const u8,
    owner_path: []const u8,
};

/// Optional module graphs are compile roots owned by their build-family module.
/// Naming that owner keeps this audit valid as `build.zig` is split by subject.
const separately_registered = [_]Separate{
    .{ .test_path = "c_abi/loam_execution_test.zig", .owner_path = "tools/build/loam_abi.zig" },
    .{ .test_path = "c_abi/loam_test.zig", .owner_path = "tools/build/loam_abi.zig" },
    .{ .test_path = "loam_lmdb_test.zig", .owner_path = "tools/build/loam/lmdb.zig" },
    .{ .test_path = "loam_sqlite_test.zig", .owner_path = "tools/build/loam/sqlite.zig" },
    .{ .test_path = "net/completion_loop_deadlines_test.zig", .owner_path = "tools/build/gates.zig" },
    .{ .test_path = "onion_loop_test.zig", .owner_path = "tools/build/gates.zig" },
    .{ .test_path = "onion_pending_test.zig", .owner_path = "tools/build/gates.zig" },
    .{ .test_path = "net/iroh_locator_test.zig", .owner_path = "tools/build/iroh.zig" },
    .{ .test_path = "net/iroh_resident_internal_test.zig", .owner_path = "tools/build/iroh.zig" },
    .{ .test_path = "net/iroh_sidecar_internal_test.zig", .owner_path = "tools/build/iroh.zig" },
    .{ .test_path = "net/mbedtls_engine_test.zig", .owner_path = "tools/build/relay_tls.zig" },
    .{ .test_path = "net/webrtc_internal_test.zig", .owner_path = "tools/build/webrtc.zig" },
    .{ .test_path = "net/webrtc_signal_contract_test.zig", .owner_path = "tools/build/webrtc.zig" },
    .{ .test_path = "net/webrtc_provider_dial_test.zig", .owner_path = "tools/build/webrtc.zig" },
    .{ .test_path = "net/webrtc_provider_accept_test.zig", .owner_path = "tools/build/webrtc.zig" },
};

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try checkTypeScript(io, gpa, root, violations);
    try checkCheckerTests(io, gpa, root, violations);

    var root_contents: [suite_roots.len][]u8 = undefined;
    var loaded: usize = 0;
    defer for (root_contents[0..loaded]) |contents| gpa.free(contents);
    for (suite_roots, 0..) |path, i| {
        root_contents[i] = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for test-suite wiring check with {s}", .{ path, @errorName(err) });
            return;
        };
        loaded = i + 1;
        // A commented-out import runs nothing, so it wires nothing.
        blankComments(root_contents[i]);
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
        const needle = std.mem.print(&needle_buf, "@import(\"{s}\")", .{entry.path}) catch {
            try appendViolation(gpa, violations, "test/{s}: path too long for test-suite wiring check", .{entry.path});
            continue;
        };
        var imported = importedByAny(&root_contents, needle);
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
        while (std.mem.find(u8, rest, "@import(\"")) |start| {
            const after = rest[start + "@import(\"".len ..];
            const end = std.mem.findScalar(u8, after, '"') orelse break;
            const target = after[0..end];
            rest = after[end..];
            if (!std.mem.endsWith(u8, target, "_test.zig")) continue;
            var target_buf: [192]u8 = undefined;
            const target_path = std.mem.print(&target_buf, "test/{s}", .{target}) catch {
                try appendViolation(gpa, violations, "test/{s}: the target path overflows the wiring needle buffer; grow it", .{target});
                continue;
            };
            root.access(io, target_path, .{}) catch |err| try appendViolation(
                gpa,
                violations,
                "{s}: imports `{s}` but `{s}` is not accessible ({s})",
                .{ path, target, target_path, @errorName(err) },
            );
        }
    }
}

/// Every Rooms TypeScript test is either in the ordinary aggregate batches or
/// owns a named product scenario in the Rooms build package. Merely placing a
/// `Deno.test` file under the test directory does not make any build step run
/// it, so `rooms.zig` and its subject modules are the one authority this
/// inventory checks.
/// A directory of TypeScript tests and the build files that run them. A step
/// names each test by its path from the repository root, or from `dir` itself
/// when the step runs there.
const TypeScriptSuite = struct {
    dir: []const u8,
    owners: []const []const u8,
    runs_inside: bool = false,
};

const typescript_suites = [_]TypeScriptSuite{
    .{ .dir = "test/driver/transports", .owners = &.{"tools/build/"} },
    .{ .dir = "apps/rooms/test", .owners = &.{ "tools/build/rooms.zig", "tools/build/rooms/" } },
    .{ .dir = "bindings/ts", .owners = &.{"tools/build/"}, .runs_inside = true },
};

fn checkTypeScript(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (typescript_suites) |suite| try checkTypeScriptSuite(io, gpa, root, suite, violations);
}

fn checkTypeScriptSuite(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    suite: TypeScriptSuite,
    violations: *std.ArrayList([]const u8),
) !void {
    var owners: std.ArrayList(u8) = .empty;
    defer owners.deinit(gpa);
    for (suite.owners) |owner| {
        const body = (try @import("source_tree.zig").readSourceSubject(io, gpa, root, owner)) orelse {
            try appendViolation(gpa, violations, "{s}: failed to read the owner of the {s} tests", .{ owner, suite.dir });
            return;
        };
        defer gpa.free(body);
        try owners.appendSlice(gpa, body);
    }

    var test_dir = root.openDir(io, suite.dir, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for test wiring check with {s}", .{
            suite.dir,
            @errorName(err),
        });
        return;
    };
    defer test_dir.close(io);
    var walker = try test_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, "_test.ts")) continue;
        var rooted_buf: [256]u8 = undefined;
        var inside_buf: [256]u8 = undefined;
        const rooted = std.mem.print(&rooted_buf, "\"{s}/{s}\"", .{ suite.dir, entry.path }) catch null;
        const inside = std.mem.print(&inside_buf, "\"{s}\"", .{entry.path}) catch null;
        if (rooted == null or inside == null) {
            try appendViolation(gpa, violations, "{s}/{s}: path too long for test wiring check", .{ suite.dir, entry.path });
            continue;
        }
        const named = std.mem.find(u8, owners.items, rooted.?) != null or
            (suite.runs_inside and std.mem.find(u8, owners.items, inside.?) != null);
        if (!named) try appendViolation(
            gpa,
            violations,
            "{s}/{s}: no build step names it, so it never runs",
            .{ suite.dir, entry.path },
        );
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
        blankComments(owner);
        var needle_buf: [224]u8 = undefined;
        const needle = std.mem.print(&needle_buf, "\"test/{s}\"", .{test_path}) catch return false;
        return std.mem.find(u8, owner, needle) != null;
    }
    return false;
}

/// Whether any comment-blanked root contains `needle`.
fn importedByAny(roots: []const []u8, needle: []const u8) bool {
    for (roots) |contents| if (std.mem.find(u8, contents, needle) != null) return true;
    return false;
}

test "a commented-out suite import wires nothing" {
    const needle = "@import(\"net/x_test.zig\")";
    var commented = "test {\n    // _ = @import(\"net/x_test.zig\");\n}\n".*;
    blankComments(&commented);
    try std.testing.expect(!importedByAny(&.{&commented}, needle));

    var live = "test {\n    _ = @import(\"net/x_test.zig\"); // runs\n}\n".*;
    blankComments(&live);
    try std.testing.expect(importedByAny(&.{&live}, needle));
}

const checker_root = "tools/check/source_check.zig";
const checker_modules = "tools/check/source_check";

/// The checks' own unit tests reach their artifact the same way. Zig compiles
/// a file's `test` declarations only when a test block refers to the file, and
/// the `test` block of `checker_root` is the one list. A check module with
/// tests that the block does not import has tests that pass by never running.
fn checkCheckerTests(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const root_source = root.readFileAlloc(io, checker_root, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for checker test wiring with {s}", .{ checker_root, @errorName(err) });
        return;
    };
    defer gpa.free(root_source);
    const block = testBlock(root_source) orelse {
        try appendViolation(gpa, violations, "{s}: has no `test {{` block to import the check modules' tests", .{checker_root});
        return;
    };

    var dir = root.openDir(io, checker_modules, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for checker test wiring with {s}", .{ checker_modules, @errorName(err) });
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const source = dir.readFileAlloc(io, entry.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}/{s}: failed to read for checker test wiring with {s}", .{ checker_modules, entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(source);
        // A comment after the opening brace would hide the declaration.
        blankComments(source);
        if (!declaresTest(source)) continue;
        if (!try imports(gpa, block, entry.path)) try appendViolation(
            gpa,
            violations,
            "{s}/{s}: declares tests the `test` block in {s} does not import, so they never run; add `_ = @import(\"source_check/{s}\");` there",
            .{ checker_modules, entry.path, checker_root, entry.path },
        );
    }
}

/// The body of the root's anonymous `test` block, with comments blanked in
/// place, because a commented-out import runs nothing and wires nothing.
fn testBlock(source: []u8) ?[]const u8 {
    blankComments(source);
    const open = "\ntest {\n";
    const start = (std.mem.find(u8, source, open) orelse return null) + open.len;
    const len = std.mem.find(u8, source[start..], "\n}") orelse return null;
    return source[start..][0..len];
}

/// True when a line of `source` opens a `test` declaration: a named one, an
/// anonymous one, or one named for a declaration, at any indent.
fn declaresTest(source: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const code = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, code, "test ") and std.mem.endsWith(u8, code, "{")) return true;
    }
    return false;
}

/// True when `block` imports the module at `path` under the modules directory.
fn imports(gpa: std.mem.Allocator, block: []const u8, path: []const u8) !bool {
    const line = try gpa.print("_ = @import(\"source_check/{s}\");", .{path});
    defer gpa.free(line);
    return std.mem.find(u8, block, line) != null;
}

test "a module's tests run only when the root's test block imports the module" {
    const gpa = std.testing.allocator;
    const root_source = try gpa.dupe(u8,
        \\const a = @import("source_check/a.zig");
        \\
        \\test {
        \\    _ = @import("source_check/b/c.zig");
        \\    // _ = @import("source_check/d.zig");
        \\}
        \\
        \\test "named" {}
    );
    defer gpa.free(root_source);
    const block = testBlock(root_source).?;
    try std.testing.expect(!try imports(gpa, block, "d.zig"));
    try std.testing.expect(try imports(gpa, block, "b/c.zig"));
    // A module the root imports for its code alone has unwired tests.
    try std.testing.expect(!try imports(gpa, block, "a.zig"));
    try std.testing.expect(!try imports(gpa, block, "c.zig"));
    var no_block = "test \"named\" {}\n".*;
    try std.testing.expect(testBlock(&no_block) == null);

    try std.testing.expect(declaresTest("const x = 1;\ntest \"x is one\" {\n}\n"));
    try std.testing.expect(declaresTest("test {\n    _ = x;\n}\n"));
    try std.testing.expect(declaresTest("const T = struct {\n    test parse {\n    }\n};\n"));
    try std.testing.expect(!declaresTest("// test \"commented\"\nconst s = \"test \\\"quoted\\\"\";\n"));
    var trailing = "test \"x is one\" { // why\n}\n".*;
    try std.testing.expect(!declaresTest(&trailing));
    blankComments(&trailing);
    try std.testing.expect(declaresTest(&trailing));
}
