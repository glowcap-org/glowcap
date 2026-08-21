//! Process execution postures for build-owned test artifacts.
//!
//! A deterministic test subprocess is not allowed to inherit an ambient CI
//! timeout: its owner supplies the shortest measured process deadline that
//! still leaves scheduling headroom. Zig tests still run through the standard
//! server-mode runner; the deadline wrapper is only the outer process. This is
//! external process-group containment, not a semantic timer inside a test.

const std = @import("std");

pub const Posture = union(enum) {
    /// A deterministic test or proof subprocess. The source gate holds this to
    /// the project's 30-second maximum; the build-time check keeps direct
    /// callers from constructing an invalid value outside that scan.
    deterministic: u8,
    /// Intentional unbounded postures. These are names, not escape hatches:
    /// the source gate inventories which artifact owns each one.
    benchmark,
    /// Compilation, generation, formatting, cache population, or setup. This
    /// is not a test escape hatch; source-check inventories every call site.
    build_tool,
    search,
    real_internet,
    service,
};

/// Run one Zig test artifact under its explicit process posture.
///
/// The `null` entry becomes Zig's `--test-cmd-bin`, preserving the compiled
/// test binary at the exact point the standard runner expects it.
pub fn addZigTest(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    posture: Posture,
) *std.Build.Step.Run {
    switch (posture) {
        .deterministic => |seconds| {
            if (seconds == 0 or seconds > 30) {
                @panic("deterministic Zig test deadline must be 1..30 seconds");
            }
            const run = boundedCommand(b, &.{}, seconds);
            run.addArtifactArg(compile);
            run.enableTestRunnerMode();
            return run;
        },
        .search => {},
        .benchmark, .build_tool, .real_internet, .service => @panic("Zig tests may be deterministic or explicit searches only"),
    }
    return b.addRunArtifact(compile);
}

/// Emit one system command under an explicit execution posture.
pub fn addSystemCommand(
    b: *std.Build,
    posture: Posture,
    argv: []const []const u8,
) *std.Build.Step.Run {
    return switch (posture) {
        .deterministic => |seconds| boundedCommand(b, argv, seconds),
        .benchmark, .build_tool, .search, .real_internet, .service => b.addSystemCommand(argv),
    };
}

/// Emit one compiled executable under an explicit execution posture.
pub fn addArtifact(
    b: *std.Build,
    posture: Posture,
    compile: *std.Build.Step.Compile,
) *std.Build.Step.Run {
    return switch (posture) {
        .deterministic => |seconds| blk: {
            const run = boundedCommand(b, &.{}, seconds);
            run.addArtifactArg(compile);
            break :blk run;
        },
        .benchmark, .build_tool, .search, .real_internet, .service => b.addRunArtifact(compile),
    };
}

/// Where the deadline wrapper is, said absolutely.
///
/// A step is free to run from wherever its artifact lives, and several do: the
/// TypeScript binding tests run from `bindings/ts`. A relative path here is read
/// against that directory rather than against the repository, so the wrapper is
/// simply not there and the process exits 2 before the command under test has
/// started. That failure wears a deadline's clothes — the step that fails is the
/// one with a deadline on it — while the test it names passes in milliseconds on
/// its own, so it reads as a flake and outlives several attempts to reproduce it.
fn wrapperPath(b: *std.Build) []const u8 {
    return b.root.joinString(b.allocator, "tools/run-with-timeout.py") catch @panic("OOM");
}

fn boundedCommand(
    b: *std.Build,
    argv: []const []const u8,
    seconds: u8,
) *std.Build.Step.Run {
    if (seconds == 0 or seconds > 30) {
        @panic("deterministic process deadline must be 1..30 seconds");
    }
    const run = b.addSystemCommand(&.{
        "python3",
        wrapperPath(b),
        "--kill-after",
        "2s",
        b.fmt("{d}s", .{seconds}),
    });
    run.addArgs(argv);
    return run;
}
