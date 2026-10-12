//! Declared runtime checker for the in-tree build gates.
//!
//! `tools/build/toolchain.zig` owns the runtime inventory. This module walks a
//! completed gate graph and rejects programs outside that inventory. An
//! interpreter may run only the scripts or modules its row names.
//!
//! The walk recognizes plain `env NAME=value ... command` wrappers. It cannot
//! see programs launched from inside a declared script, so each interpreter
//! row must name that hidden floor in its reason. Presence and capability
//! probes are wired separately by the owning gate. They fail before the first
//! member that needs a stale devcontainer toolchain.

const std = @import("std");
const Build = std.Build;
const Step = Build.Step;

/// One program an in-tree gate may invoke, and why that gate needs it.
pub const Runtime = struct {
    /// The command name as written, after any plain environment assignments.
    program: []const u8,
    /// For an interpreter, the scripts it may run under the gate. Arguments are
    /// unconstrained only when both this and `modules` are empty.
    scripts: []const []const u8 = &.{},
    /// Modules accepted after `-m`. Kept separate from scripts so declaring
    /// one standard-library compiler does not admit every Python module.
    modules: []const []const u8 = &.{},
    /// The member that needs it, the reason it is not a sibling, and any runtime
    /// a script or module reaches that this gate cannot see.
    why: []const u8,
};

/// What one gate graph says about the runtimes it declares.
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
/// Callers create this after wiring the full gate, so the walk sees exactly
/// what that gate would run. Reaching the root itself is harmless because a
/// top-level step runs no program.
pub fn create(b: *Build, root: *Step, runtimes: []const Runtime) Verdict {
    const gpa = b.allocator;
    const findings = checkGraph(gpa, root, root.name, runtimes, b.graph.zig_exe, b.root.toString(gpa) catch @panic("OOM")) catch @panic("OOM");
    if (findings.undeclared) |text|
        return .{ .declaration = &b.addFail(text).step, .reached = findings.reached };

    const ok = b.addWriteFiles();
    _ = ok.add("toolchain-check.ok", "");
    return .{ .declaration = &ok.step, .reached = findings.reached };
}

/// Peel only `env NAME=value ... command`, including build-resolved paths.
/// Unsupported options stay visible as `env` and require their own declaration,
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
/// name there as bytes, which is the case that costs something on PATH, except
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

/// A script named the way `in_tree_runtimes` names it: relative to the repository.
///
/// A call site is free to write the path absolutely, and one has to. The
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

/// The row declaring `program`, or null when the gate declares no such runtime.
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
    gate_name: []const u8,
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
        "step '{s}' runs '{s}', which `{s}` does not declare",
        .{ step.name, program, gate_name },
    );
}

/// What one gate-graph walk found.
const Findings = struct {
    /// Steps invoking a program `in_tree_runtimes` does not permit, or null when
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
    gate_name: []const u8,
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
            if (try violation(gpa, if (index) |found| runtimes[found] else null, current, program, root_path, gate_name)) |line|
                try offenders.append(gpa, line);
        }
        for (current.dependencies.items) |dependency| try pending.append(gpa, dependency);
    }

    std.mem.sort(usize, reached.items, {}, std.sort.asc(usize));
    const reached_rows = try reached.toOwnedSlice(gpa);
    errdefer gpa.free(reached_rows);

    if (offenders.items.len == 0) return .{ .undeclared = null, .reached = reached_rows };

    var report: std.ArrayList(u8) = .empty;
    try report.print(gpa, "`zig build {s}` may only invoke the runtimes it declares, but:\n", .{gate_name});
    for (offenders.items) |line| {
        try report.appendSlice(gpa, "  - ");
        try report.appendSlice(gpa, line);
        try report.append(gpa, '\n');
    }
    try report.appendSlice(
        gpa,
        \\
        \\Either give the step its own `zig build` step and sequence it from
        \\`ci/gates.sh`, or add a row to `in_tree_runtimes` in tools/build/toolchain.zig saying
        \\which member needs the program and why it belongs in this gate. A new
        \\row raises what a contributor must install, so its reason is reviewed.
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
