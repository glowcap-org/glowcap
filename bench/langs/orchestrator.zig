//! Native orchestrator for the per-language consumer-cost bench
//! (`zig build bench-langs`).
//!
//! One fixed reference host — the native Zig taskboard server — is held constant
//! while the *client* language varies. For each client language present on the
//! machine this driver spawns a fresh host, runs the taskboard workload from
//! that language's bench client, parses the NDJSON it prints, samples the client
//! process's resident set, times a cold start, then tears the host down and
//! moves on. A comparison prints to the terminal and artifacts land under
//! `zig-out/bench-reports/`.
//!
//! This is NOT a language leaderboard: each row is a whole consumer stack
//! (runtime + binding + per-language app + GC/JIT) over one pancake host. See
//! `bench/langs/README.md` for the fairness model and caveats.
//!
//! Being native Zig, it needs no Racket — Racket joins only as two of the client
//! rows (the binding row and the Goblins reference), each skipped with a note
//! when its runtime is absent. The substrate bench (`bench-goblins`) and the
//! site report keep their Racket orchestration; this one stands on the Zig
//! toolchain so the Zig-only smoke runs with nothing else installed.
//!
//!   orchestrator <host-exe> <zig-client-exe> [--smoke] [--client=NAME] [--port=N]

const std = @import("std");
const Io = std.Io;

const host_addr = "127.0.0.1";
const reports_dir = "zig-out/bench-reports";
const client_dir = "bench/langs/clients";

// Resident-set sampling for the `connections` mode. The client prints `warmed`,
// sleeps `conn_warmed_sleep_ms`, then prints `connections` and sleeps
// `conn_loaded_sleep_ms` holding every connection open (see contract.md). Each
// window below must finish inside the matching client sleep, so the sample lands
// while the client is paused rather than racing its next line:
//   base   window = base_samples   * base_dt_ms   (400ms) <  600ms client sleep
//   loaded window = loaded_samples * loaded_dt_ms (1800ms) < 2500ms client sleep
// Every client uses the same two sleeps, so one orchestrator policy fits all.
const base_samples = 4;
const base_dt_ms = 100;
const loaded_samples = 12;
const loaded_dt_ms = 150;

const Kind = enum { native, rust, deno, python, racket, goblins };

const ClientDef = struct {
    name: []const u8,
    runtime: []const u8,
    kind: Kind,
};

// Roster order is report order; it also fixes the language-palette assignment
// (see paletteColor), so the Goblins reference stays visually apart.
const roster = [_]ClientDef{
    .{ .name = "zig", .runtime = "native-zig", .kind = .native },
    .{ .name = "rust", .runtime = "rust", .kind = .rust },
    .{ .name = "deno", .runtime = "deno", .kind = .deno },
    .{ .name = "python", .runtime = "cpython", .kind = .python },
    .{ .name = "racket", .runtime = "racket-cs", .kind = .racket },
    .{ .name = "goblins-ref", .runtime = "racket-cs/goblins", .kind = .goblins },
};

/// One measured client's results. Latency/throughput/connection fields hold the
/// client's own NDJSON strings verbatim (so the report reproduces what the
/// client reported); the orchestrator computes per_conn_kb and cold_ms.
const Row = struct {
    name: []const u8,
    runtime: []const u8,
    p50: []const u8 = "-",
    p99: []const u8 = "-",
    p999: []const u8 = "-",
    mean: []const u8 = "-",
    rps: []const u8 = "-",
    conn_ms: []const u8 = "-",
    per_conn_kb: []const u8 = "-",
    cold_ms: []const u8 = "-",
    local_in_ns: []const u8 = "-",
    local_in_p99_ns: []const u8 = "-",
    local_via_ns: []const u8 = "-",
    local_via_p99_ns: []const u8 = "-",
    local_ratio: []const u8 = "-",
};

const Ctx = struct {
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    environ: ?*const std.process.Environ.Map,
    host_exe: []const u8,
    zig_client: []const u8,
    rust_bin: []const u8,
    racket_path: ?[]const u8,
    smoke: bool,
    lat_n: usize,
    tput_n: usize,
    conns: usize,
    cold_samples: usize,
    local_n: usize,
    pinned_port: ?u16,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const host_exe = args.next() orelse return fail("missing <host-exe>");
    const zig_client = args.next() orelse return fail("missing <zig-client-exe>");

    var smoke = false;
    var client_filter: ?[]const u8 = null;
    var pinned_port: ?u16 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) {
            smoke = true;
        } else if (std.mem.startsWith(u8, arg, "--client=")) {
            client_filter = arg["--client=".len..];
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            pinned_port = std.fmt.parseInt(u16, arg["--port=".len..], 10) catch
                return fail("--port must be an integer in 1..65535");
        } else if (std.mem.startsWith(u8, arg, "--root=")) {
            // Accepted for forward compatibility; paths resolve against the
            // run step's cwd (the repository root), so it is unused.
        } else {
            std.debug.print("bench-langs: unknown argument '{s}'\n", .{arg});
            return error.BadArgument;
        }
    }

    var ctx = Ctx{
        .io = io,
        .gpa = gpa,
        .arena = arena,
        .environ = init.environ_map,
        .host_exe = host_exe,
        .zig_client = zig_client,
        .rust_bin = client_dir ++ "/rust_bench/target/release/langs-bench",
        .racket_path = try onPath(io, arena, init.environ_map, "racket"),
        .smoke = smoke,
        .lat_n = if (smoke) 20 else 2000,
        .tput_n = if (smoke) 20 else 2000,
        .conns = if (smoke) 4 else 50,
        .cold_samples = if (smoke) 3 else 5,
        .local_n = if (smoke) 20 else 2000,
        .pinned_port = pinned_port,
    };

    var present: std.ArrayList(ClientDef) = .empty;
    var skipped: std.ArrayList(ClientDef) = .empty;
    for (roster) |def| {
        if (client_filter) |want| {
            if (!std.mem.eql(u8, want, def.name)) continue;
        }
        if (try available(&ctx, def.kind)) {
            try present.append(arena, def);
        } else {
            try skipped.append(arena, def);
        }
    }

    for (skipped.items) |def|
        try out(io, "bench-langs: skipping {s} (runtime or client script absent)\n", .{def.name});

    try precompileRacket(&ctx, present.items);

    var rows: std.ArrayList(Row) = .empty;
    for (present.items) |def| {
        try out(io, "running {s} ...\n", .{def.name});
        try rows.append(arena, try benchOne(&ctx, def));
    }

    try report(&ctx, rows.items, skipped.items);
}

fn fail(message: []const u8) error{Usage} {
    std.debug.print("usage: orchestrator <host-exe> <zig-client-exe> [--smoke] [--client=NAME] [--port=N]\n  ({s})\n", .{message});
    return error.Usage;
}

// ── Roster availability ──────────────────────────────────────────────────────
fn available(ctx: *Ctx, kind: Kind) !bool {
    return switch (kind) {
        .native => exists(ctx.io, ctx.zig_client),
        .rust => (try onPath(ctx.io, ctx.arena, ctx.environ, "cargo")) != null and try buildRust(ctx),
        .deno => (try onPath(ctx.io, ctx.arena, ctx.environ, "deno")) != null and exists(ctx.io, client_dir ++ "/deno_bench.ts"),
        .python => (try onPath(ctx.io, ctx.arena, ctx.environ, "python3")) != null and exists(ctx.io, client_dir ++ "/python_bench.py"),
        .racket => ctx.racket_path != null and exists(ctx.io, client_dir ++ "/racket_bench.rkt"),
        .goblins => ctx.racket_path != null and try goblinsPresent(ctx) and exists(ctx.io, client_dir ++ "/goblins_bench.rkt"),
    };
}

fn exists(io: Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Resolve `name` against the parent PATH, returning its absolute path or null.
/// `alloc` is the arena: the resolved path lives for the run, and the rejected
/// candidates are reclaimed when the arena is freed.
fn onPath(io: Io, alloc: std.mem.Allocator, environ: ?*const std.process.Environ.Map, name: []const u8) !?[]const u8 {
    const path_var = (if (environ) |e| e.get("PATH") else null) orelse return null;
    var it = std.mem.tokenizeScalar(u8, path_var, ':');
    while (it.next()) |dir| {
        const candidate = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
        if (exists(io, candidate)) return candidate;
    }
    return null;
}

/// Build the Rust bench client (release) against the installed archives. Cargo
/// output goes to our stdout/stderr so a failure is visible; the dependency's
/// build.rs finds zig-out/lib from its own manifest.
fn buildRust(ctx: *Ctx) !bool {
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
fn goblinsPresent(ctx: *Ctx) !bool {
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
/// recompiling the pancake binding from source (~650 ms here), which lands
/// entirely in its cold-start number and — absurdly — makes the thin binding
/// look slower to start than all of Spritely Goblins, whose collection ships
/// precompiled `.zo` bytecode. Compiling the scripts puts both Racket rows on
/// the same footing: a spawn loads bytecode, so cold-start measures real
/// startup, not our packaging (verified: ~775 ms → ~120 ms per spawn).
///
/// `compiler/cm`'s `managed-compile-zo` follows the module's imports, so one
/// call writes `.zo` for the script, the binding, and the shared metrics into
/// each source's `compiled/` (all git-ignored). It rides on `racket` itself —
/// `raco make` lives in a `compiler-lib` package this minimal install lacks —
/// so it needs nothing the run did not already require. Best-effort: if the
/// compile fails, the run proceeds with the source-load cost still in the
/// number (a slower but honest fallback, not a crash).
fn precompileRacket(ctx: *Ctx, present: []const ClientDef) !void {
    const racket = ctx.racket_path orelse return;
    for (present) |def| {
        const script = switch (def.kind) {
            .racket => client_dir ++ "/racket_bench.rkt",
            .goblins => client_dir ++ "/goblins_bench.rkt",
            else => continue,
        };
        try out(ctx.io, "bench-langs: precompiling {s} client (managed-compile-zo) ...\n", .{def.name});
        const compile_expr = try std.fmt.allocPrint(ctx.arena, "(managed-compile-zo \"{s}\")", .{script});
        var child = std.process.spawn(ctx.io, .{
            .argv = &.{ racket, "-e", "(require compiler/cm)", "-e", compile_expr },
            .environ_map = ctx.environ,
            .stdout = .ignore,
            .stderr = .inherit,
        }) catch continue;
        _ = child.wait(ctx.io) catch continue;
    }
}

// ── Per-client driving ───────────────────────────────────────────────────────
fn benchOne(ctx: *Ctx, def: ClientDef) !Row {
    var row = Row{ .name = def.name, .runtime = def.runtime };

    // Each window gets a fresh host so one language's connection burst never
    // bleeds server heap into the next row's memory figure.
    {
        var host = try startHost(ctx);
        defer host.kill(ctx.io);
        const line = try runMetric(ctx, def, "latency", host.port, ctx.lat_n);
        if (line) |l| {
            row.p50 = jf(l, "\"p50_ms\"") orelse "-";
            row.p99 = jf(l, "\"p99_ms\"") orelse "-";
            row.p999 = jf(l, "\"p999_ms\"") orelse "-";
            row.mean = jf(l, "\"mean_ms\"") orelse "-";
        }
    }
    {
        var host = try startHost(ctx);
        defer host.kill(ctx.io);
        const line = try runMetric(ctx, def, "throughput", host.port, ctx.tput_n);
        if (line) |l| row.rps = jf(l, "\"rps\"") orelse "-";
    }
    {
        var host = try startHost(ctx);
        defer host.kill(ctx.io);
        const conn = try runConnections(ctx, def, host.port, ctx.conns);
        if (conn.line) |l| row.conn_ms = jf(l, "\"per_conn_ms\"") orelse "-";
        row.per_conn_kb = conn.per_conn_kb;
    }
    {
        var host = try startHost(ctx);
        defer host.kill(ctx.io);
        row.cold_ms = try runCold(ctx, def, host.port, ctx.cold_samples);
    }
    {
        // `local` is self-contained (contract.md): the client ignores the
        // host/port arguments, so no host is spawned and the port is 0. The
        // goblins-ref row reports its via_host fields as JSON null.
        const line = try runMetric(ctx, def, "local", 0, ctx.local_n);
        if (line) |l| {
            row.local_in_ns = jfDash(l, "\"in_lang_ns\"");
            row.local_in_p99_ns = jfDash(l, "\"in_lang_p99_ns\"");
            row.local_via_ns = jfDash(l, "\"via_host_ns\"");
            row.local_via_p99_ns = jfDash(l, "\"via_host_p99_ns\"");
            row.local_ratio = jfDash(l, "\"ratio\"");
        }
    }
    return row;
}

const Host = struct {
    child: std.process.Child,
    port: u16,

    fn kill(self: *Host, io: Io) void {
        self.child.kill(io);
    }
};

/// Spawn a fresh host and read its NDJSON readiness line to learn the port.
fn startHost(ctx: *Ctx) !Host {
    const port_arg = if (ctx.pinned_port) |p|
        try std.fmt.allocPrint(ctx.arena, "{d}", .{p})
    else
        "0";
    var child = try std.process.spawn(ctx.io, .{
        .argv = &.{ ctx.host_exe, port_arg },
        .environ_map = ctx.environ,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    errdefer child.kill(ctx.io);

    const out_file = child.stdout orelse return error.NoHostStdout;
    var buf: [4096]u8 = undefined;
    var reader = out_file.readerStreaming(ctx.io, &buf);
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch
            return error.HostExitedBeforeReady;
        const listen = jf(line, "\"listen\"") orelse continue;
        const colon = std.mem.lastIndexOfScalar(u8, listen, ':') orelse continue;
        const port = std.fmt.parseInt(u16, listen[colon + 1 ..], 10) catch continue;
        return .{ .child = child, .port = port };
    }
}

/// Build the client's argv for `mode` against `port`/`n` (arena-owned).
fn buildArgv(ctx: *Ctx, def: ClientDef, mode: []const u8, port: u16, n: usize) ![]const []const u8 {
    const port_str = try std.fmt.allocPrint(ctx.arena, "{d}", .{port});
    const n_str = try std.fmt.allocPrint(ctx.arena, "{d}", .{n});
    return switch (def.kind) {
        .native => try dupArgv(ctx, &.{ ctx.zig_client, mode, host_addr, port_str, n_str }),
        .rust => try dupArgv(ctx, &.{ ctx.rust_bin, mode, host_addr, port_str, n_str }),
        // `--v8-flags=--expose-gc` lets the Deno client force a collection before
        // each measured window, the same GC-settled start the other rows get.
        .deno => try dupArgv(ctx, &.{ "deno", "run", "--allow-ffi", "--allow-read", "--allow-net", "--v8-flags=--expose-gc", client_dir ++ "/deno_bench.ts", mode, host_addr, port_str, n_str }),
        .python => try dupArgv(ctx, &.{ "python3", client_dir ++ "/python_bench.py", mode, host_addr, port_str, n_str }),
        .racket => try dupArgv(ctx, &.{ ctx.racket_path.?, client_dir ++ "/racket_bench.rkt", mode, host_addr, port_str, n_str }),
        .goblins => try dupArgv(ctx, &.{ ctx.racket_path.?, client_dir ++ "/goblins_bench.rkt", mode, host_addr, port_str, n_str }),
    };
}

fn dupArgv(ctx: *Ctx, items: []const []const u8) ![]const []const u8 {
    return ctx.arena.dupe([]const u8, items);
}

/// Run a client to completion in `mode`; return the first NDJSON `metric` line
/// (arena-owned), or null if it produced none.
fn runMetric(ctx: *Ctx, def: ClientDef, mode: []const u8, port: u16, n: usize) !?[]const u8 {
    const argv = try buildArgv(ctx, def, mode, port, n);
    var child = try std.process.spawn(ctx.io, .{
        .argv = argv,
        .environ_map = ctx.environ,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(ctx.io);

    const out_file = child.stdout orelse return error.NoClientStdout;
    var buf: [8192]u8 = undefined;
    var reader = out_file.readerStreaming(ctx.io, &buf);
    var found: ?[]const u8 = null;
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch break;
        if (found == null and std.mem.indexOf(u8, line, "\"metric\"") != null)
            found = try ctx.arena.dupe(u8, line);
    }
    return found;
}

const ConnResult = struct {
    line: ?[]const u8,
    per_conn_kb: []const u8,
};

/// Connections + per-client memory: spawn the client in `connections` mode, read
/// its `warmed` marker (sample the baseline resident set), read its
/// `connections` line (sample the loaded set while it holds them open), and
/// return the line plus the per-connection RSS delta. The sample windows fit
/// inside the client's documented post-marker sleeps (0.6s, then 2.5s).
fn runConnections(ctx: *Ctx, def: ClientDef, port: u16, n: usize) !ConnResult {
    const argv = try buildArgv(ctx, def, "connections", port, n);
    var child = try std.process.spawn(ctx.io, .{
        .argv = argv,
        .environ_map = ctx.environ,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(ctx.io);
    const pid = child.id orelse return error.NoClientPid;

    const out_file = child.stdout orelse return error.NoClientStdout;
    var buf: [8192]u8 = undefined;
    var reader = out_file.readerStreaming(ctx.io, &buf);
    var base: u64 = 0;
    var loaded: u64 = 0;
    var line: ?[]const u8 = null;
    while (true) {
        const l = reader.interface.takeDelimiterInclusive('\n') catch break;
        if (std.mem.indexOf(u8, l, "\"event\"") != null and std.mem.indexOf(u8, l, "warmed") != null) {
            base = sampleMinRss(ctx, pid, base_samples, base_dt_ms);
        } else if (std.mem.indexOf(u8, l, "\"metric\"") != null and std.mem.indexOf(u8, l, "connections") != null) {
            line = try ctx.arena.dupe(u8, l);
            loaded = sampleMinRss(ctx, pid, loaded_samples, loaded_dt_ms);
        }
    }
    const delta: u64 = if (loaded > base) loaded - base else 0;
    const per_conn = @as(f64, @floatFromInt(delta)) / @as(f64, @floatFromInt(@max(1, n)));
    return .{ .line = line, .per_conn_kb = try std.fmt.allocPrint(ctx.arena, "{d:.1}", .{per_conn}) };
}

/// Cold start: spawn a fresh client in `cold` mode and time from just-before
/// spawn to the `cold-done` marker. Repeat `samples` times; return the median
/// (ms, two decimals, arena-owned).
fn runCold(ctx: *Ctx, def: ClientDef, port: u16, samples: usize) ![]const u8 {
    const times = try ctx.arena.alloc(f64, samples);
    for (0..samples) |i| {
        const argv = try buildArgv(ctx, def, "cold", port, 1);
        const t0 = nowNs(ctx.io);
        var child = try std.process.spawn(ctx.io, .{
            .argv = argv,
            .environ_map = ctx.environ,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        const out_file = child.stdout orelse return error.NoClientStdout;
        var buf: [4096]u8 = undefined;
        var reader = out_file.readerStreaming(ctx.io, &buf);
        while (true) {
            const l = reader.interface.takeDelimiterInclusive('\n') catch break;
            if (std.mem.indexOf(u8, l, "cold-done") != null) break;
        }
        times[i] = @as(f64, @floatFromInt(nowNs(ctx.io) - t0)) / 1_000_000.0;
        child.kill(ctx.io);
    }
    std.sort.pdq(f64, times, {}, lessThanF64);
    return std.fmt.allocPrint(ctx.arena, "{d:.2}", .{percentile(times, 0.50)});
}

fn lessThanF64(_: void, a: f64, b: f64) bool {
    return a < b;
}

/// Nearest-rank percentile (1-indexed ceil) over an ascending-sorted slice.
fn percentile(sorted: []const f64, p: f64) f64 {
    if (sorted.len == 0) return 0;
    const rank: usize = @intFromFloat(@ceil(p * @as(f64, @floatFromInt(sorted.len))));
    const idx = if (rank == 0) 0 else @min(sorted.len - 1, rank - 1);
    return sorted[idx];
}

fn nowNs(io: Io) u64 {
    return @intCast(std.Io.Clock.now(.awake, io).nanoseconds);
}

/// Sample a pid's VmRSS `samples` times `dt_ms` apart, keeping the minimum (the
/// live-set floor, not a process caught mid-collection).
fn sampleMinRss(ctx: *Ctx, pid: std.posix.pid_t, samples: usize, dt_ms: i64) u64 {
    var best: ?u64 = null;
    for (0..samples) |_| {
        if (readVmRssKb(ctx, pid)) |s| best = if (best) |b| @min(b, s) else s;
        ctx.io.sleep(std.Io.Duration.fromMilliseconds(dt_ms), .awake) catch {};
    }
    return best orelse 0;
}

/// Read VmRSS (kB) for a live pid from /proc, or null if unreadable.
fn readVmRssKb(ctx: *Ctx, pid: std.posix.pid_t) ?u64 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{pid}) catch return null;
    var file = std.Io.Dir.cwd().openFile(ctx.io, path, .{}) catch return null;
    defer file.close(ctx.io);
    var rbuf: [4096]u8 = undefined;
    var reader = file.readerStreaming(ctx.io, &rbuf);
    var scratch: [8192]u8 = undefined;
    var len: usize = 0;
    while (len < scratch.len) {
        const nread = reader.interface.readSliceShort(scratch[len..]) catch break;
        if (nread == 0) break;
        len += nread;
    }
    const text = scratch[0..len];
    const at = std.mem.indexOf(u8, text, "VmRSS:") orelse return null;
    var i = at + "VmRSS:".len;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    const start = i;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') i += 1;
    return std.fmt.parseInt(u64, text[start..i], 10) catch null;
}

/// `jf`, with a JSON `null` (or a missing key) rendered as `-`: the
/// goblins-ref row's `local` line carries null via_host fields (contract.md).
fn jfDash(line: []const u8, key: []const u8) []const u8 {
    const value = jf(line, key) orelse return "-";
    if (std.mem.eql(u8, value, "null")) return "-";
    return value;
}

/// Pull a `"key":num` or `"key":"str"` value out of an NDJSON line (a subslice
/// of `line`, so it lives as long as the caller's line). `key` includes its
/// surrounding quotes, e.g. `"\"p50_ms\""`.
fn jf(line: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    var i = at + key.len;
    while (i < line.len and line[i] != ':') i += 1;
    if (i >= line.len) return null;
    i += 1;
    while (i < line.len and line[i] == ' ') i += 1;
    if (i < line.len and line[i] == '"') {
        i += 1;
        const start = i;
        while (i < line.len and line[i] != '"') i += 1;
        return line[start..i];
    }
    const start = i;
    while (i < line.len and line[i] != ',' and line[i] != '}') i += 1;
    var end = i;
    while (end > start and line[end - 1] == ' ') end -= 1;
    return line[start..end];
}

// ── Reporting ────────────────────────────────────────────────────────────────
const INK = "#3a3027";
const INK_SOFT = "#6b5d4d";
const PAPER = "#fff9ee";
const RULE = "#e7d4b7";
const GOBLINS_COLOR = "#257f88";
const lang_colors = [_][]const u8{ "#c76f18", "#4f8a5b", "#9c4f96", "#3f6fa3", "#b8762a", "#737373" };

fn report(ctx: *Ctx, rows: []const Row, skipped: []const ClientDef) !void {
    const mode_str: []const u8 = if (ctx.smoke) "smoke" else "full";

    // Terminal summary.
    var term: std.ArrayList(u8) = .empty;
    defer term.deinit(ctx.gpa);
    try term.appendSlice(ctx.gpa, "pancake per-language consumer cost (NOT a leaderboard)\n");
    try term.print(ctx.gpa, "mode={s} lat_n={d} tput_n={d} conns={d} cold_samples={d} local_n={d}\n\n", .{ mode_str, ctx.lat_n, ctx.tput_n, ctx.conns, ctx.cold_samples, ctx.local_n });
    for (rows) |r| {
        try term.print(ctx.gpa, "  {s} ({s})  p50={s}ms p99={s}ms p999={s}ms mean={s}ms rps={s} setup={s}ms/conn per_conn={s}kB cold={s}ms local={s}ns local_p99={s}ns via_host={s}ns via_p99={s}ns via/local={s}\n", .{ r.name, r.runtime, r.p50, r.p99, r.p999, r.mean, r.rps, r.conn_ms, r.per_conn_kb, r.cold_ms, r.local_in_ns, r.local_in_p99_ns, r.local_via_ns, r.local_via_p99_ns, r.local_ratio });
    }
    try out(ctx.io, "{s}", .{term.items});

    std.Io.Dir.cwd().createDirPath(ctx.io, reports_dir) catch {};
    const stamp: i64 = @intCast(@divFloor(std.Io.Clock.now(.real, ctx.io).nanoseconds, 1_000_000_000));

    try writeArtifact(ctx, stamp, "txt", term.items);

    if (skipped.len != 0) {
        var s: std.ArrayList(u8) = .empty;
        defer s.deinit(ctx.gpa);
        for (skipped) |def| try s.print(ctx.gpa, "{s}\n", .{def.name});
        try writeNamed(ctx, try std.fmt.allocPrint(ctx.arena, "langs-compare-{d}-skipped.txt", .{stamp}), s.items);
    }

    if (rows.len != 0) {
        try writeSvg(ctx, rows, stamp, "latency", "Latency p50 (ms, lower is better)", "ms", .p50, 2);
        try writeSvg(ctx, rows, stamp, "throughput", "Throughput (req/s, higher is better)", "req/s", .rps, 0);
        try writeSvg(ctx, rows, stamp, "cold", "Cold start (ms, lower is better)", "ms", .cold_ms, 1);
    }

    try writeArtifact(ctx, stamp, "md", try renderMarkdown(ctx, rows, mode_str, stamp));

    try out(ctx.io, "\nartifacts: {s}/langs-compare-{d}.{{txt,md,*.svg}}\n", .{ reports_dir, stamp });
}

fn writeArtifact(ctx: *Ctx, stamp: i64, ext: []const u8, data: []const u8) !void {
    try writeNamed(ctx, try std.fmt.allocPrint(ctx.arena, "langs-compare-{d}.{s}", .{ stamp, ext }), data);
}

fn writeNamed(ctx: *Ctx, name: []const u8, data: []const u8) !void {
    const path = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ reports_dir, name });
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = data });
}

const Field = enum { p50, rps, cold_ms };

fn fieldValue(r: Row, f: Field) f64 {
    const s = switch (f) {
        .p50 => r.p50,
        .rps => r.rps,
        .cold_ms => r.cold_ms,
    };
    return std.fmt.parseFloat(f64, s) catch 0;
}

/// A stable color per client: the reference row is teal, every other row draws
/// from the language palette in roster order (the Racket `palette-for` rule).
fn paletteColor(rows: []const Row, idx: usize) []const u8 {
    var pool: usize = 0;
    for (rows, 0..) |r, i| {
        if (std.mem.eql(u8, r.name, "goblins-ref")) {
            if (i == idx) return GOBLINS_COLOR;
        } else {
            if (i == idx) return lang_colors[pool % lang_colors.len];
            pool += 1;
        }
    }
    return lang_colors[0];
}

fn writeSvg(ctx: *Ctx, rows: []const Row, stamp: i64, name: []const u8, title: []const u8, y_label: []const u8, field: Field, precision: usize) !void {
    const W = 760;
    const H = 430;
    const ml = 72;
    const mr = 24;
    const mt = 56;
    const mb = 96;
    const pw: f64 = W - ml - mr;
    const ph: f64 = H - mt - mb;
    const x0: f64 = ml;
    const y1: f64 = mt + ph;

    const nbars = @max(1, rows.len);
    const slot = pw / @as(f64, @floatFromInt(nbars));
    const bw = slot * 0.6;
    var maxv: f64 = 0.0001;
    for (rows) |r| maxv = @max(maxv, fieldValue(r, field));

    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(ctx.gpa);
    const a = ctx.gpa;
    const ymid: f64 = mt + ph / 2.0;
    try s.print(a, "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {d} {d}\" font-family=\"system-ui,-apple-system,sans-serif\" role=\"img\">\n", .{ W, H });
    try s.print(a, "<rect width=\"{d}\" height=\"{d}\" fill=\"{s}\" rx=\"10\"/>\n", .{ W, H, PAPER });
    try s.print(a, "<text x=\"{d}\" y=\"30\" text-anchor=\"middle\" font-size=\"18\" font-weight=\"700\" fill=\"{s}\">{s}</text>\n", .{ W / 2, INK, title });
    try s.print(a, "<text x=\"18\" y=\"{d}\" text-anchor=\"middle\" font-size=\"12\" fill=\"{s}\" transform=\"rotate(-90 18 {d})\">{s}</text>\n", .{ ymid, INK_SOFT, ymid, y_label });
    try s.print(a, "<line x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\" stroke=\"{s}\" stroke-dasharray=\"3 3\"/>\n", .{ x0, mt, x0 + pw, mt, RULE });
    try s.print(a, "<line x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\" stroke=\"{s}\" stroke-width=\"1.5\"/>\n", .{ x0, y1, x0 + pw, y1, INK });
    try s.print(a, "<text x=\"{d}\" y=\"{d}\" text-anchor=\"end\" font-size=\"11\" fill=\"{s}\">", .{ x0 - 8, mt + 4, INK_SOFT });
    try fmtNum(&s, a, maxv, precision);
    try s.appendSlice(a, "</text>\n");
    try s.print(a, "<text x=\"{d}\" y=\"{d}\" text-anchor=\"end\" font-size=\"11\" fill=\"{s}\">0</text>\n", .{ x0 - 8, y1 + 4, INK_SOFT });
    for (rows, 0..) |r, i| {
        const v = fieldValue(r, field);
        const cx = x0 + slot * (@as(f64, @floatFromInt(i)) + 0.5);
        const bx = cx - bw / 2.0;
        const by = y1 - (v / maxv) * ph;
        const color = paletteColor(rows, i);
        try s.print(a, "<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"{s}\" rx=\"2\"/>\n", .{ bx, by, bw, @max(0, y1 - by), color });
        try s.print(a, "<text x=\"{d}\" y=\"{d}\" text-anchor=\"middle\" font-size=\"10\" fill=\"{s}\">", .{ cx, by - 4, INK });
        try fmtNum(&s, a, v, precision);
        try s.appendSlice(a, "</text>\n");
        try s.print(a, "<text x=\"{d}\" y=\"{d}\" text-anchor=\"middle\" font-size=\"11\" fill=\"{s}\">{s}</text>\n", .{ cx, y1 + 18, INK, r.name });
    }
    try s.appendSlice(a, "</svg>\n");

    try writeNamed(ctx, try std.fmt.allocPrint(ctx.arena, "langs-compare-{d}-{s}.svg", .{ stamp, name }), s.items);
}

fn fmtNum(s: *std.ArrayList(u8), a: std.mem.Allocator, v: f64, precision: usize) !void {
    switch (precision) {
        0 => try s.print(a, "{d:.0}", .{v}),
        1 => try s.print(a, "{d:.1}", .{v}),
        else => try s.print(a, "{d:.2}", .{v}),
    }
}

fn renderMarkdown(ctx: *Ctx, rows: []const Row, mode: []const u8, stamp: i64) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    const a = ctx.arena;
    try s.appendSlice(a, "# pancake per-language consumer cost\n\n");
    try s.print(a, "Mode **{s}** \u{b7} latency n={d} \u{b7} throughput n={d} \u{b7} connections={d} \u{b7} cold-start samples={d} \u{b7} local n={d}. One native Zig host, the client language swapped per row, over real loopback TCP.\n\n", .{ mode, ctx.lat_n, ctx.tput_n, ctx.conns, ctx.cold_samples, ctx.local_n });
    try s.appendSlice(a, "> This is **not** a language leaderboard. Each row is a whole consumer stack — runtime, that language's binding, the app rewritten in it, and its garbage collector — over one pancake host. A faster row does not mean pancake's wire is faster in that language; it means that whole stack was faster on this one machine on this one day. Reproduce with `zig build bench-langs`, and read [`bench/langs/README.md`](README.md) for the fairness model and caveats.\n\n");
    try s.appendSlice(a, "## Results\n\n");
    try s.appendSlice(a, "| client | runtime | p50 ms | p99 ms | p999 ms | mean ms | req/s | setup ms/conn | mem kB/conn | cold ms | local ns/turn | local p99 ns | via-host ns/turn | via-host p99 ns | via/local |\n");
    try s.appendSlice(a, "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n");
    for (rows) |r| {
        try s.print(a, "| {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} |\n", .{ r.name, r.runtime, r.p50, r.p99, r.p999, r.mean, r.rps, r.conn_ms, r.per_conn_kb, r.cold_ms, r.local_in_ns, r.local_in_p99_ns, r.local_via_ns, r.local_via_p99_ns, r.local_ratio });
    }
    try s.print(a, "\n## Latency — p50, milliseconds (lower is better)\n\n![latency p50](langs-compare-{d}-latency.svg)\n", .{stamp});
    try s.print(a, "\n## Throughput — requests/second (higher is better)\n\n![throughput](langs-compare-{d}-throughput.svg)\n", .{stamp});
    try s.print(a, "\n## Cold start — milliseconds, spawn to first settled call (lower is better)\n\n![cold start](langs-compare-{d}-cold.svg)\n\n", .{stamp});
    return s.items;
}

fn out(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    try stdout.interface.print(fmt, args);
    try stdout.interface.flush();
}
