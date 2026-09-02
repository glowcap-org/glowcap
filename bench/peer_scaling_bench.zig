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
//! are a shared backend-owned pool (`BackendOptions.read_buffers`, default 256 x
//! 16 KiB, about 4 MiB total), so an idle connection holds zero read-buffer
//! bytes and the 500k extrapolation below is the warmed footprint plus
//! one pool. The opt-in live phase complements that marginal-state figure with
//! process RSS from real loopback sockets: every unique signed session fetches
//! a published capability and remains open at the measurement barrier.
//!
//! Run `zig build bench-peer-scaling` to measure and write the report under
//! `zig-out/bench-reports/`. The `--smoke` argument (used by `zig build check`)
//! runs a tiny sample and skips the report write.

const std = @import("std");

const live = @import("peer_scaling/live.zig");
const report = @import("peer_scaling/report.zig");
const glowcap = @import("glowcap");

const engine = glowcap.ocapn.engine;
const actors = glowcap.actors;
const driver = glowcap.driver;
const model = glowcap.ocapn.model;

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

pub const target_connections: u64 = 500_000;

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

pub const Scenario = enum {
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

pub const Measurement = struct {
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
    // held in untracked memory so only each connection's session heap and the
    // scenario's one shared Vat count toward the footprint, never these
    // bookkeeping slices. Stable
    // addresses also let each serve core borrow its peer
    // (`Served.over(&peers[i])`).
    const peers = try backing.alloc(engine.Peer, sample);
    defer backing.free(peers);
    const serveds: []driver.Served = if (holds_vat) try backing.alloc(driver.Served, sample) else &.{};
    defer if (holds_vat) backing.free(serveds);
    var shared_vat = actors.Vat.init(tracked);
    defer shared_vat.deinit();

    const before = tracker.liveBytes();
    var created: u64 = 0;
    errdefer {
        var j: u64 = 0;
        while (j < created) : (j += 1) {
            if (holds_vat) serveds[j].deinit(&shared_vat);
            peers[j].deinit();
        }
    }
    while (created < sample) : (created += 1) {
        peers[created] = engine.Peer.init(tracked);
        try warmPeer(&peers[created], scenario);
        if (holds_vat) {
            serveds[created] = driver.Served.over(tracked, &peers[created]);
            _ = try serveds[created].publish(&shared_vat, "greeter", BenchGreeter, .{});
        }
    }
    const after = tracker.liveBytes();

    var i: u64 = 0;
    while (i < sample) : (i += 1) {
        if (holds_vat) serveds[i].deinit(&shared_vat);
        peers[i].deinit();
    }

    // The inline per-connection cost is the `Peer` struct, plus the `Served`
    // serve core for a loop-served connection — the loop host holds both inline
    // in its slot, and `Served` is what it actually holds (the vat plus the
    // bounded partner-abort retention), so sizing the bare `Vat` would
    // under-count the real slot.
    //
    // The `completion.Loop` wrapper (`Conn`) adds 144 bytes of its own slot
    // bookkeeping on top of this — the outbound queue's two `ArrayList` headers,
    // the spill header, the link pair the free, starved, and parked lists share,
    // and the in-flight and app-context words — held inline in `conns[]` and
    // knowingly *not* in this figure. That overhead is held separately by
    // `conn_slot_overhead_bytes` in `net/completion/loop/state.zig`, so the two guards
    // partition the slot: this bench tracks `Peer` + `Served`, that constant
    // tracks the wrapper. `source-check` holds the number the same in all three
    // places that state it.
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

pub fn gib(bytes: f64) f64 {
    return bytes / (1024.0 * 1024.0 * 1024.0);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // Match the allocator used by the production C context and the other
    // concurrent benches. Giving every session the page allocator turns each
    // small protocol allocation into page-granular RSS and measures allocator
    // fragmentation rather than Glowcap's live state.
    const backing = std.heap.smp_allocator;

    // `--smoke` (used by `zig build check`) runs a tiny sample and skips the
    // report write: a correctness gate proves the bench still runs without doing
    // report work or writing artifacts. Check also passes `--live --live-max=8`
    // so the two-process socket barrier stays exercised cheaply. The full run
    // (`zig build bench-peer-scaling`)
    // uses the large sample and writes the markdown and SVG report. Opt-in
    // `--live` runs Phase 2 with separate completion-loop server and load
    // processes at stepped N; `--live-max=N` caps the largest step (default
    // 10000). The footprint *budget* is held by
    // `test/engine/footprint_budget_test.zig`; this bench is the human-facing
    // report, not the gate.
    var args = std.process.Args.Iterator.init(init.minimal.args);
    const executable = args.next() orelse return error.MissingExecutablePath;
    var smoke = false;
    var run_live = false;
    var live_max: usize = 10_000;
    var worker_options = live.WorkerOptions{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) {
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--live")) {
            run_live = true;
        } else if (std.mem.startsWith(u8, arg, "--live-max=")) {
            live_max = try std.fmt.parseInt(usize, arg["--live-max=".len..], 10);
        } else if (!try live.parseWorkerArg(&worker_options, arg)) return error.UnknownArgument;
    }
    if (worker_options.active()) {
        if (smoke or run_live or live_max != 10_000) return error.AmbiguousLiveWorker;
        return live.runWorker(io, backing, worker_options);
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

    if (run_live) {
        try live.run(io, backing, executable, smoke, live_max);
    } else if (smoke) {
        std.debug.print("peer_scaling phase2: skipped (pass --live for TCP loopback scale measurement)\n", .{});
    }

    if (smoke) return;

    try report.writeReport(backing, io, &results);
    std.debug.print("peer_scaling report written to zig-out/bench-reports/peer-scaling.md\n", .{});
}
