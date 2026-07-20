//! Per-connection memory footprint, and what it means for a 500k-connection
//! server.
//!
//! The binding constraint on a high-fan-out OCapN server is not CPU. It is the
//! heap a single idle connection costs, multiplied by the connection count. This
//! benchmark measures that cost the way the sans-io core makes possible: it
//! stands up thousands of `engine.Peer`s in-process, with no sockets and no
//! event loop, drives each through representative traffic, and divides the live
//! heap by the peer count to get the marginal bytes one more connection adds.
//! From that single number it extrapolates to 500k and reports how many
//! connections fit in common RAM sizes.
//!
//! This measures core *peer state* only, and since ADR-0054 the core state is
//! also the dominant per-connection cost: the completion loop's read buffers
//! are a shared backend-owned pool (`Options.read_buffers`, default 256 x
//! 16 KiB, about 4 MiB total), so an idle connection holds zero read-buffer
//! bytes and the 500k extrapolation below is the warmed footprint plus
//! one pool. Real socket-level RSS and syscall-rate figures under load
//! still need a live measurement; the loop itself has shipped.
//!
//! Run `zig build bench-peer-scaling` to measure and write the report under
//! `zig-out/bench-reports/`. The `--smoke` argument (used by `zig build check`)
//! runs a tiny sample and skips the report write.

const std = @import("std");
const pancake = @import("pancake");

const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const model = pancake.ocapn.model;
const net = pancake.net;

/// A trivial published capability, so the `served` scenario's vat holds one live
/// actor cell, the per-connection state a loop-driven host (ADR-0057) carries
/// on top of the bare `engine.Peer`.
const BenchGreeter = struct {
    pub fn handle(self: *BenchGreeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        _ = msg;
        return .{ .string = "ok" };
    }
};

const target_connections: u64 = 500_000;

/// Tracks live (outstanding) heap bytes by accumulating the signed delta of every
/// allocator operation. Live bytes after peers are constructed and warmed, with
/// every transient event frame already freed, is the steady-state heap they hold.
const LiveBytesAllocator = struct {
    backing: std.mem.Allocator,
    live: i128 = 0,

    fn allocator(self: *LiveBytesAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
        };
    }

    fn note(self: *LiveBytesAllocator, delta: i128) void {
        self.live += delta;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *LiveBytesAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, alignment, ret_addr);
        if (result != null) self.note(@intCast(len));
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *LiveBytesAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.backing.rawResize(memory, alignment, new_len, ret_addr);
        if (ok) self.note(@as(i128, @intCast(new_len)) - @as(i128, @intCast(memory.len)));
        return ok;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *LiveBytesAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null) self.note(@as(i128, @intCast(new_len)) - @as(i128, @intCast(memory.len)));
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *LiveBytesAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
        self.note(-@as(i128, @intCast(memory.len)));
    }

    fn liveBytes(self: *const LiveBytesAllocator) u64 {
        return if (self.live < 0) 0 else @intCast(self.live);
    }
};

/// One inbound no-answer (`#f` answer position) `op:deliver` to live local
/// export 7, the steady-state turn the alloc-budget test pins. Driving it once
/// grows a peer's event-queue and table backing arrays to their warmed size, so
/// the measured footprint reflects a connection that has actually carried
/// traffic rather than a bare `init`.
const deliver_to_live_export = "<10'op:deliver<11'desc:export7+>[5:hello]ff>";

const Scenario = enum {
    /// Freshly constructed peer: a connection accepted but not yet active.
    idle,
    /// One export registered and one deliver turn driven: a connection that has
    /// exchanged a message and settled.
    warmed,
    /// Sixteen exports registered plus a driven turn: a connection holding a
    /// handful of live capabilities.
    active16,
    /// The loop-driven path (ADR-0057): a warmed peer plus the `driver.Served`
    /// serve core (the vat and the bounded partner-abort retention) with one
    /// published capability, the slot a bridged completion loop
    /// (`iroh.Backend` + `driver.Bridge` + Host) holds per connection. This is
    /// the marginal cost a connection
    /// adds when served from one loop thread rather than a thread of its own, the
    /// number the `iroh-loop` gate proves at scale.
    served,
};

/// True for scenarios whose per-connection state includes a vat, not just a peer.
fn scenarioHoldsVat(s: Scenario) bool {
    return s == .served;
}

fn warmPeer(peer: *engine.Peer, scenario: Scenario) !void {
    switch (scenario) {
        .idle => {},
        .warmed, .served => {
            try peer.exportObject(7);
            try driveOneTurn(peer);
        },
        .active16 => {
            var i: u64 = 0;
            while (i < 16) : (i += 1) try peer.exportObject(i + 1);
            // Export 7 is among the sixteen, so the fixed deliver lands on a live target.
            try driveOneTurn(peer);
        },
    }
}

fn driveOneTurn(peer: *engine.Peer) !void {
    try peer.recvBorrowed(.{ .bytes = deliver_to_live_export, .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
}

const Measurement = struct {
    scenario: Scenario,
    sample: u64,
    /// Marginal steady-state heap bytes one more connection of this kind adds.
    heap_per_peer: f64,
    /// Inline per-connection struct bytes: `Peer`, plus the `Served` serve core
    /// for a loop-served connection. Held in the host's per-connection slot,
    /// not on the heap.
    inline_bytes: f64,
    /// Total per-connection bytes: the inline struct(s) plus marginal heap.
    bytes_per_conn: f64,
};

/// Stand up `sample` peers of one scenario, hold them all live, and divide the
/// resulting live heap by the count. Holding them simultaneously (rather than
/// measuring one in isolation) amortizes the allocator's chunked growth across
/// the set, so the quotient is the true marginal cost of one more connection.
fn measure(backing: std.mem.Allocator, scenario: Scenario, sample: u64) !Measurement {
    var tracker = LiveBytesAllocator{ .backing = backing };
    const tracked = tracker.allocator();

    const holds_vat = scenarioHoldsVat(scenario);

    // The arrays of peers (and, for the loop-driven scenario, serve cores) are
    // held in untracked memory so only each connection's own session and vat heap
    // counts toward the footprint, never these bookkeeping slices. Stable
    // addresses also let each serve core borrow its peer
    // (`Served.over(&peers[i])`).
    const peers = try backing.alloc(engine.Peer, sample);
    defer backing.free(peers);
    const serveds: []driver.Served = if (holds_vat) try backing.alloc(driver.Served, sample) else &.{};
    defer if (holds_vat) backing.free(serveds);

    const before = tracker.liveBytes();
    var created: u64 = 0;
    errdefer {
        var j: u64 = 0;
        while (j < created) : (j += 1) {
            if (holds_vat) serveds[j].deinit();
            peers[j].deinit();
        }
    }
    while (created < sample) : (created += 1) {
        peers[created] = engine.Peer.init(tracked);
        try warmPeer(&peers[created], scenario);
        if (holds_vat) {
            serveds[created] = driver.Served.over(tracked, &peers[created]);
            _ = try serveds[created].publish("greeter", BenchGreeter, .{});
        }
    }
    const after = tracker.liveBytes();

    var i: u64 = 0;
    while (i < sample) : (i += 1) {
        if (holds_vat) serveds[i].deinit();
        peers[i].deinit();
    }

    // The inline per-connection cost is the `Peer` struct, plus the `Served`
    // serve core for a loop-served connection — the loop host holds both inline
    // in its slot, and `Served` is what it actually holds (the vat plus the
    // bounded partner-abort retention), so sizing the bare `Vat` would
    // under-count the real slot.
    //
    // The `completion.Loop` wrapper (`Conn`) adds ~112 bytes of its own slot
    // bookkeeping on top of this — the outbound queue's two `ArrayList` headers,
    // the spill header, the intrusive free/starved link, and the in-flight and
    // app-context words — held inline in `conns[]` and knowingly *not* in this
    // figure. That overhead is gated separately by the `conn_slot_overhead_bytes`
    // ceiling in `net/completion/loop.zig`, so the two guards partition the slot:
    // this bench tracks `Peer` + `Served`, the ceiling tracks the wrapper.
    const vat_inline: usize = if (holds_vat) @sizeOf(driver.Served) else 0;
    const inline_bytes: f64 = @floatFromInt(@sizeOf(engine.Peer) + vat_inline);
    const heap_per_peer = @as(f64, @floatFromInt(after - before)) / @as(f64, @floatFromInt(sample));
    return .{
        .scenario = scenario,
        .sample = sample,
        .heap_per_peer = heap_per_peer,
        .inline_bytes = inline_bytes,
        .bytes_per_conn = heap_per_peer + inline_bytes,
    };
}

fn gib(bytes: f64) f64 {
    return bytes / (1024.0 * 1024.0 * 1024.0);
}

const TcpBridge = driver.Bridge(net.TcpLoop);
const live_frame_cap: usize = 4096;
const live_greeting = "peer-scaling live";
const live_calls_per_conn: usize = 2;

const LiveGreeter = struct {
    pub fn handle(self: *LiveGreeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "greet")) return error.NoSuchMethod;
        return .{ .string = live_greeting };
    }
};

fn livePublishGreeter(ctx: ?*anyopaque, served: *driver.Served) anyerror!void {
    _ = ctx;
    _ = try served.publish("greeter", LiveGreeter, .{});
}

fn liveRssKb(io: std.Io) u64 {
    // Linux: VmRSS from /proc/self/status. Other platforms report 0 (unknown).
    var file = std.Io.Dir.cwd().openFile(io, "/proc/self/status", .{}) catch return 0;
    defer file.close(io);
    var rbuf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &rbuf);
    var scratch: [8192]u8 = undefined;
    var len: usize = 0;
    while (len < scratch.len) {
        const nread = reader.interface.readSliceShort(scratch[len..]) catch break;
        if (nread == 0) break;
        len += nread;
    }
    const text = scratch[0..len];
    const at = std.mem.indexOf(u8, text, "VmRSS:") orelse return 0;
    var i = at + "VmRSS:".len;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    const start = i;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') i += 1;
    return std.fmt.parseInt(u64, text[start..i], 10) catch 0;
}

fn liveNowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}

fn liveRunLoop(loop: *net.TcpLoop, until_closed: usize, out_err: *?anyerror) void {
    loop.run(.{ .after_closed = until_closed }) catch |err| {
        out_err.* = err;
    };
}

fn liveClientOnce(io: std.Io, allocator: std.mem.Allocator, port: u16) anyerror!void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = live_frame_cap;

    const read_buf = try allocator.alloc(u8, live_frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, live_frame_cap);
    defer allocator.free(write_buf);

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var cv = try driver.connectTcp(allocator, io, &peer, address, read_buf, write_buf);
    defer cv.deinit();

    const greeter = try cv.fetch("greeter");
    var i: usize = 0;
    while (i < live_calls_per_conn) : (i += 1) {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const settled = try cv.call(greeter, .{ .verb = "greet", .args = &.{} }, arena_state.allocator());
        const ok = switch (settled) {
            .fulfilled => |arg| arg == .string and std.mem.eql(u8, arg.string, live_greeting),
            .broken, .give => false,
        };
        if (!ok) return error.WrongReply;
    }
}

/// Phase 2: TCP loopback on `completion.Loop` + `driver.Bridge` at stepped N.
/// Opt-in (`--live`); not under `zig build check`. Smoke + `--live` with a
/// small `--live-max` still exercises the path; tiny N prints a stub note.
fn runLivePhase(parent_io: std.Io, allocator: std.mem.Allocator, smoke: bool, live_max: usize) !void {
    _ = parent_io;
    const steps_src = [_]usize{ 1_000, 10_000, 50_000, 100_000, 500_000 };
    var steps_buf: [steps_src.len]usize = undefined;
    var step_count: usize = 0;
    for (steps_src) |n| {
        if (n > live_max) break;
        steps_buf[step_count] = n;
        step_count += 1;
    }
    if (step_count == 0) {
        // Cap below the first step: still run one small measurement so the
        // harness stays honest under `--live-max` / smoke dry-runs.
        steps_buf[0] = @min(live_max, if (smoke) @as(usize, 8) else @as(usize, 64));
        if (steps_buf[0] == 0) {
            std.debug.print("peer_scaling phase2: skipped (live-max=0)\n", .{});
            return;
        }
        step_count = 1;
        std.debug.print(
            "peer_scaling phase2: live-max={d} below stepped schedule; measuring N={d} only\n",
            .{ live_max, steps_buf[0] },
        );
    }
    const steps = steps_buf[0..step_count];

    std.debug.print(
        "peer_scaling phase2: TCP loopback on completion.Loop + driver.Bridge (opt-in; not under check)\n",
        .{},
    );

    for (steps) |n| {
        var threaded = std.Io.Threaded.init(allocator, .{});
        defer threaded.deinit();
        const step_io = threaded.io();

        var host = driver.core.Host.init(allocator, [_]u8{0x42} ** 32, .{
            .limits = .{ .max_frame_bytes = live_frame_cap },
            .local_turn_budget = actors.Vat.max_batch_local_turns,
        });
        defer host.deinit();
        var loop: net.TcpLoop = undefined;
        var bridge = TcpBridge.init(allocator, &host, step_io, &loop, .{ .publish = livePublishGreeter });
        defer bridge.deinit();

        loop = try net.TcpLoop.init(allocator, TcpBridge.makePeer, @ptrCast(&bridge), TcpBridge.hookOptions(.{
            .frame_cap = live_frame_cap,
            .max_conns = n + 8,
            .listen = 0,
        }));
        defer loop.deinit();
        const port = loop.port.?;
        var designator_buf: [net.tcp.designator_buf_len]u8 = undefined;
        const designator_addr = try net.tcp.parseHostPort("127.0.0.1", port);
        const designator = net.tcp.locator(&designator_buf, designator_addr).designator;
        try bridge.attach(net.tcp.transport_name, designator, &.{});

        var loop_err: ?anyerror = null;
        var loop_future = try step_io.concurrent(liveRunLoop, .{ &loop, n, &loop_err });

        const rss_before = liveRssKb(step_io);
        const t0 = liveNowNs(step_io);

        const Future = @TypeOf(step_io.concurrent(liveClientOnce, .{ step_io, allocator, port }) catch unreachable);
        const futures = try allocator.alloc(Future, n);
        defer allocator.free(futures);
        var spawned: usize = 0;
        var first_err: ?anyerror = null;
        for (futures) |*f| {
            f.* = step_io.concurrent(liveClientOnce, .{ step_io, allocator, port }) catch |err| {
                if (first_err == null) first_err = err;
                break;
            };
            spawned += 1;
        }
        var successes: usize = 0;
        var i: usize = 0;
        while (i < spawned) : (i += 1) {
            futures[i].await(step_io) catch |err| {
                if (first_err == null) first_err = err;
                continue;
            };
            successes += 1;
        }

        loop_future.await(step_io);
        const t1 = liveNowNs(step_io);
        const rss_after = liveRssKb(step_io);

        if (loop_err) |err| return err;
        const elapsed_ns: u64 = @intCast(@max(t1 - t0, 0));
        const turns = successes * live_calls_per_conn;
        const ns_per_turn: u64 = if (turns == 0) 0 else elapsed_ns / turns;
        const rss_delta = if (rss_after >= rss_before) rss_after - rss_before else 0;

        std.debug.print(
            "peer_scaling phase2 n={d} ok={s} connected={d}/{d} rss_kb_before={d} rss_kb_after={d} rss_delta_kb={d} elapsed_ms={d} ns_per_turn={d}\n",
            .{
                n,
                if (first_err == null and successes == n) "true" else "false",
                successes,
                n,
                rss_before,
                rss_after,
                rss_delta,
                elapsed_ns / 1_000_000,
                ns_per_turn,
            },
        );
        if (first_err) |err| return err;
        if (successes != n) return error.LiveConnectShortfall;
    }
}

fn scenarioLabel(s: Scenario) []const u8 {
    return switch (s) {
        .idle => "idle (just accepted)",
        .warmed => "warmed (one turn carried)",
        .active16 => "active (16 capabilities held)",
        .served => "served (loop host: peer + vat + cap)",
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const backing = std.heap.page_allocator;

    // `--smoke` (used by `zig build check`) runs a tiny sample and skips the
    // report write: a correctness gate proves the bench still runs without doing
    // report work or writing artifacts. The full run (`zig build bench-peer-scaling`)
    // uses the large sample and writes the markdown and SVG report. Opt-in
    // `--live` runs Phase 2 (TCP loopback on completion.Loop + Bridge) at
    // stepped N; `--live-max=N` caps the largest step (default 10000). Neither
    // live flag is part of `check`. The footprint *budget* is held by
    // `test/engine/footprint_budget_test.zig`; this bench is the human-facing
    // report, not the gate.
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // program name
    var smoke = false;
    var live = false;
    var live_max: usize = 10_000;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) {
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--live")) {
            live = true;
        } else if (std.mem.startsWith(u8, arg, "--live-max=")) {
            live_max = try std.fmt.parseInt(usize, arg["--live-max=".len..], 10);
        }
    }

    const sample: u64 = if (smoke) 64 else 2000;

    const scenarios = [_]Scenario{ .idle, .warmed, .active16, .served };
    var results: [scenarios.len]Measurement = undefined;
    for (scenarios, 0..) |scenario, idx| {
        results[idx] = try measure(backing, scenario, sample);
        const m = results[idx];
        std.debug.print(
            "peer_scaling scenario={s} sample={d} inline_struct_bytes={d:.0} heap_per_peer_bytes={d:.1} bytes_per_conn={d:.1} mem_at_500k_gib={d:.3}\n",
            .{
                @tagName(m.scenario),
                m.sample,
                m.inline_bytes,
                m.heap_per_peer,
                m.bytes_per_conn,
                gib(m.bytes_per_conn * @as(f64, @floatFromInt(target_connections))),
            },
        );
    }

    if (live) {
        try runLivePhase(io, backing, smoke, live_max);
    } else if (smoke) {
        std.debug.print("peer_scaling phase2: skipped (pass --live for TCP loopback scale measurement)\n", .{});
    }

    if (smoke) return;

    try writeReport(backing, io, &results);
    std.debug.print("peer_scaling report written to zig-out/bench-reports/peer-scaling.md\n", .{});
}

fn writeReport(gpa: std.mem.Allocator, io: std.Io, results: []const Measurement) !void {
    const svg = try renderSvg(gpa, results);
    defer gpa.free(svg);
    const md = try renderMarkdown(gpa, results);
    defer gpa.free(md);

    var dir = std.Io.Dir.cwd();
    dir.createDirPath(io, "zig-out/bench-reports") catch {};
    try dir.writeFile(io, .{ .sub_path = "zig-out/bench-reports/peer-scaling.svg", .data = svg });
    try dir.writeFile(io, .{ .sub_path = "zig-out/bench-reports/peer-scaling.md", .data = md });
}

fn appendFmt(b: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(s);
    try b.appendSlice(gpa, s);
}

fn renderMarkdown(gpa: std.mem.Allocator, results: []const Measurement) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);

    try b.appendSlice(gpa,
        \\# Per-connection memory footprint at 500k
        \\
        \\Generated by `zig build bench-peer-scaling`. This is Phase 1 of the
        \\500k-connection study: the memory-per-connection constraint, measured
        \\in-process with no sockets. Because the protocol core is sans-io, a
        \\connection's cost is one `engine.Peer` plus its session heap (and, when
        \\served from the completion loop, an `actors.Vat`). That means thousands
        \\of connections can be stood up, warmed, and weighed without a transport.
        \\
        \\## Method
        \\
        \\For each scenario, the benchmark constructs `sample` peers under a
        \\live-bytes-tracking allocator, drives each through representative
        \\traffic, holds them all simultaneously, and divides the resulting live
        \\heap by the count. Holding them together amortizes the allocator's
        \\chunked growth, so the quotient is the marginal cost of one more
        \\connection. The inline `Peer` struct size is added to get the total
        \\per-connection footprint.
        \\
        \\
    );

    try appendFmt(&b, gpa, "`Peer` struct (inline, includes session table headers): **{d} bytes**\n\n", .{@sizeOf(engine.Peer)});

    try b.appendSlice(gpa,
        \\## Results
        \\
        \\| Scenario | sample | heap/peer (B) | total/conn (B) | 500k (GiB) | fits 16 GiB | fits 32 GiB | fits 64 GiB |
        \\| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
        \\
    );

    for (results) |m| {
        const per = m.bytes_per_conn;
        const at500k = gib(per * @as(f64, @floatFromInt(target_connections)));
        const fit16 = (16.0 * 1024.0 * 1024.0 * 1024.0) / per;
        const fit32 = (32.0 * 1024.0 * 1024.0 * 1024.0) / per;
        const fit64 = (64.0 * 1024.0 * 1024.0 * 1024.0) / per;
        try appendFmt(&b, gpa, "| {s} | {d} | {d:.0} | {d:.0} | {d:.3} | {d:.2}M | {d:.2}M | {d:.2}M |\n", .{
            scenarioLabel(m.scenario), m.sample,            m.heap_per_peer,     per, at500k,
            fit16 / 1_000_000.0,       fit32 / 1_000_000.0, fit64 / 1_000_000.0,
        });
    }

    try b.appendSlice(gpa,
        \\
        \\The "fits" columns are connections (millions) of that kind that the
        \\core state alone fits in that RAM, ignoring transport buffers.
        \\
        \\## The loop-driven path (ADR-0057)
        \\
        \\The `served` row is the per-connection cost when a connection is served
        \\from one completion-loop thread (`iroh.Backend` + Bridge) instead
        \\of a thread of its own: a warmed `engine.Peer` plus the `actors.Vat`,
        \\with one published capability, that the host holds inline in its
        \\per-connection slot. The `iroh-loop` gate proves that one thread serves
        \\many concurrent iroh connections from the sidecar's readiness fd,
        \\drained ready-queue, and non-blocking frame I/O; this row reports what
        \\one such connection costs, and the gate proves the multiplexing, not the
        \\bytes. The blocking thread-per-connection path (ADR-0053) adds the same
        \\core state *plus* an OS thread (or two) per connection — megabytes of
        \\stack each — which is exactly what the loop removes.
        \\
        \\## Transport buffers (the part the loop owns)
        \\
        \\Since ADR-0054 the core state above is also the dominant
        \\per-connection cost. The completion loop's read buffers are a shared
        \\backend-owned pool (`Options.read_buffers`, default 256 x 16 KiB,
        \\about 4 MiB total), so an idle connection holds zero read-buffer
        \\bytes; a frame larger than a pool buffer, or split across reads,
        \\rides the bounded spill that frees on drain (ADR-0041). The warmed
        \\footprint at 500k is the core state plus one pool.
        \\
        \\For the iroh loop path the sidecar adds its own per-connection bytes,
        \\in the Rust heap rather than this measurement: each non-blocking
        \\connection buffers inbound and outbound bytes, each direction bounded
        \\at 1 MiB (`NB_BUFFER_BOUND`) as a burst ceiling — a full inbound
        \\buffer parks the sidecar's reader so QUIC flow control reaches the
        \\remote sender, and a full outbound buffer returns `WOULD_BLOCK` to
        \\the loop. So the bound is a flow-control ceiling, never a silent drop
        \\or an unbounded queue. Steady retention is far below the ceiling:
        \\the reader borrows QUIC segments zero-copy (no resident scratch),
        \\outbound batches are taken by move and their storage drops once
        \\flushed, and inbound burst capacity frees down to a 16 KiB steady
        \\bound (`NB_STEADY_BYTES`) when the loop drains the buffer empty,
        \\mirroring the loop's own burst-frees-on-drain posture.
        \\
        \\![per-connection memory to 500k](peer-scaling.svg)
        \\
        \\## Phase 2 (real socket load)
        \\
        \\Opt-in: `zig build bench-peer-scaling -- --live` (and optional
        \\`--live-max=N`) drives TCP loopback on `completion.Loop` +
        \\`driver.Bridge` (the same substrate as `zig build tcp-loop`) at
        \\stepped connection counts, printing RSS, connect success, and
        \\ns/turn. It is not part of `zig build check`; smoke mode skips the
        \\live leg. Full-target ~500k runs need machine ulimit headroom — the
        \\harness exists; the number it prints at your `--live-max` is
        \\measured, while the `served` row above remains the in-process
        \\extrapolation.
        \\
    );

    return b.toOwnedSlice(gpa);
}

const svg_w: f64 = 820;
const svg_h: f64 = 480;
const plot_l: f64 = 70;
const plot_r: f64 = 600;
const plot_t: f64 = 48;
const plot_b: f64 = 410;
const x_max: f64 = 600_000;

fn xCoord(conns: f64) f64 {
    return plot_l + (conns / x_max) * (plot_r - plot_l);
}

fn yCoord(gib_val: f64, y_max: f64) f64 {
    return plot_b - (gib_val / y_max) * (plot_b - plot_t);
}

fn renderSvg(gpa: std.mem.Allocator, results: []const Measurement) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);

    // y-axis ceiling: 15% headroom over the tallest line at the right edge.
    var top_gib: f64 = 0;
    for (results) |m| {
        const v = gib(m.bytes_per_conn * x_max);
        if (v > top_gib) top_gib = v;
    }
    const y_max = if (top_gib <= 0) 1.0 else top_gib * 1.15;

    const colors = [_][]const u8{ "#2563eb", "#16a34a", "#dc2626", "#9333ea" };

    try appendFmt(&b, gpa,
        \\<svg xmlns="http://www.w3.org/2000/svg" width="{d:.0}" height="{d:.0}" font-family="sans-serif" font-size="13">
        \\<rect width="{d:.0}" height="{d:.0}" fill="white"/>
        \\<text x="{d:.0}" y="26" font-size="16" font-weight="bold">pancake: per-connection memory to 500k (protocol core only)</text>
        \\
    , .{ svg_w, svg_h, svg_w, svg_h, plot_l });

    // Axes.
    try appendFmt(&b, gpa,
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#333" stroke-width="1.5"/>
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#333" stroke-width="1.5"/>
        \\
    , .{ plot_l, plot_t, plot_l, plot_b, plot_l, plot_b, plot_r, plot_b });

    // Horizontal gridlines + y labels (GiB), 4 divisions.
    var g: usize = 0;
    while (g <= 4) : (g += 1) {
        const val = y_max * @as(f64, @floatFromInt(g)) / 4.0;
        const y = yCoord(val, y_max);
        try appendFmt(&b, gpa,
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#eee"/>
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="end" fill="#555">{d:.2} GiB</text>
            \\
        , .{ plot_l, y, plot_r, y, plot_l - 8, y + 4, val });
    }

    // X labels at 0,100k..600k.
    var x: usize = 0;
    while (x <= 6) : (x += 1) {
        const conns = @as(f64, @floatFromInt(x)) * 100_000.0;
        const px = xCoord(conns);
        try appendFmt(&b, gpa,
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" fill="#555">{d:.0}k</text>
            \\
        , .{ px, plot_b + 18, conns / 1000.0 });
    }
    try appendFmt(&b, gpa,
        \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" fill="#333">connections</text>
        \\
    , .{ (plot_l + plot_r) / 2.0, plot_b + 38 });

    // 500k marker.
    const x500 = xCoord(@floatFromInt(target_connections));
    try appendFmt(&b, gpa,
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#999" stroke-width="1" stroke-dasharray="4 3"/>
        \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" fill="#666">500k</text>
        \\
    , .{ x500, plot_t, x500, plot_b, x500, plot_t - 6 });

    // One straight line per scenario (footprint is linear in connection count),
    // with the 500k value labeled at the marker.
    for (results, 0..) |m, idx| {
        const color = colors[idx % colors.len];
        const y0 = yCoord(0, y_max);
        const yEnd = yCoord(gib(m.bytes_per_conn * x_max), y_max);
        try appendFmt(&b, gpa,
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="2.5"/>
            \\
        , .{ xCoord(0), y0, xCoord(x_max), yEnd, color });

        const y500 = yCoord(gib(m.bytes_per_conn * @as(f64, @floatFromInt(target_connections))), y_max);
        try appendFmt(&b, gpa,
            \\<circle cx="{d:.1}" cy="{d:.1}" r="3.5" fill="{s}"/>
            \\
        , .{ x500, y500, color });

        // Legend entry.
        const ly = plot_t + 6 + @as(f64, @floatFromInt(idx)) * 22.0;
        try appendFmt(&b, gpa,
            \\<rect x="{d:.1}" y="{d:.1}" width="14" height="14" fill="{s}"/>
            \\<text x="{d:.1}" y="{d:.1}" fill="#222">{s}, {d:.2} GiB @ 500k</text>
            \\
        , .{ plot_r + 14, ly, color, plot_r + 32, ly + 12, scenarioLabel(m.scenario), gib(m.bytes_per_conn * @as(f64, @floatFromInt(target_connections))) });
    }

    try b.appendSlice(gpa, "</svg>\n");
    return b.toOwnedSlice(gpa);
}
