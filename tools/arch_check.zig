//! Architecture gate — walks `src/**/*.zig`, parses each file's `@import("…")`
//! edges, and asserts the layer dependency DAG plus the no-`std.Io`-in-core ban.
//! Wired as the `zig build arch-check` step and into `zig build check`.
//!
//! A simplified view of the core DAG (the full enforced edge set lives in the
//! `allowedTargets` table below, and the authoritative layer ownership is
//! `.agents/rules/architecture.md` § Layer Ownership — which also covers
//! `actors` above `engine`, `net_adapter` as the one `std.Io` adapter over
//! `engine`, and `driver` composing `actors` + `net_adapter`):
//!
//! ```text
//! foundation ← model ← codec ← engine → (c_abi | conformance)
//!                          ↖ session ↗
//! ```
//!
//! The load-bearing edges, beyond "lower layers don't import higher ones":
//!   * `session` is codec-neutral — it MUST NOT import `codec` or `engine`
//!     (authority lives in the session, never reached through a codec).
//!   * `codec` parses/renders only — it MUST NOT import `session` or `engine`.
//!   * `model` is pure semantic data — it imports nothing above `foundation`.
//!   * core protocol modules (foundation/model/codec/session/engine) carry no
//!     `std.Io` — the sync, no-I/O core boundary (Invariant 13 analog).
//!
//! A new top-level `src/<dir>/` with no rule here fails the gate loudly: adding
//! a module is a deliberate act that must declare its allowed dependencies.

const std = @import("std");
const Build = std.Build;
const Step = Build.Step;

/// Create the `arch-check` build step.
pub fn create(b: *Build) *Step {
    const wrapper = b.allocator.create(ArchCheck) catch @panic("OOM");
    wrapper.* = .{ .step = Step.init(.{
        .id = .custom,
        .name = "arch-check",
        .owner = b,
        .makeFn = make,
    }) };
    return &wrapper.step;
}

const ArchCheck = struct {
    step: Step,
};

/// Layers that must stay free of `std.Io` (the sync, no-I/O core). `actors`
/// drives the engine as a pure turn loop — it owns no I/O, so it joins the ban.
const core_layers = [_][]const u8{ "foundation", "model", "codec", "session", "engine", "actors" };

/// One layer's allowed `@import` target layers (its own layer is always allowed
/// — intra-layer imports). `null` for an unrecognized layer means "no rule;
/// fail loudly so a new module declares its dependencies."
fn allowedTargets(layer: []const u8) ?[]const []const u8 {
    const Rule = struct { layer: []const u8, targets: []const []const u8 };
    const rules = [_]Rule{
        .{ .layer = "foundation", .targets = &.{"foundation"} },
        .{ .layer = "model", .targets = &.{ "foundation", "model" } },
        .{ .layer = "codec", .targets = &.{ "foundation", "model", "codec" } },
        .{ .layer = "session", .targets = &.{ "foundation", "model", "session" } },
        .{ .layer = "engine", .targets = &.{ "foundation", "model", "codec", "session", "engine" } },
        // `c_abi` also re-exposes the byte-stream adapter as blocking endpoint
        // handles (the host-driven netlayer seam), so it may import
        // `net_adapter` (and the `model` codec id it threads through).
        .{ .layer = "c_abi", .targets = &.{ "foundation", "model", "engine", "net_adapter", "c_abi" } },
        .{ .layer = "conformance", .targets = &.{ "foundation", "model", "codec", "session", "engine", "conformance" } },
        // The actor layer sits above the engine: a sync, no-I/O turn loop that
        // drives a `engine.Peer` and binds local actors to its exports. It adds
        // no CapTP semantics the engine lacks.
        .{ .layer = "actors", .targets = &.{ "foundation", "model", "engine", "actors" } },
        // The byte-stream adapter is NOT a core layer (absent from `core_layers`
        // above), so it is the one place `std.Io` is allowed. It drives the
        // engine over a stream; it never reaches below `engine`'s authority.
        .{ .layer = "net_adapter", .targets = &.{ "foundation", "model", "codec", "session", "engine", "net_adapter" } },
        // The driver sits above BOTH the actor turn loop and the I/O adapter: it
        // binds an `actors.Vat` to a live `net_adapter.Connection`, so it is the
        // one place that may import both, and it touches `std.Io` (so it is not a
        // core layer). It adds no CapTP semantics — it only composes.
        .{ .layer = "driver", .targets = &.{ "foundation", "model", "engine", "actors", "net_adapter", "driver" } },
        // The public aggregator at `src/root.zig` re-exports every layer.
        .{ .layer = "<root>", .targets = &.{ "foundation", "model", "codec", "session", "engine", "c_abi", "conformance", "net_adapter", "actors", "driver" } },
    };
    for (rules) |rule| {
        if (std.mem.eql(u8, rule.layer, layer)) return rule.targets;
    }
    return null;
}

fn make(step: *Step, options: Step.MakeOptions) anyerror!void {
    const b = step.owner;
    const io = b.graph.io;
    const gpa = options.gpa;

    var src_dir = try b.build_root.handle.openDir(io, "src", .{ .iterate = true });
    defer src_dir.close(io);

    var violations: std.ArrayList([]const u8) = .empty;
    defer violations.deinit(gpa);

    var walker = try src_dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const contents = try src_dir.readFileAlloc(io, entry.path, gpa, .limited(4 << 20));
        defer gpa.free(contents);

        // OS path separator is '/' on the platforms this gate runs.
        const file_path = entry.path;
        const layer = layerOf(file_path);

        const targets = allowedTargets(layer) orelse {
            try violations.append(gpa, try std.fmt.allocPrint(
                gpa,
                "{s}: top-level module '{s}/' has no arch rule — add one to tools/arch_check.zig",
                .{ file_path, layer },
            ));
            continue;
        };

        // No-std.Io-in-core ban.
        if (isCoreLayer(layer) and std.mem.indexOf(u8, contents, "std.Io") != null) {
            try violations.append(gpa, try std.fmt.allocPrint(
                gpa,
                "{s}: core layer '{s}' references std.Io — the core stays sync and no-I/O",
                .{ file_path, layer },
            ));
        }

        // Import-edge DAG.
        var rest = contents;
        while (std.mem.indexOf(u8, rest, "@import(\"")) |start| {
            const after = rest[start + "@import(\"".len ..];
            const end = std.mem.indexOfScalar(u8, after, '"') orelse break;
            const target = after[0..end];
            rest = after[end..];

            if (!std.mem.endsWith(u8, target, ".zig")) continue; // std / package import
            const target_layer = resolveTargetLayer(file_path, target) orelse continue;

            if (!containsLayer(targets, target_layer)) {
                try violations.append(gpa, try std.fmt.allocPrint(
                    gpa,
                    "{s}: layer '{s}' may not import layer '{s}' (via @import(\"{s}\"))",
                    .{ file_path, layer, target_layer, target },
                ));
            }
        }
    }

    if (violations.items.len != 0) {
        for (violations.items) |msg| std.debug.print("arch-check: {s}\n", .{msg});
        return step.fail("arch-check found {d} layering violation(s)", .{violations.items.len});
    }
}

/// The layer a source file belongs to: the first path component, or `<root>`
/// for a file directly under `src/` (e.g. `root.zig`).
fn layerOf(file_path: []const u8) []const u8 {
    const sep = std.mem.indexOfScalar(u8, file_path, '/') orelse return "<root>";
    return file_path[0..sep];
}

fn isCoreLayer(layer: []const u8) bool {
    for (core_layers) |core| {
        if (std.mem.eql(u8, core, layer)) return true;
    }
    return false;
}

fn containsLayer(targets: []const []const u8, layer: []const u8) bool {
    for (targets) |t| {
        if (std.mem.eql(u8, t, layer)) return true;
    }
    return false;
}

/// Resolve an `@import` target (relative to the importing file's directory) to
/// the layer it lands in, or `null` if it escapes `src/` (which never happens
/// for the core tree, so it is simply ignored).
fn resolveTargetLayer(file_path: []const u8, target: []const u8) ?[]const u8 {
    // Component stack of the file's directory, then walked by the target path.
    var stack: [32][]const u8 = undefined;
    var depth: usize = 0;

    // Seed with the importing file's directory components (drop the basename).
    const dir_end = std.mem.lastIndexOfScalar(u8, file_path, '/') orelse 0;
    if (dir_end != 0) {
        var it = std.mem.splitScalar(u8, file_path[0..dir_end], '/');
        while (it.next()) |component| {
            if (component.len == 0) continue;
            if (depth >= stack.len) return null;
            stack[depth] = component;
            depth += 1;
        }
    }

    var it = std.mem.splitScalar(u8, target, '/');
    while (it.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (depth == 0) return null; // escapes src/
            depth -= 1;
            continue;
        }
        if (depth >= stack.len) return null;
        stack[depth] = component;
        depth += 1;
    }

    if (depth == 0) return null;
    return stack[0];
}
