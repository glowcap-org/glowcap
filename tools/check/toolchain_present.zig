//! Presence half of the toolchain gate: are the runtimes `check` declares
//! actually installed on the machine about to run it?
//!
//! The declaration half in `toolchain_check.zig` reads the build graph and can
//! answer at configure time. Presence cannot. `PATH` and its directories are
//! environment, not configuration, so observing them while configuring either
//! poisons the build cache for every `zig build` in the repository or, worse,
//! serves a verdict from a cache that was right yesterday: a reader who
//! rebuilds their container would still be told the program is missing, with
//! nothing to do about it. So this is a compiled executable the gate runs, and
//! the declaration half hands it the rows the graph reaches, each as its
//! program name followed by the reason that row exists.
//!
//! A missing runtime is not usually something the reader did. It is an image
//! layer that landed after their container was built, so the report says that
//! and names the remedy, rather than leaving `FileNotFound` from some step deep
//! in the graph as the only evidence.
//!
//! **Not every requirement is a program.** A compiler is on `PATH` long before
//! it can compile for a given target, and the same missing image layer that
//! takes `wasm-bindgen` away takes `wasm32-unknown-unknown` with it. That one
//! surfaces as a missing `core` crate from inside a dependency build, which
//! names neither the container nor the layer. So a capability is declared as
//! the command that reports it and the text that report must contain, and the
//! gate runs the probe. Declaring the probe argv is what keeps a host-tool call
//! behind this artifact reviewed rather than silent, `.devcontainer/image/
//! verify-toolchains.sh` remains the complete container contract, and this is
//! the subset `check` itself cannot run without.

const std = @import("std");
const Io = std.Io;

const usage =
    \\usage: toolchain-present programs (<program> <reason>)...
    \\       toolchain-present capability <expected> <reason> -- <probe argv>...
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const mode = args.next() orelse fail(io, usage);
    var missing: std.ArrayList([2][]const u8) = .empty;
    defer missing.deinit(gpa);

    if (std.mem.eql(u8, mode, "programs")) {
        while (args.next()) |program| {
            const why = args.next() orelse fail(io, usage);
            if (!try resolvesOnPath(gpa, io, init.environ_map, program))
                try missing.append(gpa, .{ program, why });
        }
    } else if (std.mem.eql(u8, mode, "capability")) {
        const expected = args.next() orelse fail(io, usage);
        const why = args.next() orelse fail(io, usage);
        const separator = args.next() orelse fail(io, usage);
        if (!std.mem.eql(u8, separator, "--")) fail(io, usage);
        var probe: std.ArrayList([]const u8) = .empty;
        defer probe.deinit(gpa);
        while (args.next()) |word| try probe.append(gpa, word);
        if (probe.items.len == 0) fail(io, usage);
        if (!try probeReports(gpa, io, probe.items, expected))
            try missing.append(gpa, .{ expected, why });
    } else fail(io, usage);

    if (missing.items.len == 0) return;

    const report = try renderReport(gpa, missing.items);
    defer gpa.free(report);
    // best-effort: the exit code is the verdict, so a stderr that cannot be
    // written costs the explanation and never the refusal.
    Io.File.stderr().writeStreamingAll(io, report) catch {};
    std.process.exit(1);
}

fn fail(io: Io, message: []const u8) noreturn {
    // best-effort: same as above, the exit code carries the refusal.
    Io.File.stderr().writeStreamingAll(io, message) catch {};
    std.process.exit(2);
}

/// Whether running `probe` succeeds and its output contains `expected`.
///
/// This is how a capability that is not a program gets checked: `cargo` is on
/// `PATH` long before it can compile for a given target, and `rustup target
/// list --installed` is the only thing that knows the difference. A probe that
/// cannot run at all counts as the capability being absent, because from the
/// gate's side the two are the same missing container layer.
pub fn probeReports(
    gpa: std.mem.Allocator,
    io: Io,
    probe: []const []const u8,
    expected: []const u8,
) !bool {
    // tolerant: a probe that cannot spawn, or that refuses, answers the
    // question the same way an empty listing does.
    const result = std.process.run(gpa, io, .{
        .argv = probe,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 16),
    }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    // A probe can print a partial listing and then fail; only a clean exit
    // makes its output evidence.
    if (!result.term.success()) return false;
    return std.mem.indexOf(u8, result.stdout, expected) != null;
}

/// Whether `program` resolves to something the build could execute.
///
/// This is the lookup a `Run` step's child process will do: a bare name walks
/// `PATH`, and a name carrying a separator is taken as written, the way
/// `execvp` treats it. A candidate counts only when it is a file with an
/// execute bit, so a directory of the same name, which every `access` for
/// execution accepts because directories are searchable, is not the program.
pub fn resolvesOnPath(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    program: []const u8,
) !bool {
    if (std.mem.indexOfScalar(u8, program, std.fs.path.sep) != null)
        return isExecutableFile(io, program);
    const path = environ.get("PATH") orelse return false;
    var entries = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        const candidate = try std.fs.path.join(gpa, &.{ entry, program });
        defer gpa.free(candidate);
        if (isExecutableFile(io, candidate)) return true;
    }
    return false;
}

fn isExecutableFile(io: Io, path: []const u8) bool {
    // tolerant: every way a candidate can fail to open (absent, an unreadable
    // parent, a dangling symlink) means this entry is not the program, and the
    // next `PATH` entry still can be.
    const info = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    if (info.kind != .file) return false;
    if (!Io.File.Permissions.has_executable_bit) return true;
    return info.permissions.toMode() & 0o111 != 0;
}

/// The report for what this `check` needs and this machine does not have.
pub fn renderReport(gpa: std.mem.Allocator, missing: []const [2][]const u8) ![]const u8 {
    var report: std.ArrayList(u8) = .empty;
    errdefer report.deinit(gpa);
    try report.appendSlice(gpa, "`zig build check` needs a toolchain that is not installed here:\n");
    for (missing) |row| {
        try report.print(gpa, "  - '{s}' is missing; {s}\n", .{ row[0], row[1] });
    }
    try report.appendSlice(gpa,
        \\
        \\The devcontainer image installs everything `check` declares, so a
        \\missing one usually means this container is older than the image layer
        \\that installs it. Rebuild the container; .devcontainer/README.md says
        \\how, and .devcontainer/image/verify-toolchains.sh reports the rest of
        \\the environment the same way. Installing it by hand answers this one
        \\report and leaves the next layer to find you. Outside the devcontainer,
        \\install it, or run the members that do not need it as their own steps.
        \\
    );
    return report.toOwnedSlice(gpa);
}

test "a runtime is present only when PATH holds an executable file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A `PATH` this test owns outright: the host's own is what the check reads
    // in production, and reading it here would make the result depend on which
    // machine ran the suite.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "installed-program",
        .data = "#!/bin/sh\n",
        .flags = .{ .permissions = .executable_file },
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "data-file", .data = "not a program\n" });
    try tmp.dir.createDir(io, "named-like-a-program", .default_dir);
    const bin = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(bin);

    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put("PATH", bin);

    // Calibrate on the positive first: a check that finds nothing anywhere
    // would pass the two negatives below while reporting every runtime missing.
    try std.testing.expect(try resolvesOnPath(gpa, io, &environ, "installed-program"));
    // The shape a container older than an image layer produces.
    try std.testing.expect(!try resolvesOnPath(gpa, io, &environ, "absent-program"));
    // A file of the right name that nothing can execute is not the program.
    try std.testing.expect(!try resolvesOnPath(gpa, io, &environ, "data-file"));
    // Nor is a directory, which every `access` for execution accepts.
    try std.testing.expect(!try resolvesOnPath(gpa, io, &environ, "named-like-a-program"));

    // An empty `PATH`, and no `PATH` at all, both mean nothing resolves.
    try environ.put("PATH", "");
    try std.testing.expect(!try resolvesOnPath(gpa, io, &environ, "installed-program"));
    var bare: std.process.Environ.Map = .init(gpa);
    defer bare.deinit();
    try std.testing.expect(!try resolvesOnPath(gpa, io, &bare, "installed-program"));
}

test "a capability probe answers on its output, its exit code, and whether it ran" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Calibrate on the positive: a probe runner that never finds anything would
    // pass every negative below while reporting each capability missing.
    try std.testing.expect(try probeReports(gpa, io, &.{ "echo", "wasm32-unknown-unknown" }, "wasm32-unknown-unknown"));
    try std.testing.expect(!try probeReports(gpa, io, &.{ "echo", "aarch64-unknown-linux-gnu" }, "wasm32-unknown-unknown"));

    // A probe that reports the text but refuses is not evidence: `rustup` can
    // print a partial listing and then fail.
    try std.testing.expect(!try probeReports(gpa, io, &.{ "sh", "-c", "echo wasm32-unknown-unknown; exit 3" }, "wasm32-unknown-unknown"));
    // Neither is a probe that cannot run at all, which is the same absent layer.
    try std.testing.expect(!try probeReports(gpa, io, &.{"glowcap-probe-that-nothing-installs"}, "anything"));
}

test "the report names what is missing against its reason and the remedy" {
    const gpa = std.testing.allocator;
    // A program and a capability read the same way, because to the reader they
    // are one absent container layer.
    const report = try renderReport(gpa, &.{
        .{ "wasm-bindgen", "the browser application's generated glue must match the pinned Wasm ABI" },
        .{ "wasm32-unknown-unknown", "the wasm C ABI archives compile for it" },
    });
    defer gpa.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "'wasm-bindgen' is missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "pinned Wasm ABI") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "'wasm32-unknown-unknown' is missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "Rebuild the container") != null);
}
