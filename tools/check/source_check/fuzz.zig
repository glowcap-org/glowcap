//! The fuzzing setup's two invariants: every crash input replays, and every
//! target is where the fuzzer looks.
//!
//! Every crash input sitting in the regressions directory has to be wired into
//! the replay, because a regression test nobody runs is worse than no test at
//! all.
//!
//! And every fuzz target has to be somewhere `zig build fuzz` will find it. The
//! driver runs the fuzzer once per target, which it discovers by reading test
//! names out of the `fuzz_test.zig` files that `test/fuzz_check.zig` imports. A
//! target written anywhere else compiles, passes the ordinary suite by replaying
//! its seeds, and is never once mutated, it looks like coverage and is not.
//!
//! Both checks read one walk of every Zig file under `test/` at any depth
//! (`testZigFiles`), so a target nested two directories down is held exactly
//! like one at the top.

const std = @import("std");
const source_tree = @import("source_tree.zig");
const text_match = @import("text_match.zig");
const violation_log = @import("violation_log.zig");

const appendViolation = violation_log.appendViolation;

/// Every Zig file under `test/` at any depth, sorted, or null when `test/` is
/// not a directory. The caller frees the list and each path.
fn testZigFiles(io: std.Io, gpa: std.mem.Allocator, root: std.Io.Dir) !?[][]u8 {
    return source_tree.collectSourceFiles(io, gpa, root, "test", &source_tree.isZigPath);
}

fn freeFiles(gpa: std.mem.Allocator, files: [][]u8) void {
    for (files) |path| gpa.free(path);
    gpa.free(files);
}

/// Every crash input in every target's regressions directory must be replayed.
///
/// The fuzzer writes a failing input to the build cache, which is wiped by any
/// clean. Copying it into the tree is only half the job. If nobody wires it into
/// the replay it sits there looking like coverage and proving nothing.
///
/// Every target owns its own directory, because that is what the fuzz driver
/// tells you to use when it reports a finding. Checking only one of them left
/// the other eight able to accumulate crash inputs that nothing replayed, which
/// is the exact state this check exists to refuse.
pub fn checkFuzzRegressionSeeds(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const test_files = (try testZigFiles(io, gpa, root)) orelse {
        try appendViolation(gpa, violations, "test/: no such directory for the fuzz regressions check", .{});
        return;
    };
    defer freeFiles(gpa, test_files);

    for (test_files) |harness_path| {
        if (!std.mem.eql(u8, std.fs.path.basename(harness_path), target_file)) continue;
        const harness = root.readFileAlloc(io, harness_path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: cannot be read for the fuzz-wiring check ({s})", .{ harness_path, @errorName(err) });
            continue;
        };
        defer gpa.free(harness);

        // Per target, not per file. One file may hold several targets, and
        // asking only whether the *file* mentions a seed list passes a file
        // where one target replays its regressions and the others cannot. That
        // is worse than no check: the target reads as covered, and a crash
        // pasted into the list it was told to use is handed to some other
        // target that will never take the path it was found on.
        try checkTargetsReplayRegressions(gpa, harness_path, harness, violations);

        const regressions_dir = try std.fmt.allocPrint(gpa, "{s}/fuzz_regressions", .{std.fs.path.dirname(harness_path).?});
        defer gpa.free(regressions_dir);
        // Git holds no empty directory, so a target without saved crashes has
        // none; the driver's copy instruction creates it with the first one.
        var dir = root.openDir(io, regressions_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                try appendViolation(gpa, violations, "{s}: failed to open for fuzz-regression check with {s}", .{ regressions_dir, @errorName(err) });
                continue;
            },
        };
        defer dir.close(io);

        var files = dir.iterate();
        while (try files.next(io)) |file| {
            if (file.kind != .file) continue;
            if (!std.mem.endsWith(u8, file.name, ".bin")) continue;

            const needle = try std.fmt.allocPrint(gpa, "fuzz_regressions/{s}\")", .{file.name});
            defer gpa.free(needle);
            const embed = std.mem.indexOf(u8, harness, needle) orelse {
                try appendViolation(gpa, violations, "{s}: `{s}` is not replayed. Add it to the regression seeds in {s}, or delete it.", .{ regressions_dir, file.name, harness_path });
                continue;
            };
            // And into a list some target reads. A file may hold two
            // targets whose inputs mean different things, a saved completion
            // schedule is nothing to a frame reader, so being embedded
            // *somewhere* is not the same as being replayed.
            const list = enclosingSeedList(harness, embed) orelse {
                try appendViolation(gpa, violations, "{s}: `{s}` is embedded in {s} but not inside a `regression_seeds` list, so nothing replays it.", .{ regressions_dir, file.name, harness_path });
                continue;
            };
            // In a file with more than one seed list, the filename must say
            // which. Binding a saved input to a *list* is all the check can
            // decide from here. It cannot read the bytes and tell a completion
            // schedule from a frame, so the one mistake left is pasting into
            // the wrong list, and a filename prefix makes that visible where
            // nothing else can.
            if (seedListCount(harness) > 1) {
                const want = try std.fmt.allocPrint(gpa, "{s}-", .{list});
                defer gpa.free(want);
                if (!std.mem.startsWith(u8, file.name, want)) {
                    try appendViolation(gpa, violations, "{s}: `{s}` is embedded in `{s}`, but this file has more than one seed list and the name does not say which. Rename it `{s}<something>.bin`, or move it to the list its input shape belongs to.", .{ regressions_dir, file.name, list, want });
                    continue;
                }
            }
            switch (targetsReading(harness, list)) {
                0 => try appendViolation(gpa, violations, "{s}: `{s}` is embedded in `{s}`, which no fuzz target's corpus reads. It is replayed by nothing.", .{ regressions_dir, file.name, list }),
                1 => {},
                // More than one target reads the list, so which of them this
                // input was saved for is unknowable from here, and in a file
                // whose targets take different input shapes, a schedule handed
                // to a frame reader is replayed by a target that cannot take
                // the path it was found on. One list per target keeps the
                // binding decidable.
                else => |n| try appendViolation(gpa, violations, "{s}: `{s}` is embedded in `{s}`, which {d} targets read, so nothing here says which one replays it. Give each target its own seed list.", .{ regressions_dir, file.name, list, n }),
            }
        }
    }
}

/// The name of the `const … = [_][]const u8{ … }` declaration whose braces
/// enclose `at`, or null when `at` is not inside one.
fn enclosingSeedList(source: []const u8, at: usize) ?[]const u8 {
    const opener = " = [_][]const u8{";
    var probe: usize = 0;
    var best: ?[]const u8 = null;
    while (std.mem.indexOfPos(u8, source, probe, opener)) |hit| {
        probe = hit + opener.len;
        if (hit > at) break;
        const close = matchingBrace(source, probe) orelse continue;
        if (at > close) continue;
        // Back over the identifier that precedes the `=`.
        var start = hit;
        while (start > 0 and (std.ascii.isAlphanumeric(source[start - 1]) or source[start - 1] == '_')) start -= 1;
        best = source[start..hit];
    }
    return best;
}

/// The index of the `}` that closes a brace opened just before `from`. An
/// entry such as `draws(&.{ 0, 1 })` nests its own braces, and braces inside a
/// line comment or string literal are text, so neither ends the list.
fn matchingBrace(source: []const u8, from: usize) ?usize {
    var depth: usize = 1;
    var i = from;
    while (i < source.len) : (i += 1) switch (source[i]) {
        '{' => depth += 1,
        '}' => {
            depth -= 1;
            if (depth == 0) return i;
        },
        '/' => if (i + 1 < source.len and source[i + 1] == '/') {
            i = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse return null;
        },
        '"' => {
            i += 1;
            while (i < source.len and source[i] != '"') : (i += 1) {
                if (source[i] == '\\') i += 1;
            }
        },
        else => {},
    };
    return null;
}

test "a seed list ends at its own closing brace" {
    const harness =
        \\const regression_seeds = [_][]const u8{
        \\    // a comment's } is text
        \\    seeds.seed("}") ++ draws(&.{ 0, 1 }),
        \\    @embedFile("fuzz_regressions/after.bin"),
        \\};
        \\const other = @embedFile("fuzz_regressions/outside.bin");
    ;
    const inside = std.mem.indexOf(u8, harness, "after.bin").?;
    try std.testing.expectEqualStrings("regression_seeds", enclosingSeedList(harness, inside).?);
    const outside = std.mem.indexOf(u8, harness, "outside.bin").?;
    try std.testing.expect(enclosingSeedList(harness, outside) == null);
}

/// How many distinct seed lists the harness declares.
fn seedListCount(source: []const u8) usize {
    const opener = " = [_][]const u8{";
    var count: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, source, at, opener)) |hit| {
        at = hit + opener.len;
        var start = hit;
        while (start > 0 and text_match.isIdentChar(source[start - 1])) start -= 1;
        if (std.mem.endsWith(u8, source[start..hit], "regression_seeds")) count += 1;
    }
    return count;
}

/// Whether `body` reads any seed list, an identifier ending in
/// `regression_seeds`, so `schedule_regression_seeds` counts and the bare
/// substring inside it does not.
fn mentionsSeedList(body: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, body, at, "regression_seeds")) |hit| {
        at = hit + "regression_seeds".len;
        if (at >= body.len or !text_match.isIdentChar(body[at])) return true;
    }
    return false;
}

/// How many `test "fuzz: …"` bodies in `source` read the seed list `name`.
///
/// Whole-identifier, not substring: `schedule_regression_seeds` contains
/// `regression_seeds`, so a substring test cannot tell the two lists apart and
/// every target looks like it reads every list.
fn targetsReading(source: []const u8, name: []const u8) usize {
    var count: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, source, at, target_opener)) |hit| {
        at = hit + target_opener.len;
        if (mentionsIdentifier(testBody(source, at), name)) count += 1;
    }
    return count;
}

/// Whether `haystack` contains `name` as a whole identifier.
fn mentionsIdentifier(haystack: []const u8, name: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, name)) |hit| {
        at = hit + name.len;
        const before_ok = hit == 0 or !text_match.isIdentChar(haystack[hit - 1]);
        const after_ok = at >= haystack.len or !text_match.isIdentChar(haystack[at]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

/// The braces of the test whose name ends at `at`, or an empty slice when the
/// file does not parse as expected.
///
/// Comments and literals are both skipped. Comments are not optional here: an
/// apostrophe in ordinary prose ("doesn't") reads as the start of a character
/// literal, and the scan then runs to the next apostrophe, swallowing whatever
/// braces lie between. Two targets in this tree hit exactly that.
fn testBody(source: []const u8, at: usize) []const u8 {
    const open = std.mem.indexOfScalarPos(u8, source, at, '{') orelse return source[0..0];
    var depth: usize = 0;
    var i = open;
    while (i < source.len) {
        switch (source[i]) {
            '/' => {
                if (i + 1 < source.len and source[i + 1] == '/') {
                    while (i < source.len and source[i] != '\n') : (i += 1) {}
                } else i += 1;
            },
            '"', '\'' => {
                const quote = source[i];
                i += 1;
                while (i < source.len and source[i] != quote) : (i += 1) {
                    if (source[i] == '\\') i += 1;
                }
                i += 1;
            },
            '{' => {
                depth += 1;
                i += 1;
            },
            '}' => {
                depth -= 1;
                i += 1;
                if (depth == 0) return source[open..i];
            },
            else => i += 1,
        }
    }
    return source[0..0];
}

/// Every target in `source` must hand its `std.testing.fuzz` call a corpus that
/// includes the file's regression seeds.
///
/// The corpus is the only route a saved crash has back into the ordinary suite:
/// `zig build fuzz` writes the input to `fuzz_regressions/` and tells the author
/// to add it to the seed list, and a target whose corpus never reads that list
/// silently ignores it. The check is the name, not the value, whether the
/// seeds are threaded through a shared `corpus_seeds` or spliced into a local
/// array does not matter, only that the target's corpus reaches them.
fn checkTargetsReplayRegressions(
    gpa: std.mem.Allocator,
    harness_path: []const u8,
    source: []const u8,
    violations: *std.ArrayList([]const u8),
) !void {
    const seeds_name = "regression_seeds";
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, source, at, target_opener)) |hit| {
        at = hit + target_opener.len;
        const name_end = std.mem.indexOfScalarPos(u8, source, at, '"') orelse source.len;
        const name = source[at..@min(name_end, source.len)];
        // The target's body: its own braces, not "everything until the next
        // target". A file whose last target is a five-hundred-line harness gave
        // every earlier target a body that swallowed the whole rest of the
        // file, so any one target's seed list satisfied all of them, the
        // per-file check this replaced, wearing per-target clothes.
        const body = testBody(source, at);
        if (std.mem.indexOf(u8, body, fuzz_call) == null) {
            try appendViolation(gpa, violations, "{s}: target \"{s}\" never calls `{s}`, so `zig build fuzz` selects a name that searches nothing.", .{ harness_path, name, fuzz_call });
            continue;
        }
        // The whole body, not just from the call onward: a target that builds
        // its corpus into a local array first names the seeds above the call,
        // not inside it.
        // Whole-identifier again: a target reading only `schedule_regression_seeds`
        // must not be satisfied by the substring inside it.
        if (!mentionsSeedList(body)) {
            try appendViolation(gpa, violations, "{s}: target \"{s}\" passes a corpus that does not include `{s}`, so a crash saved for it is never replayed. Splice the seed list into this target's corpus.", .{ harness_path, name, seeds_name });
        }
    }
}

/// Where the fuzz driver looks for targets, and the shape it looks for.
const target_file = "fuzz_test.zig";
const target_opener = "test \"fuzz: ";
const fuzz_call = "std.testing.fuzz(";
const fuzz_root = "test/fuzz_check.zig";

/// Hold every fuzz target where `zig build fuzz` can find it.
///
/// `tools/fuzz/main.zig` reads the `fuzz_test.zig` files the fuzz root imports
/// for `test "fuzz: …"` names and runs the fuzzer once per name. Three ways a
/// target anywhere under `test/` can slip out of that, all of which leave a
/// green build:
///
///   - it lives in a file with another name, so the driver never reads it,
///   - it is named without the `fuzz: ` prefix, same result,
///   - its file is not imported by the fuzz root, so it is neither compiled
///     into the artifact the fuzzer runs nor read by the driver.
///
/// In all three the test still passes under `zig build test`, replaying its
/// seeds without mutation. That is the failure worth guarding: a target that
/// looks like coverage and never searches anything.
pub fn checkFuzzTargetsAreReachable(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const fuzz_check = root.readFileAlloc(io, fuzz_root, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot read it to check the fuzz targets ({s})", .{ fuzz_root, @errorName(err) });
        return;
    };
    defer gpa.free(fuzz_check);

    const files = (try testZigFiles(io, gpa, root)) orelse {
        try appendViolation(gpa, violations, "test/: no such directory for the fuzz target check", .{});
        return;
    };
    defer freeFiles(gpa, files);

    for (files) |path| {
        const source = root.readFileAlloc(io, path, gpa, .limited(source_tree.source_read_limit)) catch |err| {
            try appendViolation(gpa, violations, "{s}: cannot be read for the fuzz target check ({s})", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(source);

        const calls = std.mem.count(u8, source, fuzz_call);
        if (calls == 0) continue;

        const dir = std.fs.path.dirname(path).?;
        if (!std.mem.eql(u8, std.fs.path.basename(path), target_file)) {
            try appendViolation(gpa, violations, "{s}: calls `{s}` but `zig build fuzz` only finds targets in files named `{s}`. Move it to {s}/{s}, or it will never be mutated.", .{ path, fuzz_call, target_file, dir, target_file });
            continue;
        }

        const named = std.mem.count(u8, source, target_opener);
        if (named < calls) {
            try appendViolation(gpa, violations, "{s}: has {d} `{s}` calls but only {d} tests named `{s}…`. `zig build fuzz` selects targets by that name, so an unnamed one is never mutated.", .{ path, calls, fuzz_call, named, target_opener });
        }

        // The exact import line the driver reads, relative to the root's own
        // directory. A substring of the path would let `collections/fuzz_test.zig`
        // pass for `loam/collections/fuzz_test.zig`.
        const relative = path[(std.fs.path.dirname(fuzz_root).?.len + 1)..];
        const import = try std.fmt.allocPrint(gpa, "@import(\"{s}\")", .{relative});
        defer gpa.free(import);
        if (std.mem.indexOf(u8, fuzz_check, import) == null) {
            try appendViolation(gpa, violations, "{s}: is not imported by {s}, so it is not in the artifact the fuzzer runs and the driver never reads it. Add `_ = {s};`.", .{ path, fuzz_root, import });
        }
    }
}

test "a nested fuzz target is held to the fuzz root and its own regressions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const target =
        \\const regression_seeds = [_][]const u8{};
        \\test "fuzz: probe" {
        \\    try std.testing.fuzz({}, one, .{ .corpus = &regression_seeds });
        \\}
    ;
    try tmp.dir.createDirPath(io, "test/top");
    try tmp.dir.createDirPath(io, "test/deep/nested/fuzz_regressions");
    try tmp.dir.writeFile(io, .{ .sub_path = "test/top/fuzz_test.zig", .data = target });
    try tmp.dir.writeFile(io, .{ .sub_path = "test/deep/nested/fuzz_test.zig", .data = target });
    try tmp.dir.writeFile(io, .{ .sub_path = "test/deep/nested/fuzz_regressions/crash.bin", .data = "x" });
    // The nested path named in a comment, which a substring match would accept.
    try tmp.dir.writeFile(io, .{ .sub_path = "test/fuzz_check.zig", .data = "_ = @import(\"top/fuzz_test.zig\");\n// deep/nested/fuzz_test.zig\n" });

    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |v| gpa.free(v);
        violations.deinit(gpa);
    }
    try checkFuzzTargetsAreReachable(io, gpa, tmp.dir, &violations);
    try checkFuzzRegressionSeeds(io, gpa, tmp.dir, &violations);
    try std.testing.expectEqual(@as(usize, 2), violations.items.len);
    try std.testing.expect(std.mem.startsWith(u8, violations.items[0], "test/deep/nested/fuzz_test.zig: is not imported by test/fuzz_check.zig"));
    try std.testing.expect(std.mem.startsWith(u8, violations.items[1], "test/deep/nested/fuzz_regressions: `crash.bin` is not replayed"));

    for (violations.items) |v| gpa.free(v);
    violations.clearRetainingCapacity();
    try tmp.dir.writeFile(io, .{ .sub_path = "test/fuzz_check.zig", .data = "_ = @import(\"top/fuzz_test.zig\");\n_ = @import(\"deep/nested/fuzz_test.zig\");\n" });
    try checkFuzzTargetsAreReachable(io, gpa, tmp.dir, &violations);
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}
