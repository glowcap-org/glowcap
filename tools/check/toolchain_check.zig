//! Toolchain gate — holds `zig build check` to a declared set of runtimes.
//!
//! `check` is hermetic in the sense that matters: no network, no submodules, no
//! live peer, no authority outside glowcap. That is the axis `check-external`
//! divides on. It is *not* Zig-only, and the [cli rule](../../.agents/rules/cli.md)
//! promised for a long time that it was, even though the hermetic CLI tests link
//! the iroh sidecar staticlib and two gated harnesses invoke host tools.
//!
//! Each of those was a deliberate call by its author, and each was right — a
//! soft-green extract matrix is a footgun, and the CLI goldens are worth having
//! in the gate everyone runs. What went wrong is that the requirement arrived
//! silently three times, so the rule's claim died without anyone deciding to
//! kill it, and a contributor with only Zig found the gate would not run at all.
//!
//! So the set is declared in `check_runtimes` in tools/build/toolchain.zig and held here: a
//! member of `check` that invokes a program outside it fails this step, and an
//! interpreter may only run the scripts its row names. Requiring a fourth
//! runtime becomes a one-line, reviewed edit to that table.
//!
//! **What this cannot see.** The graph identifies the command after plain
//! `env NAME=value` assignments, but a program a
//! declared script reaches *inside* itself is invisible here. The extract matrix
//! requires `tar`; its Python and Deno validators and the visualizer's Deno suite
//! are optional coverage that reports an explicit skip. The Bash row records
//! that contract because the graph can only see Bash.
//!
//! **The other direction.** Declaring a runtime is a claim that the machine
//! running `check` has it, and that claim goes stale on its own: a commit adds
//! an image layer, and every container built before it keeps working until some
//! member deep in the graph reports `FileNotFound` for a program the reader has
//! never heard of. So the same walk that finds what `check` runs also resolves
//! each declared program on `PATH` and names the missing one against its
//! reason, before the gate spends a compile on the step that needs it.
//!
//! Wired as the `zig build toolchain-check` step and into `zig build check`.

const std = @import("std");
const Build = std.Build;
const Step = Build.Step;

/// One program `check` may invoke, and why a step needing it belongs in the main
/// gate instead of a sibling.
pub const Runtime = struct {
    /// The command name as written, after any plain environment assignments.
    program: []const u8,
    /// For an interpreter, the scripts it may run under `check`. Arguments are
    /// unconstrained only when both this and `modules` are empty.
    scripts: []const []const u8 = &.{},
    /// Modules accepted after `-m`. Kept separate from scripts so declaring
    /// one standard-library compiler does not admit every Python module.
    modules: []const []const u8 = &.{},
    /// The member that needs it, the reason it is not a sibling, and any runtime
    /// a script or module reaches that this gate cannot see.
    why: []const u8,
};

/// What `check`'s graph says about the runtimes it declares.
pub const Verdict = struct {
    /// The declaration verdict as a step: a failing step naming every member
    /// that reaches for an undeclared program, or a satisfied marker.
    declaration: *Step,
    /// Rows in `runtimes` this graph will actually run. The caller hands these
    /// to the presence checker, so a row nobody reaches asks nothing of anyone.
    reached: []const usize,
};

/// Read the graph rooted at `root` against `runtimes`.
///
/// `root` is `check` itself. Zig 0.17 removed make-time custom build steps, so
/// callers create this after wiring the full gate; the walk then sees exactly
/// what `check` would run. Reaching itself is harmless: a top-level step runs
/// no program.
pub fn create(b: *Build, root: *Step, runtimes: []const Runtime) Verdict {
    const gpa = b.allocator;
    const findings = checkGraph(gpa, root, runtimes, b.graph.zig_exe, b.root.toString(gpa) catch @panic("OOM")) catch @panic("OOM");
    if (findings.undeclared) |text|
        return .{ .declaration = &b.addFail(text).step, .reached = findings.reached };

    const ok = b.addWriteFiles();
    _ = ok.add("toolchain-check.ok", "");
    return .{ .declaration = &ok.step, .reached = findings.reached };
}

/// Peel only `env NAME=value ... command`, including build-resolved paths.
/// Unsupported options stay visible as `env` and require their own declaration;
/// an assignment wrapper never grants permission to run its command.
fn commandArgs(args: []const Step.Run.Arg) []const Step.Run.Arg {
    if (args.len == 0) return args;
    switch (args[0]) {
        .bytes => |bytes| if (!std.mem.eql(u8, bytes, "env")) return args,
        else => return args,
    }
    for (args[1..], 1..) |arg, index| {
        const prefix = switch (arg) {
            .bytes => |bytes| bytes,
            .lazy_path, .decorated_directory => |path| path.prefix,
            else => return args[index..],
        };
        const equals = std.mem.indexOfScalar(u8, prefix, '=') orelse {
            if (std.mem.startsWith(u8, prefix, "-")) return args;
            return args[index..];
        };
        if (equals == 0) return args;
        for (prefix[0..equals], 0..) |char, position| {
            if (char != '_' and !std.ascii.isAlphabetic(char) and
                !(position > 0 and std.ascii.isDigit(char))) return args;
        }
    }
    return args; // No command was supplied.
}

/// The program a step invokes, or null when it runs a Zig-built artifact, the
/// Zig compiler itself, or no program at all.
///
/// `addRunArtifact` puts the compiled binary in the first argument, so the
/// `.artifact` arm needs no declaration. `addSystemCommand` puts the program
/// name there as bytes, which is the case that costs something on PATH — except
/// when that name is the running compiler, which is on PATH by construction.
fn programOf(step: *Step, zig_exe: []const u8) ?[]const u8 {
    const run = step.cast(Step.Run) orelse return null;
    const args = commandArgs(run.argv.items);
    if (args.len == 0) return null;
    const program = switch (args[0]) {
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
    const args = commandArgs(run.argv.items);
    if (args.len < 2) return null;
    return switch (args[1]) {
        .bytes => |bytes| bytes,
        else => null,
    };
}

fn moduleOf(step: *Step) ?[]const u8 {
    const run = step.cast(Step.Run) orelse return null;
    const args = commandArgs(run.argv.items);
    if (args.len < 3) return null;
    const marker = switch (args[1]) {
        .bytes => |bytes| bytes,
        else => return null,
    };
    if (!std.mem.eql(u8, marker, "-m")) return null;
    return switch (args[2]) {
        .bytes => |bytes| bytes,
        else => null,
    };
}

/// A script named the way `check_runtimes` names it: relative to the repository.
///
/// A call site is free to write the path absolutely, and one has to — the
/// deadline wrapper runs from whichever directory its step works in, so only an
/// absolute path finds it. That is a spelling, not a different script, and the
/// declaration is about which script may run. Comparing spellings instead made
/// a correct call site look undeclared.
fn repoRelative(root: []const u8, script: []const u8) []const u8 {
    if (!std.fs.path.isAbsolute(script)) return script;
    if (!std.mem.startsWith(u8, script, root)) return script;
    const rest = script[root.len..];
    return if (rest.len > 0 and rest[0] == std.fs.path.sep) rest[1..] else rest;
}

/// The row declaring `program`, or null when `check` declares no such runtime.
fn declaredIndex(runtimes: []const Runtime, program: []const u8) ?usize {
    for (runtimes, 0..) |runtime, index| {
        if (std.mem.eql(u8, runtime.program, program)) return index;
    }
    return null;
}

/// How `step` breaks its declaration, or null when the invocation is permitted.
/// `declared` is the row `declaredIndex` found, so the walk resolves the row
/// once and both the declaration report and the presence report read the same
/// answer.
fn violation(
    gpa: std.mem.Allocator,
    declared: ?Runtime,
    step: *Step,
    program: []const u8,
    root_path: []const u8,
) !?[]const u8 {
    if (declared) |runtime| {
        if (moduleOf(step)) |module| {
            for (runtime.modules) |allowed| {
                if (std.mem.eql(u8, allowed, module)) return null;
            }
            return try std.fmt.allocPrint(
                gpa,
                "step '{s}' runs '{s} -m {s}', which is not among the modules declared for '{s}'",
                .{ step.name, program, module, program },
            );
        }
        if (runtime.scripts.len == 0 and runtime.modules.len == 0) return null;
        const written = scriptOf(step) orelse return try std.fmt.allocPrint(
            gpa,
            "step '{s}' runs '{s}' with no named script, and '{s}' is declared for named scripts only",
            .{ step.name, program, program },
        );
        const script = repoRelative(root_path, written);
        for (runtime.scripts) |allowed| {
            if (std.mem.eql(u8, allowed, script)) return null;
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

/// What one walk of the `check` graph found.
const Findings = struct {
    /// Steps invoking a program `check_runtimes` does not permit, or null when
    /// every invocation is declared.
    undeclared: ?[]const u8,
    /// Rows in `runtimes` this graph will actually run, deduplicated. The
    /// presence report reads only these, so a row nobody reaches cannot ask a
    /// contributor to install anything.
    reached: []const usize,
};

fn checkGraph(
    gpa: std.mem.Allocator,
    root: *Step,
    runtimes: []const Runtime,
    zig_exe: []const u8,
    root_path: []const u8,
) !Findings {
    var seen: std.AutoHashMapUnmanaged(*Step, void) = .empty;
    defer seen.deinit(gpa);
    var pending: std.ArrayList(*Step) = .empty;
    defer pending.deinit(gpa);
    var offenders: std.ArrayList([]const u8) = .empty;
    defer {
        for (offenders.items) |line| gpa.free(line);
        offenders.deinit(gpa);
    }
    // Declaration order, not walk order, so the report reads like the table.
    var reached: std.ArrayList(usize) = .empty;
    errdefer reached.deinit(gpa);

    try pending.append(gpa, root);
    while (pending.pop()) |current| {
        if ((try seen.getOrPut(gpa, current)).found_existing) continue;
        if (programOf(current, zig_exe)) |program| {
            const index = declaredIndex(runtimes, program);
            if (index) |found| {
                if (std.mem.indexOfScalar(usize, reached.items, found) == null)
                    try reached.append(gpa, found);
            }
            if (try violation(gpa, if (index) |found| runtimes[found] else null, current, program, root_path)) |line|
                try offenders.append(gpa, line);
        }
        for (current.dependencies.items) |dependency| try pending.append(gpa, dependency);
    }

    std.mem.sort(usize, reached.items, {}, std.sort.asc(usize));
    const reached_rows = try reached.toOwnedSlice(gpa);
    errdefer gpa.free(reached_rows);

    if (offenders.items.len == 0) return .{ .undeclared = null, .reached = reached_rows };

    var report: std.ArrayList(u8) = .empty;
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
        \\`ci/gates.sh`, or add a row to `check_runtimes` in tools/build/toolchain.zig saying
        \\which member needs the program and why it belongs in the gate everyone
        \\runs. A new row raises what a contributor must install, so the cli rule
        \\names the set too.
        ,
    );
    return .{ .undeclared = try report.toOwnedSlice(gpa), .reached = reached_rows };
}

test "environment assignments preserve the wrapped program and interpreter arguments" {
    const args = [_]Step.Run.Arg{
        .{ .bytes = "env" },
        .{ .bytes = "MODE=check" },
        .{ .decorated_directory = .{ .prefix = "GLOWCAP_LIB_DIR=", .suffix = "", .make_absolute = true, .lazy_path = .{ .relative = .{ .base = .install_lib } } } },
        .{ .bytes = "python3" },
        .{ .bytes = "-m" },
        .{ .bytes = "py_compile" },
    };
    const command = commandArgs(&args);
    try std.testing.expectEqual(@as(usize, 3), command.len);
    try std.testing.expectEqualStrings("python3", command[0].bytes);
    try std.testing.expectEqualStrings("-m", command[1].bytes);
    try std.testing.expectEqualStrings("py_compile", command[2].bytes);
    const undeclared = [_]Step.Run.Arg{ .{ .bytes = "env" }, .{ .bytes = "VALUE=yes" }, .{ .bytes = "undeclared-runtime" } };
    try std.testing.expectEqualStrings("undeclared-runtime", commandArgs(&undeclared)[0].bytes);
}

test "unsupported env options and missing commands are not transparent" {
    for ([_][]const u8{ "-S", "--split-string=sh", "=value", "1BAD=value" }) |option| {
        const args = [_]Step.Run.Arg{ .{ .bytes = "env" }, .{ .bytes = option }, .{ .bytes = "cargo" } };
        try std.testing.expectEqualStrings("env", commandArgs(&args)[0].bytes);
    }
    const missing = [_]Step.Run.Arg{ .{ .bytes = "env" }, .{ .bytes = "MODE=check" } };
    try std.testing.expectEqualStrings("env", commandArgs(&missing)[0].bytes);
}

test "the reached set is the declared rows the graph will actually run" {
    const runtimes = [_]Runtime{
        .{ .program = "cargo", .why = "first" },
        .{ .program = "raco", .why = "second" },
    };
    try std.testing.expectEqual(@as(?usize, 0), declaredIndex(&runtimes, "cargo"));
    try std.testing.expectEqual(@as(?usize, 1), declaredIndex(&runtimes, "raco"));
    try std.testing.expectEqual(@as(?usize, null), declaredIndex(&runtimes, "deno"));
}
