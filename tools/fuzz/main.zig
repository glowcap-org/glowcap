//! Runs the fuzzer over every target and decides whether it found anything.
//!
//! Two things make this a program rather than a build step.
//!
//! First, `zig build <step> --fuzz=<n>` exits 0 even when the fuzzer crashes a
//! test. It prints the failure, writes the offending input to
//! `f/crash` in the local cache, and then reports success. Wrapping that command
//! directly would mean a build that goes green on a real bug, so this makes its
//! own decision instead of trusting the exit code.
//!
//! Second, one `--fuzz` run searches exactly one target, whichever the runner
//! picks. With four targets in the artifact that meant three of them were never
//! touched and the run still said "no findings", the shape of failure that is
//! worse than a red build, because nobody looks at it again. So this finds every
//! target itself and runs the fuzzer once per target, narrowing the build to
//! that one with `-Dtest-filter`.
//!
//! A target counts as searched only if the fuzzer's own run counter advanced
//! while it ran, checked per target rather than once for the whole sweep. The
//! counter is the only reliable signal: the coverage file is created, sized, and
//! written at fuzzer startup, before a single input is tried, so a check that
//! merely notices the file appearing passes for a target that searched nothing.
//! There is such a file in this repository's cache with a run count of zero.
//!
//! The counter is read straight out of the coverage file's own header, the
//! `n_runs` field of `std.Build.abi.fuzz.SeenPcsHeader`. A file whose header does
//! not describe the file fails the sweep and says so, rather than counting as a
//! zero and reappearing later as "this target searched nothing."
//!
//! Usage, which the build step fills in:
//!
//!     glowcap-fuzz <path-to-zig> --fuzz=<budget> [--shard=<k>/<n>]
//!
//! The budget applies to each target, not to the sweep. A shard runs every
//! `n`th target in name order, starting at the `k`th, so `n` gates with their
//! own deadlines cover the whole sweep however many targets it grows to.

const std = @import("std");
const Shard = @import("shard").Shard;

/// Where the fuzzer leaves the input that crashed a test, relative to the
/// effective local cache (see `localCacheDir`).
const crash_artifact = "f/crash";

/// Where a finding is kept for whoever reads the report, including a CI run
/// that uploads it: outside the build cache, which a clean or a restored CI
/// cache replaces. A search never repeats, so this input is the only replay.
const finding_path = "zig-out/fuzz-finding.bin";
/// Where the fuzzer keeps its coverage counters, one file per distinct binary,
/// relative to the effective local cache. The run counts in them are how we
/// know a run really searched.
const coverage_dir = "v";
/// The local cache the fuzz-run child writes its `v`/`f` directories into:
/// ZIG_LOCAL_CACHE_DIR when the environment names one (the devcontainer's
/// named volume does), else the repo's `.zig-cache`. The child inherits this
/// process's environment, so reading the same variable keeps the driver's
/// counters under the directory the fuzzer used.
fn localCacheDir(init: std.process.Init) []const u8 {
    return init.environ_map.get("ZIG_LOCAL_CACHE_DIR") orelse ".zig-cache";
}
/// Every fuzz target lives in a file with this name, one directory under
/// `test/`. `zig build source-check` holds that, so scanning those files finds
/// every target there is.
const target_file = "fuzz_test.zig";
/// The prefix every fuzz target's test name carries. It is also what gets
/// handed to `-Dtest-filter`, so it has to be distinctive enough to select one
/// target and no other.
const target_prefix = "fuzz: ";

const Target = struct {
    /// The test name, without the `test "` and closing quote.
    name: []const u8,
    /// Where it was found, for the crash report.
    file: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    // Create-if-missing, as the fuzzer itself does for `v`/`f`: a fresh
    // checkout's cache need not exist when this step starts.
    const cache_dir = try std.Io.Dir.cwd().createDirPathOpen(io, localCacheDir(init), .{});

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    defer it.deinit();
    _ = it.skip(); // our own program name
    const zig_exe = it.next() orelse return usage();
    const fuzz_flag = it.next() orelse return usage();
    const shard: Shard = if (it.next()) |arg| parseShardArg(arg) orelse return usage() else .{};

    if (!fuzzingAvailable()) {
        // Not a failure. The contributor's platform simply cannot run this, and
        // saying so plainly beats failing their build over it.
        std.debug.print(
            "mutation fuzzing is not available on this platform; skipping.\n" ++
                "Zig's fuzzer needs a 64-bit Linux or macOS host.\n",
            .{},
        );
        return;
    }

    const targets = try findTargets(io, cwd, arena);
    if (targets.len == 0) {
        std.debug.print(
            \\found no fuzz targets to run.
            \\
            \\A target is a `test "fuzz: …"` block in a file named `fuzz_test.zig`
            \\one directory under `test/`. If you just moved one, move it back or
            \\teach this program where it went.
            \\
        , .{});
        std.process.exit(1);
    }

    var selected_list: std.ArrayList(Target) = .empty;
    for (targets, 0..) |target, position| {
        if (shard.selects(position)) try selected_list.append(arena, target);
    }
    const selected = selected_list.items;
    if (selected.len == 0) {
        std.debug.print("shard {d}/{d} selects none of the {d} targets; use fewer shards.\n", .{ shard.index, shard.count, targets.len });
        std.process.exit(1);
    }
    std.debug.print("fuzzing {d} of {d} targets (shard {d}/{d}), {s} each\n\n", .{ selected.len, targets.len, shard.index, shard.count, fuzz_flag });

    for (selected, 1..) |target, n| {
        std.debug.print("[{d}/{d}] {s}\n", .{ n, selected.len, target.name });

        // tolerant: a crash file left behind by an earlier target would be status-allow: event or source ordering
        // read as this one's finding, so clear it before every run; usually
        // there is nothing to delete.
        cache_dir.deleteFile(io, crash_artifact) catch {};
        const runs_before = totalRuns(io, cache_dir);

        const filter = try std.fmt.allocPrint(arena, "-Dtest-filter={s}", .{target.name});
        var child = try std.process.spawn(io, .{
            // Fuzzing needs safety, not Debug's per-operation overhead. This
            // target repeatedly builds complete hosts under a leak-checking
            // allocator; ReleaseSafe preserves those checks while making the
            // finite mutation budget practical.
            .argv = &.{ zig_exe, "build", "fuzz-run", "-Doptimize=ReleaseSafe", fuzz_flag, filter },
        });
        const term = try child.wait(io);

        switch (term) {
            .exited => |code| if (code != 0) {
                std.debug.print("\nthe fuzz run failed to start or build (exit {d}).\n", .{code});
                std.process.exit(1);
            },
            else => {
                std.debug.print("\nthe fuzz run was killed by a signal.\n", .{});
                std.process.exit(1);
            },
        }

        if (fileExists(io, cache_dir, crash_artifact)) {
            const cached = try std.fs.path.join(arena, &.{ localCacheDir(init), crash_artifact });
            reportFinding(target, keepFinding(io, cwd, cache_dir) orelse cached);
            std.process.exit(1);
        }

        const runs_after = totalRuns(io, cache_dir);
        // A coverage file this program cannot read as a header is not a zero to
        // be summed past: the number it was asked for would be meaningless, and
        // a meaningless number that happens to have grown would report a search
        // that may never have happened. Loud here, where the reason is known.
        if (runs_before.unreadable != 0 or runs_after.unreadable != 0) {
            std.debug.print(
                \\
                \\the fuzzer's run counter could not be read: {d} of the {d} files in
                \\`{s}` do not match `std.Build.abi.fuzz.SeenPcsHeader`.
                \\
                \\That header is the declared interface between Zig's build runner
                \\and its fuzzer, and this program reads `n_runs` out of it to know
                \\a target really searched. If the layout moved with a Zig upgrade,
                \\`readRunCount` in this file is what needs teaching.
                \\
            , .{
                @max(runs_before.unreadable, runs_after.unreadable),
                @max(runs_before.files, runs_after.files),
                coverage_dir,
            });
            std.process.exit(1);
        }
        if (runs_after.n_runs <= runs_before.n_runs) {
            std.debug.print(
                \\
                \\this target reported success but the fuzzer's run counter did
                \\not move, so it searched nothing. Treating that as a failure: a
                \\fuzz step that stops working while still passing is the one
                \\outcome worth guarding against.
                \\
                \\Check that `{s}` still selects exactly this test, and that the
                \\test still calls `std.testing.fuzz`.
                \\
            , .{target.name});
            std.process.exit(1);
        }
        std.debug.print("      {d} runs\n", .{runs_after.n_runs - runs_before.n_runs});
    }

    std.debug.print("\nno findings across {d} targets.\n", .{targets.len});
}

/// Every fuzz target in the tree, found by reading the test names out of the
/// source rather than from a list somebody has to remember to update.
fn findTargets(io: std.Io, cwd: std.Io.Dir, gpa: std.mem.Allocator) ![]const Target {
    var found: std.ArrayList(Target) = .empty;

    var test_dir = try cwd.openDir(io, "test", .{ .iterate = true });
    defer test_dir.close(io);

    var entries = test_dir.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const path = try std.fmt.allocPrint(gpa, "test/{s}/{s}", .{ entry.name, target_file });
        // tolerant: a test tree without this file hosts no fuzz targets;
        // the fuzz-wiring check owns reporting an unreadable one.
        const source = cwd.readFileAlloc(io, path, gpa, .limited(1 << 22)) catch continue;
        try collectTargets(source, path, &found, gpa);
    }

    // Stable order, so a run reads the same way twice and a failure is easy to
    // find in a log.
    std.mem.sort(Target, found.items, {}, lessByName);
    return found.items;
}

fn lessByName(_: void, a: Target, b: Target) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn collectTargets(source: []const u8, file: []const u8, out: *std.ArrayList(Target), gpa: std.mem.Allocator) !void {
    const opener = "test \"" ++ target_prefix;
    var rest = source;
    while (std.mem.indexOf(u8, rest, opener)) |at| {
        const name_start = at + "test \"".len;
        const after = rest[name_start..];
        const close = std.mem.indexOfScalar(u8, after, '"') orelse break;
        try out.append(gpa, .{ .name = after[0..close], .file = file });
        rest = after[close..];
    }
}

/// Zig's build runner refuses `--fuzz` on Windows and on 32-bit hosts.
fn fuzzingAvailable() bool {
    const os = @import("builtin").os.tag;
    const supported_os = os == .linux or os.isDarwin();
    return supported_os and @sizeOf(usize) == 8;
}

fn usage() void {
    std.debug.print("usage: glowcap-fuzz <zig-exe> --fuzz=<budget> [--shard=<k>/<n>]\n", .{});
    std.process.exit(2);
}

fn parseShardArg(arg: []const u8) ?Shard {
    const prefix = "--shard=";
    if (!std.mem.startsWith(u8, arg, prefix)) return null;
    return Shard.parse(arg[prefix.len..]);
}

fn fileExists(io: std.Io, cwd: std.Io.Dir, path: []const u8) bool {
    cwd.access(io, path, .{}) catch return false;
    return true;
}

/// What the coverage directory says about how much searching has happened.
const Runs = struct {
    /// Inputs the fuzzer has tried, summed over every coverage file it could
    /// read.
    n_runs: u128 = 0,
    /// Files in the directory, and how many of them did not read as a header.
    /// The caller fails on any of the second kind: the count it asked for is
    /// only as good as the layout it was read through.
    files: usize = 0,
    unreadable: usize = 0,
};

/// How many inputs the fuzzer has tried, summed over every coverage file.
///
/// Only the running target's file advances, so the difference across one run is
/// exactly that target's run count. Summing means the answer does not depend on
/// working out which file belongs to which target, and the files accumulate:
/// one per distinct binary, kept across sweeps.
///
/// The layout is `std.Build.abi.fuzz.SeenPcsHeader`, the declared interface
/// between Zig's build runner and its fuzzer rather than an internal detail.
/// Even so, `readRunCount` verifies each file's length against what its own
/// header implies, and a file that fails that check is counted here rather than
/// summed as a zero, so a layout change fails the sweep with its own reason
/// instead of looking like a target that searched nothing.
fn totalRuns(io: std.Io, cwd: std.Io.Dir) Runs {
    var dir = cwd.openDir(io, coverage_dir, .{ .iterate = true }) catch return .{};
    defer dir.close(io);
    var tally: Runs = .{};
    var it = dir.iterate();
    while (it.next(io) catch return tally) |entry| {
        if (entry.kind != .file) continue;
        tally.files += 1;
        if (readRunCount(io, dir, entry.name)) |n| {
            tally.n_runs += n;
        } else {
            tally.unreadable += 1;
        }
    }
    return tally;
}

/// The run count out of one coverage file, or null if the file is not one.
fn readRunCount(io: std.Io, dir: std.Io.Dir, name: []const u8) ?u64 {
    const Header = std.Build.abi.fuzz.SeenPcsHeader;
    // The read buffer must carry the header's alignment in its type: a plain
    // byte array aligns to 1, and the cast below panics on an unaligned stack
    // slot instead of reading a wrong counter.
    var buf: [@sizeOf(Header)]u8 align(@alignOf(Header)) = undefined;

    var file = dir.openFile(io, name, .{}) catch return null;
    defer file.close(io);
    var reader = file.reader(io, &.{});
    reader.interface.readSliceAll(&buf) catch return null;

    const header: *align(@alignOf(usize)) const Header = @ptrCast(@alignCast(&buf));
    // The header fixes the file's whole size, so a mismatch means the layout
    // moved under us and this number would be meaningless.
    const expected = @sizeOf(Header) +
        @sizeOf(usize) * (Header.seenElemsLen(header.pcs_len) + header.pcs_len);
    const stat = file.stat(io) catch return null;
    if (stat.size != expected) return null;
    return header.n_runs;
}

/// Copy the crash input to `finding_path`. A copy that fails leaves the input
/// in the cache, and the report names that path instead.
fn keepFinding(io: std.Io, cwd: std.Io.Dir, cache_dir: std.Io.Dir) ?[]const u8 {
    cwd.createDirPath(io, std.fs.path.dirname(finding_path).?) catch return null;
    std.Io.Dir.copyFile(cache_dir, crash_artifact, cwd, finding_path, io, .{}) catch return null;
    return finding_path;
}

fn reportFinding(target: Target, input: []const u8) void {
    const dir = std.fs.path.dirname(target.file) orelse "test";
    std.debug.print(
        \\
        \\The fuzzer found an input that crashes this target:
        \\
        \\    {s}
        \\    {s}
        \\
        \\Details are in the output above; the input itself was written to
        \\
        \\    {s}
        \\
        \\Before treating it as a bug, check the output above for the words
        \\"in use by another fuzzer". Two sweeps at once, or one left behind by
        \\a killed run, abort on the corpus lock and leave the same file — the
        \\test never failed. Sweep for stray `fuzz-tests` processes and run
        \\this alone.
        \\
        \\Otherwise it is real. Fuzzing never repeats a search, so turn the
        \\input into a permanent test before you do anything else:
        \\
        \\  1. Copy it, naming it for what broke:
        \\
        \\       cp {s} {s}/fuzz_regressions/<name>.bin
        \\
        \\  2. Add one line to the regression seed list in that target's file.
        \\
        \\Now reproduce it whenever you like, with no fuzzer involved:
        \\
        \\       zig build test -Dtest-filter=fuzz
        \\
        \\Fuzzing is not repeatable; the saved input is. That replay is what
        \\proves the fix, and what stops the bug coming back.
        \\
    , .{ target.name, target.file, input, input, dir });
}
