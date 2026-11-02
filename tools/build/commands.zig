//! System commands the build graph runs from the repository root: the rooted
//! and in-directory forms, the installed-archive form interop orchestrators
//! share, and the launcher compile preps that keep a cold toolchain out of a
//! bounded run.

const std = @import("std");
const execution = @import("execution.zig");

/// Run a system command from the repository root.
pub fn addRootedSystemCommand(
    b: *std.Build,
    posture: execution.Posture,
    argv: []const []const u8,
) *std.Build.Step.Run {
    return addSystemCommandIn(b, posture, b.path("."), argv);
}

/// Run a system command from `cwd`. A run under a process deadline gets its
/// launcher's compile as a prior build step from the same directory
/// (`addCompilePreps`).
pub fn addSystemCommandIn(
    b: *std.Build,
    posture: execution.Posture,
    cwd: std.Build.LazyPath,
    argv: []const []const u8,
) *std.Build.Step.Run {
    const run = execution.addSystemCommand(b, posture, argv);
    run.setCwd(cwd);
    switch (posture) {
        .deterministic, .browser_proof => addCompilePreps(b, cwd, argv, run),
        else => {},
    }
    return run;
}

/// Keep a launcher's own compile out of a bounded run, so the deadline times
/// the program and not a cold toolchain: `cargo run|test` builds first,
/// `deno test` type-checks with `--no-run`, a Deno entry point is cached, and
/// a Racket module is compiled with `raco make`. The run's argv stays the one
/// authority, and the scenario never executes twice. Each prep shares the run's
/// environment map, so a variable the caller sets on the run later reaches the
/// prep too, and Cargo never sees a tracked variable change between them.
fn addCompilePreps(b: *std.Build, cwd: std.Build.LazyPath, argv: []const []const u8, run: *std.Build.Step.Run) void {
    var deno_test = false;
    for (1..argv.len) |at| {
        const word = argv[at - 1];
        const next = argv[at];
        const prep_argv: []const []const u8 = if (std.mem.eql(u8, word, "cargo") and std.mem.eql(u8, next, "run"))
            &.{ "cargo", "build" }
        else if (std.mem.eql(u8, word, "cargo") and std.mem.eql(u8, next, "test"))
            &.{ "cargo", "test", "--no-run" }
        else if (std.mem.eql(u8, word, "deno") and std.mem.eql(u8, next, "test"))
            &.{ "deno", "test", "--no-run" }
        else
            continue;
        const prep = addSystemCommandIn(b, .build_tool, cwd, prep_argv);
        prep.environ_map = run.getEnvMap();
        // Cargo links the installed C ABI archives.
        if (std.mem.eql(u8, word, "cargo")) prep.step.dependOn(b.getInstallStep());
        if (std.mem.eql(u8, word, "deno")) deno_test = true;
        for (argv[at + 1 ..]) |arg| {
            if (std.mem.eql(u8, arg, "--")) break;
            prep.addArg(arg);
        }
        run.step.dependOn(&prep.step);
    }
    var deno_cache: ?*std.Build.Step.Run = null;
    var raco_make: ?*std.Build.Step.Run = null;
    for (argv) |arg| {
        if (arg.len == 0 or arg[0] == '-') continue;
        const prep = if (!deno_test and std.mem.endsWith(u8, arg, ".ts"))
            &deno_cache
        else if (std.mem.endsWith(u8, arg, ".rkt"))
            &raco_make
        else
            continue;
        if (prep.* == null) {
            prep.* = addSystemCommandIn(b, .build_tool, cwd, if (prep == &deno_cache) &.{ "deno", "cache" } else &.{ "raco", "make" });
            prep.*.?.environ_map = run.getEnvMap();
            run.step.dependOn(&prep.*.?.step);
        }
        prep.*.?.addArg(arg);
    }
}

/// A sibling-step system command that needs the installed archive set and its
/// headers and runs from the repository root with side effects, the shape
/// every cross-language interop and demo orchestrator shares.
pub fn addInstalledSystemRun(b: *std.Build, posture: execution.Posture, argv: []const []const u8) *std.Build.Step.Run {
    const run = addRootedSystemCommand(b, posture, argv);
    run.step.dependOn(b.getInstallStep());
    run.has_side_effects = true;
    return run;
}

/// Absolute path under the repository root, for environment variables passed
/// to subprocesses that cannot consume a `LazyPath`.
pub fn rootPath(b: *std.Build, sub_path: []const u8) []const u8 {
    return b.root.joinString(b.allocator, sub_path) catch @panic("OOM");
}
