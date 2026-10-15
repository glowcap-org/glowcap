//! Completeness and posture ownership for the standard Zig test suites.
//!
//! `tools/build/execution.zig` is the sole process-construction authority.
//! Every build-facing run names its posture at the call site (or in the typed
//! table row the call consumes), while the standard Zig suites in gates keep
//! their additional declaration-to-classification completeness check.

const std = @import("std");
const util = @import("../../util.zig");
const syntax = @import("syntax.zig");

const appendViolation = util.appendViolation;
const gates_path = "tools/build/gates.zig";

const Kind = enum { unit_test, search, memcheck };
const Exemption = struct { name: []const u8, kind: Kind };

/// The assigned Zig tests in this owner that do not run as ordinary unit
/// tests: the fuzz search, and the protocol core and actors suite under valgrind. This
/// list is tiny and exact. Ordinary tests derive their inventory from the
/// declarations and classifications.
const exemptions = [_]Exemption{
    .{ .name = "fuzz_tests", .kind = .search },
    .{ .name = "memcheck_tests", .kind = .memcheck },
};

const Classification = struct {
    name: []const u8,
    kind: Kind,
};

pub fn checkSource(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    source: []const u8,
) !void {
    const code = try syntax.codeOnly(gpa, source);
    defer gpa.free(code);

    var declarations: std.ArrayList([]const u8) = .empty;
    defer declarations.deinit(gpa);
    try collectTestDeclarations(gpa, violations, code, &declarations);

    var classifications: std.ArrayList(Classification) = .empty;
    defer classifications.deinit(gpa);
    try collectClassifications(gpa, violations, code, &classifications);
    try rejectRawTestRuns(gpa, violations, code, declarations.items);

    for (declarations.items, 0..) |name, declaration_index| {
        if (firstNameIndex(declarations.items, name) != declaration_index) continue;
        const declared = countNames(declarations.items, name);
        if (declared != 1) {
            try appendViolation(gpa, violations, "{s}: assigned Zig test name `{s}` appears {d} times; every compile artifact needs one unambiguous execution posture", .{ gates_path, name, declared });
        }
        const exemption = findExemption(name);
        var classified: usize = 0;
        for (classifications.items) |got| {
            if (!std.mem.eql(u8, got.name, name)) continue;
            classified += 1;
            const expected_kind: Kind = if (exemption) |item| item.kind else .unit_test;
            if (got.kind != expected_kind) {
                try appendViolation(gpa, violations, "{s}: `{s}` has posture `.{s}`, expected `.{s}`; only the explicit unbounded exemption inventory may use search", .{ gates_path, name, @tagName(got.kind), @tagName(expected_kind) });
            }
        }
        if (classified != 1) {
            try appendViolation(gpa, violations, "{s}: Zig test `{s}` must have exactly one `execution.addZigTest` posture, found {d}", .{ gates_path, name, classified });
        }
    }

    for (classifications.items) |got| {
        if (countNames(declarations.items, got.name) == 0) {
            try appendViolation(gpa, violations, "{s}: execution posture for unknown Zig test `{s}`; remove the stale classification or restore its assigned `b.addTest`", .{ gates_path, got.name });
        }
    }
    for (exemptions) |item| {
        if (countNames(declarations.items, item.name) != 1) {
            try appendViolation(gpa, violations, "{s}: unbounded exemption `{s}` is stale; explicit exemption inventories shrink when their owner disappears", .{ gates_path, item.name });
        }
    }
}

fn collectTestDeclarations(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    source: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, "b.addTest")) |call_at| {
        cursor = call_at + "b.addTest".len;
        const name = syntax.assignedConstName(source, call_at) orelse {
            try appendViolation(gpa, violations, "{s}: every `b.addTest` must be assigned to a named compile step before it is classified", .{gates_path});
            continue;
        };
        try out.append(gpa, name);
    }
}

fn collectClassifications(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    source: []const u8,
    out: *std.ArrayList(Classification),
) !void {
    const marker = "execution.addZigTest(";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, marker)) |call_at| {
        const open = call_at + marker.len - 1;
        const close = syntax.matchingDelimiter(source, open, '(', ')') orelse {
            try appendViolation(gpa, violations, "{s}: unterminated `execution.addZigTest` call", .{gates_path});
            return;
        };
        cursor = close + 1;
        var args: [3][]const u8 = undefined;
        const count = syntax.splitThreeTopLevel(source[open + 1 .. close], &args);
        if (count != 3) {
            try appendViolation(gpa, violations, "{s}: `execution.addZigTest` requires build, named test compile, and explicit posture", .{gates_path});
            continue;
        }
        if (!std.mem.eql(u8, std.mem.trim(u8, args[0], " \t\r\n"), "b")) {
            try appendViolation(gpa, violations, "{s}: `execution.addZigTest` must use this build owner directly", .{gates_path});
        }
        const name_text = std.mem.trim(u8, args[1], " \t\r\n");
        const name = syntax.leadingIdentifier(name_text) orelse {
            try appendViolation(gpa, violations, "{s}: `execution.addZigTest` test compile must be a named `b.addTest` declaration", .{gates_path});
            continue;
        };
        if (name.len != name_text.len) {
            try appendViolation(gpa, violations, "{s}: `execution.addZigTest` compile argument `{s}` is not a plain named test artifact", .{ gates_path, name_text });
            continue;
        }
        const posture = try parsePosture(gpa, violations, args[2]) orelse continue;
        try out.append(gpa, .{ .name = name, .kind = posture.kind });
    }
}

fn parsePosture(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    text: []const u8,
) !?Classification {
    var compact: std.ArrayList(u8) = .empty;
    defer compact.deinit(gpa);
    for (text) |byte| if (!std.ascii.isWhitespace(byte)) try compact.append(gpa, byte);
    const value = compact.items;
    if (std.mem.eql(u8, value, ".search")) {
        return .{ .name = "", .kind = .search };
    }
    if (std.mem.eql(u8, value, ".unit_test")) {
        return .{ .name = "", .kind = .unit_test };
    }
    const memcheck_prefix = ".{.memcheck=";
    if (std.mem.startsWith(u8, value, memcheck_prefix) and std.mem.endsWith(u8, value, "}")) {
        const number = value[memcheck_prefix.len .. value.len - 1];
        const seconds = std.fmt.parseInt(u16, number, 10) catch 0;
        if (seconds <= 30 or seconds > 1800) {
            try appendViolation(gpa, violations, "{s}: memcheck deadline `{s}` must be a literal integer from 31 through 1800; the checker multiplies the suite's own time", .{ gates_path, number });
            return null;
        }
        return .{ .name = "", .kind = .memcheck };
    }
    try appendViolation(gpa, violations, "{s}: Zig test posture `{s}` is missing or unsupported in the standard-suite inventory", .{ gates_path, std.mem.trim(u8, text, " \t\r\n") });
    return null;
}

fn rejectRawTestRuns(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    source: []const u8,
    declarations: []const []const u8,
) !void {
    const marker = "b.addRunArtifact(";
    var cursor: usize = 0;
    scan: while (std.mem.indexOfPos(u8, source, cursor, marker)) |call_at| {
        const open = call_at + marker.len - 1;
        const close = syntax.matchingDelimiter(source, open, '(', ')') orelse {
            try appendViolation(gpa, violations, "{s}: unterminated raw `b.addRunArtifact` call", .{gates_path});
            return;
        };
        cursor = close + 1;
        const arg = std.mem.trim(u8, source[open + 1 .. close], " \t\r\n");
        // The mutation-fuzz driver is an ordinary executable that orchestrates
        // the explicitly classified `fuzz_tests` search. It is the only raw
        // RunArtifact construction in this standard-suite build owner.
        if (std.mem.eql(u8, arg, "fuzz_driver_exe")) continue :scan;
        if (std.mem.indexOf(u8, arg, "b.addTest") != null) {
            try appendViolation(gpa, violations, "{s}: inline `b.addRunArtifact(b.addTest(...))` bypasses the Zig test execution posture", .{gates_path});
            continue :scan;
        }
        for (declarations) |name| {
            if (std.mem.eql(u8, arg, name)) {
                try appendViolation(gpa, violations, "{s}: raw `b.addRunArtifact({s})` bypasses its explicit Zig test execution posture", .{ gates_path, name });
                continue :scan;
            }
        }
        try appendViolation(gpa, violations, "{s}: raw `b.addRunArtifact({s})` is outside the standard-suite inventory; classify the process through tools/build/execution.zig", .{ gates_path, arg });
    }
}

fn countNames(names: []const []const u8, expected_name: []const u8) usize {
    var count: usize = 0;
    for (names) |name| {
        if (std.mem.eql(u8, name, expected_name)) count += 1;
    }
    return count;
}

fn firstNameIndex(names: []const []const u8, wanted: []const u8) usize {
    for (names, 0..) |name, index| {
        if (std.mem.eql(u8, name, wanted)) return index;
    }
    unreachable;
}

fn findExemption(name: []const u8) ?Exemption {
    for (exemptions) |item| {
        if (std.mem.eql(u8, item.name, name)) return item;
    }
    return null;
}

const good_source =
    \\const tests = b.addTest(.{});
    \\const run_tests = execution.addZigTest(b, tests, .unit_test);
    \\const completion_deadlines_tests = b.addTest(.{});
    \\const run_completion = execution.addZigTest(b, completion_deadlines_tests, .unit_test);
    \\const fuzz_tests = b.addTest(.{});
    \\const run_fuzz = execution.addZigTest(b, fuzz_tests, .search);
    \\const onion_loop_tests = b.addTest(.{});
    \\const run_onion = execution.addZigTest(b, onion_loop_tests, .unit_test);
    \\const oracle_tests = b.addTest(.{});
    \\const run_oracle = execution.addZigTest(b, oracle_tests, .unit_test);
    \\const source_check_tests = b.addTest(.{});
    \\const run_source = execution.addZigTest(b, source_check_tests, .unit_test);
    \\const memcheck_tests = b.addTest(.{});
    \\const run_memcheck = execution.addZigTest(b, memcheck_tests, .{ .memcheck = 900 });
;

fn expectClean(source: []const u8) !void {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |item| gpa.free(item);
        violations.deinit(gpa);
    }
    try checkSource(gpa, &violations, source);
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

fn expectViolation(source: []const u8, needle: []const u8) !void {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |item| gpa.free(item);
        violations.deinit(gpa);
    }
    try checkSource(gpa, &violations, source);
    for (violations.items) |item| {
        if (std.mem.indexOf(u8, item, needle) != null) return;
    }
    return error.ExpectedDeadlineViolation;
}

test "standard Zig test inventory accepts the classified gate set" {
    try expectClean(good_source);
}

test "Zig test rejects a process-level deterministic posture" {
    const bad = try std.mem.replaceOwned(u8, std.testing.allocator, good_source, ".unit_test", ".{ .deterministic = 30 }");
    defer std.testing.allocator.free(bad);
    try expectViolation(bad, "missing or unsupported");
}

test "assigned Zig test without a posture is rejected" {
    const bad = try std.mem.replaceOwned(u8, std.testing.allocator, good_source, "const run_tests = execution.addZigTest(b, tests, .unit_test);", "");
    defer std.testing.allocator.free(bad);
    try expectViolation(bad, "must have exactly one");
}

test "raw Zig test run is rejected" {
    const bad = try std.mem.replaceOwned(u8, std.testing.allocator, good_source, "execution.addZigTest(b, tests, .unit_test)", "b.addRunArtifact(tests)");
    defer std.testing.allocator.free(bad);
    try expectViolation(bad, "raw `b.addRunArtifact(tests)`");
}

test "a raw alias cannot hide a Zig test run" {
    const bad = good_source ++ "\nconst alias = tests; const raw = b.addRunArtifact(alias);\n";
    try expectViolation(bad, "outside the standard-suite inventory");
}

test "duplicate Zig test classification is rejected" {
    const bad = good_source ++ "\nconst duplicate = execution.addZigTest(b, tests, .unit_test);\n";
    try expectViolation(bad, "exactly one `execution.addZigTest`");
}

test "inline Zig test run cannot bypass assignment and posture" {
    const bad = good_source ++ "\nconst inline_run = b.addRunArtifact(b.addTest(.{}));\n";
    try expectViolation(bad, "inline `b.addRunArtifact(b.addTest(...))`");
}

test "comments and strings cannot fabricate Zig test inventory entries" {
    const decorated = good_source ++
        \\// const phantom = b.addTest(.{}); execution.addZigTest(b, phantom, .unit_test);
        \\/// b.addTest execution.addZigTest
        \\const quoted = "b.addTest execution.addZigTest b.addRunArtifact(tests)";
    ;
    try expectClean(decorated);
}

test "ordinary unit test cannot claim search posture" {
    const bad = try std.mem.replaceOwned(u8, std.testing.allocator, good_source, ".unit_test", ".search");
    defer std.testing.allocator.free(bad);
    try expectViolation(bad, "only the explicit unbounded exemption inventory");
}

test "newly assigned unit test needs no detached inventory row" {
    const expanded = good_source ++
        \\const new_suite = b.addTest(.{});
        \\const run_new = execution.addZigTest(b, new_suite, .unit_test);
    ;
    try expectClean(expanded);
}

test "removed unit test leaves no deadline tombstone" {
    const removed_declaration = try std.mem.replaceOwned(u8, std.testing.allocator, good_source, "const completion_deadlines_tests = b.addTest(.{});\n", "");
    defer std.testing.allocator.free(removed_declaration);
    const removed = try std.mem.replaceOwned(u8, std.testing.allocator, removed_declaration, "const run_completion = execution.addZigTest(b, completion_deadlines_tests, .unit_test);\n", "");
    defer std.testing.allocator.free(removed);
    try expectClean(removed);
}

test "ordinary unit test cannot claim the memcheck posture" {
    const bad = try std.mem.replaceOwned(u8, std.testing.allocator, good_source, "execution.addZigTest(b, tests, .unit_test)", "execution.addZigTest(b, tests, .{ .memcheck = 900 })");
    defer std.testing.allocator.free(bad);
    try expectViolation(bad, "only the explicit unbounded exemption inventory");
}

test "memcheck deadline must be minutes, never a unit-test deadline or unbounded" {
    const short = try std.mem.replaceOwned(u8, std.testing.allocator, good_source, ".{ .memcheck = 900 }", ".{ .memcheck = 30 }");
    defer std.testing.allocator.free(short);
    try expectViolation(short, "31 through 1800");
    const long = try std.mem.replaceOwned(u8, std.testing.allocator, good_source, ".{ .memcheck = 900 }", ".{ .memcheck = 1801 }");
    defer std.testing.allocator.free(long);
    try expectViolation(long, "31 through 1800");
}
