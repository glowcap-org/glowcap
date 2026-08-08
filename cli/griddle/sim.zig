//! The griddle simulator: deterministic CapTP conversations under a seeded
//! schedule.
//!
//! The protocol core is sync and does no I/O, which is what makes this
//! possible at all — a peer is a value that takes frames and hands frames
//! back, so a scheduler can own the network entirely and replay it exactly.
//! Given a seed, this runs a whole conversation and emits a timeline; the
//! same seed always produces the same timeline, byte for byte.
//!
//! What the seed varies is the *schedule*, not the wire. CapTP rides an
//! ordered transport, so frames between one pair of peers must arrive in the
//! order they were sent: reordering them would not model a slow network, it
//! would model a broken one. Each directed link therefore keeps a FIFO, and
//! the seed chooses only which link advances next. That is the real degree of
//! freedom a network has — two connections make progress in an order nobody
//! controls, while each connection stays in order — and exploring it is how a
//! seeded run finds interleavings a hand-written test would not think to try.
//!
//! The property worth having, and what `test/cli/griddle_cases.zig` holds:
//! the schedule changes with the seed and the outcome does not.
//!
//! The same rule decides what an *unreliable* network may mean here. A
//! reliable ordered transport does not drop or reorder bytes: if it cannot
//! deliver, it fails the connection. So this simulator models neither loss
//! nor reordering within a live link — those would model a broken transport
//! rather than a bad network, and would make the protocol answer for a
//! promise it never made. What a real network does to a reliable link is
//! delay it and cut it, and those are the two knobs: per-link latency, and
//! partition. Partition is the honest failure mode, and what it teaches is
//! the reason `.unbounded` is a hazard — a question sent into a cut link is
//! never answered and never refused, so only the caller's own deadline ends
//! the wait.

const std = @import("std");
const pancake = @import("pancake");

const timeline_mod = @import("timeline.zig");

pub const Event = timeline_mod.Event;
pub const Timeline = timeline_mod.Timeline;

const engine = pancake.ocapn.engine;
const model = pancake.ocapn.model;
const foundation = pancake.foundation;

/// A frame in flight, with the tick it becomes deliverable. Latency is a
/// property of the link, so `due` never goes backwards within one link and
/// the FIFO stays a FIFO.
const InFlight = struct {
    frame: foundation.Frame,
    due: u64,
};

/// One directed link's in-flight frames, oldest first. A link is ordered even
/// when the schedule is not, which is the whole point (see the module note).
const Link = struct {
    from: u8,
    to: u8,
    queue: std.ArrayList(InFlight) = .empty,
    /// Ticks a frame spends in flight on this link. Zero is the instant
    /// network the base scenarios use.
    latency: u64 = 0,
    /// A cut link. It carries nothing further, and what it was carrying is
    /// gone; the peers are not told, because a partition is exactly the
    /// failure nobody is told about until a deadline expires.
    down: bool = false,
    /// The tick this link's last frame was made due, so latency cannot
    /// reorder a link against itself.
    last_due: u64 = 0,

    fn deinit(self: *Link, gpa: std.mem.Allocator) void {
        for (self.queue.items) |*entry| entry.frame.deinit();
        self.queue.deinit(gpa);
    }
};

/// How the network misbehaves. Both knobs are things a reliable transport
/// genuinely does; see the module note for what is deliberately absent.
pub const Weather = struct {
    /// Give each link its own latency, drawn from the seed. Off by default,
    /// so the base scenarios stay the instant network.
    latency: bool = false,
    /// Cut every link at this tick, or never.
    partition_at: ?u64 = null,
    /// The widest per-link latency the seed may draw.
    pub const max_latency_ticks: u64 = 4;
};

/// How many deliveries a run may take before it is treated as a runaway. A
/// real scenario settles in a handful; this only stops a bug from spinning.
pub const max_deliveries: usize = 512;

pub const Error = error{
    /// The scenario did not reach its end state within `max_deliveries`.
    Runaway,
};

/// A two-peer conversation under a seeded schedule. Two peers is what the
/// first scenario needs; the link table is general, so a wider topology is a
/// matter of more peers and more links, not a different scheduler.
pub const Sim = struct {
    gpa: std.mem.Allocator,
    /// Borrowed: the runner owns the peers, so a live `engine.Peer` is never
    /// moved after the handshake that wired it.
    pair: *engine.pairing.Pair,
    links: [2]Link,
    prng: std.Random.DefaultPrng,
    timeline: *Timeline,
    weather: Weather = .{},
    /// The scenario's own reader of surfaced events. A CapTP answer can come
    /// back as a resolve or, under V1.0, as a deliver to the resolver export,
    /// so what counts as "the conversation finished" is the scenario's
    /// question, not the scheduler's.
    observer: ?Observer = null,

    /// A scenario's hook into delivered events: `func` sees every event a
    /// peer surfaces, in schedule order.
    pub const Observer = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, peer_id: u8, event: *engine.Event) void,
    };

    /// Build a simulation of two handshaked peers over `codec`, scheduled by
    /// `seed`, recording into `timeline`.
    pub fn init(
        gpa: std.mem.Allocator,
        pair: *engine.pairing.Pair,
        seed: u64,
        timeline: *Timeline,
        weather: Weather,
    ) !Sim {
        var sim = Sim{
            .gpa = gpa,
            .pair = pair,
            .links = .{
                .{ .from = 0, .to = 1 },
                .{ .from = 1, .to = 0 },
            },
            .prng = std.Random.DefaultPrng.init(seed),
            .timeline = timeline,
            .weather = weather,
        };
        if (weather.latency) {
            for (&sim.links) |*link| {
                link.latency = sim.prng.random().uintAtMost(u64, Weather.max_latency_ticks);
            }
        }
        try timeline.record(.{ .host_joined = .{ .id = 0 } });
        try timeline.record(.{ .host_joined = .{ .id = 1 } });
        // Announce the links before any traffic, with the latency each will
        // impose, so a consumer can draw the topology before the first frame
        // rather than inferring it from what happens to fly.
        for (&sim.links) |*link| {
            try timeline.record(.{ .link_up = .{
                .src = link.from,
                .dst = link.to,
                .latency_ms = link.latency,
            } });
        }
        return sim;
    }

    /// Release the frames still in flight. The peers belong to the runner.
    pub fn deinit(self: *Sim) void {
        for (&self.links) |*link| link.deinit(self.gpa);
    }

    fn peerById(self: *Sim, id: u8) *engine.Peer {
        return if (id == 0) &self.pair.p1 else &self.pair.p2;
    }

    /// Drain both peers' outbound frames onto their links, recording a `send`
    /// for each. Called before every scheduling decision, so a frame minted by
    /// the previous delivery is a candidate for the next one.
    fn collect(self: *Sim) !void {
        for (0..2) |i| {
            const id: u8 = @intCast(i);
            const peer = self.peerById(id);
            _ = peer.step() catch |err| try self.timeline.record(.{ .captp_failed = .{
                .id = id,
                .reason = @errorName(err),
            } });
            while (peer.takeOutbound()) |frame| {
                const link = &self.links[i];
                if (link.down) {
                    // A cut link swallows it. The sender is not told, which is
                    // the whole difficulty of a partition.
                    var lost = frame;
                    try self.timeline.record(.{ .message_lost = .{
                        .src = link.from,
                        .dst = link.to,
                        .bytes = lost.bytes().len,
                    } });
                    lost.deinit();
                    continue;
                }
                // Due no earlier than the link's previous frame: latency
                // delays a link, it never reorders one against itself.
                const earliest = self.timeline.clock + link.latency;
                const due = @max(earliest, link.last_due);
                link.last_due = due;
                try self.timeline.record(.{ .message_in_flight = .{
                    .src = link.from,
                    .dst = link.to,
                    .bytes = frame.bytes().len,
                    .arrive_ns = due * timeline_mod.ns_per_tick,
                } });
                try link.queue.append(self.gpa, .{ .frame = frame, .due = due });
            }
        }
    }

    /// What one scheduling step did. Only `delivered` is progress a runaway
    /// guard should count: advancing the clock to the next arrival is time
    /// passing, not a conversation going in circles.
    const Step = enum { delivered, advanced, idle };

    /// Deliver one frame, choosing among the links that have one.
    fn deliverOne(self: *Sim) !Step {
        var ready: [2]usize = undefined;
        var n: usize = 0;
        var earliest_pending: ?u64 = null;
        for (&self.links, 0..) |*link, i| {
            const head = if (link.queue.items.len > 0) &link.queue.items[0] else continue;
            if (head.due <= self.timeline.clock) {
                ready[n] = i;
                n += 1;
            } else if (earliest_pending == null or head.due < earliest_pending.?) {
                earliest_pending = head.due;
            }
        }
        if (n == 0) {
            // Nothing due. If something is still in flight, time passes until
            // it arrives; otherwise the network is idle and the run is over.
            const next = earliest_pending orelse return .idle;
            self.timeline.clock = next;
            return .advanced;
        }
        // The seed's only job: which link advances. Each link still delivers
        // its own head, so the wire stays ordered.
        const chosen = ready[self.prng.random().uintLessThan(usize, n)];
        const link = &self.links[chosen];
        const entry = link.queue.orderedRemove(0);
        const frame = entry.frame;
        try self.timeline.record(.{ .message_delivered = .{
            .src = link.from,
            .dst = link.to,
            .bytes = frame.bytes().len,
        } });
        self.timeline.tick();
        const target = self.peerById(link.to);
        try target.feedOwned(frame);
        _ = target.step() catch |err| try self.timeline.record(.{ .captp_failed = .{
            .id = link.to,
            .reason = @errorName(err),
        } });
        while (target.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            try self.timeline.record(.{ .captp_surfaced = .{
                .id = link.to,
                .kind = @tagName(event.kind()),
            } });
            if (self.observer) |obs| obs.func(obs.ctx, link.to, &event);
        }
        return .delivered;
    }

    /// Cut every link, recording what died in flight. What a partition takes
    /// is not only the frames sent afterwards but the ones already on the
    /// wire, exactly as a failed connection loses its socket buffers.
    fn partition(self: *Sim) !void {
        for (&self.links) |*link| {
            if (link.down) continue;
            const lost = link.queue.items.len;
            for (link.queue.items) |*entry| entry.frame.deinit();
            link.queue.clearRetainingCapacity();
            link.down = true;
            try self.timeline.record(.{ .link_down = .{
                .src = link.from,
                .dst = link.to,
                .in_flight_lost = lost,
            } });
        }
    }

    /// Run until the network goes idle, or refuse as a runaway. The scenario's
    /// own end state is recorded by whoever set it up. A partition fires when
    /// the clock reaches its tick, and the run continues afterwards: the peers
    /// keep talking into a dead network, which is precisely what they cannot
    /// detect.
    pub fn runToQuiescence(self: *Sim) !void {
        var delivered: usize = 0;
        while (true) {
            if (self.weather.partition_at) |at| {
                if (self.timeline.clock >= at) try self.partition();
            }
            try self.collect();
            switch (try self.deliverOne()) {
                .idle => return,
                .advanced => {},
                .delivered => {
                    delivered += 1;
                    if (delivered > max_deliveries) return Error.Runaway;
                },
            }
        }
    }
};

/// The scenarios a run can name. Each is a whole CapTP conversation with an
/// end state worth asserting.
pub const Scenario = enum {
    /// Peer 0 fetches a capability peer 1 published, and the answer settles.
    /// One question at a time, so the links take turns and every seed sees
    /// the same schedule — the base case.
    bootstrap_fetch,
    /// Both peers publish and both fetch at once, so both links carry traffic
    /// simultaneously and the seed genuinely chooses who advances. This is
    /// the scenario worth replaying under different seeds.
    crossed_fetch,
    /// A question asked into a network that is about to be cut. Run with
    /// `--partition-at`, it shows what a partition costs: the question is
    /// never answered and never refused, because nothing on either side can
    /// tell a slow partner from an absent one. The caller's own deadline is
    /// the only thing that ends the wait, which is why the library refuses to
    /// pick one for you.
    partitioned_fetch,

    pub fn fromArg(s: []const u8) ?Scenario {
        if (std.mem.eql(u8, s, "bootstrap-fetch")) return .bootstrap_fetch;
        if (std.mem.eql(u8, s, "crossed-fetch")) return .crossed_fetch;
        if (std.mem.eql(u8, s, "partitioned-fetch")) return .partitioned_fetch;
        return null;
    }
};

/// Counts what each peer's answers did, which is how a scenario states its
/// end condition without caring which frame shape carried it.
const Answers = struct {
    surfaced: [2]usize = .{ 0, 0 },

    fn observe(ctx: *anyopaque, peer_id: u8, event: *engine.Event) void {
        const self: *Answers = @ptrCast(@alignCast(ctx));
        _ = event;
        self.surfaced[peer_id] += 1;
    }
};

/// Run `scenario` under `seed` and return its timeline. The caller owns the
/// returned `Timeline`.
pub fn run(
    gpa: std.mem.Allocator,
    scenario: Scenario,
    seed: u64,
    codec: model.CodecId,
    weather: Weather,
) !Timeline {
    var timeline = Timeline.init(gpa);
    errdefer timeline.deinit();
    var pair = try engine.pairing.pairedWithCodec(gpa, codec);
    defer pair.deinit();
    try timeline.record(.{ .sim_started = .{ .scenario = @tagName(scenario), .seed = seed } });
    var sim = try Sim.init(gpa, &pair, seed, &timeline, weather);
    defer sim.deinit();

    var answers = Answers{};
    sim.observer = .{ .ctx = &answers, .func = Answers.observe };

    switch (scenario) {
        .bootstrap_fetch => {
            _ = try pair.p2.registerBootstrapCap("thermostat");
            const prepared = try engine.fetch.prepareFetchSwissnum(
                gpa,
                &pair.p1.session_state,
                "thermostat",
            );
            try pair.p1.send(prepared.message);
            try sim.runToQuiescence();
            // Peer 0 asked one question, so one answer reaching it is the end
            // state. Under V1.0 that answer arrives as a deliver to the
            // resolver export rather than a resolve, which is exactly why the
            // scenario counts answers instead of matching a frame shape.
            try timeline.record(.{ .captp_outcome = .{
                .id = 0,
                .detail = if (answers.surfaced[0] > 0) "answered" else "unanswered",
            } });
        },
        .partitioned_fetch => {
            _ = try pair.p2.registerBootstrapCap("thermostat");
            const prepared = try engine.fetch.prepareFetchSwissnum(
                gpa,
                &pair.p1.session_state,
                "thermostat",
            );
            try pair.p1.send(prepared.message);
            try sim.runToQuiescence();
            // With the network cut before the answer could return, peer 0's
            // question simply stands. Nothing broke it, because nothing
            // observed the failure.
            try timeline.record(.{ .captp_outcome = .{
                .id = 0,
                .detail = if (answers.surfaced[0] > 0) "answered" else "stranded",
            } });
        },
        .crossed_fetch => {
            // Both sides publish, then both ask at once: two questions in
            // flight in opposite directions, which is what gives the seed a
            // real choice.
            _ = try pair.p1.registerBootstrapCap("left");
            _ = try pair.p2.registerBootstrapCap("right");
            const from_left = try engine.fetch.prepareFetchSwissnum(gpa, &pair.p1.session_state, "right");
            const from_right = try engine.fetch.prepareFetchSwissnum(gpa, &pair.p2.session_state, "left");
            try pair.p1.send(from_left.message);
            try pair.p2.send(from_right.message);
            try sim.runToQuiescence();
            // Both questions must be answered whatever order the schedule
            // chose. That invariance is the property a seeded run exists to
            // check.
            const both = answers.surfaced[0] > 0 and answers.surfaced[1] > 0;
            try timeline.record(.{ .captp_outcome = .{
                .id = 0,
                .detail = if (both) "both-answered" else "incomplete",
            } });
        },
    }
    try timeline.record(.{ .sim_ended = .{ .reason = "quiesced" } });
    return timeline;
}
