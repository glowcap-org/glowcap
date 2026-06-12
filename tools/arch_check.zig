//! Architecture gate — checks the layer table against the source tree.
//!
//! The layer dependency DAG itself is enforced by the compiler: each `src/`
//! layer is an internal build.zig module with an explicit one-way import table
//! (`layer_table` in build.zig — ADR-0040, and ADR-0048 for the sibling-codec
//! modules below the codec layer), so a cross-layer reach is a compile error —
//! a layer cannot even name a file outside its module root. This gate receives
//! that same table and walks `src/**/*.zig` to hold what the compiler alone
//! does not:
//!
//!   * every granted edge is alive — a layer whose files never `@import` a
//!     granted module name fails the gate, so the table carries the edges the
//!     code uses, never a wider silent allowance (ADR-0040);
//!   * every file belongs to a declared layer — under a module graph an
//!     unwired directory is silently-dead code, so an unclaimed file fails
//!     loud instead;
//!   * core layers (the sync, no-I/O core) carry no `std.Io`, sockets,
//!     filesystem handles, threads, or schedulers — with the one sanctioned
//!     GiftRegistry atomic (ADR-0009);
//!   * portable code names no platform syscall namespace (`std.os.linux` /
//!     `std.os.windows`) — only platform-gated backends may;
//!   * no production module names `std.testing` — test vocabulary and the
//!     copy helpers it anchors live under `test/`, never in `src/`.
//!
//! Wired as the `zig build arch-check` step and into `zig build check`.

const std = @import("std");
const Build = std.Build;
const Step = Build.Step;

/// One row of the layer DAG. The authoritative table is `layer_table` in
/// build.zig: build graphs are generated from it and this gate verifies it.
pub const LayerSpec = struct {
    /// Module/import name — internal vocabulary (ADR-0040).
    name: []const u8,
    /// The `src/`-relative file set: a directory prefix ending in `/`, or an
    /// exact `.zig` path for a single-file module. The longest matching prefix
    /// claims a file, so a nested module's files never count as its parent's.
    prefix: []const u8,
    /// The modules this layer may import — the one-way edge table.
    imports: []const []const u8,
    /// True for the sync, no-I/O core: bans `std.Io`, `std.net`,
    /// `std.fs.File`, `std.Thread`, and (one sanctioned exception) `std.atomic`.
    core: bool,
};

/// Create the `arch-check` build step over the authoritative layer table.
pub fn create(b: *Build, table: []const LayerSpec) *Step {
    const wrapper = b.allocator.create(ArchCheck) catch @panic("OOM");
    wrapper.* = .{
        .step = Step.init(.{
            .id = .custom,
            .name = "arch-check",
            .owner = b,
            .makeFn = make,
        }),
        .table = table,
    };
    return &wrapper.step;
}

const ArchCheck = struct {
    step: Step,
    table: []const LayerSpec,
};

fn make(step: *Step, options: Step.MakeOptions) anyerror!void {
    const b = step.owner;
    const io = b.graph.io;
    const gpa = options.gpa;
    const check: *ArchCheck = @fieldParentPtr("step", step);
    const table = check.table;

    var src_dir = try b.build_root.handle.openDir(io, "src", .{ .iterate = true });
    defer src_dir.close(io);

    var violations: std.ArrayList([]const u8) = .empty;
    defer violations.deinit(gpa);

    // One liveness flag per granted edge, set when any of the layer's files
    // names the edge in an `@import`.
    const live = try gpa.alloc([]bool, table.len);
    defer {
        for (live) |row| gpa.free(row);
        gpa.free(live);
    }
    for (table, 0..) |spec, i| {
        live[i] = try gpa.alloc(bool, spec.imports.len);
        @memset(live[i], false);
    }

    var walker = try src_dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const contents = try src_dir.readFileAlloc(io, entry.path, gpa, .limited(4 << 20));
        defer gpa.free(contents);

        // OS path separator is '/' on the platforms this gate runs.
        const file_path = entry.path;

        const layer_index = layerIndexOf(table, file_path) orelse {
            try violations.append(gpa, try std.fmt.allocPrint(
                gpa,
                "{s}: no layer in build.zig's layer_table claims this file — declare its module or move it",
                .{file_path},
            ));
            continue;
        };
        const spec = table[layer_index];

        // Edge liveness: record every granted module name this file imports.
        for (spec.imports, live[layer_index]) |edge, *seen| {
            if (seen.*) continue;
            const needle = try std.fmt.allocPrint(gpa, "@import(\"{s}\")", .{edge});
            defer gpa.free(needle);
            if (std.mem.indexOf(u8, contents, needle) != null) seen.* = true;
        }

        // No-I/O-in-core ban. `std.Io` is the I/O seam, but the core must also
        // not reach a socket or the filesystem directly — `std.net` and
        // `std.fs.File` are I/O the adapters own, so a core layer touching them
        // is the same boundary violation by another name.
        for ([_][]const u8{ "std.Io", "std.net", "std.fs.File" }) |needle| {
            if (spec.core and std.mem.indexOf(u8, contents, needle) != null) {
                try violations.append(gpa, try std.fmt.allocPrint(
                    gpa,
                    "{s}: core layer '{s}' references {s} — the core stays sync and no-I/O",
                    .{ file_path, spec.name, needle },
                ));
            }
        }

        // No-scheduler / no-threading-in-core ban. The Core Boundary
        // (docs/architecture.md) forbids background tasks and hidden schedulers,
        // not only std.Io. `std.Thread` is never allowed in a core layer. The one
        // sanctioned `std.atomic` is the engine's GiftRegistry table lock, which
        // guards a host-shared gift table without pulling in std.Io (ADR-0009);
        // it is allowlisted by path so any other core atomic still fails loud.
        const allows_atomic = std.mem.endsWith(u8, file_path, "engine/bootstrap.zig");
        if (spec.core and std.mem.indexOf(u8, contents, "std.Thread") != null) {
            try violations.append(gpa, try std.fmt.allocPrint(
                gpa,
                "{s}: core layer '{s}' references std.Thread — the core owns no threads or scheduler",
                .{ file_path, spec.name },
            ));
        }
        if (spec.core and !allows_atomic and std.mem.indexOf(u8, contents, "std.atomic") != null) {
            try violations.append(gpa, try std.fmt.allocPrint(
                gpa,
                "{s}: core layer '{s}' references std.atomic — concurrency primitives belong in adapters; only the GiftRegistry lock in engine/bootstrap.zig is sanctioned",
                .{ file_path, spec.name },
            ));
        }

        // Test-vocabulary ban, repo-wide over src/. `std.testing` (and the
        // test/support copy helpers it anchors) belongs under test/, never in
        // a production module — the memory rule's "copy helpers belong in
        // test/support" line, held mechanically. Comment lines are skipped so
        // prose may name the symbol.
        {
            var line_no: usize = 1;
            var lines = std.mem.splitScalar(u8, contents, '\n');
            while (lines.next()) |line| : (line_no += 1) {
                const trimmed = std.mem.trimStart(u8, line, " \t");
                if (std.mem.startsWith(u8, trimmed, "//")) continue;
                if (std.mem.indexOf(u8, line, "std.testing") != null) {
                    try violations.append(gpa, try std.fmt.allocPrint(
                        gpa,
                        "{s}:{d}: references std.testing — test vocabulary lives under test/, never in src/ production code",
                        .{ file_path, line_no },
                    ));
                }
            }
        }

        // Platform-syscall-namespace ban. Portable code reaches the OS through
        // `std.posix` / `std.crypto`, which select the platform underneath; a
        // direct `std.os.linux` / `std.os.windows` reference compiles on one OS
        // and breaks every other build. Only a platform-gated completion
        // backend may name its own OS — `net_adapter/uring.zig` is imported
        // behind an `os.tag == .linux` check. A new platform backend allowlists
        // itself here in the same change that gates its import.
        const platform_gated = std.mem.endsWith(u8, file_path, "net_adapter/uring.zig");
        if (!platform_gated and
            (std.mem.indexOf(u8, contents, "std.os.linux") != null or
                std.mem.indexOf(u8, contents, "std.os.windows") != null))
        {
            try violations.append(gpa, try std.fmt.allocPrint(
                gpa,
                "{s}: names a platform syscall namespace (std.os.linux / std.os.windows) — portable code uses std.posix; platform-gated backends are allowlisted in tools/arch_check.zig",
                .{file_path},
            ));
        }
    }

    // Dead-edge ban: a granted import no file in the layer names is a silent
    // standing allowance — the exact hole the one-way tables exist to close.
    for (table, live) |spec, row| {
        for (spec.imports, row) |edge, seen| {
            if (!seen) {
                try violations.append(gpa, try std.fmt.allocPrint(
                    gpa,
                    "layer '{s}' grants edge '{s}' but no file under src/{s} imports it — remove the edge from build.zig's layer_table",
                    .{ spec.name, edge, spec.prefix },
                ));
            }
        }
    }

    if (violations.items.len != 0) {
        for (violations.items) |msg| std.debug.print("arch-check: {s}\n", .{msg});
        return step.fail("arch-check found {d} violation(s)", .{violations.items.len});
    }
}

/// The table row that claims `file_path` (relative to `src/`): the longest
/// matching prefix wins, so `ocapn/codec/syrup/decode.zig` belongs to `syrup`,
/// not `codec`, and an exact single-file row claims only itself.
fn layerIndexOf(table: []const LayerSpec, file_path: []const u8) ?usize {
    var best: ?usize = null;
    var best_len: usize = 0;
    for (table, 0..) |spec, i| {
        const matches = if (std.mem.endsWith(u8, spec.prefix, ".zig"))
            std.mem.eql(u8, file_path, spec.prefix)
        else
            std.mem.startsWith(u8, file_path, spec.prefix);
        if (matches and spec.prefix.len > best_len) {
            best = i;
            best_len = spec.prefix.len;
        }
    }
    return best;
}
