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

/// A gate whose members must not overlap. Each member may keep its own
/// internal parallelism, but the next family starts only after the previous
/// family has released ports, target directories, and child processes.
pub const SerialGate = struct {
    step: *std.Build.Step,
    members: std.ArrayListUnmanaged(*std.Build.Step) = .empty,
    prerequisite: ?*std.Build.Step = null,
    finalized: bool = false,

    pub fn add(self: *SerialGate, member: *std.Build.Step) void {
        if (self.finalized) @panic("cannot add a member to a finalized serial gate");
        self.members.append(member.owner.allocator, member) catch @panic("OOM");
        self.step.dependOn(member);
    }

    pub fn addPrerequisite(self: *SerialGate, prerequisite: *std.Build.Step) void {
        if (self.finalized) @panic("cannot add a prerequisite to a finalized serial gate");
        if (self.prerequisite != null) @panic("serial gate already has a prerequisite");
        self.prerequisite = prerequisite;
        if (self.members.items.len == 0) {
            self.step.dependOn(prerequisite);
        }
    }

    /// Add the sequencing edges after every registrar has finished wiring the
    /// graph. `protected_root` owns shared prerequisites that this gate may
    /// consume but must never mutate, or the protected gate can acquire a
    /// runtime family through the new back edge.
    pub fn finalize(self: *SerialGate, protected_root: *std.Build.Step) void {
        if (self.finalized) @panic("serial gate finalized twice");
        self.finalized = true;

        const gpa = self.step.owner.allocator;
        var protected: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
        defer protected.deinit(gpa);
        collectReachable(gpa, protected_root, &protected);

        // Shared prerequisites cannot carry a family barrier without pulling
        // that family into the protected gate. Complete every shared node in
        // the runtime preflight instead. Runtime-only process and workspace
        // nodes can then serialize without racing those shared build outputs.
        if (self.prerequisite) |prerequisite| {
            var shared: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
            defer shared.deinit(gpa);
            for (self.members.items) |member| {
                collectProtectedReachable(gpa, member, &protected, &shared);
            }
            var it = shared.keyIterator();
            while (it.next()) |step| prerequisite.dependOn(step.*);
        }

        var previous = self.prerequisite;
        for (self.members.items) |member| {
            if (protected.contains(member)) {
                @panic("serial-gate member is also reachable from its protected gate");
            }
            if (previous) |barrier| {
                sequenceRunsAfter(member, barrier, &protected);
                member.dependOn(barrier);
            }
            previous = member;
        }

        var protected_after: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
        defer protected_after.deinit(gpa);
        collectReachable(gpa, protected_root, &protected_after);
        for (self.members.items) |member| {
            if (protected_after.contains(member)) {
                @panic("serial-gate sequencing leaked a member into its protected gate");
            }
        }
        if (self.prerequisite) |prerequisite| {
            if (protected_after.contains(prerequisite)) {
                @panic("serial-gate sequencing leaked its prerequisite into the protected gate");
            }
        }
    }
};

fn collectProtectedReachable(
    gpa: std.mem.Allocator,
    root: *std.Build.Step,
    protected: *const std.AutoHashMapUnmanaged(*std.Build.Step, void),
    shared: *std.AutoHashMapUnmanaged(*std.Build.Step, void),
) void {
    var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    defer seen.deinit(gpa);
    var pending: std.ArrayList(*std.Build.Step) = .empty;
    defer pending.deinit(gpa);
    pending.append(gpa, root) catch @panic("OOM");
    while (pending.pop()) |current| {
        if ((seen.getOrPut(gpa, current) catch @panic("OOM")).found_existing) continue;
        if (protected.contains(current)) {
            shared.put(gpa, current, {}) catch @panic("OOM");
            continue;
        }
        for (current.dependencies.items) |dependency| {
            pending.append(gpa, dependency) catch @panic("OOM");
        }
    }
}

fn sequenceRunsAfter(
    member: *std.Build.Step,
    previous: *std.Build.Step,
    protected: *const std.AutoHashMapUnmanaged(*std.Build.Step, void),
) void {
    const gpa = member.owner.allocator;
    var previous_nodes: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    defer previous_nodes.deinit(gpa);
    collectReachable(gpa, previous, &previous_nodes);

    var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    defer seen.deinit(gpa);
    var pending: std.ArrayList(*std.Build.Step) = .empty;
    defer pending.deinit(gpa);
    pending.append(gpa, member) catch @panic("OOM");
    while (pending.pop()) |current| {
        if ((seen.getOrPut(gpa, current) catch @panic("OOM")).found_existing) continue;
        if (previous_nodes.contains(current) or protected.contains(current)) continue;
        if (current.cast(std.Build.Step.Run) != null) current.dependOn(previous);
        for (current.dependencies.items) |dependency| {
            pending.append(gpa, dependency) catch @panic("OOM");
        }
    }
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
