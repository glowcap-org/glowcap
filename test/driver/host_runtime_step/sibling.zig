//! A second adopted connection on a pressure rig's runtime: its own resident,
//! its own raw partner, and a session that serves the same published object.
//! A test refuses the runtime's allocations while the rig's wire carries
//! traffic, then asks the sibling for a call to see whether the failure ended
//! only that wire.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const driver_core = glowcap.driver.core;
const net = glowcap.net;

const residents = @import("../host_runtime_multiplexed/residents.zig");
const raw_partner = @import("raw_partner.zig");
const pressure_rig = @import("pressure_rig.zig");
const Rig = pressure_rig.Rig;
const Fixture = residents.ExternalAdoptionResident;
const RawPartner = raw_partner.RawPartner;

pub const Sibling = struct {
    allocator: std.mem.Allocator,
    rig: *Rig,
    resident: Fixture,
    observed: residents.ObservedOpen = .{},
    partner: RawPartner,
    session: *driver_core.HostSession,
    resident_ready: bool = false,
    partner_ready: bool = false,
    request: std.ArrayList(u8) = .empty,
    request_chunk: [1][]const u8 = undefined,
    asked: usize = 0,

    pub const transport = "external-sibling";
    const conn: usize = 10;
    const key_seed: u8 = 0x5e;
    const partner_seed: u8 = 0x62;

    /// Adopt a second connection onto `rig`'s runtime and open its session,
    /// which the embedder has attended or not. The runtime's allocations
    /// during this call must succeed. A failure destroys `rig` as well,
    /// because its runtime holds the sibling's resident from the moment the
    /// resident is added.
    pub fn attach(rig: *Rig, attended: bool) !*Sibling {
        const allocator = rig.allocator;
        const self = allocator.create(Sibling) catch |err| {
            rig.destroy();
            return err;
        };
        self.* = .{
            .allocator = allocator,
            .rig = rig,
            .resident = undefined,
            .partner = undefined,
            .session = undefined,
        };
        self.open(attended) catch |err| {
            rig.destroy();
            self.destroy();
            return err;
        };
        return self;
    }

    fn open(self: *Sibling, attended: bool) !void {
        const allocator = self.allocator;
        const rig = self.rig;
        self.resident = .{
            .wake = try net.wake_channel.WakeChannel.open(),
            .read_result = net.multiplexed_resident.would_block,
            .record_writes = allocator,
            .edge_reads = true,
            .close_completes = true,
            .conn = conn,
            .key_seed = key_seed,
        };
        self.resident_ready = true;
        const profile: model.transport.Metadata = .{
            .symbol = transport,
            .designator_scheme = .key,
            .wire_framing = .byte_stream,
            .max_packet_bytes = residents.frame_cap + 2048,
        };
        _ = try rig.runtime.addResident(profile, self.resident.multiplexedResident());
        try rig.runtime.core.ensureAdvertisedLocator(transport);
        const designator = rig.runtime.core.advertisedLocator(transport).?.designator;
        self.partner = try RawPartner.initWithSeed(allocator, rig.threaded.io(), null, .dialer, transport, profile, designator, partner_seed);
        self.partner_ready = true;
        // The runtime's hello names its selected locator, which is the rig's
        // transport, so the partner learns that profile too.
        var canonical: [1][]const u8 = undefined;
        try self.partner.host.defineTransports(&.{.{
            .symbol = Fixture.transport,
            .designator_scheme = .key,
            .wire_framing = .byte_stream,
            .max_packet_bytes = residents.frame_cap + 2048,
        }}, &canonical);
        var hello_bytes: std.ArrayList(u8) = .empty;
        defer hello_bytes.deinit(allocator);
        try self.partner.takeWire(&hello_bytes);
        var hello: [1][]const u8 = .{hello_bytes.items};
        try rig.runtime.startAdoptExternal(transport, conn, .accepted, 8, .{
            .ctx = &self.observed,
            .reserve = residents.ObservedOpen.reserve,
            .release = residents.ObservedOpen.release,
            .opened = residents.ObservedOpen.opened,
            .failed = residents.ObservedOpen.failed,
        });
        self.resident.offer(&hello);
        _ = try self.step();
        // The hello is consumed inside that step, so the offer holds no borrow.
        self.resident.inbound = &.{};
        self.session = self.observed.session orelse return error.NeverOpened;
        try self.feedPartnerWritten();
        if (!self.partner.session.sessionOpen()) return error.PartnerNeverOpened;
        if (attended) try rig.runtime.attendSession(self.session) else rig.runtime.markSessionUnattended(self.session);
    }

    /// Release the sibling after the rig's runtime has been destroyed.
    pub fn destroy(self: *Sibling) void {
        const allocator = self.allocator;
        self.request.deinit(allocator);
        if (self.partner_ready) self.partner.deinit();
        if (self.resident_ready) self.resident.deinit();
        allocator.destroy(self);
    }

    /// One step with this connection's readiness raised.
    pub fn step(self: *Sibling) !?net.Progress {
        _ = try self.resident.wake.nudge();
        return self.rig.runtime.stepAny(0);
    }

    fn feedPartnerWritten(self: *Sibling) !void {
        try self.partner.host.feedBytes(self.partner.session, self.resident.written.items);
        self.resident.written.clearRetainingCapacity();
        self.resident.write_ends.clearRetainingCapacity();
    }

    /// Ask the partner's session for the published object and hand the
    /// request to the resident as one read.
    pub fn ask(self: *Sibling) !void {
        _ = try self.partner.host.fetch(self.partner.session, "treasure");
        self.request.clearRetainingCapacity();
        try self.partner.takeWire(&self.request);
        self.request_chunk = .{self.request.items};
        self.resident.offer(&self.request_chunk);
        self.asked += 1;
    }

    /// Whether the wire holds input the runtime will replay.
    pub fn holdsParked(self: *Sibling) bool {
        const wire = self.rig.runtime.wires.get(self.session.peer_handle) orelse return false;
        return wire.link.parked.items.len != 0;
    }

    /// Queue the embedder's own fetches behind a closed write window until
    /// the session is at its outbound waterline.
    pub fn pressure(self: *Sibling) !void {
        self.resident.write_open = false;
        var fetches: usize = 0;
        while (!self.session.outboundPressured()) : (fetches += 1) {
            if (fetches == 1000) return error.NeverPressured;
            _ = try self.rig.runtime.core.fetch(self.session, "treasure");
            _ = try self.step();
        }
    }

    /// Step until the partner has an answer for every request it asked, and
    /// say whether it did.
    pub fn answered(self: *Sibling) !bool {
        var settled: usize = 0;
        for (0..pressure_rig.max_rounds) |_| {
            _ = try self.step();
            try self.feedPartnerWritten();
            while (try self.partner.host.nextAction()) |action| {
                if (action == .settled) settled += 1;
            }
            if (settled == self.asked) return true;
        }
        return false;
    }
};
