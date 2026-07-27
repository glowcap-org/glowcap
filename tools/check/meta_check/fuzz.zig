//! Checks on the fuzzing setup.
//!
//! Three things need holding.
//!
//! The vendored copy of Zig's test runner has to stay exactly what it claims to
//! be, and it has to disappear the moment Zig no longer needs patching.
//!
//! Every crash input sitting in the regressions directory has to be wired into
//! the replay, because a regression test nobody runs is worse than no test at
//! all.
//!
//! And every fuzz target has to be somewhere `zig build fuzz` will find it. The
//! driver runs the fuzzer once per target, which it discovers by reading test
//! names out of files called `fuzz_test.zig` one directory under `test/`. A
//! target written anywhere else compiles, passes the ordinary suite by replaying
//! its seeds, and is never once mutated — it looks like coverage and is not.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

/// The call in Zig's own test runner that does not compile in fuzz mode. It
/// hands an error-return trace to a function expecting a different struct.
const upstream_call = "std.debug.writeStackTrace(trace, stderr)";
/// The neighbouring function that takes exactly the type in hand. Zig's own
/// `debug.zig` uses it for this same job everywhere else.
const patched_call = "std.debug.writeErrorReturnTrace(trace, stderr)";

const vendored_path = "tools/fuzz/test_runner.zig";
const upstream_path = "compiler/test_runner.zig";
/// Everything above this line in the vendored file is pancake's own note about
/// where the rest came from; everything below it is Zig's file with one call
/// renamed. Comparing from offset zero left no room for that note, so the copy
/// could not say whose it was — which is the thing a reader most needs it to
/// say, and the thing a licence asks it to say.
const upstream_marker = "// ---- Zig's file begins here ----\n";
const notice_path = "LICENSE-THIRD-PARTY";

/// Hold the vendored test runner's licence notice, and the notice's place in
/// the package manifest.
///
/// Separate from the drift comparison below on purpose: an unreadable notice
/// must not double as an excuse to skip checking whether the copy still
/// matches the toolchain. One failure reporting two things, and silencing the
/// load-bearing one, is how a gate quietly stops gating.
pub fn checkVendoredRunnerLicense(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    if (root.readFileAlloc(io, notice_path, gpa, .limited(1 << 20))) |notice| {
        defer gpa.free(notice);
        const notice_needles = [_][]const u8{
            "`tools/fuzz/test_runner.zig`",
            "Copyright (c) Zig contributors",
            "MIT-only",
        };
        for (notice_needles) |needle| {
            if (std.mem.indexOf(u8, notice, needle) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` required by the vendored Zig test runner's license scope", .{ notice_path, needle });
            }
        }
    } else |err| {
        try appendViolation(gpa, violations, "{s}: {s} is vendored but its Zig MIT notice cannot be read ({s})", .{ vendored_path, notice_path, @errorName(err) });
    }

    const manifest_path = "build.zig.zon";
    if (root.readFileAlloc(io, manifest_path, gpa, .limited(1 << 20))) |manifest| {
        defer gpa.free(manifest);
        if (std.mem.indexOf(u8, manifest, "\"" ++ notice_path ++ "\"") == null) {
            try appendViolation(gpa, violations, "{s}: package includes {s} but omits {s}; source distributions would lose Zig's MIT notice", .{ manifest_path, vendored_path, notice_path });
        }
    } else |err| {
        try appendViolation(gpa, violations, "{s}: cannot read package manifest to verify {s} ships with the vendored source ({s})", .{ manifest_path, notice_path, @errorName(err) });
    }
}

/// Hold the vendored test runner against the toolchain's own copy.
///
/// The vendored file is upstream's, with one call renamed and nothing else
/// changed. Comparing it that way, rather than looking for a marker inside it,
/// means the check can tell three situations apart and say something useful
/// about each: the copy is exactly right, Zig changed the file and the copy
/// needs remaking, or Zig fixed the call and the copy should be deleted.
///
/// That last case is the reason this check earns its place. Vendored code
/// outlives its excuse unless something notices.
pub fn checkVendoredTestRunner(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    zig_lib_path: []const u8,
) !void {
    var lib = std.Io.Dir.cwd().openDir(io, zig_lib_path, .{}) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot open the Zig library directory `{s}` to compare the vendored test runner ({s})", .{ vendored_path, zig_lib_path, @errorName(err) });
        return;
    };
    defer lib.close(io);

    const upstream = lib.readFileAlloc(io, upstream_path, gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot read `{s}/{s}` to compare against ({s})", .{ vendored_path, zig_lib_path, upstream_path, @errorName(err) });
        return;
    };
    defer gpa.free(upstream);

    const vendored = root.readFileAlloc(io, vendored_path, gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot read the vendored copy ({s})", .{ vendored_path, @errorName(err) });
        return;
    };
    defer gpa.free(vendored);

    switch (std.mem.count(u8, upstream, upstream_call)) {
        0 => {
            try appendViolation(gpa, violations, "{s}: this Zig no longer contains `{s}`, so the bug the copy works around looks fixed. Delete {s}, remove the `.test_runner` line from the fuzz artifact in build.zig, and delete this check.", .{ vendored_path, upstream_call, vendored_path });
            return;
        },
        1 => {},
        else => |n| {
            try appendViolation(gpa, violations, "{s}: expected one `{s}` in this Zig's test runner, found {d}. Work out which one needs patching before re-vendoring.", .{ vendored_path, upstream_call, n });
            return;
        },
    }

    const marker_at = std.mem.indexOf(u8, vendored, upstream_marker) orelse {
        try appendViolation(gpa, violations, "{s}: has no `{s}` line. That line separates pancake's note about where this file came from from the file itself; without it there is no way to tell the two apart.", .{ vendored_path, upstream_marker });
        return;
    };
    const copied = vendored[marker_at + upstream_marker.len ..];

    const expected = try std.mem.replaceOwned(u8, gpa, upstream, upstream_call, patched_call);
    defer gpa.free(expected);
    if (!std.mem.eql(u8, expected, copied)) {
        try appendViolation(gpa, violations, "{s}: below the marker, does not match this Zig's `{s}` with `{s}` renamed to `{s}`. Copy the file again, keep the note above the marker, and redo that one rename.", .{ vendored_path, upstream_path, upstream_call, patched_call });
    }
}

/// Every crash input in every target's regressions directory must be replayed.
///
/// The fuzzer writes a failing input to the build cache, which is wiped by any
/// clean. Copying it into the tree is only half the job; if nobody wires it into
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
    var test_dir = root.openDir(io, "test", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "test/: cannot open it to check the fuzz regressions ({s})", .{@errorName(err)});
        return;
    };
    defer test_dir.close(io);

    // Null, not an early return: an unreadable canonical README costs the
    // README comparison below and nothing else. Returning here would silence
    // the seed-replay walk this function exists for, which is the same
    // one-failure-hides-another shape `checkVendoredRunnerLicense` was split
    // out to remove.
    const canonical_readme: ?[]const u8 = root.readFileAlloc(io, canonical_regressions_readme_path, gpa, .limited(1 << 20)) catch |err| blk: {
        try appendViolation(gpa, violations, "{s}: cannot read the canonical fuzz-regression README ({s})", .{ canonical_regressions_readme_path, @errorName(err) });
        break :blk null;
    };
    defer if (canonical_readme) |text| gpa.free(text);

    var entries = test_dir.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        const harness_path = try std.fmt.allocPrint(gpa, "test/{s}/{s}", .{ entry.name, target_file });
        defer gpa.free(harness_path);
        const harness = root.readFileAlloc(io, harness_path, gpa, .limited(2 << 20)) catch continue;
        defer gpa.free(harness);

        // A target with no regressions directory at all used to look exactly
        // like one with an empty directory, so this check could not see the
        // case it exists to refuse: a crash the driver tells you to save into a
        // path that is not there, and a seed list to add it to that does not
        // exist either. Absent is a violation now, not a skip.
        //
        // Per target, not per file. One file may hold several targets, and
        // asking only whether the *file* mentions a seed list passes a file
        // where one target replays its regressions and the others cannot. That
        // is worse than no check: the target reads as covered, and a crash
        // pasted into the list it was told to use is handed to some other
        // target that will never take the path it was found on.
        try checkTargetsReplayRegressions(gpa, harness_path, harness, violations);

        const regressions_dir = try std.fmt.allocPrint(gpa, "test/{s}/fuzz_regressions", .{entry.name});
        defer gpa.free(regressions_dir);
        var dir = root.openDir(io, regressions_dir, .{ .iterate = true }) catch {
            try appendViolation(gpa, violations, "{s}: does not exist, and `zig build fuzz` tells you to copy a crash into it. Create it.", .{regressions_dir});
            continue;
        };
        defer dir.close(io);

        // Every one of these directories carries the same README, explaining
        // what the files are and how to wire one in. One text, one meaning:
        // seven near-identical copies are how the explanation drifts into
        // seven different half-truths.
        if (canonical_readme) |canonical| {
            const readme_path = try std.fmt.allocPrint(gpa, "{s}/README.md", .{regressions_dir});
            defer gpa.free(readme_path);
            if (root.readFileAlloc(io, readme_path, gpa, .limited(1 << 20))) |readme| {
                defer gpa.free(readme);
                if (!std.mem.eql(u8, readme, canonical)) {
                    try appendViolation(gpa, violations, "{s}: differs from {s}. The fuzz-regression READMEs are one text; edit the canonical copy and mirror it.", .{ readme_path, canonical_regressions_readme_path });
                }
            } else |err| {
                try appendViolation(gpa, violations, "{s}: cannot be read ({s}); every fuzz-regression directory carries the same README.", .{ readme_path, @errorName(err) });
            }
        }

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
            // And into a list some target actually reads. A file may hold two
            // targets whose inputs mean different things — a saved completion
            // schedule is nothing to a frame reader — so being embedded
            // *somewhere* is not the same as being replayed.
            const list = enclosingSeedList(harness, embed) orelse {
                try appendViolation(gpa, violations, "{s}: `{s}` is embedded in {s} but not inside a `regression_seeds` list, so nothing replays it.", .{ regressions_dir, file.name, harness_path });
                continue;
            };
            // In a file with more than one seed list, the filename must say
            // which. Binding a saved input to a *list* is all the check can
            // decide from here — it cannot read the bytes and tell a completion
            // schedule from a frame — so the one mistake left is pasting into
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
                // input was saved for is unknowable from here — and in a file
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
        const close = std.mem.indexOfScalarPos(u8, source, probe, '}') orelse continue;
        if (at > close) continue;
        // Back over the identifier that precedes the `=`.
        var start = hit;
        while (start > 0 and (std.ascii.isAlphanumeric(source[start - 1]) or source[start - 1] == '_')) start -= 1;
        best = source[start..hit];
    }
    return best;
}

/// How many distinct seed lists the harness declares.
fn seedListCount(source: []const u8) usize {
    const opener = " = [_][]const u8{";
    var count: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, source, at, opener)) |hit| {
        at = hit + opener.len;
        var start = hit;
        while (start > 0 and isIdentChar(source[start - 1])) start -= 1;
        if (std.mem.endsWith(u8, source[start..hit], "regression_seeds")) count += 1;
    }
    return count;
}

/// Whether `body` reads any seed list — an identifier ending in
/// `regression_seeds`, so `schedule_regression_seeds` counts and the bare
/// substring inside it does not.
fn mentionsSeedList(body: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, body, at, "regression_seeds")) |hit| {
        at = hit + "regression_seeds".len;
        if (at >= body.len or !isIdentChar(body[at])) return true;
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
        const before_ok = hit == 0 or !isIdentChar(haystack[hit - 1]);
        const after_ok = at >= haystack.len or !isIdentChar(haystack[at]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
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
/// silently ignores it. The check is the name, not the value — whether the
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
        // file, so any one target's seed list satisfied all of them — the
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

/// The copy that owns the one text every `test/*/fuzz_regressions/README.md`
/// carries.
const canonical_regressions_readme_path = "test/codec/fuzz_regressions/README.md";

/// Where the fuzz driver looks for targets, and the shape it looks for.
const target_file = "fuzz_test.zig";
const target_opener = "test \"fuzz: ";
const fuzz_call = "std.testing.fuzz(";
const fuzz_root = "test/fuzz_check.zig";

/// Hold every fuzz target where `zig build fuzz` can find it.
///
/// `tools/fuzz/main.zig` discovers targets by scanning `test/<dir>/fuzz_test.zig`
/// for `test "fuzz: …"` names and running the fuzzer once per name. Three ways
/// a target can slip out of that, all of which leave a green build:
///
///   - it lives in a file with another name, so the scan never sees it;
///   - it is named without the `fuzz: ` prefix, same result;
///   - its file is not imported by the fuzz root, so it is not even compiled
///     into the artifact the fuzzer runs.
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

    var test_dir = root.openDir(io, "test", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "test/: cannot open it to check the fuzz targets ({s})", .{@errorName(err)});
        return;
    };
    defer test_dir.close(io);

    var it = test_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        var sub = test_dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
        defer sub.close(io);

        var files = sub.iterate();
        while (try files.next(io)) |file| {
            if (file.kind != .file) continue;
            if (!std.mem.endsWith(u8, file.name, ".zig")) continue;

            const path = try std.fmt.allocPrint(gpa, "test/{s}/{s}", .{ entry.name, file.name });
            defer gpa.free(path);
            const source = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch continue;
            defer gpa.free(source);

            const calls = std.mem.count(u8, source, fuzz_call);
            if (calls == 0) continue;

            if (!std.mem.eql(u8, file.name, target_file)) {
                try appendViolation(gpa, violations, "{s}: calls `{s}` but `zig build fuzz` only finds targets in files named `{s}`. Move it to test/{s}/{s}, or it will never be mutated.", .{ path, fuzz_call, target_file, entry.name, target_file });
                continue;
            }

            const named = std.mem.count(u8, source, target_opener);
            if (named < calls) {
                try appendViolation(gpa, violations, "{s}: has {d} `{s}` calls but only {d} tests named `{s}…`. `zig build fuzz` selects targets by that name, so an unnamed one is never mutated.", .{ path, calls, fuzz_call, named, target_opener });
            }

            const import = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ entry.name, file.name });
            defer gpa.free(import);
            if (std.mem.indexOf(u8, fuzz_check, import) == null) {
                try appendViolation(gpa, violations, "{s}: is not imported by {s}, so it is not in the artifact the fuzzer runs. Add `_ = @import(\"{s}\");`.", .{ path, fuzz_root, import });
            }
        }
    }
}
