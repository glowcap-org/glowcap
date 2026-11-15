//! The iroh binding aggregates: loop-scale convergence across the four
//! bindings, and every per-binding client row present in each aggregate.

const std = @import("std");
const text_match = @import("../text_match.zig");
const violation_log = @import("../violation_log.zig");

const appendViolation = violation_log.appendViolation;
const expectFileContains = text_match.expectFileContains;
const fileContains = text_match.fileContains;
const containsAsSymbol = text_match.containsAsSymbol;
const extractBraceBlock = text_match.extractBraceBlock;

/// Apex for ADR-0018 iroh convergence: CapTP fan-out must not re-grow inside
/// the iroh resident. The resident supplies the netlayer + completion
/// `Backend` only, serving is `driver.HostRuntime` + Host. A reintroduced
/// `LoopHost` / `driver_core` / `actors` import fails the gate instead of
/// shipping a second diverging serve spine.
pub fn checkIrohLoopConvergence(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const forbidden = [_]struct { needle: []const u8, reason: []const u8 }{
        .{ .needle = "LoopHost", .reason = "CapTP scale must stay on `driver.HostRuntime` + Host, not a resident-local serve loop" },
        .{ .needle = "@import(\"driver_core\")", .reason = "the iroh resident must not import the serve core; HostRuntime owns CapTP" },
        .{ .needle = "@import(\"actors\")", .reason = "the iroh resident must not mint vats; HostRuntime + Host own CapTP" },
    };
    const paths = [_][]const u8{
        "src/net/transport/iroh.zig",
        "src/net/transport/iroh/backend.zig",
        "src/net/transport/iroh/locators.zig",
        "src/net/transport/iroh/resident.zig",
        "src/net/transport/iroh/resolver.zig",
        "src/net/transport/iroh/sidecar.zig",
    };
    for (paths) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for iroh-loop-convergence check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (forbidden) |entry| {
            if (std.mem.find(u8, contents, entry.needle) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — {s}", .{ path, entry.needle, entry.reason });
            }
        }
    }
    try expectFileContains(io, gpa, root, violations, "src/net/transport/iroh.zig", &.{"pub const Backend"});
}

/// The iroh `BindingClientRow` tables (`iroh_loop_clients`,
/// `iroh_handoff_clients`, `iroh_reach_clients`) each feed a `bindings-iroh-*`
/// aggregate. A binding silently missing from one of these tables would still
/// build, the aggregate degrades to whichever rows remain, so the gap is
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
    const path = "tools/build/binding_families/iroh.zig";
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
            const needle = std.mem.print(&buf, "\"{s}\"", .{step}) catch {
                try appendViolation(gpa, violations, "iroh family step `{s}` overflows the needle buffer; grow it", .{step});
                continue;
            };
            if (std.mem.find(u8, block, needle) == null) {
                try appendViolation(gpa, violations, "{s}: `{s}` is missing a `{s}` row — every iroh binding aggregate must carry deno, python, rust, and racket", .{ path, family.marker, step });
            }
        }
    }
}

/// The sidecar header states the reachability postures, the readiness bits, the
/// would-block sentinel, and the dial classification as `#define`s. Zig owns those values and
/// `gen-iroh-sidecar-constants` mirrors them into `constants_gen.rs`, which its
/// own check holds fresh. This holds the header's defines equal to that mirror,
/// in both directions, so a number the header states cannot drift from the
/// Zig declaration it names.
pub fn checkIrohSidecarHeaderConstants(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const rust_path = "transports/iroh/src/constants_gen.rs";
    const header_path = "transports/iroh/include/glowcap_iroh_sidecar.h";
    const rust = root.readFileAlloc(io, rust_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for the sidecar header constants check with {s}", .{ rust_path, @errorName(err) });
        return;
    };
    defer gpa.free(rust);
    const header = root.readFileAlloc(io, header_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for the sidecar header constants check with {s}", .{ header_path, @errorName(err) });
        return;
    };
    defer gpa.free(header);

    const const_prefix = "pub(crate) const ";
    var rows = std.mem.splitScalar(u8, rust, '\n');
    while (rows.next()) |row| {
        if (!std.mem.startsWith(u8, row, const_prefix)) continue;
        const colon = std.mem.find(u8, row, ": ") orelse continue;
        const equals = std.mem.find(u8, row, " = ") orelse continue;
        const name = row[const_prefix.len..colon];
        if (!isSidecarHeaderName(name)) continue;
        const rust_type = row[colon + 2 .. equals];
        const value = std.mem.trimEnd(u8, row[equals + 3 ..], ";");
        const expected = if (std.mem.eql(u8, rust_type, "i32"))
            try gpa.print("#define GLOWCAP_IROH_{s} {s}", .{ name, value })
        else if (std.mem.eql(u8, rust_type, "isize"))
            try gpa.print("#define GLOWCAP_IROH_{s} ((intptr_t){s})", .{ name, value })
        else
            try gpa.print("#define GLOWCAP_IROH_{s} {s}u", .{ name, value });
        defer gpa.free(expected);
        const define = expected[0 .. "#define GLOWCAP_IROH_".len + name.len];
        var stated: usize = 0;
        var header_lines = std.mem.splitScalar(u8, header, '\n');
        while (header_lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, define)) continue;
            if (line.len > define.len and line[define.len] != ' ') continue;
            stated += 1;
            if (!std.mem.eql(u8, line, expected)) {
                try appendViolation(gpa, violations, "{s}: `{s}` must read `{s}`, the value {s} holds (zig build gen-iroh-sidecar-constants owns it)", .{ header_path, line, expected, rust_path });
            }
        }
        if (stated != 1) {
            try appendViolation(gpa, violations, "{s}: {d} lines define GLOWCAP_IROH_{s}, and exactly one must read `{s}`", .{ header_path, stated, name, expected });
        }
    }

    const define_prefix = "#define GLOWCAP_IROH_";
    var lines = std.mem.splitScalar(u8, header, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, define_prefix)) continue;
        const rest = line[define_prefix.len..];
        const name = rest[0 .. std.mem.findScalar(u8, rest, ' ') orelse rest.len];
        if (!isSidecarHeaderName(name)) continue;
        const needle = try gpa.print("{s}{s}: ", .{ const_prefix, name });
        defer gpa.free(needle);
        if (std.mem.find(u8, rust, needle) == null) {
            try appendViolation(gpa, violations, "{s}: `{s}` has no row in {s}, so no Zig declaration owns it", .{ header_path, std.mem.trimEnd(u8, line, " "), rust_path });
        }
    }
}

/// The header names the generated mirror covers: the reachability postures, the
/// would-block sentinel, the readiness bits, and the dial classification with
/// its text bound.
fn isSidecarHeaderName(name: []const u8) bool {
    return std.mem.eql(u8, name, "WOULD_BLOCK") or
        std.mem.startsWith(u8, name, "REACH_") or
        std.mem.startsWith(u8, name, "EV_") or
        std.mem.startsWith(u8, name, "DIAL_");
}
