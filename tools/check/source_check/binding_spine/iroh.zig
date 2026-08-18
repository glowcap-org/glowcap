//! The iroh binding aggregates: loop-scale convergence across the four
//! bindings, and every per-binding client row present in each aggregate.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;
const fileContains = util.fileContains;
const containsAsSymbol = util.containsAsSymbol;
const extractBraceBlock = util.extractBraceBlock;

/// Apex for ADR-0076 iroh convergence: CapTP fan-out must not re-grow inside
/// the iroh resident. The resident supplies the netlayer + completion
/// `Backend` only; serving is `driver.Bridge` + Host. A reintroduced
/// `LoopHost` / `driver_core` / `actors` import fails the gate instead of
/// shipping a second diverging serve spine.
pub fn checkIrohLoopConvergence(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const path = "src/net/transport/iroh.zig";
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for iroh-loop-convergence check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    const forbidden = [_]struct { needle: []const u8, reason: []const u8 }{
        .{ .needle = "LoopHost", .reason = "CapTP scale must stay on `driver.Bridge` + Host, not a resident-local serve loop" },
        .{ .needle = "@import(\"driver_core\")", .reason = "the iroh resident must not import the serve core; Bridge owns CapTP" },
        .{ .needle = "@import(\"actors\")", .reason = "the iroh resident must not mint vats; Bridge + Host own CapTP" },
    };
    for (forbidden) |entry| {
        if (std.mem.indexOf(u8, contents, entry.needle) != null) {
            try appendViolation(gpa, violations, "{s}: forbidden `{s}` — {s}", .{ path, entry.needle, entry.reason });
        }
    }
    if (std.mem.indexOf(u8, contents, "pub const Backend") == null) {
        try appendViolation(gpa, violations, "{s}: missing `pub const Backend` — iroh scale must expose a completion Backend (ADR-0057/0076)", .{path});
    }
}

/// The iroh `BindingClientRow` tables (`iroh_loop_clients`,
/// `iroh_handoff_clients`, `iroh_reach_clients`) each feed a `bindings-iroh-*`
/// aggregate. A binding silently missing from one of these tables would still
/// build — the aggregate degrades to whichever rows remain — so the gap is
/// invisible to `zig build check` unless something demands every step name
/// explicitly. This holds the closed binding set (deno/python/rust/racket) the
/// sibling `iroh_redeem_clients` and `keyed_tcp_restart_clients` tables already
/// carry.
pub fn checkIrohBindingAggregatesComplete(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const path = "tools/build/binding_families.zig";
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for iroh-binding-aggregate check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    const families = [_]struct {
        marker: []const u8,
        steps: []const []const u8,
    }{
        .{
            .marker = "iroh_loop_clients = [_]BindingClientRow{",
            .steps = &.{ "deno-iroh-loop", "python-iroh-loop", "rust-iroh-loop", "racket-iroh-loop" },
        },
        .{
            .marker = "iroh_handoff_clients = [_]BindingClientRow{",
            .steps = &.{ "deno-iroh-handoff", "python-iroh-handoff", "rust-iroh-handoff", "racket-iroh-handoff" },
        },
        .{
            .marker = "iroh_reach_clients = [_]BindingClientRow{",
            .steps = &.{ "deno-iroh-reachability", "python-iroh-reachability", "rust-iroh-reachability", "racket-iroh-reachability" },
        },
    };

    for (families) |family| {
        const block = extractBraceBlock(contents, family.marker) orelse {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — cannot find the iroh binding-client row table", .{ path, family.marker });
            continue;
        };
        for (family.steps) |step| {
            var buf: [64]u8 = undefined;
            const needle = std.fmt.bufPrint(&buf, "\"{s}\"", .{step}) catch continue;
            if (std.mem.indexOf(u8, block, needle) == null) {
                try appendViolation(gpa, violations, "{s}: `{s}` is missing a `{s}` row — every iroh binding aggregate must carry deno, python, rust, and racket", .{ path, family.marker, step });
            }
        }
    }
}
