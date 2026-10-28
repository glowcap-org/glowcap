//! Process execution postures for build-owned test artifacts.
//!
//! A deterministic non-Zig subprocess owns a measured process deadline. Zig
//! tests use Zig 0.17's `--test-timeout`, which resets for each active test.
//! Putting the same ceiling around an aggregate artifact turns ordinary suite
//! growth or CPU contention into a false timeout on whichever test ran last.

const std = @import("std");
const Shard = @import("shard.zig").Shard;

/// Every command built under the `build_tool` posture, so a gate can name the
/// compile half of what it reaches (`addCompileHalf`). The build script
/// configures one graph per process, so one set serves it.
var build_tools: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;

fn registerBuildTool(b: *std.Build, run: *std.Build.Step.Run) *std.Build.Step.Run {
    build_tools.put(b.allocator, &run.step, {}) catch @panic("OOM");
    return run;
}

pub const Posture = union(enum) {
    /// A deterministic test or proof subprocess. The source gate holds this to
    /// the project's 30-second maximum. The build-time check keeps direct
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
    /// it, set to that deadline plus scheduling headroom. Bounded 31..900,
    /// a proof that fits 30 seconds is deterministic.
    browser_proof: u16,
    /// A Zig test artifact run under valgrind's memcheck, built for the
    /// baseline CPU so the checker can execute it. The checker multiplies
    /// the suite's own time, so the ceiling is minutes: bounded 31..1800.
    /// Success is quiet. Suppressions live in `tools/memcheck.supp`, each
    /// naming a false positive outside glowcap's code.
    memcheck: u16,
    /// A benchmark executable run under valgrind's callgrind, built
    /// ReleaseFast for the baseline CPU with client requests on, so the
    /// bench's phase marks (`bench/support/profile.zig`) choose what is
    /// collected and each marked phase lands as its own part under
    /// `report_dir`. Bounded 31..1800 like memcheck. A person reads the
    /// result, so output stays visible.
    profile: u16,
    /// Intentional unbounded postures. These are names, not escape hatches:
    /// the source gate inventories which artifact owns each one.
    benchmark,
    /// Compilation, generation, formatting, cache population, or setup. This
    /// is not a test escape hatch, source-check inventories every call site.
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
        .memcheck => |seconds| {
            if (seconds <= 30 or seconds > 1800) {
                @panic("memcheck deadline must be 31..1800 seconds");
            }
            const run = wrappedCommand(b, &.{
                "valgrind",
                "--leak-check=full",
                "--error-exitcode=1",
                "--num-callers=50",
                b.fmt("--suppressions={s}", .{repoPath(b, "tools/memcheck.supp")}),
            }, seconds, .{ .quiet_success = true, .deadline_retry = false });
            run.addArtifactArg(compile);
            return run;
        },
        .search => {},
        .benchmark, .browser_proof, .build_tool, .child_bounded, .deterministic, .profile, .real_internet, .service => @panic("Zig tests may be unit tests, memcheck runs, or explicit searches only"),
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
        .build_tool => registerBuildTool(b, b.addSystemCommand(argv)),
        .benchmark, .child_bounded, .search, .real_internet, .service => b.addSystemCommand(argv),
        .profile => @panic("profile runs a compiled bench, never a system command"),
        .unit_test, .memcheck => @panic("system commands cannot use a Zig test posture"),
    };
}

/// Assert a test's child output before quiet-success can hide it. Zig captures
/// checked stdout itself; the command still runs on every gate invocation. A
/// deadline retry would append a stopped attempt's partial output to the
/// checked stream, so a checked command runs once.
pub fn expectStdOutMatch(run: *std.Build.Step.Run, expected: []const u8) void {
    var index: usize = 0;
    while (index < run.argv.items.len) {
        const arg = run.argv.items[index];
        if (arg == .bytes and std.mem.eql(u8, arg.bytes, "--quiet-success")) {
            _ = run.argv.orderedRemove(index);
        } else if (arg == .bytes and std.mem.eql(u8, arg.bytes, "--deadline-retries")) {
            _ = run.argv.orderedRemove(index);
            _ = run.argv.orderedRemove(index);
        } else {
            index += 1;
        }
    }
    run.has_side_effects = true;
    run.expectStdOutMatch(expected);
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
        .profile => |seconds| blk: {
            if (seconds <= 30 or seconds > 1800) {
                @panic("profile deadline must be 31..1800 seconds");
            }
            // Instrumentation and collection both start off: the bench's
            // marks turn them on for each measured phase and dump it.
            const run = wrappedCommand(b, &.{
                "valgrind",
                "--tool=callgrind",
                "--instr-atstart=no",
                "--collect-atstart=no",
                b.fmt("--callgrind-out-file={s}", .{profileOutput(b, compile.name)}),
            }, seconds, .{ .quiet_success = false, .deadline_retry = false });
            // On 64-bit hosts, leave room below the first client mapping for
            // Zig's descending allocation hints. A large allocation after a
            // low mapping can wrap the hint, which Valgrind refuses as OOM.
            if (@sizeOf(usize) == 8) run.addArg("--aspace-minaddr=0x100000000");
            run.addArtifactArg(compile);
            break :blk run;
        },
        .build_tool => registerBuildTool(b, b.addRunArtifact(compile)),
        .benchmark, .child_bounded, .search, .real_internet, .service => b.addRunArtifact(compile),
        .unit_test, .memcheck => @panic("ordinary artifacts cannot use a Zig test posture"),
    };
}

/// Where benchmarks and profiles write, relative to the build root.
pub const report_dir = "zig-out/bench-reports";

/// The callgrind base file a profiled `name` writes. Each marked phase is a
/// numbered part beside it, and the report tool reads the set.
pub fn profileOutput(b: *std.Build, name: []const u8) []const u8 {
    return b.fmt("{s}/{s}.callgrind", .{ report_dir, name });
}

/// The aggregate for checks that own processes, ports, or shared language
/// workspaces. Runtime runs inherit stdio, which gives each one the Zig build
/// runner's global execution lock without adding dependencies to its focused
/// step or to a product command that shares a build prerequisite. Running one
/// at a time keeps a proof's deadline from measuring another proof's CPU use.
///
/// `build` is the gate's compile half: every Zig compile and build-tool
/// command the members reach. Running it first leaves the gate's own time to
/// its runs, so a cold compile on a slow machine never counts against them.
pub const RuntimeGate = struct {
    step: *std.Build.Step,
    build: *std.Build.Step,
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
        addCompileHalf(self.step, self.build);

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

/// Make `half` depend on every Zig compile and build-tool command `gate`
/// reaches. Running the half first as its own invocation leaves the gate's
/// time to its runs, so a cold compile on a slow machine never spends a run's
/// deadline. Call it after every registrar has wired `gate`.
pub fn addCompileHalf(gate: *std.Build.Step, half: *std.Build.Step) void {
    const gpa = gate.owner.allocator;
    var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    defer seen.deinit(gpa);
    var members: std.ArrayList(*std.Build.Step) = .empty;
    defer members.deinit(gpa);
    appendCompileHalf(gpa, gate, &seen, &members);
    for (members.items) |member| half.dependOn(member);
}

/// Read a `-D<name>=k/n` option, the whole family when it is absent. A value
/// that is not a shard stops configuration, so a CI line cannot run nothing.
pub fn shardOption(b: *std.Build, name: []const u8, description: []const u8) Shard {
    const text = b.option([]const u8, name, description) orelse return .{};
    return Shard.parse(text) orelse
        std.process.fatal("-D{s}={s} is not k/n with 1 <= k <= n", .{ name, text });
}

/// Declare `-Dcompile-only` and `-Dcompile-shard`, and apply them. Call it
/// after every registrar and after anything that reads the unmodified graph.
pub fn registerCompileOnly(b: *std.Build) void {
    const shard = shardOption(b, "compile-shard", "With -Dcompile-only, compile only the k-th of n interleaved slices, as k/n (default 1/1)");
    if (b.option(bool, "compile-only", "Compile what the requested steps would run, and run nothing (CI build jobs)") orelse false) {
        compileOnly(b, shard);
    }
}

/// Rewire every top-level step to its share of the compile half of what it
/// reaches, so `zig build <steps> -Dcompile-only` compiles what the same
/// invocation without the option would run, and runs nothing. A CI build job
/// uses it to fill the cache a later job's ordinary invocation hits, and
/// `shard` splits one cold build across parallel jobs: each Zig compile
/// belongs to the shard its position in one walk of the whole graph selects,
/// so the shards of an invocation together compile its half once. Every
/// build-tool command belongs to the first shard, because those commands share
/// one Cargo target directory, and Cargo calls a unit stale when a dependency
/// another job rebuilt is newer than it. A step another selected step depends
/// on still builds in that shard. Every half is taken from the unmodified graph
/// before any step is rewired.
fn compileOnly(b: *std.Build, shard: Shard) void {
    const gpa = b.allocator;
    const steps = b.top_level_steps.values();
    // Configuration is deterministic, so this walk orders the same graph the
    // same way in every shard's process.
    var everything: std.ArrayList(*std.Build.Step) = .empty;
    var walked: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    for (steps) |top| appendCompileHalf(gpa, &top.step, &walked, &everything);
    var selected: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    var compiles: usize = 0;
    for (everything.items) |member| {
        const owned = if (build_tools.contains(member)) shard.index == 1 else owned: {
            defer compiles += 1;
            break :owned shard.selects(compiles);
        };
        if (owned) selected.put(gpa, member, {}) catch @panic("OOM");
    }

    const halves = gpa.alloc(std.ArrayList(*std.Build.Step), steps.len) catch @panic("OOM");
    for (steps, halves) |top, *half| {
        half.* = .empty;
        var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
        defer seen.deinit(gpa);
        appendCompileHalf(gpa, &top.step, &seen, half);
    }
    for (steps, halves) |top, half| {
        top.step.dependencies.clearRetainingCapacity();
        for (half.items) |member| {
            if (selected.contains(member)) top.step.dependOn(member);
        }
    }
}

/// Append to `half`, in the graph's own order, every Zig compile and
/// build-tool command `root` reaches that `seen` does not already hold.
fn appendCompileHalf(
    gpa: std.mem.Allocator,
    root: *std.Build.Step,
    seen: *std.AutoHashMapUnmanaged(*std.Build.Step, void),
    half: *std.ArrayList(*std.Build.Step),
) void {
    var pending: std.ArrayList(*std.Build.Step) = .empty;
    defer pending.deinit(gpa);
    pending.append(gpa, root) catch @panic("OOM");
    while (pending.pop()) |current| {
        if ((seen.getOrPut(gpa, current) catch @panic("OOM")).found_existing) continue;
        if (current.cast(std.Build.Step.Compile) != null or build_tools.contains(current)) {
            half.append(gpa, current) catch @panic("OOM");
        }
        for (current.dependencies.items) |dependency| {
            pending.append(gpa, dependency) catch @panic("OOM");
        }
    }
}

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

/// Build-owned fronts resolve from the repository root. Each Run may choose
/// its working directory independently.
fn repoPath(b: *std.Build, relative: []const u8) []const u8 {
    return b.root.joinString(b.allocator, relative) catch @panic("OOM");
}

fn boundedCommand(
    b: *std.Build,
    argv: []const []const u8,
    seconds: u8,
) *std.Build.Step.Run {
    if (seconds == 0 or seconds > 30) {
        @panic("deterministic process deadline must be 1..30 seconds");
    }
    return wrappedCommand(b, argv, seconds, .{ .quiet_success = true, .deadline_retry = true });
}

fn browserBoundedCommand(
    b: *std.Build,
    argv: []const []const u8,
    seconds: u16,
) *std.Build.Step.Run {
    if (seconds <= 30 or seconds > 900) {
        @panic("browser-proof process deadline must be 31..900 seconds");
    }
    // In the devcontainer, every browser consumer runs under the managed-tool
    // exec front: it prepares the checkout's exact pinned browsers and supplies
    // PLAYWRIGHT_BROWSERS_PATH for this command, resolved once before the
    // timeout wrapper launches the real command. A child preflight cannot
    // export an environment value back into sibling build steps, so this
    // handoff is the seam that carries it. On a host build (macOS CI, a direct
    // host run) the existing local Playwright environment is kept and the
    // container-only front is never invoked.
    const in_devcontainer = b.graph.environ_map.get("GLOWCAP_DEVCONTAINER_DIR") != null;
    if (in_devcontainer) {
        const prefixed = b.allocator.alloc([]const u8, argv.len + 5) catch @panic("OOM");
        prefixed[0] = "bash";
        prefixed[1] = repoPath(b, ".devcontainer/bin/tools.sh");
        prefixed[2] = "exec";
        prefixed[3] = "playwright";
        prefixed[4] = "--";
        for (argv, 0..) |arg, i| {
            prefixed[5 + i] = arg;
        }
        return wrappedCommand(b, prefixed, seconds, .{ .quiet_success = false, .deadline_retry = true });
    }
    return wrappedCommand(b, argv, seconds, .{ .quiet_success = false, .deadline_retry = true });
}

const Wrap = struct {
    quiet_success: bool,
    /// One rerun when the deadline alone fires absorbs a stalled runner, and
    /// the wrapper reports the miss so a retry never hides a slow test. A
    /// valgrind run is minutes long and a profile is a measurement, so
    /// neither repeats.
    deadline_retry: bool,
};

fn wrappedCommand(
    b: *std.Build,
    argv: []const []const u8,
    seconds: u16,
    wrap: Wrap,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{
        "python3",
        repoPath(b, "tools/run-with-timeout.py"),
        "--kill-after",
        "2s",
    });
    if (wrap.quiet_success) run.addArg("--quiet-success");
    if (wrap.deadline_retry) run.addArgs(&.{ "--deadline-retries", "1" });
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
