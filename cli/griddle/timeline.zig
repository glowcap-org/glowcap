//! The griddle timeline wire format: one JSON object per line.
//!
//! The schema is layered and versioned, and both properties are load-bearing.
//! Versioned (`"v"`) so a consumer detects a format change loudly instead of
//! misreading it. Layered so the network facts a viewer draws — hosts, links,
//! messages in flight — stay free of any protocol, and the CapTP facts ride
//! as their own kinds beside them. A viewer that only understands the base
//! kinds still draws a correct picture of a pancake run.
//!
//! Times are simulated nanoseconds (`sim_t_ns`), not wall time: a replay must
//! reproduce them exactly, which a real clock could never do. The scheduler
//! counts ticks; `ns_per_tick` is the one place that becomes a duration.

const std = @import("std");

/// Schema version. Bump when a consumer would misread the old shape.
pub const schema_version: u32 = 1;

/// What one scheduler tick is worth in simulated nanoseconds. A tick is one
/// unit of network progress, and a millisecond is a fair story for one hop.
pub const ns_per_tick: u64 = 1_000_000;

/// One timeline event. The base kinds describe the network and carry no
/// protocol; the `captp_*` kinds are pancake's own extension, named so a
/// consumer can tell at a glance which layer it is reading.
pub const Event = union(enum) {
    /// The run began. Once, at tick zero.
    sim_started: struct { scenario: []const u8, seed: u64 },
    /// The run reached its end state.
    sim_ended: struct { reason: []const u8 },
    /// A host joined the simulated network.
    host_joined: struct { id: u8 },
    /// A link came up, with the one-way latency it will impose.
    link_up: struct { src: u8, dst: u8, latency_ms: u64 },
    /// A link went down, losing whatever it was carrying.
    link_down: struct { src: u8, dst: u8, in_flight_lost: usize },
    /// A message left its sender, with the tick it is due to arrive.
    message_in_flight: struct { src: u8, dst: u8, bytes: usize, arrive_ns: u64 },
    /// A message arrived at its destination.
    message_delivered: struct { src: u8, dst: u8, bytes: usize },
    /// A message handed to a link that was already down. Nothing carries it
    /// and nobody is told.
    message_lost: struct { src: u8, dst: u8, bytes: usize },
    /// A CapTP peer surfaced an application event of this kind.
    captp_surfaced: struct { id: u8, kind: []const u8 },
    /// A peer's step failed. A simulator that swallowed this would spin to
    /// its runaway bound with nothing to show for it, which is the opposite
    /// of what a debugging tool is for.
    captp_failed: struct { id: u8, reason: []const u8 },
    /// The scenario's own end state, in its own words.
    captp_outcome: struct { id: u8, detail: []const u8 },

    /// Render as one NDJSON line, including the trailing newline.
    pub fn writeJson(self: Event, out: *std.ArrayList(u8), gpa: std.mem.Allocator, clock: u64) !void {
        const t = clock * ns_per_tick;
        try out.print(gpa, "{{\"v\":{d},\"sim_t_ns\":{d},\"kind\":\"{s}\"", .{
            schema_version,
            t,
            @tagName(self),
        });
        switch (self) {
            .sim_started => |e| try out.print(gpa, ",\"scenario\":\"{s}\",\"seed\":{d}", .{ e.scenario, e.seed }),
            .sim_ended => |e| try out.print(gpa, ",\"reason\":\"{s}\"", .{e.reason}),
            .host_joined => |e| try out.print(gpa, ",\"id\":{d}", .{e.id}),
            .link_up => |e| try out.print(
                gpa,
                ",\"src\":{d},\"dst\":{d},\"latency_ms\":{d}",
                .{ e.src, e.dst, e.latency_ms },
            ),
            .link_down => |e| try out.print(
                gpa,
                ",\"src\":{d},\"dst\":{d},\"in_flight_lost\":{d}",
                .{ e.src, e.dst, e.in_flight_lost },
            ),
            .message_in_flight => |e| try out.print(
                gpa,
                ",\"src\":{d},\"dst\":{d},\"bytes\":{d},\"depart_ns\":{d},\"arrive_ns\":{d}",
                .{ e.src, e.dst, e.bytes, t, e.arrive_ns },
            ),
            .message_delivered => |e| try out.print(
                gpa,
                ",\"src\":{d},\"dst\":{d},\"bytes\":{d},\"delivered_ns\":{d}",
                .{ e.src, e.dst, e.bytes, t },
            ),
            .message_lost => |e| try out.print(
                gpa,
                ",\"src\":{d},\"dst\":{d},\"bytes\":{d}",
                .{ e.src, e.dst, e.bytes },
            ),
            .captp_surfaced => |e| try out.print(gpa, ",\"id\":{d},\"event\":\"{s}\"", .{ e.id, e.kind }),
            .captp_failed => |e| try out.print(gpa, ",\"id\":{d},\"reason\":\"{s}\"", .{ e.id, e.reason }),
            .captp_outcome => |e| try out.print(gpa, ",\"id\":{d},\"detail\":\"{s}\"", .{ e.id, e.detail }),
        }
        try out.appendSlice(gpa, "}\n");
    }
};

/// The timeline a run produces: NDJSON lines in scheduler order. Owned by the
/// caller, who decides whether it goes to stdout, a file, or an assertion.
pub const Timeline = struct {
    gpa: std.mem.Allocator,
    lines: std.ArrayList(u8) = .empty,
    clock: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) Timeline {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Timeline) void {
        self.lines.deinit(self.gpa);
    }

    pub fn record(self: *Timeline, event: Event) !void {
        try event.writeJson(&self.lines, self.gpa, self.clock);
    }

    /// Advance the logical clock by one tick of network progress.
    pub fn tick(self: *Timeline) void {
        self.clock += 1;
    }

    pub fn bytes(self: *const Timeline) []const u8 {
        return self.lines.items;
    }

    /// This tick as simulated nanoseconds, for an event that names a future
    /// arrival.
    pub fn nowNs(self: *const Timeline) u64 {
        return self.clock * ns_per_tick;
    }
};
