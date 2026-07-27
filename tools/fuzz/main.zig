//! Runs the fuzzer over every target and decides whether it found anything.
//!
//! Two things make this a program rather than a build step.
//!
//! First, `zig build <step> --fuzz=<n>` exits 0 even when the fuzzer crashes a
//! test. It prints the failure, writes the offending input to
//! `.zig-cache/f/crash`, and then reports success. Wrapping that command
//! directly would mean a build that goes green on a real bug, so this makes its
//! own decision instead of trusting the exit code.
//!
//! Second, one `--fuzz` run searches exactly one target, whichever the runner
//! picks. With four targets in the artifact that meant three of them were never
//! touched and the run still said "no findings" — the shape of failure that is
//! worse than a red build, because nobody looks at it again. So this finds every
//! target itself and runs the fuzzer once per target, narrowing the build to
//! that one with `-Dtest-filter`.
//!
//! A target counts as searched only if the fuzzer's own run counter advanced
//! while it ran, checked per target rather than once for the whole sweep. The
//! counter is the only honest signal: the coverage file is created, sized, and
//! written at fuzzer startup, before a single input is tried, so a check that
//! merely notices the file appearing passes for a target that searched nothing.
//! There is such a file in this repository's cache with a run count of zero.
//!
//! Usage, which the build step fills in:
//!
//!     pancake-fuzz <path-to-zig> --fuzz=<budget>
//!
//! The budget applies to each target, not to the sweep.

const std = @import("std");

/// Where the fuzzer leaves the input that crashed a test.
const crash_artifact = ".zig-cache/f/crash";
/// Where the fuzzer keeps its coverage counters, one file per distinct binary.
/// The run counts in them are how we know a run really searched.
const coverage_dir = ".zig-cache/v";
/// Every fuzz target lives in a file with this name, one directory under
/// `test/`. `zig build meta-check` holds that, so scanning those files finds
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

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    defer it.deinit();
    _ = it.skip(); // our own program name
    const zig_exe = it.next() orelse return usage();
    const fuzz_flag = it.next() orelse return usage();

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

    std.debug.print("fuzzing {d} targets, {s} each\n\n", .{ targets.len, fuzz_flag });

    for (targets, 1..) |target, n| {
        std.debug.print("[{d}/{d}] {s}\n", .{ n, targets.len, target.name });

        // A crash file left behind by an earlier target would be read as this
        // one's finding, so clear it before every run.
        cwd.deleteFile(io, crash_artifact) catch {};
        const runs_before = totalRuns(io, cwd);

        const filter = try std.fmt.allocPrint(arena, "-Dtest-filter={s}", .{target.name});
        var child = try std.process.spawn(io, .{
            .argv = &.{ zig_exe, "build", "fuzz-run", fuzz_flag, filter },
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

        if (fileExists(io, cwd, crash_artifact)) {
            reportFinding(target);
            std.process.exit(1);
        }

        const runs_after = totalRuns(io, cwd);
        if (runs_after <= runs_before) {
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
        std.debug.print("      {d} runs\n", .{runs_after - runs_before});
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
    std.debug.print("usage: pancake-fuzz <zig-exe> --fuzz=<budget>\n", .{});
    std.process.exit(2);
}

fn fileExists(io: std.Io, cwd: std.Io.Dir, path: []const u8) bool {
    cwd.access(io, path, .{}) catch return false;
    return true;
}

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
/// header implies, so a layout change becomes a loud miscount rather than a
/// quiet wrong number.
fn totalRuns(io: std.Io, cwd: std.Io.Dir) u128 {
    var dir = cwd.openDir(io, coverage_dir, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var total: u128 = 0;
    var it = dir.iterate();
    while (it.next(io) catch return total) |entry| {
        if (entry.kind != .file) continue;
        total += readRunCount(io, dir, entry.name) orelse 0;
    }
    return total;
}

/// The run count out of one coverage file, or null if the file is not one.
fn readRunCount(io: std.Io, dir: std.Io.Dir, name: []const u8) ?u64 {
    const Header = std.Build.abi.fuzz.SeenPcsHeader;
    var buf: [@sizeOf(Header)]u8 = undefined;

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

fn reportFinding(target: Target) void {
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
        \\    .zig-cache/f/crash
        \\
        \\Before treating it as a bug, check the output above for the words
        \\"in use by another fuzzer". Two sweeps at once, or one left behind by
        \\a killed run, abort on the corpus lock and leave the same file — the
        \\test never failed. Sweep for stray `fuzz-tests` processes and run
        \\this alone.
        \\
        \\Otherwise it is real. The file lives in the build cache and will not
        \\survive a clean, so turn it into a permanent test before you do
        \\anything else:
        \\
        \\  1. Copy it, naming it for what broke:
        \\
        \\       cp .zig-cache/f/crash {s}/fuzz_regressions/<name>.bin
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
    , .{ target.name, target.file, dir });
}
