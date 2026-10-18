//! Which client rows join a run: each language's runtime on PATH, its client
//! script or built binary present, and the one-time builds and precompiles a
//! row needs before its cold-start numbers mean anything. Measurement stays in
//! `orchestrator.zig`.
const std = @import("std");
const Io = std.Io;

const o = @import("orchestrator.zig");
const Ctx = o.Ctx;
const Kind = o.Kind;
const ClientDef = o.ClientDef;
const client_dir = o.client_dir;
const out = o.out;

/// Why a client is not in the run. A missing runtime is an expected, benign
/// skip. A client that will not build is a defect in this repository, and the
/// two must never print the same sentence, a build failure reported as an
/// absent runtime hides a stale client behind a routine-looking line.
pub const Availability = union(enum) {
    ready,
    runtime_absent,
    client_absent,
    build_failed,

    pub fn reason(self: Availability) []const u8 {
        return switch (self) {
            .ready => "",
            .runtime_absent => "runtime not on PATH",
            .client_absent => "client script missing",
            .build_failed => "client failed to build (see the compiler output above)",
        };
    }
};

pub fn available(ctx: *Ctx, kind: Kind) !Availability {
    switch (kind) {
        .zig => return if (exists(ctx.io, ctx.zig_client)) .ready else .client_absent,
        .rust => {
            if ((try onPath(ctx.io, ctx.arena, ctx.environ, "cargo")) == null) return .runtime_absent;
            return if (try buildRust(ctx)) .ready else .build_failed;
        },
        .deno => {
            if ((try onPath(ctx.io, ctx.arena, ctx.environ, "deno")) == null) return .runtime_absent;
            return if (exists(ctx.io, client_dir ++ "/deno_bench.ts")) .ready else .client_absent;
        },
        .python => {
            if ((try onPath(ctx.io, ctx.arena, ctx.environ, "python3")) == null) return .runtime_absent;
            return if (exists(ctx.io, client_dir ++ "/python_bench.py")) .ready else .client_absent;
        },
        .racket => {
            if (ctx.racket_path == null) return .runtime_absent;
            return if (exists(ctx.io, client_dir ++ "/racket_bench.rkt")) .ready else .client_absent;
        },
        .goblins => {
            if (ctx.racket_path == null or !(try goblinsPresent(ctx))) return .runtime_absent;
            return if (exists(ctx.io, client_dir ++ "/goblins_bench.rkt")) .ready else .client_absent;
        },
    }
}

pub fn exists(io: Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Resolve `name` against the parent PATH, returning its absolute path or null.
/// `alloc` is the arena: the resolved path lives for the run, and the rejected
/// candidates are reclaimed when the arena is freed.
pub fn onPath(io: Io, alloc: std.mem.Allocator, environ: ?*const std.process.Environ.Map, name: []const u8) !?[]const u8 {
    const path_var = (if (environ) |e| e.get("PATH") else null) orelse return null;
    var it = std.mem.tokenizeScalar(u8, path_var, ':');
    while (it.next()) |dir| {
        const candidate = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
        if (exists(io, candidate)) return candidate;
    }
    return null;
}

/// Build the Rust bench client (release) against the installed archives. Cargo
/// output goes to our stdout/stderr so a failure is visible. The dependency's
/// build.rs finds zig-out/lib from its own manifest.
pub fn buildRust(ctx: *Ctx) !bool {
    try out(ctx.io, "bench-langs: building rust client (cargo build --release) ...\n", .{});
    var child = std.process.spawn(ctx.io, .{
        .argv = &.{ "cargo", "build", "--release", "--manifest-path", client_dir ++ "/rust_bench/Cargo.toml" },
        .environ_map = ctx.environ,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return false;
    const term = child.wait(ctx.io) catch return false;
    const ok = term == .exited and term.exited == 0;
    return ok and exists(ctx.io, ctx.rust_bin);
}

/// Probe whether the `goblins` collection is importable, so the reference row
/// is skipped with a note when Goblins is not installed.
pub fn goblinsPresent(ctx: *Ctx) !bool {
    const racket = ctx.racket_path orelse return false;
    var child = std.process.spawn(ctx.io, .{
        .argv = &.{ racket, "-e", "(require goblins)" },
        .environ_map = ctx.environ,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(ctx.io) catch return false;
    return term == .exited and term.exited == 0;
}

/// Precompile every present Racket client script to bytecode before the
/// cold-start runs. Without this, each spawn of the `racket` row pays Racket
/// recompiling the glowcap binding from source (~650 ms here), which lands
/// entirely in its cold-start number and, absurdly, makes the thin binding
/// look slower to start than all of Spritely Goblins, whose collection ships
/// precompiled `.zo` bytecode. Compiling the scripts puts both Racket rows on
/// the same footing: a spawn loads bytecode, so cold-start measures real
/// startup, not our packaging (verified: ~775 ms → ~120 ms per spawn).
///
/// `raco make` follows the module's imports, so one call writes `.zo` for the
/// script, the binding, and the shared metrics into each source's `compiled/`
/// (all git-ignored). Best-effort: when the command is absent or compilation
/// fails, the run proceeds with the source-load cost still in the number.
pub fn precompileRacket(ctx: *Ctx, present: []const ClientDef) !void {
    if (ctx.racket_path == null) return;
    const raco = (try onPath(ctx.io, ctx.arena, ctx.environ, "raco")) orelse return;
    for (present) |def| {
        const script = switch (def.kind) {
            .racket => client_dir ++ "/racket_bench.rkt",
            .goblins => client_dir ++ "/goblins_bench.rkt",
            else => continue,
        };
        try out(ctx.io, "bench-langs: precompiling {s} client (raco make) ...\n", .{def.name});
        var child = try std.process.spawn(ctx.io, .{
            .argv = &.{ raco, "make", script },
            .environ_map = ctx.environ,
            .stdout = .ignore,
            .stderr = .inherit,
        });
        const term = try child.wait(ctx.io);
        if (term != .exited or term.exited != 0) return error.RacoMakeFailed;
    }
}
