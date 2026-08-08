//! Toolchain gate — holds `zig build check` to a declared set of runtimes.
//!
//! `check` is hermetic in the sense that matters: no network, no submodules, no
//! live peer, no authority outside pancake. That is the axis `check-external`
//! divides on. It is *not* Zig-only, and the [cli rule](../../.agents/rules/cli.md)
//! promised for a long time that it was, because three members need a program on
//! PATH: the hermetic CLI tests link the iroh sidecar staticlib, the visualizer's
//! suite is TypeScript, and the C-ABI extract matrix drives real extractors.
//!
//! Each of those was a deliberate call by its author, and each was right — a
//! soft-green extract matrix is a footgun, and the CLI goldens are worth having
//! in the gate everyone runs. What went wrong is that the requirement arrived
//! silently three times, so the rule's claim died without anyone deciding to
//! kill it, and a contributor with only Zig found the gate would not run at all.
//!
//! So the set is declared in `check_runtimes` in build.zig and held here: a
//! member of `check` that invokes a program outside it fails this step, and an
//! interpreter may only run the scripts its row names. Requiring a fourth
//! runtime becomes a one-line, reviewed edit to that table.
//!
//! **What this cannot see.** The graph carries `argv[0]` only, so a runtime a
//! declared script reaches *inside* itself is invisible here: the extract matrix
//! reaches `python3`, `deno`, and `tar` through bash, and nothing mechanical
//! holds that list. Its row says so, and that prose is the only record.
//!
//! Wired as the `zig build toolchain-check` step and into `zig build check`.

const std = @import("std");
const Build = std.Build;
const Step = Build.Step;

/// One program `check` may invoke, and why a step needing it belongs in the main
/// gate instead of a sibling.
pub const Runtime = struct {
    /// `argv[0]` exactly as build.zig writes it.
    program: []const u8,
    /// For an interpreter, the scripts it may run under `check`. Empty means the
    /// program's arguments are unconstrained.
    scripts: []const []const u8 = &.{},
    /// The member that needs it, the reason it is not a sibling, and any runtime
    /// the script reaches that this gate cannot see.
    why: []const u8,
};

/// Create the `toolchain-check` step over the graph rooted at `root`.
///
/// `root` is `check` itself, so the walk sees exactly what `check` would run,
/// including members added after this call. Reaching itself is harmless: a
/// custom step runs no program.
pub fn create(b: *Build, root: *Step, runtimes: []const Runtime) *Step {
    const wrapper = b.allocator.create(ToolchainCheck) catch @panic("OOM");
    wrapper.* = .{
        .step = Step.init(.{
            .id = .custom,
            .name = "toolchain-check",
            .owner = b,
            .makeFn = make,
        }),
        .root = root,
        .runtimes = runtimes,
    };
    return &wrapper.step;
}

const ToolchainCheck = struct {
    step: Step,
    root: *Step,
    runtimes: []const Runtime,
};

/// The program a step invokes, or null when it runs a Zig-built artifact, the
/// Zig compiler itself, or no program at all.
///
/// `addRunArtifact` puts the compiled binary in the first argument, so the
/// `.artifact` arm needs no declaration. `addSystemCommand` puts the program
/// name there as bytes, which is the case that costs something on PATH — except
/// when that name is the running compiler, which is on PATH by construction.
fn programOf(step: *Step, zig_exe: []const u8) ?[]const u8 {
    const run = step.cast(Step.Run) orelse return null;
    if (run.argv.items.len == 0) return null;
    const program = switch (run.argv.items[0]) {
        .bytes => |bytes| bytes,
        else => return null,
    };
    if (std.mem.eql(u8, program, zig_exe)) return null;
    return program;
}

/// The first argument as a plain string, for holding an interpreter to its
/// declared scripts. A non-bytes argument has no name to match, so it is
/// reported rather than accepted.
fn scriptOf(step: *Step) ?[]const u8 {
    const run = step.cast(Step.Run) orelse return null;
    if (run.argv.items.len < 2) return null;
    return switch (run.argv.items[1]) {
        .bytes => |bytes| bytes,
        else => null,
    };
}

fn violation(
    gpa: std.mem.Allocator,
    runtimes: []const Runtime,
    step: *Step,
    program: []const u8,
) !?[]const u8 {
    for (runtimes) |runtime| {
        if (!std.mem.eql(u8, runtime.program, program)) continue;
        if (runtime.scripts.len == 0) return null;
        const script = scriptOf(step) orelse return try std.fmt.allocPrint(
            gpa,
            "step '{s}' runs '{s}' with no named script, and '{s}' is declared for named scripts only",
            .{ step.name, program, program },
        );
        for (runtime.scripts) |declared| {
            if (std.mem.eql(u8, declared, script)) return null;
        }
        return try std.fmt.allocPrint(
            gpa,
            "step '{s}' runs '{s} {s}', which is not among the scripts declared for '{s}'",
            .{ step.name, program, script, program },
        );
    }
    return try std.fmt.allocPrint(
        gpa,
        "step '{s}' runs '{s}', which `check` does not declare",
        .{ step.name, program },
    );
}

fn make(step: *Step, options: Step.MakeOptions) anyerror!void {
    const gpa = options.gpa;
    const check: *ToolchainCheck = @fieldParentPtr("step", step);
    const zig_exe = step.owner.graph.zig_exe;

    var seen: std.AutoHashMapUnmanaged(*Step, void) = .empty;
    defer seen.deinit(gpa);
    var pending: std.ArrayList(*Step) = .empty;
    defer pending.deinit(gpa);
    var offenders: std.ArrayList([]const u8) = .empty;
    defer {
        for (offenders.items) |line| gpa.free(line);
        offenders.deinit(gpa);
    }

    try pending.append(gpa, check.root);
    while (pending.pop()) |current| {
        if ((try seen.getOrPut(gpa, current)).found_existing) continue;
        if (programOf(current, zig_exe)) |program| {
            if (try violation(gpa, check.runtimes, current, program)) |line|
                try offenders.append(gpa, line);
        }
        for (current.dependencies.items) |dependency| try pending.append(gpa, dependency);
    }

    if (offenders.items.len == 0) return;

    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(gpa);
    try report.appendSlice(gpa, "`zig build check` may only invoke the runtimes it declares, but:\n");
    for (offenders.items) |line| {
        try report.appendSlice(gpa, "  - ");
        try report.appendSlice(gpa, line);
        try report.append(gpa, '\n');
    }
    try report.appendSlice(
        gpa,
        \\
        \\Either give the step its own `zig build` step and sequence it from
        \\`ci/gates.sh`, or add a row to `check_runtimes` in build.zig saying
        \\which member needs the program and why it belongs in the gate everyone
        \\runs. A new row raises what a contributor must install, so the cli rule
        \\names the set too.
        ,
    );
    return step.fail("{s}", .{report.items});
}
