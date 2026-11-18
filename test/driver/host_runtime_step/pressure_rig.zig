//! The rig the outbound-pressure scenarios share: a stepped runtime serving
//! one adopted connection through a scripted resident that refuses writes on
//! demand, with a raw core session as the partner whose fetches it delivers.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const driver_core = driver.core;
const net = glowcap.net;

const stream_framing = glowcap.foundation.stream_framing;

const harness = @import("harness.zig");
const residents = @import("../host_runtime_multiplexed/residents.zig");
const raw_partner = @import("raw_partner.zig");
const SteppedClock = @import("../../support/stepped_clock.zig").SteppedClock;
const RawPartner = raw_partner.RawPartner;
const Fixture = residents.ExternalAdoptionResident;
const Treasure = harness.Treasure;

pub const max_rounds = 400;
pub const waterline = 1024;

/// How a rig is built. `opens_on_read` leaves the session unopened: its
/// partner's hello and every fetch are the one read `burst` holds, and the
/// test sets `session` once that read opens it. `blocking` drives the
/// runtime through its blocking face.
pub const Spec = struct {
    fetches: usize,
    attended: bool = true,
    limit: ?usize = waterline,
    opens_on_read: bool = false,
    blocking: bool = false,
    /// The resident lends its received bytes instead of copying them.
    lending: bool = false,
    /// The wire carries one bare frame per packet, with no outer prefix.
    message: bool = false,
    /// The open's observer holds the session's inbound until the test
    /// attends it, as the driver's event queue does.
    unattended_on_open: bool = false,
    /// The allocator the runtime and its core draw from, when a test refuses
    /// their allocations apart from the rig's own.
    runtime_allocator: ?std.mem.Allocator = null,
    /// Read the runtime's clock through a `SteppedClock` that moves this many
    /// nanoseconds per reading and otherwise only through `Rig.clock`, so a
    /// test crosses a deadline by naming the moment.
    clock_step_ns: ?i64 = null,
    /// The runtime's busy-poll window, validated by `HostRuntime.init`.
    busy_poll_ns: u64 = 0,
};

/// A runtime serving one adopted connection whose partner is a raw core
/// session. Its fetch frames are outer-framed in `frames`, one packet per
/// fetch in `packets`.
pub const Rig = struct {
    allocator: std.mem.Allocator,
    threaded: std.Io.Threaded,
    /// The runtime's clock when `Spec.clock_step_ns` is set.
    clock: SteppedClock = undefined,
    resident: Fixture,
    observed: residents.ObservedOpen = .{},
    runtime: driver.HostRuntime,
    partner: RawPartner,
    session: *driver_core.HostSession,
    ready_fd: i32,
    frames: std.ArrayList(u8) = .empty,
    packets: std.ArrayList([]const u8) = .empty,
    ids: std.ArrayList(u64) = .empty,
    hello: [1][]const u8 = undefined,
    opening: std.ArrayList(u8) = .empty,
    burst: [1][]const u8 = undefined,
    /// The next fetch the partner has not yet offered the resident.
    next: usize = 0,
    message: bool = false,

    /// An attended session with the test waterline.
    pub fn create(allocator: std.mem.Allocator, fetches: usize) !*Rig {
        return build(allocator, .{ .fetches = fetches });
    }

    /// A rig whose session the embedder has or has not attended, with
    /// `limit` as its waterline, or the Host's default-derived one for null.
    pub fn createWith(allocator: std.mem.Allocator, fetches: usize, attended: bool, limit: ?usize) !*Rig {
        return build(allocator, .{ .fetches = fetches, .attended = attended, .limit = limit });
    }

    pub fn build(allocator: std.mem.Allocator, spec: Spec) !*Rig {
        const fetches = spec.fetches;
        const rig = try allocator.create(Rig);
        errdefer allocator.destroy(rig);
        rig.* = .{
            .allocator = allocator,
            .threaded = std.Io.Threaded.init(allocator, .{}),
            .resident = .{
                .wake = try net.wake_channel.WakeChannel.open(),
                .read_result = net.multiplexed_resident.would_block,
                .record_writes = allocator,
                .edge_reads = true,
                .close_completes = true,
            },
            .runtime = undefined,
            .partner = undefined,
            .session = undefined,
            .ready_fd = undefined,
            .message = spec.message,
        };
        errdefer rig.threaded.deinit();
        errdefer rig.resident.deinit();
        var options = if (spec.blocking) residents.opts else rig.observed.steppedOpts();
        // One read carries a whole burst, so a chunk is never split by scratch.
        options.wire_buffer_bytes = 64 * 1024;
        options.busy_poll_ns = spec.busy_poll_ns;
        const runtime_io = if (spec.clock_step_ns) |step_ns| blk: {
            rig.clock = SteppedClock.init(rig.threaded.io(), 0, step_ns);
            break :blk rig.clock.io();
        } else rig.threaded.io();
        rig.runtime = try driver.HostRuntime.init(spec.runtime_allocator orelse allocator, runtime_io, .{}, .ephemeral, options);
        errdefer rig.runtime.deinit();
        try rig.runtime.core.setSessionLimits(null, null, spec.limit, null, null);
        if (spec.unattended_on_open) rig.observed.unattend = &rig.runtime;
        const profile: model.transport.Metadata = .{
            .symbol = Fixture.transport,
            .designator_scheme = .key,
            .wire_framing = if (spec.message) .message else .byte_stream,
            .max_packet_bytes = residents.frame_cap + 2048,
        };
        const resident = if (spec.lending) rig.resident.lendingResident() else rig.resident.multiplexedResident();
        _ = try rig.runtime.addResident(profile, resident);
        try rig.runtime.core.ensureAdvertisedLocator(Fixture.transport);
        const designator = rig.runtime.core.advertisedLocator(Fixture.transport).?.designator;
        try rig.runtime.publish("treasure", Treasure, .{});

        rig.partner = try RawPartner.init(allocator, rig.threaded.io(), null, .dialer, Fixture.transport, profile, designator);
        errdefer rig.partner.deinit();
        errdefer rig.opening.deinit(allocator);
        errdefer rig.frames.deinit(allocator);
        errdefer rig.packets.deinit(allocator);
        errdefer rig.ids.deinit(allocator);
        var hello: std.ArrayList(u8) = .empty;
        defer hello.deinit(allocator);
        try rig.takeFrames(&hello);
        rig.hello = .{hello.items};
        try rig.runtime.startAdoptExternal(Fixture.transport, Fixture.conn_id, .accepted, 7, .{
            .ctx = &rig.observed,
            .reserve = residents.ObservedOpen.reserve,
            .release = residents.ObservedOpen.release,
            .opened = residents.ObservedOpen.opened,
            .failed = residents.ObservedOpen.failed,
        });
        if (spec.opens_on_read) {
            _ = try rig.runtime.stepAny(0);
        } else {
            rig.resident.offer(&rig.hello);
            _ = try rig.resident.wake.nudge();
            _ = try rig.runtime.stepAny(0);
            rig.session = rig.observed.session orelse return error.NeverOpened;
        }
        // The server's hello opens the partner's session.
        try rig.feedPartner(rig.resident.written.items, rig.resident.write_ends.items);
        rig.resident.written.clearRetainingCapacity();
        rig.resident.write_ends.clearRetainingCapacity();
        if (!rig.partner.session.sessionOpen()) return error.PartnerNeverOpened;
        if (!spec.opens_on_read) {
            if (spec.attended) try rig.runtime.attendSession(rig.session) else rig.runtime.markSessionUnattended(rig.session);
        }
        rig.ready_fd = if (spec.blocking) -1 else try rig.runtime.readinessDescriptor();

        // Every fetch is recorded before the first packet is cut, so the
        // frame buffer stays put under the packet slices.
        var ends: std.ArrayList(usize) = .empty;
        defer ends.deinit(allocator);
        for (0..fetches) |_| {
            try rig.ids.append(allocator, try rig.partner.host.fetch(rig.partner.session, "treasure"));
            try rig.takeFrames(&rig.frames);
            try ends.append(allocator, rig.frames.items.len);
        }
        var start: usize = 0;
        for (ends.items) |end| {
            try rig.packets.append(allocator, rig.frames.items[start..end]);
            start = end;
        }
        if (spec.opens_on_read) {
            try rig.opening.appendSlice(allocator, rig.hello[0]);
            try rig.opening.appendSlice(allocator, rig.frames.items);
            rig.burst = .{rig.opening.items};
        }
        return rig;
    }

    pub fn destroy(self: *Rig) void {
        const allocator = self.allocator;
        self.opening.deinit(allocator);
        self.frames.deinit(allocator);
        self.packets.deinit(allocator);
        self.ids.deinit(allocator);
        self.partner.deinit();
        self.runtime.deinit();
        self.resident.deinit();
        self.threaded.deinit();
        allocator.destroy(self);
    }

    /// Every frame the partner queued, outer-framed on a byte stream and bare
    /// on a message-framed wire.
    pub fn takeFrames(self: *Rig, out: *std.ArrayList(u8)) !void {
        if (!self.message) return self.partner.takeWire(out);
        while (try self.partner.session.takeOutbound()) |frame_value| {
            var frame = frame_value;
            defer frame.deinit();
            try out.appendSlice(self.allocator, frame.bytes());
        }
    }

    /// Hand the partner's session `bytes`, cut at `ends` on a message-framed
    /// wire, where each write is one packet. A write that backs the partner's
    /// own queue up is retried once that queue is taken.
    pub fn feedPartner(self: *Rig, bytes: []const u8, ends: []const usize) !void {
        const host = self.partner.host;
        const session = self.partner.session;
        var at: usize = 0;
        var index: usize = 0;
        while (at < bytes.len) {
            const end = if (self.message) ends[index] else @min(bytes.len, at + 4096);
            host.feedTransportPacket(session, bytes[at..end]) catch |err| switch (err) {
                error.OutboundBackpressure => {
                    while (try session.takeOutbound()) |frame| {
                        var owned = frame;
                        owned.deinit();
                    }
                    continue;
                },
                else => |e| return e,
            };
            at = end;
            index += 1;
        }
    }

    pub fn queued(self: *const Rig) usize {
        return self.session.served.queuedOutboundBytes();
    }

    /// One step, with the resident's readiness nudged as a partner's bytes or
    /// a window opening would, so the resident reports whatever it owes.
    pub fn step(self: *Rig) !?net.Progress {
        _ = try self.resident.wake.nudge();
        return self.runtime.stepAny(0);
    }

    /// One step with no readiness from the resident, so only the runtime's own
    /// sweep can move anything.
    pub fn stepQuiet(self: *Rig) !?net.Progress {
        return self.runtime.stepAny(0);
    }

    /// The opening burst of an `opens_on_read` rig with no fetches, followed by
    /// an `op:abort`. The partner's session projects one on a frame it cannot
    /// decode, as a dialer does on a hello it refuses.
    pub fn helloThenAbort(self: *Rig) ![]const u8 {
        var prefix_buf: [stream_framing.prefix_buffer_bytes]u8 = undefined;
        const prefix = stream_framing.renderPrefix(&prefix_buf, 1);
        var bad: [stream_framing.prefix_buffer_bytes + 1]u8 = undefined;
        @memcpy(bad[0..prefix.len], prefix);
        bad[prefix.len] = 0xff;
        // tolerant: the partner refuses the frame, and the abort it queues is what the test takes.
        self.partner.host.feedBytes(self.partner.session, bad[0 .. prefix.len + 1]) catch {};
        try self.takeFrames(&self.opening);
        return self.opening.items;
    }

    /// Park the first `parked` fetches on the unattended wire, then queue the
    /// embedder's own fetches behind a closed write window until the session
    /// is pressured.
    pub fn parkAndPressure(self: *Rig, parked: usize) !void {
        try self.park(parked);
        self.resident.write_open = false;
        var embedder_fetches: usize = 0;
        while (!self.session.outboundPressured()) : (embedder_fetches += 1) {
            if (embedder_fetches == 1000) return error.NeverPressured;
            _ = try self.runtime.core.fetch(self.session, "treasure");
            // The step hands the window one frame, which stays pending, so
            // the queue holds the rest.
            _ = try self.step();
        }
        try std.testing.expect(self.session.outboundPressured());
    }

    /// Park the first `parked` fetches on the unattended wire.
    pub fn park(self: *Rig, parked: usize) !void {
        self.resident.offer(self.packets.items[0..parked]);
        _ = try self.step();
        self.next = parked;
        try std.testing.expect(self.runtime.wires.get(self.session.peer_handle).?.link.parked.items.len != 0);
    }

    /// Offer the next fetch as one read, when the resident holds none.
    pub fn offerNext(self: *Rig) void {
        if (self.resident.inbound.len != 0 or self.next == self.packets.items.len) return;
        self.resident.offer(self.packets.items[self.next..][0..1]);
        self.next += 1;
    }

    /// Whether the readiness descriptor is quiet. A step posts its wake before
    /// it returns, so no wait is needed.
    pub fn quiet(self: *const Rig) !bool {
        return !try raw_partner.readable(self.ready_fd);
    }

    /// Offer one fetch per step with the write window closed until the
    /// session's outbound reaches its waterline. Returns the bytes one
    /// fetch's reply queues.
    pub fn fillToWaterline(self: *Rig) !usize {
        self.resident.write_open = false;
        var reply_bytes: usize = 0;
        var previous: usize = 0;
        for (0..self.packets.items.len) |_| {
            self.offerNext();
            _ = try self.step();
            if (self.queued() > previous and reply_bytes == 0 and previous != 0)
                reply_bytes = self.queued() - previous;
            previous = self.queued();
            if (self.session.outboundPressured()) return reply_bytes;
        }
        return error.NeverPressured;
    }

    /// Feed what the resident wrote to the partner's session and expect every
    /// fetch's answer, once and in order.
    pub fn expectAnswersInOrder(self: *Rig) !void {
        const host = self.partner.host;
        try self.feedPartner(self.resident.written.items, self.resident.write_ends.items);
        var settled: usize = 0;
        while (try host.nextAction()) |action| {
            if (action != .settled) continue;
            try std.testing.expect(settled < self.ids.items.len);
            try std.testing.expectEqual(self.ids.items[settled], action.settled.vow_id);
            settled += 1;
        }
        try std.testing.expectEqual(self.ids.items.len, settled);
    }
};
