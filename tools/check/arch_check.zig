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
//!   * every layer-module import is declared — a claimed file that `@import`s
//!     a layer name outside its row's granted edges fails, so an
//!     injected-module seam (a module wired outside `graphFromTable`) cannot
//!     widen the real dependency graph invisibly; the sanctioned injections
//!     are allowlisted per file in `injected_layer_imports` below;
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
    /// True (the default) for a normal layer materialized into the build graph
    /// by `graphFromTable`. False for an out-of-graph artifact that this gate
    /// still claims (file coverage, edge liveness, and the I/O bans) but that is
    /// built outside the layer DAG — the iroh C ABI (`c_abi_net_transport_iroh`) links the Rust
    /// sidecar and imports the injected `iroh` resident, neither expressible as a
    /// DAG edge, so it is minted by `irohAbiModule`, not here.
    graph: bool = true,
};

/// Create the `arch-check` build step over the authoritative layer table.
pub fn create(b: *Build, table: []const LayerSpec) *Step {
    const table_file = b.addWriteFiles().add("arch_check_table.zig", renderLayerTable(b, table));
    const check_mod = b.createModule(.{
        .root_source_file = b.path("tools/check/arch_check.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const table_mod = b.createModule(.{
        .root_source_file = table_file,
        .target = b.graph.host,
        .optimize = .Debug,
    });
    table_mod.addImport("arch_check", check_mod);
    const main_mod = b.createModule(.{
        .root_source_file = b.path("tools/check/arch_check_main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    main_mod.addImport("arch_check", check_mod);
    main_mod.addImport("arch_check_table", table_mod);
    const exe = b.addExecutable(.{ .name = "arch-check-tool", .root_module = main_mod });
    const run = b.addRunArtifact(exe);
    run.addArg(b.root.toString(b.allocator) catch @panic("OOM"));
    return &run.step;
}

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    table: []const LayerSpec,
) anyerror!usize {
    var src_dir = try root.openDir(io, "src", .{ .iterate = true });
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
                "{s}: no layer in build.zig's layer_table claims this file, declare its module or move it",
                .{file_path},
            ));
            continue;
        };
        const spec = table[layer_index];

        // Edge liveness: a granted edge counts live only when its import binding
        // is actually *used*, not merely present as an `@import` string. The
        // string proxy let an unused `const model = @import("model")` laundered
        // by a `_ = model;` discard read live; `edgeLiveInFile` closes that.
        for (spec.imports, live[layer_index]) |edge, *seen| {
            if (seen.*) continue;
            if (try edgeLiveInFile(gpa, contents, edge)) seen.* = true;
        }

        // Undeclared-edge ban, the liveness check's converse: a claimed file
        // importing a layer module its row never granted widens the real
        // dependency graph past the declared one. The compiler cannot catch it
        // when the file's module is minted outside `graphFromTable` (an
        // injected resident), so the gate holds it: every layer-name import
        // must be a granted edge, the layer's own name, or a sanctioned
        // injection declared in `injected_layer_imports`.
        {
            var line_no: usize = 1;
            var lines = std.mem.splitScalar(u8, contents, '\n');
            while (lines.next()) |line| : (line_no += 1) {
                const trimmed = std.mem.trimStart(u8, line, " \t");
                if (std.mem.startsWith(u8, trimmed, "//")) continue;
                var rest = line;
                while (std.mem.indexOf(u8, rest, "@import(\"")) |start| {
                    rest = rest[start + "@import(\"".len ..];
                    const end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
                    const imported = rest[0..end];
                    rest = rest[end..];
                    if (!isLayerName(table, imported)) continue;
                    if (std.mem.eql(u8, imported, spec.name)) continue;
                    var granted = false;
                    for (spec.imports) |edge| {
                        if (std.mem.eql(u8, edge, imported)) granted = true;
                    }
                    if (!granted and !isInjectedImport(file_path, imported)) {
                        try violations.append(gpa, try std.fmt.allocPrint(
                            gpa,
                            "{s}:{d}: imports layer module '{s}' but layer '{s}' grants no such edge — add the edge to build.zig's layer_table or declare the injection in tools/check/arch_check.zig's injected_layer_imports",
                            .{ file_path, line_no, imported, spec.name },
                        ));
                    }
                }
            }
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
        // not only std.Io. `std.Thread` is never allowed in a core layer for
        // spawning or scheduling, and `std.atomic` is never allowed at all —
        // concurrency primitives belong in adapters. One sanctioned exception:
        // `std.Thread.getCurrentId` in the byte-fed Host admission owner
        // asserts the single-owning-thread contract already in prose
        // (ADR-0072) — affinity
        // only, never spawn — allowlisted by path so any other core atomic /
        // Thread still fails loud. (The engine's GiftRegistry carries no lock;
        // ADR-0056 deleted the prior spinlock, so no atomic is sanctioned there.)
        const allows_thread_id = std.mem.endsWith(u8, file_path, "driver/core/host/admission.zig");
        if (spec.core and !allows_thread_id and std.mem.indexOf(u8, contents, "std.Thread") != null) {
            try violations.append(gpa, try std.fmt.allocPrint(
                gpa,
                "{s}: core layer '{s}' references std.Thread — the core owns no threads or scheduler",
                .{ file_path, spec.name },
            ));
        }
        if (spec.core and std.mem.indexOf(u8, contents, "std.atomic") != null) {
            try violations.append(gpa, try std.fmt.allocPrint(
                gpa,
                "{s}: core layer '{s}' references std.atomic — concurrency primitives belong in adapters",
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

        // Codec-by-name ban. Every byte the engine emits is supposed to go
        // through `codec.dispatch`, so the negotiated codec decides — except
        // the bytes a signature is defined over, which are Syrup whatever the
        // session negotiated, because a give signed on one session is verified
        // on another that negotiated independently. Those live behind
        // `codec.signed`, which states that reason once. Naming a codec
        // anywhere else above the codec layer is either a dispatch bypass or a
        // signature path that lost its precondition; both compile, and neither
        // fails a single-codec test. `codec/` owns the codecs and `oracle/`
        // generates per-codec traces, so they are exempt. Comment lines are
        // skipped so prose may name a codec.
        if (!std.mem.startsWith(u8, file_path, "src/ocapn/codec/") and
            !std.mem.startsWith(u8, file_path, "src/oracle/"))
        {
            var line_no: usize = 1;
            var lines = std.mem.splitScalar(u8, contents, '\n');
            while (lines.next()) |line| : (line_no += 1) {
                const trimmed = std.mem.trimStart(u8, line, " \t");
                if (std.mem.startsWith(u8, trimmed, "//")) continue;
                for ([_][]const u8{ "codec.syrup.", "codec.capnp." }) |needle| {
                    if (std.mem.indexOf(u8, line, needle) != null) {
                        try violations.append(gpa, try std.fmt.allocPrint(
                            gpa,
                            "{s}:{d}: names `{s}` above the codec layer — route ordinary bytes through `codec.dispatch`, and signature bytes through `codec.signed`, which says why they do not follow the negotiated codec",
                            .{ file_path, line_no, needle },
                        ));
                    }
                }
            }
        }

        // Platform-syscall-namespace ban. Portable code reaches the OS through
        // `std.posix` / `std.crypto`, which select the platform underneath; a
        // direct `std.os.linux` / `std.os.windows` reference compiles on one OS
        // and breaks every other build. Only a platform-gated completion
        // backend (or its shared socket helpers) may name its own OS.
        // `net/completion/uring.zig` and `net/completion/epoll.zig` are imported
        // behind an `os.tag == .linux` check. `socket_tcp.zig` is their shared
        // helper.
        // A new platform backend allowlists itself here in the same change
        // that gates its import.
        const platform_gated = std.mem.endsWith(u8, file_path, "net/completion/epoll.zig") or
            std.mem.endsWith(u8, file_path, "net/completion/uring.zig") or
            std.mem.endsWith(u8, file_path, "net/completion/socket_tcp.zig") or
            std.mem.endsWith(u8, file_path, "net/wake_channel.zig") or
            std.mem.endsWith(u8, file_path, "net/readiness.zig");
        if (!platform_gated and
            (std.mem.indexOf(u8, contents, "std.os.linux") != null or
                std.mem.indexOf(u8, contents, "std.os.windows") != null))
        {
            try violations.append(gpa, try std.fmt.allocPrint(
                gpa,
                "{s}: names a platform syscall namespace (std.os.linux / std.os.windows) — portable code uses std.posix; platform-gated backends are allowlisted in tools/check/arch_check.zig",
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
    }
    return violations.items.len;
}

fn renderLayerTable(b: *Build, table: []const LayerSpec) []const u8 {
    const gpa = b.allocator;
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(gpa, "const arch_check = @import(\"arch_check\");\n\npub const layer_table = [_]arch_check.LayerSpec{\n") catch @panic("OOM");
    for (table) |spec| {
        out.appendSlice(gpa, "    .{ .name = \"") catch @panic("OOM");
        out.appendSlice(gpa, spec.name) catch @panic("OOM");
        out.appendSlice(gpa, "\", .prefix = \"") catch @panic("OOM");
        out.appendSlice(gpa, spec.prefix) catch @panic("OOM");
        out.appendSlice(gpa, "\", .imports = &.{") catch @panic("OOM");
        for (spec.imports, 0..) |edge, i| {
            if (i != 0) out.appendSlice(gpa, ", ") catch @panic("OOM");
            out.appendSlice(gpa, "\"") catch @panic("OOM");
            out.appendSlice(gpa, edge) catch @panic("OOM");
            out.appendSlice(gpa, "\"") catch @panic("OOM");
        }
        out.appendSlice(gpa, "}, .core = ") catch @panic("OOM");
        out.appendSlice(gpa, if (spec.core) "true" else "false") catch @panic("OOM");
        if (!spec.graph) out.appendSlice(gpa, ", .graph = false") catch @panic("OOM");
        out.appendSlice(gpa, " },\n") catch @panic("OOM");
    }
    out.appendSlice(gpa, "};\n") catch @panic("OOM");
    return out.items;
}

/// The sanctioned injected-module seams: files whose build module is minted
/// outside `graphFromTable` with layer imports the claiming layer's row does
/// not grant. Each row is a declared exception the gate would otherwise
/// reject, so an injection is visible here instead of silent in a module
/// constructor. Keep this list to injections that genuinely cannot be a DAG
/// edge.
const injected_layer_imports = [_]struct { path: []const u8, imports: []const []const u8 }{
    // Empty: the iroh resident module no longer imports actors/driver_core
    // (CapTP serving moved to `driver.Bridge` + Host). Keep this table for
    // future sanctioned injections that cannot be DAG edges.
};

fn isLayerName(table: []const LayerSpec, name: []const u8) bool {
    for (table) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return true;
    }
    return false;
}

/// A Zig identifier byte: what may sit inside a token, so a token boundary is
/// any byte that is not one of these.
fn identByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Whether `name` occurs in `line` as a standalone token, not as a fragment of a
/// longer identifier — so `model` matches in `model.Foo` but not in `session_mod`.
// The scan is line-based, not lexer-aware: a binding named only inside a string
// literal or a trailing comment still reads as LIVE. That is conservative by
// design — it can only miss a genuinely-dead edge, never raise a false RED for a
// binding that is actually used.
fn lineHasToken(line: []const u8, name: []const u8) bool {
    var base: usize = 0;
    while (std.mem.indexOfPos(u8, line, base, name)) |pos| {
        const before_ok = pos == 0 or !identByte(line[pos - 1]);
        const after = pos + name.len;
        const after_ok = after >= line.len or !identByte(line[after]);
        if (before_ok and after_ok) return true;
        base = pos + 1;
    }
    return false;
}

/// If the `@import("edge")` at `pos` is the whole right-hand side of a pure
/// `const X = @import("edge")` (or `pub const X = @import("edge")`) alias, return
/// the binding identifier `X`; otherwise null (an inline use, or a typed/aliased
/// form we treat as a use). The binding comes from the `const X =` form, never
/// the module name, so `const session_mod = @import("session")` resolves to
/// `session_mod`, not `session`.
fn pureAliasBinding(line: []const u8, pos: usize) ?[]const u8 {
    var before = std.mem.trimEnd(u8, line[0..pos], " \t");
    if (!std.mem.endsWith(u8, before, "=")) return null;
    before = std.mem.trimEnd(u8, before[0 .. before.len - 1], " \t");
    var lhs = before;
    if (std.mem.startsWith(u8, lhs, "pub ")) lhs = std.mem.trimStart(u8, lhs[4..], " \t");
    if (!std.mem.startsWith(u8, lhs, "const ")) return null;
    const ident = std.mem.trimStart(u8, lhs[6..], " \t");
    if (ident.len == 0) return null;
    for (ident) |c| if (!identByte(c)) return null;
    return ident;
}

/// Whether `trimmed` (a leading-trimmed line) is exactly a `_ = <name>;` discard
/// of `name`, the laundering form that keeps a dead alias compiling.
fn isDiscardOf(trimmed: []const u8, name: []const u8) bool {
    if (!std.mem.startsWith(u8, trimmed, "_")) return false;
    var s = std.mem.trimStart(u8, trimmed[1..], " \t");
    if (!std.mem.startsWith(u8, s, "=")) return false;
    s = std.mem.trimStart(u8, s[1..], " \t");
    if (!std.mem.startsWith(u8, s, name)) return false;
    s = std.mem.trimStart(u8, s[name.len..], " \t");
    return std.mem.startsWith(u8, s, ";");
}

/// Whether the private alias `name`, declared on `decl_line`, is referenced as a
/// token anywhere else in `contents` — outside its own decl line, comment lines,
/// and `_ = name;` discards. This is what separates a live private import from a
/// dead one laundered by a discard.
fn bindingUsedOutsideDecl(contents: []const u8, name: []const u8, decl_line: usize) bool {
    var ln: usize = 0;
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| : (ln += 1) {
        if (ln == decl_line) continue;
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        if (isDiscardOf(trimmed, name)) continue;
        if (lineHasToken(line, name)) return true;
    }
    return false;
}

/// Strengthened edge liveness: a granted layer edge counts live only when its
/// import binding is genuinely used, not merely present as an `@import` string.
/// A pub re-export (`pub const X = @import("edge")`) or an inline use
/// (`_ = @import("edge")`, `@import("edge").Field`) is a use. A private
/// `const X = @import("edge")` alias is live only when `X` is referenced as a
/// token outside its decl line, comments, and `_ = X;` discards — so an unused
/// import laundered by a discard reads dead and the dead-edge ban fires.
fn edgeLiveInFile(gpa: std.mem.Allocator, contents: []const u8, edge: []const u8) !bool {
    const import_expr = try std.fmt.allocPrint(gpa, "@import(\"{s}\")", .{edge});
    defer gpa.free(import_expr);

    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        var base: usize = 0;
        while (std.mem.indexOfPos(u8, line, base, import_expr)) |pos| {
            base = pos + import_expr.len;
            const after = pos + import_expr.len;
            // `@import("edge").Field` — an inline field/method use.
            if (after < line.len and line[after] == '.') return true;
            if (pureAliasBinding(line, pos)) |binding| {
                // `pub const X = @import("edge")` — the re-export is the use.
                if (std.mem.startsWith(u8, trimmed, "pub ")) return true;
                if (bindingUsedOutsideDecl(contents, binding, line_no)) return true;
            } else {
                // `_ = @import("edge")` or any other inline expression = a use.
                return true;
            }
        }
    }
    return false;
}

fn isInjectedImport(file_path: []const u8, imported: []const u8) bool {
    for (injected_layer_imports) |row| {
        if (!std.mem.eql(u8, row.path, file_path)) continue;
        for (row.imports) |name| {
            if (std.mem.eql(u8, name, imported)) return true;
        }
    }
    return false;
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
