//! Build-process execution posture and deadline ownership.
//!
//! `tools/build/execution.zig` is the sole process-construction authority.
//! Every build-facing run names its posture at the call site (or in the typed
//! table row the call consumes). The sibling Zig-test owner additionally pins
//! declaration-to-classification completeness for the standard gate suites.

const std = @import("std");
const util = @import("../util.zig");
const syntax = @import("execution_deadlines/syntax.zig");
const zig_tests = @import("execution_deadlines/zig_tests.zig");

const appendViolation = util.appendViolation;
const gates_path = "tools/build/gates.zig";

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const gates_source = root.readFileAlloc(io, gates_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read the Zig test deadline inventory with {s}", .{ gates_path, @errorName(err) });
        return;
    };
    defer gpa.free(gates_source);
    try zig_tests.checkSource(gpa, violations, gates_source);

    const root_source = root.readFileAlloc(io, "build.zig", gpa, .limited(1 << 21)) catch |err| {
        try appendViolation(gpa, violations, "build.zig: failed to read execution postures with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(root_source);
    try checkBuildFile(gpa, violations, "build.zig", root_source);

    var dir = root.openDir(io, "tools/build", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "tools/build: failed to inventory execution postures with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "tools/build/{s}", .{entry.name});
        defer gpa.free(path);
        const source = dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 21)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read execution postures with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(source);
        try checkBuildFile(gpa, violations, path, source);
    }
}

const process_calls = [_]struct {
    marker: []const u8,
    posture_arg: usize,
    zig_test: bool = false,
}{
    .{ .marker = "execution.addZigTest(", .posture_arg = 2, .zig_test = true },
    .{ .marker = "execution.addArtifact(", .posture_arg = 1 },
    .{ .marker = "execution.addSystemCommand(", .posture_arg = 1 },
    .{ .marker = "common.addPancakeRun(", .posture_arg = 1 },
    .{ .marker = "common.addRootedSystemCommand(", .posture_arg = 1 },
    .{ .marker = "common.addInstalledSystemRun(", .posture_arg = 1 },
    .{ .marker = "addPancakeRun(", .posture_arg = 1 },
    .{ .marker = "addRootedSystemCommand(", .posture_arg = 1 },
    .{ .marker = "addInstalledSystemRun(", .posture_arg = 1 },
};

fn checkBuildFile(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    source: []const u8,
) !void {
    const code = try syntax.codeOnly(gpa, source);
    defer gpa.free(code);
    const execution_owner = std.mem.eql(u8, path, "tools/build/execution.zig");
    if (!execution_owner) {
        for ([_][]const u8{ ".addRunArtifact(", ".addSystemCommand(" }) |raw| {
            var raw_cursor: usize = 0;
            while (std.mem.indexOfPos(u8, code, raw_cursor, raw)) |at| {
                raw_cursor = at + raw.len;
                const receiver = precedingIdentifier(code, at);
                if (std.mem.eql(u8, receiver, "execution")) continue;
                try appendViolation(gpa, violations, "{s}: raw `{s}{s}` bypasses tools/build/execution.zig; every build process needs an explicit execution posture", .{ path, receiver, raw[0 .. raw.len - 1] });
            }
        }
    }
    if (execution_owner) return;

    var test_names: std.ArrayList([]const u8) = .empty;
    defer test_names.deinit(gpa);
    var test_cursor: usize = 0;
    while (std.mem.indexOfPos(u8, code, test_cursor, "b.addTest")) |call_at| {
        test_cursor = call_at + "b.addTest".len;
        if (syntax.assignedConstName(code, call_at)) |name| try test_names.append(gpa, name);
    }

    for (process_calls) |spec| {
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, code, cursor, spec.marker)) |call_at| {
            cursor = call_at + spec.marker.len;
            if (isFunctionDeclaration(code, call_at)) continue;
            // Qualified markers are substrings of their unqualified form.
            if (spec.marker[0] != 'e' and spec.marker[0] != 'c' and call_at > 0 and code[call_at - 1] == '.') continue;
            const open = call_at + spec.marker.len - 1;
            const close = syntax.matchingDelimiter(code, open, '(', ')') orelse {
                try appendViolation(gpa, violations, "{s}: unterminated `{s}` execution call", .{ path, spec.marker[0 .. spec.marker.len - 1] });
                break;
            };
            const posture = syntax.nthTopLevelArg(code[open + 1 .. close], spec.posture_arg) orelse {
                try appendViolation(gpa, violations, "{s}: `{s}` is missing its explicit execution posture", .{ path, spec.marker[0 .. spec.marker.len - 1] });
                continue;
            };
            try validateExecutionPosture(gpa, violations, path, posture, spec.zig_test);
            if (std.mem.eql(u8, spec.marker, "execution.addArtifact(")) {
                const artifact = syntax.nthTopLevelArg(code[open + 1 .. close], 2) orelse continue;
                const trimmed = std.mem.trim(u8, artifact, " \t\r\n");
                if (std.mem.indexOf(u8, trimmed, "b.addTest") != null or containsName(test_names.items, trimmed)) {
                    try appendViolation(gpa, violations, "{s}: Zig test artifact `{s}` must run through `execution.addZigTest`, preserving standard-runner filters, leak reporting, and subprocess deadlines", .{ path, trimmed });
                }
            }
        }
    }
}

fn containsName(names: []const []const u8, candidate: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn precedingIdentifier(code: []const u8, dot_at: usize) []const u8 {
    var start = dot_at;
    while (start > 0 and (std.ascii.isAlphanumeric(code[start - 1]) or code[start - 1] == '_')) start -= 1;
    return code[start..dot_at];
}

fn isFunctionDeclaration(code: []const u8, call_at: usize) bool {
    const start = if (std.mem.lastIndexOfScalar(u8, code[0..call_at], '\n')) |newline| newline + 1 else 0;
    return std.mem.indexOf(u8, code[start..call_at], "fn ") != null;
}

fn validateExecutionPosture(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    text: []const u8,
    zig_test: bool,
) !void {
    var compact: std.ArrayList(u8) = .empty;
    defer compact.deinit(gpa);
    for (text) |byte| if (!std.ascii.isWhitespace(byte)) try compact.append(gpa, byte);
    const value = compact.items;
    const prefix = ".{.deterministic=";
    if (std.mem.startsWith(u8, value, prefix) and std.mem.endsWith(u8, value, "}")) {
        const number = value[prefix.len .. value.len - 1];
        const seconds = std.fmt.parseInt(u16, number, 10) catch {
            try appendViolation(gpa, violations, "{s}: deterministic execution deadline must be a literal integer from 1 through 30", .{path});
            return;
        };
        if (seconds == 0 or seconds > 30) {
            try appendViolation(gpa, violations, "{s}: deterministic execution deadline is {d}s; test/proof subprocesses must be 1..30s", .{ path, seconds });
        }
        return;
    }
    if (std.mem.eql(u8, value, ".search")) return;
    if (!zig_test and (std.mem.eql(u8, value, ".benchmark") or
        std.mem.eql(u8, value, ".build_tool") or
        std.mem.eql(u8, value, ".real_internet") or
        std.mem.eql(u8, value, ".service"))) return;
    if (!zig_test and std.mem.endsWith(u8, value, ".posture")) {
        const owner = value[0 .. value.len - ".posture".len];
        if (syntax.leadingIdentifier(owner)) |identifier| {
            if (identifier.len == owner.len) return;
        }
    }
    if (std.mem.eql(u8, path, "tools/build/common.zig") and std.mem.eql(u8, value, "posture")) return;
    try appendViolation(gpa, violations, "{s}: unknown or invalid execution posture `{s}`; deterministic test/proof subprocesses use a literal 1..30s budget and every unbounded process names its exact posture", .{ path, std.mem.trim(u8, text, " \t\r\n") });
}

fn expectBuildClean(source: []const u8) !void {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |item| gpa.free(item);
        violations.deinit(gpa);
    }
    try checkBuildFile(gpa, &violations, "tools/build/fixture.zig", source);
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

fn expectBuildViolation(source: []const u8, needle: []const u8) !void {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |item| gpa.free(item);
        violations.deinit(gpa);
    }
    try checkBuildFile(gpa, &violations, "tools/build/fixture.zig", source);
    for (violations.items) |item| {
        if (std.mem.indexOf(u8, item, needle) != null) return;
    }
    return error.ExpectedDeadlineViolation;
}

test "global execution census accepts explicit and typed-row postures" {
    try expectBuildClean(
        \\const test_run = execution.addZigTest(b, tests, .{ .deterministic = 7 });
        \\const proof = execution.addArtifact(b, .{ .deterministic = 19 }, exe);
        \\const cache = execution.addSystemCommand(b, .build_tool, argv);
        \\const bench = execution.addArtifact(b, .benchmark, exe);
        \\const search = execution.addArtifact(b, .search, exe);
        \\const internet = execution.addSystemCommand(b, .real_internet, argv);
        \\const server = execution.addArtifact(b, .service, exe);
        \\const row_run = execution.addArtifact(b, row.posture, exe);
    );
}

test "global execution census rejects arbitrary raw process receivers" {
    try expectBuildViolation("const run = renamed_builder.addRunArtifact(exe);", "renamed_builder.addRunArtifact");
    try expectBuildViolation("const run = bb.addSystemCommand(argv);", "bb.addSystemCommand");
}

test "global deterministic deadline rejects 31 seconds" {
    try expectBuildViolation("const run = execution.addSystemCommand(b, .{ .deterministic = 31 }, argv);", "must be 1..30s");
}

test "Zig test execution cannot use a non-test escape posture" {
    try expectBuildViolation("const run = execution.addZigTest(b, tests, .build_tool);", "unknown or invalid execution posture");
}

test "Zig test artifact cannot bypass the standard runner through addArtifact" {
    try expectBuildViolation(
        "const tests = b.addTest(.{}); const run = execution.addArtifact(b, .{ .deterministic = 4 }, tests);",
        "must run through `execution.addZigTest`",
    );
}

test "global execution census rejects unknown or implicit posture" {
    try expectBuildViolation("const run = execution.addArtifact(b, policy, exe);", "unknown or invalid execution posture");
    try expectBuildViolation("const run = execution.addArtifact(b);", "missing its explicit execution posture");
}

test "comments and strings cannot fabricate raw global process construction" {
    try expectBuildClean(
        \\// const raw = bb.addRunArtifact(exe);
        \\const quoted = "renamed.addSystemCommand(argv)";
        \\const run = execution.addArtifact(b, .{ .deterministic = 4 }, exe);
    );
}
