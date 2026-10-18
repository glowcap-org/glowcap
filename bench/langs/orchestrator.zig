//! Zig orchestrator for the per-language consumer-cost bench
//! (`zig build bench-langs`).
//!
//! One fixed reference host, the Zig taskboard server, is held constant
//! while the *client* language varies. For each client language present on the
//! machine this driver spawns a fresh host, runs the taskboard workload from
//! that language's bench client, parses the NDJSON it prints, samples the client
//! process's resident set, times a cold start, then tears the host down and
//! moves on. A comparison prints to the terminal and artifacts land under
//! `zig-out/bench-reports/`.
//!
//! This is NOT a language leaderboard: each row is a whole consumer stack
//! (runtime + binding + per-language app + GC/JIT) over one glowcap host. See
//! `bench/langs/README.md` for the fairness model and caveats.
//!
//! As a Zig program it needs no Racket. Racket joins only as two of the client
//! rows (the binding row and the Goblins reference), each skipped with a note
//! when its runtime is absent. The substrate bench (`bench-goblins`) and the
//! site report keep their Racket orchestration. This one stands on the Zig
//! toolchain so the Zig-only smoke runs with nothing else installed.
//!
//!   orchestrator <host-exe> <zig-client-exe> [--smoke] [--client=NAME] [--port=N]

const std = @import("std");
const Io = std.Io;

const report_mod = @import("report.zig");
const affinity = @import("affinity");
const availability_mod = @import("availability.zig");

const host_addr = "127.0.0.1";
pub const reports_dir = "zig-out/bench-reports";
pub const client_dir = "bench/langs/clients";

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

pub const Kind = enum { zig, rust, deno, python, racket, goblins };

pub const ClientDef = struct {
    name: []const u8,
    runtime: []const u8,
    kind: Kind,
};

/// A roster entry that will not run, with the reason the report prints.
pub const Skip = struct {
    def: ClientDef,
    why: availability_mod.Availability,
};

// Roster order is report order; it also fixes the language-palette assignment
// (see paletteColor), so the Goblins reference stays visually apart.
const roster = [_]ClientDef{
    .{ .name = "zig", .runtime = "zig", .kind = .zig },
    .{ .name = "rust", .runtime = "rust", .kind = .rust },
    .{ .name = "deno", .runtime = "deno", .kind = .deno },
    .{ .name = "python", .runtime = "cpython", .kind = .python },
    .{ .name = "racket", .runtime = "racket-cs", .kind = .racket },
    .{ .name = "goblins-ref", .runtime = "racket-cs/goblins", .kind = .goblins },
};

/// One measured client's results. Latency/throughput/connection fields hold the
/// client's own NDJSON strings verbatim (so the report reproduces what the
/// client reported). The orchestrator computes per_conn_kb and cold_ms.
pub const Row = struct {
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

pub const Ctx = struct {
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
    /// `--pin=A,B`: every client on core A, the host on core B, and the
    /// `local` window's client on both.
    pin: ?affinity.Pair,
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
    var pin: ?affinity.Pair = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) {
            smoke = true;
        } else if (std.mem.startsWith(u8, arg, "--client=")) {
            client_filter = arg["--client=".len..];
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            pinned_port = std.fmt.parseInt(u16, arg["--port=".len..], 10) catch
                return fail("--port must be an integer in 1..65535");
        } else if (std.mem.startsWith(u8, arg, "--pin=")) {
            pin = affinity.parsePair(arg["--pin=".len..]) catch
                return fail("--pin takes two core numbers, as --pin=A,B");
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
        .racket_path = try availability_mod.onPath(io, arena, init.environ_map, "racket"),
        .smoke = smoke,
        .lat_n = if (smoke) 20 else 2000,
        .tput_n = if (smoke) 20 else 2000,
        .conns = if (smoke) 4 else 50,
        .cold_samples = if (smoke) 3 else 5,
        .local_n = if (smoke) 20 else 2000,
        .pinned_port = pinned_port,
        .pin = pin,
    };

    var present: std.ArrayList(ClientDef) = .empty;
    var skipped: std.ArrayList(Skip) = .empty;
    for (roster) |def| {
        if (client_filter) |want| {
            if (!std.mem.eql(u8, want, def.name)) continue;
        }
        const availability = try availability_mod.available(&ctx, def.kind);
        if (availability == .ready) {
            try present.append(arena, def);
        } else {
            try skipped.append(arena, .{ .def = def, .why = availability });
        }
    }

    for (skipped.items) |s|
        try out(io, "bench-langs: skipping {s} ({s})\n", .{ s.def.name, s.why.reason() });

    try availability_mod.precompileRacket(&ctx, present.items);

    var rows: std.ArrayList(Row) = .empty;
    for (present.items) |def| {
        try out(io, "running {s} ...\n", .{def.name});
        try rows.append(arena, try benchOne(&ctx, def));
    }

    try report_mod.report(&ctx, rows.items, skipped.items);
}

fn fail(message: []const u8) error{Usage} {
    std.debug.print("usage: orchestrator <host-exe> <zig-client-exe> [--smoke] [--client=NAME] [--port=N]\n  ({s})\n", .{message});
    return error.Usage;
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
        row.p50 = jf(line, "\"p50_ms\"") orelse "-";
        row.p99 = jf(line, "\"p99_ms\"") orelse "-";
        row.p999 = jf(line, "\"p999_ms\"") orelse "-";
        row.mean = jf(line, "\"mean_ms\"") orelse "-";
    }
    {
        var host = try startHost(ctx);
        defer host.kill(ctx.io);
        const line = try runMetric(ctx, def, "throughput", host.port, ctx.tput_n);
        row.rps = jf(line, "\"rps\"") orelse "-";
    }
    {
        var host = try startHost(ctx);
        defer host.kill(ctx.io);
        const conn = try runConnections(ctx, def, host.port, ctx.conns);
        row.conn_ms = jf(conn.line, "\"per_conn_ms\"") orelse "-";
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
        row.local_in_ns = jfDash(line, "\"in_lang_ns\"");
        row.local_in_p99_ns = jfDash(line, "\"in_lang_p99_ns\"");
        row.local_via_ns = jfDash(line, "\"via_host_ns\"");
        row.local_via_p99_ns = jfDash(line, "\"via_host_p99_ns\"");
        row.local_ratio = jfDash(line, "\"ratio\"");
    }
    return row;
}

/// Where a pinned run places a process: a client on core A, the host on
/// core B, and the `local` window's client on both, since that process
/// carries its own host and a spinning side must never share one core with
/// the side it waits for.
const Placement = enum { client, host, whole };

fn cores(ctx: *Ctx, placement: Placement) []const u16 {
    const pin = if (ctx.pin) |*p| p else return &.{};
    return switch (placement) {
        .client => pin[0..1],
        .host => pin[1..2],
        .whole => pin[0..2],
    };
}

/// Spawn with the child held to `cpus` when the run is pinned. A child
/// inherits the mask it is spawned under, so the orchestrator wears the mask
/// for the spawn alone and keeps its own placement, which never enters a
/// measured number.
fn spawnOn(ctx: *Ctx, cpus: []const u16, options: std.process.SpawnOptions) !std.process.Child {
    if (cpus.len == 0) return std.process.spawn(ctx.io, options);
    const own = try affinity.current();
    try affinity.apply(try affinity.mask(cpus));
    var child = std.process.spawn(ctx.io, options) catch |err| {
        try affinity.apply(own);
        return err;
    };
    affinity.apply(own) catch |err| {
        child.kill(ctx.io);
        return err;
    };
    return child;
}

/// A client that left by any path but a zero exit failed the run, and the
/// line says which client and how it left, since its stderr was its own.
fn checkExit(def: ClientDef, mode: []const u8, term: std.process.Child.Term) error{ClientFailed}!void {
    switch (term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    std.debug.print("bench-langs: {s} client left {s} with {any}\n", .{ def.name, mode, term });
    return error.ClientFailed;
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
    var child = try spawnOn(ctx, cores(ctx, .host), .{
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
        // tolerant: a listen field without a numeric port is skipped, and a host that never prints one exits and fails the read above.
        const port = std.fmt.parseInt(u16, listen[colon + 1 ..], 10) catch continue;
        return .{ .child = child, .port = port };
    }
}

/// Build the client's argv for `mode` against `port`/`n` (arena-owned).
fn buildArgv(ctx: *Ctx, def: ClientDef, mode: []const u8, port: u16, n: usize) ![]const []const u8 {
    const port_str = try std.fmt.allocPrint(ctx.arena, "{d}", .{port});
    const n_str = try std.fmt.allocPrint(ctx.arena, "{d}", .{n});
    return switch (def.kind) {
        .zig => try dupArgv(ctx, &.{ ctx.zig_client, mode, host_addr, port_str, n_str }),
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

/// Run a client to completion in `mode` and return its NDJSON metric line.
fn runMetric(ctx: *Ctx, def: ClientDef, mode: []const u8, port: u16, n: usize) ![]const u8 {
    const argv = try buildArgv(ctx, def, mode, port, n);
    var child = try spawnOn(ctx, cores(ctx, if (std.mem.eql(u8, mode, "local")) .whole else .client), .{
        .argv = argv,
        .environ_map = ctx.environ,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer child.kill(ctx.io);

    const out_file = child.stdout orelse return error.NoClientStdout;
    var buf: [8192]u8 = undefined;
    var reader = out_file.readerStreaming(ctx.io, &buf);
    var found: ?[]const u8 = null;
    while (true) {
        // tolerant: the end of the client's output ends the read, and a missing metric line or a failing exit below fails the run.
        const line = reader.interface.takeDelimiterInclusive('\n') catch break;
        if (found == null and std.mem.indexOf(u8, line, "\"metric\"") != null)
            found = try ctx.arena.dupe(u8, line);
    }
    const term = try child.wait(ctx.io);
    try checkExit(def, mode, term);
    return found orelse error.MissingClientMetric;
}

const ConnResult = struct {
    line: []const u8,
    per_conn_kb: []const u8,
};

/// Connections + per-client memory: spawn the client in `connections` mode, read
/// its `warmed` marker (sample the baseline resident set), read its
/// `connections` line (sample the loaded set while it holds them open), and
/// return the line plus the per-connection RSS delta. The sample windows fit
/// inside the client's documented post-marker sleeps (0.6s, then 2.5s).
fn runConnections(ctx: *Ctx, def: ClientDef, port: u16, n: usize) !ConnResult {
    const argv = try buildArgv(ctx, def, "connections", port, n);
    var child = try spawnOn(ctx, cores(ctx, .client), .{
        .argv = argv,
        .environ_map = ctx.environ,
        .stdout = .pipe,
        .stderr = .inherit,
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
        // tolerant: the end of the client's output ends the read, and a missing metric line or a failing exit below fails the run.
        const l = reader.interface.takeDelimiterInclusive('\n') catch break;
        if (std.mem.indexOf(u8, l, "\"event\"") != null and std.mem.indexOf(u8, l, "warmed") != null) {
            base = try sampleMinRss(ctx, pid, base_samples, base_dt_ms);
        } else if (std.mem.indexOf(u8, l, "\"metric\"") != null and std.mem.indexOf(u8, l, "connections") != null) {
            line = try ctx.arena.dupe(u8, l);
            loaded = try sampleMinRss(ctx, pid, loaded_samples, loaded_dt_ms);
        }
    }
    const term = try child.wait(ctx.io);
    try checkExit(def, "connections", term);
    const delta: u64 = if (loaded > base) loaded - base else 0;
    const per_conn = @as(f64, @floatFromInt(delta)) / @as(f64, @floatFromInt(@max(1, n)));
    return .{
        .line = line orelse return error.MissingClientMetric,
        .per_conn_kb = try std.fmt.allocPrint(ctx.arena, "{d:.1}", .{per_conn}),
    };
}

/// Cold start: spawn a fresh client in `cold` mode and time from just-before
/// spawn to the `cold-done` marker. Repeat `samples` times, return the median
/// (ms, two decimals, arena-owned).
fn runCold(ctx: *Ctx, def: ClientDef, port: u16, samples: usize) ![]const u8 {
    const times = try ctx.arena.alloc(f64, samples);
    for (0..samples) |i| {
        const argv = try buildArgv(ctx, def, "cold", port, 1);
        const t0 = nowNs(ctx.io);
        var child = try spawnOn(ctx, cores(ctx, .client), .{
            .argv = argv,
            .environ_map = ctx.environ,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        defer child.kill(ctx.io);
        const out_file = child.stdout orelse return error.NoClientStdout;
        var buf: [4096]u8 = undefined;
        var reader = out_file.readerStreaming(ctx.io, &buf);
        var found = false;
        while (true) {
            // tolerant: the end of the client's output ends the read, and the missing cold-done marker below fails the run.
            const l = reader.interface.takeDelimiterInclusive('\n') catch break;
            if (std.mem.indexOf(u8, l, "cold-done") != null) {
                found = true;
                break;
            }
        }
        if (!found) {
            const term = try child.wait(ctx.io);
            try checkExit(def, "cold", term);
            return error.MissingColdMarker;
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
/// live-set floor, not a process caught mid-collection). A sample that cannot
/// be read is skipped, and a run with no readable sample fails.
fn sampleMinRss(ctx: *Ctx, pid: std.posix.pid_t, samples: usize, dt_ms: i64) !u64 {
    var best: ?u64 = null;
    for (0..samples) |_| {
        if (readVmRssKb(ctx, pid)) |s| best = if (best) |b| @min(b, s) else s;
        try ctx.io.sleep(std.Io.Duration.fromMilliseconds(dt_ms), .awake);
    }
    return best orelse error.RssUnreadable;
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
        const nread = reader.interface.readSliceShort(scratch[len..]) catch return null;
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

pub fn out(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    try stdout.interface.print(fmt, args);
    try stdout.interface.flush();
}
