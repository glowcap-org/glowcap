//! Process execution postures for build-owned test artifacts.
//!
//! A deterministic non-Zig subprocess owns a measured process deadline. Zig
//! tests use Zig 0.17's `--test-timeout`, which resets for each active test.
//! Putting the same ceiling around an aggregate artifact turns ordinary suite
//! growth or CPU contention into a false timeout on whichever test ran last.

const std = @import("std");

pub const Posture = union(enum) {
    /// A deterministic test or proof subprocess. The source gate holds this to
    /// the project's 30-second maximum; the build-time check keeps direct
    /// callers from constructing an invalid value outside that scan.
    deterministic: u8,
    /// A Zig server-mode test. The canonical build invocations set one
    /// `--test-timeout 30s` policy for every such runner.
    unit_test,
    /// A proof that drives a real browser end to end, often beside live
    /// servers or vats. Deterministic in outcome, but its process spans a
    /// Chromium launch, on-demand bundling, and multi-peer choreography, so
    /// its owner-calibrated ceiling is minutes: the scenario's own deadline
    /// stays the semantic timer, and this wrapper is the containment above
    /// it, set to that deadline plus scheduling headroom. Bounded 31..900 —
    /// a proof that fits 30 seconds is simply deterministic.
    browser_proof: u16,
    /// Intentional unbounded postures. These are names, not escape hatches:
    /// the source gate inventories which artifact owns each one.
    benchmark,
    /// Compilation, generation, formatting, cache population, or setup. This
    /// is not a test escape hatch; source-check inventories every call site.
    build_tool,
    /// A finite orchestrator whose child processes each own their deadline.
    /// The parent cannot use one fixed deadline because its healthy duration
    /// grows with the discovered child inventory.
    child_bounded,
    search,
    real_internet,
    service,
};

/// Run one Zig test artifact through the standard server-mode runner.
pub fn addZigTest(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    posture: Posture,
) *std.Build.Step.Run {
    switch (posture) {
        .unit_test => {
            const run = b.addRunArtifact(compile);
            run.setEnvironmentVariable("GLOWCAP_TEST_IRC_LOOPBACK_ONLY", "1");
            return run;
        },
        .search => {},
        .benchmark, .browser_proof, .build_tool, .child_bounded, .deterministic, .real_internet, .service => @panic("Zig tests may be unit tests or explicit searches only"),
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
        .browser_proof => |seconds| browserBoundedCommand(b, argv, seconds),
        .benchmark, .build_tool, .child_bounded, .search, .real_internet, .service => b.addSystemCommand(argv),
        .unit_test => @panic("system commands cannot use the Zig unit-test posture"),
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
        .browser_proof => |seconds| blk: {
            const run = browserBoundedCommand(b, &.{}, seconds);
            run.addArtifactArg(compile);
            break :blk run;
        },
        .benchmark, .build_tool, .child_bounded, .search, .real_internet, .service => b.addRunArtifact(compile),
        .unit_test => @panic("ordinary artifacts cannot use the Zig unit-test posture"),
    };
}

/// The aggregate for checks that own processes, ports, or shared language
/// workspaces. Runtime runs inherit stdio, which gives each one the Zig build
/// runner's global execution lock without adding dependencies to its focused
/// step or to a product command that shares a build prerequisite.
pub const RuntimeGate = struct {
    step: *std.Build.Step,
    members: std.ArrayListUnmanaged(*std.Build.Step) = .empty,
    prerequisite: ?*std.Build.Step = null,
    finalized: bool = false,

    pub fn add(self: *RuntimeGate, member: *std.Build.Step) void {
        if (self.finalized) @panic("cannot add a member to a finalized runtime gate");
        self.members.append(member.owner.allocator, member) catch @panic("OOM");
        self.step.dependOn(member);
    }

    pub fn addPrerequisite(self: *RuntimeGate, prerequisite: *std.Build.Step) void {
        if (self.finalized) @panic("cannot add a prerequisite to a finalized runtime gate");
        if (self.prerequisite != null) @panic("runtime gate already has a prerequisite");
        self.prerequisite = prerequisite;
        self.step.dependOn(prerequisite);
    }

    /// Mark side-effecting runtime commands as exclusive after every registrar
    /// has finished wiring the graph. This changes how a command executes, not
    /// what it depends on, so a focused check stays focused and a public launch
    /// cannot acquire runtime-check families through a shared compiler step.
    pub fn finalize(self: *RuntimeGate, protected_root: *std.Build.Step) void {
        if (self.finalized) @panic("runtime gate finalized twice");
        self.finalized = true;

        const gpa = self.step.owner.allocator;
        var protected: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
        defer protected.deinit(gpa);
        collectReachable(gpa, protected_root, &protected);

        for (self.members.items) |member| {
            if (protected.contains(member)) {
                @panic("runtime-gate member is also reachable from its protected gate");
            }
            makeRuntimeRunsExclusive(gpa, member);
        }

        // Exclusivity must never change reachability. Recheck the protected
        // root so a later edit cannot hide a gate-membership cycle here.
        var protected_after: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
        defer protected_after.deinit(gpa);
        collectReachable(gpa, protected_root, &protected_after);
        for (self.members.items) |member| if (protected_after.contains(member)) {
            @panic("runtime-gate member leaked into its protected gate");
        };
    }
};

fn makeRuntimeRunsExclusive(gpa: std.mem.Allocator, root: *std.Build.Step) void {
    var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    defer seen.deinit(gpa);
    var pending: std.ArrayList(*std.Build.Step) = .empty;
    defer pending.deinit(gpa);
    pending.append(gpa, root) catch @panic("OOM");
    while (pending.pop()) |current| {
        if ((seen.getOrPut(gpa, current) catch @panic("OOM")).found_existing) continue;
        if (current.cast(std.Build.Step.Run)) |run| {
            // Output-producing prerequisites remain cacheable and parallel.
            // Only commands that Zig itself would treat as side-effecting
            // receive the build runner's process-wide lock.
            if (runHasSideEffects(run)) switch (run.stdio) {
                .infer_from_args => run.stdio = .inherit,
                else => {},
            };
        }
        for (current.dependencies.items) |dependency| {
            pending.append(gpa, dependency) catch @panic("OOM");
        }
    }
}

/// Mirror `std.Build.Step.Run`'s `infer_from_args` rule before the build runner
/// serializes the graph. An output argument makes a command cacheable. A
/// passthrough or a command with no generated output is side-effecting.
fn runHasSideEffects(run: *const std.Build.Step.Run) bool {
    if (run.has_side_effects) return true;
    if (run.captured_stdout != null or run.captured_stderr != null) return false;
    var has_output = false;
    for (run.argv.items) |arg| switch (arg) {
        .passthru => return true,
        .output_file, .output_file_dep, .output_directory => has_output = true,
        else => {},
    };
    return !has_output;
}

fn collectReachable(
    gpa: std.mem.Allocator,
    root: *std.Build.Step,
    seen: *std.AutoHashMapUnmanaged(*std.Build.Step, void),
) void {
    var pending: std.ArrayList(*std.Build.Step) = .empty;
    defer pending.deinit(gpa);
    pending.append(gpa, root) catch @panic("OOM");
    while (pending.pop()) |current| {
        if ((seen.getOrPut(gpa, current) catch @panic("OOM")).found_existing) continue;
        for (current.dependencies.items) |dependency| {
            pending.append(gpa, dependency) catch @panic("OOM");
        }
    }
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
    return wrappedCommand(b, argv, seconds, true);
}

fn browserBoundedCommand(
    b: *std.Build,
    argv: []const []const u8,
    seconds: u16,
) *std.Build.Step.Run {
    if (seconds <= 30 or seconds > 900) {
        @panic("browser-proof process deadline must be 31..900 seconds");
    }
    return wrappedCommand(b, argv, seconds, false);
}

fn wrappedCommand(
    b: *std.Build,
    argv: []const []const u8,
    seconds: u16,
    quiet_success: bool,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{
        "python3",
        wrapperPath(b),
        "--kill-after",
        "2s",
    });
    if (quiet_success) run.addArg("--quiet-success");
    run.addArg(b.fmt("{d}s", .{seconds}));
    // Every bounded command is a test or browser proof. Its descendants may
    // exercise IRC, but the transport rejects anything except an explicit
    // loopback host before DNS while this sentinel is present. Intentional
    // public-network work must use the separately inventoried real_internet
    // posture.
    run.setEnvironmentVariable("GLOWCAP_TEST_IRC_LOOPBACK_ONLY", "1");
    run.addArgs(argv);
    return run;
}
