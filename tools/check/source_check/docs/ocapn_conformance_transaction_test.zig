//! Filesystem transaction tests for adoption accounting. Drive the public
//! checker with complete, corrupted, and restored spec/suite fixtures.
const std = @import("std");
const checkManifest = @import("ocapn_conformance.zig").checkManifest;
const manifest_path = "docs/ocapn-conformance.md";
const draft_path = "conformance/ocapn-spec/upstream/draft-specifications/CapTP Specification.md";
const steps_path = "docs/build-steps.md";
const suite_root = "conformance/ocapn-conformance/upstream";
const header = "| Section | Profile | State | Evidence | Decision | Text |";
const suite_header = "| Suite source | Profile | State | Evidence | Decision | Text |";

fn fixtureDigest(bytes: []const u8) [12]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(std.mem.trimEnd(u8, bytes, "\n"), &digest, .{});
    return std.fmt.bytesToHex(digest, .lower)[0..12].*;
}

// Integration fixture exercises the public source-check boundary with real
// files. Each defect must fail for its own reason, then pass after restoration.
test "adoption manifest rejects unreviewed draft and suite changes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const draft = "# Operations\n## op:abort\nDisconnect.\n";
    const setup = "def setup_session(): pass\n";
    const root_row = try std.fmt.allocPrint(arena, "| Operations | both | adopted | `zig build test` | none | {s} |\n", .{fixtureDigest("# Operations\n")});
    const draft_row = try std.fmt.allocPrint(arena, "| op:abort | both | adopted | `zig build test` | none | {s} |\n", .{fixtureDigest("## op:abort\nDisconnect.\n")});
    const removed_row = "| op:get | next | pending | none | `docs/decision.md` | removed |\n";
    const suite_row = try std.fmt.allocPrint(arena, "| `utils/captp.py` | both | adopted | `zig build test` | none | {s} |\n", .{fixtureDigest(setup)});
    const manifest = try std.fmt.allocPrint(arena, "{s}\n| --- | --- | --- | --- | --- | --- |\n{s}{s}\n{s}\n| --- | --- | --- | --- | --- | --- |\n{s}", .{ header, try std.mem.concat(arena, u8, &.{ root_row, draft_row }), removed_row, suite_header, suite_row });
    try writeTestFile(io, tmp.dir, manifest_path, manifest);
    try writeTestFile(io, tmp.dir, draft_path, draft);
    try writeTestFile(io, tmp.dir, steps_path, "zig build test\n");
    try writeTestFile(io, tmp.dir, "docs/decision.md", "Reason and reconsideration condition.\n");
    try writeTestFile(io, tmp.dir, suite_root ++ "/utils/captp.py", setup);
    try expectManifestResult(io, tmp.dir, null);
    const quoted_manifest = try std.mem.concat(arena, u8, &.{ "~~~markdown\n", header, "\n| --- | --- | --- | --- | --- | --- |\n| example | next | pending | none | none | removed |\n~~~\n", manifest });
    try writeTestFile(io, tmp.dir, manifest_path, quoted_manifest);
    try expectManifestResult(io, tmp.dir, null);
    const indented_example = try std.mem.concat(arena, u8, &.{ "    ", header, "\n    | --- | --- | --- | --- | --- | --- |\n    | example | next | pending | none | none | removed |\n\n", manifest });
    try writeTestFile(io, tmp.dir, manifest_path, indented_example);
    try expectManifestResult(io, tmp.dir, null);
    try writeTestFile(io, tmp.dir, manifest_path, manifest);

    const cases = [_]struct { from: []const u8, to: []const u8, diagnostic: []const u8 }{
        .{ .from = "both | adopted", .to = "both | typo", .diagnostic = "must be adopted, deferred, or pending" },
        .{ .from = "both | adopted", .to = "unknown | adopted", .diagnostic = "expected 1.0, next, or both" },
        .{ .from = "both | adopted | `zig build test`", .to = "both | adopted | none", .diagnostic = "needs executable evidence" },
        .{ .from = "next | pending | none", .to = "next | pending | `zig build test`", .diagnostic = "cannot claim adoption evidence" },
        .{ .from = "next | pending | none | `docs/decision.md`", .to = "next | deferred | none | none", .diagnostic = "needs a repository decision path" },
        .{ .from = "`docs/decision.md`", .to = "`docs/absent.md`", .diagnostic = "does not exist" },
        .{ .from = "`docs/decision.md`", .to = "`../outside.md`", .diagnostic = "must name a repository Markdown file" },
        .{ .from = "`zig build test`", .to = "`zig build imaginary`", .diagnostic = "does not list" },
        .{ .from = draft_row, .to = "", .diagnostic = "manifest has no row" },
        .{ .from = suite_row, .to = "", .diagnostic = "has no reviewed row" },
        .{ .from = draft_row, .to = try std.mem.concat(arena, u8, &.{ draft_row, draft_row }), .diagnostic = "appears more than once" },
        .{ .from = suite_row, .to = try std.mem.concat(arena, u8, &.{ suite_row, suite_row }), .diagnostic = "appears more than once" },
    };
    for (cases) |case| {
        const broken = try std.mem.replaceOwned(u8, arena, manifest, case.from, case.to);
        try writeTestFile(io, tmp.dir, manifest_path, broken);
        try expectManifestResult(io, tmp.dir, case.diagnostic);
        try writeTestFile(io, tmp.dir, manifest_path, manifest);
        try expectManifestResult(io, tmp.dir, null);
    }
    const baseline_only = try std.mem.replaceOwned(u8, arena, suite_row, "both", "1.0");
    const missing_next = try std.mem.replaceOwned(u8, arena, manifest, suite_row, baseline_only);
    try writeTestFile(io, tmp.dir, manifest_path, missing_next);
    try expectManifestResult(io, tmp.dir, "has no reviewed row for next");
    const next_only = try std.mem.replaceOwned(u8, arena, suite_row, "both", "next");
    const overlap = try std.mem.replaceOwned(u8, arena, manifest, suite_row, try std.mem.concat(arena, u8, &.{ suite_row, next_only }));
    try writeTestFile(io, tmp.dir, manifest_path, overlap);
    try expectManifestResult(io, tmp.dir, "appears more than once");
    const separate = try std.mem.replaceOwned(u8, arena, manifest, suite_row, try std.mem.concat(arena, u8, &.{ baseline_only, next_only }));
    try writeTestFile(io, tmp.dir, manifest_path, separate);
    try expectManifestResult(io, tmp.dir, null);
    const plan = try @import("ocapn_conformance.zig").nextSuitePlan(io, arena, tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), plan.len);
    try std.testing.expectEqualStrings("utils/captp.py", plan[0].name);
    try std.testing.expectEqualStrings("adopted", plan[0].state);
    try writeTestFile(io, tmp.dir, manifest_path, manifest);

    // A deliberate deferral with a reason is valid accounting, never a pass
    // claim for the deferred behavior.
    const deferred = try std.mem.replaceOwned(u8, arena, manifest, "next | pending", "next | deferred");
    try writeTestFile(io, tmp.dir, manifest_path, deferred);
    try expectManifestResult(io, tmp.dir, null);
    try writeTestFile(io, tmp.dir, manifest_path, manifest);

    try writeTestFile(io, tmp.dir, draft_path, draft ++ "Changed requirement.\n");
    try expectManifestResult(io, tmp.dir, "text moved");
    try writeTestFile(io, tmp.dir, draft_path, draft ++ "## op:get\nRestored.\n");
    try expectManifestResult(io, tmp.dir, "marked removed but exists");
    try writeTestFile(io, tmp.dir, draft_path, draft ++ "# New top-level contract\nNew requirement.\n");
    try expectManifestResult(io, tmp.dir, "manifest has no row");
    try writeTestFile(io, tmp.dir, draft_path, "# Operations\n");
    try expectManifestResult(io, tmp.dir, "names no draft section");
    try writeTestFile(io, tmp.dir, draft_path, draft);

    try writeTestFile(io, tmp.dir, suite_root ++ "/utils/captp.py", "def setup_session(): new_hello()\n");
    try expectManifestResult(io, tmp.dir, "review setup and assertions");
    try writeTestFile(io, tmp.dir, suite_root ++ "/utils/captp.py", setup);
    try writeTestFile(io, tmp.dir, suite_root ++ "/tests/new_case.py", "def test_new(): pass\n");
    try expectManifestResult(io, tmp.dir, "has no reviewed row");
    try tmp.dir.deleteFile(io, suite_root ++ "/tests/new_case.py");
    try tmp.dir.deleteFile(io, suite_root ++ "/utils/captp.py");
    try expectManifestResult(io, tmp.dir, "suite Python inventory is empty");
    try expectManifestResult(io, tmp.dir, "names no source");
    try writeTestFile(io, tmp.dir, suite_root ++ "/utils/captp.py", setup);
    try expectManifestResult(io, tmp.dir, null);
}

fn writeTestFile(io: std.Io, dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn expectManifestResult(io: std.Io, dir: std.Io.Dir, expected: ?[]const u8) !void {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |message| gpa.free(message);
        violations.deinit(gpa);
    }
    try checkManifest(io, gpa, dir, &violations);
    if (expected) |needle| {
        for (violations.items) |message| if (std.mem.indexOf(u8, message, needle) != null) return;
        std.debug.print("expected manifest diagnostic: {s}\nactual: {any}\n", .{ needle, violations.items });
        return error.TestExpectedError;
    }
    for (violations.items) |message| std.debug.print("unexpected manifest diagnostic: {s}\n", .{message});
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}
