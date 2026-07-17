//! `pancake griddle` — simulator / timeline family (placeholder).
//!
//! Runtime is not implemented. This node locks the brand: CapTP stays under
//! `pancake ocapn` / `repl`; sim/timeline will live here when built. See
//! docs/planning/observability-family.md.
const Ctx = @import("../ctx.zig").Ctx;
const Command = @import("../cmd/types.zig").Command;
const Parsed = @import("../cmd/types.zig").Parsed;
const exit_codes = @import("../exit_codes.zig");
const argv = @import("../argv.zig");

const status_text =
    \\pancake griddle: simulator / timeline family — not implemented yet.
    \\
    \\When built, this subtree will run deterministic network simulation and
    \\emit topology timelines for ocapnviz (native power path; optional WASM
    \\demo path). CapTP verbs stay under `pancake ocapn` and `pancake repl`.
    \\
    \\See docs/planning/observability-family.md and docs/cli.md.
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
        \\  pancake griddle status
        \\  pancake griddle help
        \\
        \\Deterministic network simulator and timeline tools (placeholder).
        \\Runtime not implemented — CapTP stays under ocapn / repl.
        \\
    );
    return exit_codes.ok;
}

const griddle_children = [_]Command{
    .{
        .name = "status",
        .short_help = "Report griddle implementation status",
        .run = runStatus,
    },
    .{
        .name = "help",
        .short_help = "Help for pancake griddle",
        .run = runHelp,
    },
};

pub const command: Command = .{
    .name = "griddle",
    .short_help = "Simulator / timeline family (placeholder)",
    .children = &griddle_children,
};
