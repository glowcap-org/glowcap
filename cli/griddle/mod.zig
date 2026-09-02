//! `glowcap griddle` — the simulator / timeline family.
//!
//! `run` drives a whole CapTP conversation under a seeded schedule and prints
//! its timeline as NDJSON: the same seed replays byte for byte, and a
//! different seed interleaves the links differently while reaching the same
//! outcome. The simulator itself is `sim.zig`; this node owns the argv shape
//! and locks the brand — CapTP verbs stay under `glowcap ocapn` / `repl`.
//! The viewer for this timeline is `apps/ocapnviz/`, which imports a run
//! through its `scripts/griddle-import.ts`.
const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const Command = @import("../cmd/types.zig").Command;
const Parsed = @import("../cmd/types.zig").Parsed;
const exit_codes = @import("../exit_codes.zig");
const argv = @import("../argv.zig");
const sim = @import("sim.zig");

const status_text =
    \\glowcap griddle: simulator / timeline family.
    \\
    \\  run   deterministic CapTP simulation, timeline as NDJSON on stdout
    \\
    \\Pipe a run into apps/ocapnviz to watch it. CapTP verbs stay under
    \\`glowcap ocapn` and `glowcap repl`.
    \\
    \\See docs/cli.md.
    \\
;

fn runStatus(ctx: *Ctx, parsed: *Parsed) anyerror!u8 {
    _ = parsed;
    try argv.writeStdout(ctx.io, status_text);
    return exit_codes.ok;
}

fn runHelp(ctx: *Ctx, parsed: *Parsed) anyerror!u8 {
    _ = parsed;
    try argv.writeStdout(ctx.io,
        \\Usage:
        \\  glowcap griddle run [--seed N] [--scenario NAME]
        \\                      [--latency] [--partition-at TICK]
        \\  glowcap griddle status
        \\  glowcap griddle help
        \\
        \\Deterministic CapTP simulation. `run` prints a timeline as NDJSON,
        \\one event per line; the same seed replays exactly.
        \\
        \\Scenarios:
    );
    try argv.writeStdout(ctx.io, " " ++ sim.scenario_args);
    try argv.writeStdout(ctx.io,
        \\
        \\
        \\A reliable transport does not drop or reorder bytes, so neither does
        \\this simulator. What it models is what a real network does to a
        \\reliable link: --latency delays one, --partition-at cuts one.
        \\
    );
    return exit_codes.ok;
}

const run_flags = [_]@import("../cmd/types.zig").Flag{
    .{ .long = "seed", .help = "Schedule seed (default 0); the same seed replays exactly", .kind = .string_flag },
    .{ .long = "scenario", .help = "Which conversation to run (default bootstrap-fetch)", .kind = .string_flag },
    .{ .long = "latency", .help = "Give each link its own seeded latency" },
    .{ .long = "partition-at", .help = "Cut every link at this tick", .kind = .string_flag },
};

/// Run one simulated conversation and print its timeline. Deterministic in the
/// seed, so a run that shows something interesting can be handed to someone
/// else as a number.
fn runRun(ctx: *Ctx, parsed: *Parsed) anyerror!u8 {
    const seed_text = parsed.flagString("seed") orelse "0";
    const seed = std.fmt.parseInt(u64, seed_text, 10) catch {
        ctx.logErr("--seed wants a number, got {s}", .{seed_text});
        return exit_codes.usage;
    };
    const scenario_text = parsed.flagString("scenario") orelse "bootstrap-fetch";
    const scenario = sim.Scenario.fromArg(scenario_text) orelse {
        ctx.logErr("unknown --scenario {s} (want {s})", .{ scenario_text, sim.scenario_args });
        return exit_codes.usage;
    };
    var weather = sim.Weather{ .latency = parsed.flagBool("latency") };
    if (parsed.flagString("partition-at")) |at_text| {
        weather.partition_at = std.fmt.parseInt(u64, at_text, 10) catch {
            ctx.logErr("--partition-at wants a tick number, got {s}", .{at_text});
            return exit_codes.usage;
        };
    }
    var timeline = sim.run(ctx.gpa, scenario, seed, .syrup, weather) catch |err| {
        ctx.logErr("griddle run: {s}", .{@errorName(err)});
        return exit_codes.internal;
    };
    defer timeline.deinit();
    try ctx.writeResult(timeline.bytes());
    return exit_codes.ok;
}

const griddle_children = [_]Command{
    .{
        .name = "run",
        .short_help = "Run a deterministic simulation, timeline as NDJSON",
        .flags = &run_flags,
        .run = runRun,
    },
    .{
        .name = "status",
        .short_help = "Report griddle implementation status",
        .run = runStatus,
    },
    .{
        .name = "help",
        .short_help = "Help for glowcap griddle",
        .run = runHelp,
    },
};

pub const command: Command = .{
    .name = "griddle",
    .short_help = "Deterministic CapTP simulator and timeline family",
    .children = &griddle_children,
};
