//! The TypeScript package publish surface, and the JSONC normalization it
//! reads deno configs through.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const sectionBody = util.sectionBody;
const collectBulletSpans = util.collectBulletSpans;

/// Each `@pancake/*` workspace member under `bindings/ts/` is a publishable
/// package. Its directory is the ship surface; tests, harnesses, smokes,
/// benches, and probes live under that package's `test/` (or the workspace
/// `dogfood/`). A co-located `*_test.ts` next to `mod.ts` makes a broad
/// `publish.include` of `**/*.ts` ship test code unless someone remembers an
/// exclude — and remembering is not a gate.
fn jsonWithoutComments(gpa: std.mem.Allocator, contents: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, contents);
    var at: usize = 0;
    var in_string = false;
    var escaped = false;
    while (at < out.len) {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (out[at] == '\\') {
                escaped = true;
            } else if (out[at] == '"') {
                in_string = false;
            }
            at += 1;
            continue;
        }
        if (out[at] == '"') {
            in_string = true;
            at += 1;
            continue;
        }
        if (out[at] != '/' or at + 1 == out.len) {
            at += 1;
            continue;
        }
        if (out[at + 1] == '/') {
            out[at] = ' ';
            out[at + 1] = ' ';
            at += 2;
            while (at < out.len and out[at] != '\n' and out[at] != '\r') : (at += 1) out[at] = ' ';
            continue;
        }
        if (out[at + 1] == '*') {
            out[at] = ' ';
            out[at + 1] = ' ';
            at += 2;
            var closed = false;
            while (at < out.len) : (at += 1) {
                if (at + 1 < out.len and out[at] == '*' and out[at + 1] == '/') {
                    out[at] = ' ';
                    out[at + 1] = ' ';
                    at += 2;
                    closed = true;
                    break;
                }
                if (out[at] != '\n' and out[at] != '\r') out[at] = ' ';
            }
            if (!closed) return error.UnterminatedJsonComment;
            continue;
        }
        at += 1;
    }
    return out;
}

test "JSONC normalization preserves comment markers inside strings" {
    const source =
        \\{
        \\  // workspace-level note
        \\  "url": "https://example.invalid/a//b",
        \\  "marker": "/* data */",
        \\  /* task note */
        \\  "tasks": { "check": "deno check mod.ts" }
        \\}
    ;
    const normalized = try jsonWithoutComments(std.testing.allocator, source);
    defer std.testing.allocator.free(normalized);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, normalized, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "https://example.invalid/a//b",
        parsed.value.object.get("url").?.string,
    );
    try std.testing.expectEqualStrings("/* data */", parsed.value.object.get("marker").?.string);
    try std.testing.expectEqualStrings(
        "deno check mod.ts",
        parsed.value.object.get("tasks").?.object.get("check").?.string,
    );
}

fn commandHasToken(command: []const u8, token: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, command, " \t\r\n");
    while (words.next()) |word| if (std.mem.eql(u8, word, token)) return true;
    return false;
}

pub fn checkTsPackagePublishSurface(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // This is the expected package inventory. The workspace config is JSONC,
    // normalized once and then traversed as structured JSON below.
    const packages = [_][]const u8{
        "abi",
        "runtime",
        "tcp",
        "inproc",
        "onion",
        "iroh",
        "relay",
        "webrtc",
        "web",
    };
    const workspace_path = "bindings/ts/deno.json";
    const workspace = root.readFileAlloc(io, workspace_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ workspace_path, @errorName(err) });
        return;
    };
    defer gpa.free(workspace);
    const workspace_json = jsonWithoutComments(gpa, workspace) catch |err| {
        try appendViolation(gpa, violations, "{s}: invalid JSONC ({s})", .{ workspace_path, @errorName(err) });
        return;
    };
    defer gpa.free(workspace_json);
    const parsed_workspace = std.json.parseFromSlice(std.json.Value, gpa, workspace_json, .{}) catch |err| {
        try appendViolation(gpa, violations, "{s}: invalid JSONC ({s})", .{ workspace_path, @errorName(err) });
        return;
    };
    defer parsed_workspace.deinit();
    const workspace_object = switch (parsed_workspace.value) {
        .object => |object| object,
        else => {
            try appendViolation(gpa, violations, "{s}: root must be an object", .{workspace_path});
            return;
        },
    };
    const members = switch (workspace_object.get("workspace") orelse .null) {
        .array => |array| array,
        else => {
            try appendViolation(gpa, violations, "{s}: `workspace` must be an array", .{workspace_path});
            return;
        },
    };
    for (packages) |pkg| {
        var member_buf: [32]u8 = undefined;
        const member = std.fmt.bufPrint(&member_buf, "./{s}", .{pkg}) catch continue;
        var found = false;
        for (members.items) |value| switch (value) {
            .string => |actual| if (std.mem.eql(u8, actual, member)) {
                found = true;
                break;
            },
            else => {},
        };
        if (!found) {
            try appendViolation(
                gpa,
                violations,
                "{s}: workspace is missing `./{s}`; update checkTsPackagePublishSurface's package list or the workspace array",
                .{ workspace_path, pkg },
            );
        }
    }
    for (members.items) |value| {
        const member = switch (value) {
            .string => |string| string,
            else => {
                try appendViolation(gpa, violations, "{s}: every workspace member must be a string", .{workspace_path});
                continue;
            },
        };
        const pkg = if (std.mem.startsWith(u8, member, "./")) member[2..] else member;
        var found = false;
        for (packages) |expected| if (std.mem.eql(u8, pkg, expected)) {
            found = true;
            break;
        };
        if (!found) try appendViolation(
            gpa,
            violations,
            "{s}: workspace member `{s}` is missing from checkTsPackagePublishSurface's package inventory",
            .{ workspace_path, member },
        );
    }

    const root_tasks = switch (workspace_object.get("tasks") orelse .null) {
        .object => |object| object,
        else => {
            try appendViolation(gpa, violations, "{s}: missing object `tasks`", .{workspace_path});
            return;
        },
    };
    const root_check = switch (root_tasks.get("check") orelse .null) {
        .string => |string| string,
        else => {
            try appendViolation(gpa, violations, "{s}: missing string task `check`", .{workspace_path});
            return;
        },
    };

    const banned_suffixes = [_][]const u8{
        "_test.ts",
        "_smoke.ts",
        "_bench.ts",
        "_probe.ts",
        "_harness.ts",
    };

    for (packages) |pkg| {
        var pkg_path_buf: [64]u8 = undefined;
        const pkg_path = std.fmt.bufPrint(&pkg_path_buf, "bindings/ts/{s}", .{pkg}) catch continue;

        var pkg_dir = root.openDir(io, pkg_path, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for publish-surface check with {s}", .{ pkg_path, @errorName(err) });
            continue;
        };
        defer pkg_dir.close(io);

        var walker = try pkg_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.eql(u8, entry.path, "test") or std.mem.startsWith(u8, entry.path, "test/")) continue;
            for (banned_suffixes) |suffix| {
                if (std.mem.endsWith(u8, entry.path, suffix)) {
                    try appendViolation(
                        gpa,
                        violations,
                        "{s}/{s}: non-ship file lives outside `test/`; move it under `{s}/test/` so the package root stays the publish surface",
                        .{ pkg_path, entry.path, pkg_path },
                    );
                    break;
                }
            }
        }

        var deno_path_buf: [80]u8 = undefined;
        const deno_path = std.fmt.bufPrint(&deno_path_buf, "{s}/deno.json", .{pkg_path}) catch continue;
        const deno_json = root.readFileAlloc(io, deno_path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ deno_path, @errorName(err) });
            continue;
        };
        defer gpa.free(deno_json);

        const parsed_deno = std.json.parseFromSlice(std.json.Value, gpa, deno_json, .{}) catch |err| {
            try appendViolation(gpa, violations, "{s}: invalid JSON ({s})", .{ deno_path, @errorName(err) });
            continue;
        };
        defer parsed_deno.deinit();
        const package_object = switch (parsed_deno.value) {
            .object => |object| object,
            else => {
                try appendViolation(gpa, violations, "{s}: root must be an object", .{deno_path});
                continue;
            },
        };
        const package_tasks = switch (package_object.get("tasks") orelse .null) {
            .object => |object| object,
            else => {
                try appendViolation(gpa, violations, "{s}: missing object `tasks`", .{deno_path});
                continue;
            },
        };
        const package_check = switch (package_tasks.get("check") orelse .null) {
            .string => |string| string,
            else => {
                try appendViolation(gpa, violations, "{s}: missing string task `check`", .{deno_path});
                continue;
            },
        };
        const exports = switch (package_object.get("exports") orelse .null) {
            .object => |object| object,
            else => {
                try appendViolation(gpa, violations, "{s}: missing object `exports`", .{deno_path});
                continue;
            },
        };
        var export_it = exports.iterator();
        while (export_it.next()) |entry| {
            const target = switch (entry.value_ptr.*) {
                .string => |string| string,
                else => {
                    try appendViolation(gpa, violations, "{s}: export `{s}` must name one TypeScript entry point", .{ deno_path, entry.key_ptr.* });
                    continue;
                },
            };
            const relative = if (std.mem.startsWith(u8, target, "./")) target[2..] else target;
            if (!commandHasToken(package_check, relative)) try appendViolation(
                gpa,
                violations,
                "{s}: exported entry `{s}` is absent from the package `check` task",
                .{ deno_path, target },
            );
            var root_target_buf: [160]u8 = undefined;
            const root_target = std.fmt.bufPrint(&root_target_buf, "{s}/{s}", .{ pkg, relative }) catch continue;
            if (!commandHasToken(root_check, root_target)) try appendViolation(
                gpa,
                violations,
                "{s}: exported entry `{s}` is absent from the workspace `check` task",
                .{ deno_path, target },
            );
        }

        const publish = switch (package_object.get("publish") orelse .null) {
            .object => |object| object,
            else => {
                try appendViolation(gpa, violations, "{s}: missing object `publish`; every workspace package declares what ships", .{deno_path});
                continue;
            },
        };
        const excludes = switch (publish.get("exclude") orelse .null) {
            .array => |array| array,
            else => {
                try appendViolation(gpa, violations, "{s}: `publish.exclude` must be an array", .{deno_path});
                continue;
            },
        };
        var excludes_tests = false;
        for (excludes.items) |value| switch (value) {
            .string => |string| if (std.mem.eql(u8, string, "test/**")) {
                excludes_tests = true;
                break;
            },
            else => {},
        };
        if (!excludes_tests) {
            try appendViolation(
                gpa,
                violations,
                "{s}: `publish.exclude` must name `test/**` so harnesses and unit tests cannot ship with `**/*.ts`",
                .{deno_path},
            );
        }
    }
}
