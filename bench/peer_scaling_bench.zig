//! Per-connection memory footprint, and what it means for a 500k-connection
//! server.
//!
//! The binding constraint on a high-fan-out OCapN server is not CPU — it is the
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

const target_connections: u64 = 500_000;
const ram_sizes_gb = [_]u64{ 16, 32, 64, 128 };

/// Tracks live (outstanding) heap bytes and the peak, by accumulating the signed
/// delta of every allocator operation. Live bytes after a set of peers are
/// constructed and warmed, with every transient event frame already freed, is the
/// steady-state heap those peers hold.
const LiveBytesAllocator = struct {
    backing: std.mem.Allocator,
    live: i128 = 0,
    peak: i128 = 0,

    fn allocator(self: *LiveBytesAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
        };
    }

    fn note(self: *LiveBytesAllocator, delta: i128) void {
        self.live += delta;
        if (self.live > self.peak) self.peak = self.live;
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

/// One inbound `op:deliver` to live local export 7, the steady-state turn the
/// alloc-budget test pins. Driving it once grows a peer's event-queue and table
/// backing arrays to their warmed size, so the measured footprint reflects a
/// connection that has actually carried traffic rather than a bare `init`.
const deliver_to_live_export = "<10'op:deliver<11'desc:export7+>[5:hello]11+f>";

const Scenario = enum {
    /// Freshly constructed peer: a connection accepted but not yet active.
    idle,
    /// One export registered and one deliver turn driven: a connection that has
    /// exchanged a message and settled.
    warmed,
    /// Sixteen exports registered plus a driven turn: a connection holding a
    /// handful of live capabilities.
    active16,
};

fn warmPeer(peer: *engine.Peer, scenario: Scenario) !void {
    switch (scenario) {
        .idle => {},
        .warmed => {
            try peer.session_state.registerExport(7);
            try driveOneTurn(peer);
        },
        .active16 => {
            var i: u64 = 0;
            while (i < 16) : (i += 1) try peer.session_state.registerExport(i + 1);
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
    /// Total per-connection bytes: the inline `Peer` struct plus marginal heap.
    bytes_per_conn: f64,
};

/// Stand up `sample` peers of one scenario, hold them all live, and divide the
/// resulting live heap by the count. Holding them simultaneously (rather than
/// measuring one in isolation) amortizes the allocator's chunked growth across
/// the set, so the quotient is the true marginal cost of one more connection.
fn measure(backing: std.mem.Allocator, scenario: Scenario, sample: u64) !Measurement {
    var tracker = LiveBytesAllocator{ .backing = backing };
    const tracked = tracker.allocator();

    // The array of peers is held in untracked memory so only each peer's own
    // session heap counts toward the footprint, never this bookkeeping slice.
    const peers = try backing.alloc(engine.Peer, sample);
    defer backing.free(peers);

    const before = tracker.liveBytes();
    var created: u64 = 0;
    errdefer {
        var j: u64 = 0;
        while (j < created) : (j += 1) peers[j].deinit();
    }
    while (created < sample) : (created += 1) {
        peers[created] = engine.Peer.init(tracked);
        try warmPeer(&peers[created], scenario);
    }
    const after = tracker.liveBytes();

    var i: u64 = 0;
    while (i < sample) : (i += 1) peers[i].deinit();

    const heap_per_peer = @as(f64, @floatFromInt(after - before)) / @as(f64, @floatFromInt(sample));
    return .{
        .scenario = scenario,
        .sample = sample,
        .heap_per_peer = heap_per_peer,
        .bytes_per_conn = heap_per_peer + @as(f64, @floatFromInt(@sizeOf(engine.Peer))),
    };
}

fn gib(bytes: f64) f64 {
    return bytes / (1024.0 * 1024.0 * 1024.0);
}

fn scenarioLabel(s: Scenario) []const u8 {
    return switch (s) {
        .idle => "idle (just accepted)",
        .warmed => "warmed (one turn carried)",
        .active16 => "active (16 capabilities held)",
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const backing = std.heap.page_allocator;

    // `--smoke` (used by `zig build check`) runs a tiny sample and skips the
    // report write: a correctness gate proves the bench still runs without doing
    // report work or writing artifacts. The full run (`zig build bench-peer-scaling`)
    // uses the large sample and writes the markdown and SVG report. The footprint
    // *budget* is held by `test/engine/footprint_budget_test.zig`; this bench is
    // the human-facing report, not the gate.
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // program name
    var smoke = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) smoke = true;
    }

    const sample: u64 = if (smoke) 64 else 2000;

    const scenarios = [_]Scenario{ .idle, .warmed, .active16 };
    var results: [scenarios.len]Measurement = undefined;
    for (scenarios, 0..) |scenario, idx| {
        results[idx] = try measure(backing, scenario, sample);
        const m = results[idx];
        std.debug.print(
            "peer_scaling scenario={s} sample={d} peer_struct_bytes={d} heap_per_peer_bytes={d:.1} bytes_per_conn={d:.1} mem_at_500k_gib={d:.3}\n",
            .{
                @tagName(m.scenario),
                m.sample,
                @sizeOf(engine.Peer),
                m.heap_per_peer,
                m.bytes_per_conn,
                gib(m.bytes_per_conn * @as(f64, @floatFromInt(target_connections))),
            },
        );
    }

    if (smoke) return;

    try writeReport(backing, io, &results);
    std.debug.print("peer_scaling report written to zig-out/bench-reports/peer-scaling.md\n", .{});
}

// ---------------------------------------------------------------------------
// Report rendering: a markdown report plus a hand-rolled SVG line chart. Both
// are zero-dependency strings the benchmark emits directly — no plotting crate,
// honoring the project's boring, dependency-free posture.
// ---------------------------------------------------------------------------

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
        \\connection's cost is exactly one `engine.Peer` plus its session heap.
        \\That means thousands of peers can be stood up, warmed, and weighed without a
        \\transport.
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
        \\## Transport buffers (the part the loop owns)
        \\
        \\Since ADR-0054 the core state above is also the dominant
        \\per-connection cost. The completion loop's read buffers are a shared
        \\backend-owned pool (`Options.read_buffers`, default 256 x 16 KiB,
        \\about 4 MiB total), so an idle connection holds zero read-buffer
        \\bytes; a frame larger than a pool buffer, or split across reads,
        \\rides the bounded spill that frees on drain (ADR-0041). The honest
        \\warmed footprint at 500k is the core state plus one pool.
        \\
        \\![per-connection memory to 500k](peer-scaling.svg)
        \\
        \\## Phase 2 (real socket load)
        \\
        \\The completion loop (io_uring on Linux, kqueue on macOS/BSD) has
        \\shipped, but this bench still measures in-process core state, not a
        \\loop under real socket load. Accept throughput, syscalls per turn, and
        \\resident-set growth on a live 500k-connection run still need a load
        \\harness. This report does not drive that harness yet.
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

    const colors = [_][]const u8{ "#2563eb", "#16a34a", "#dc2626" };

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
            \\<text x="{d:.1}" y="{d:.1}" fill="#222">{s} — {d:.2} GiB @ 500k</text>
            \\
        , .{ plot_r + 14, ly, color, plot_r + 32, ly + 12, scenarioLabel(m.scenario), gib(m.bytes_per_conn * @as(f64, @floatFromInt(target_connections))) });
    }

    try b.appendSlice(gpa, "</svg>\n");
    return b.toOwnedSlice(gpa);
}
