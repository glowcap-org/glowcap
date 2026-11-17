//! The fixture the staged-open scenarios share: a stepped runtime over the
//! scripted accept-ownership resident, a completion sink the test can refuse,
//! and a clock the test moves.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const driver_core = driver.core;
const HostRuntime = driver.HostRuntime;
const fixtures = @import("../host_runtime_multiplexed/residents.zig");
const AcceptOwnershipResident = fixtures.AcceptOwnershipResident;
const ObservedOpen = fixtures.ObservedOpen;
const SteppedClock = @import("../../support/stepped_clock.zig").SteppedClock;

pub const retry_ms = HostRuntime.testing.memory_retry_ms;
pub const transport = AcceptOwnershipResident.transport;
pub const handshake_ms = 50;

/// The completion sink, counting and optionally refusing the reservation.
const Sink = struct {
    runtime: *HostRuntime,
    refuse: bool = false,
    /// A non-memory refusal of the reservation, for a drain that fails apart
    /// from memory.
    fail_with: ?anyerror = null,
    reserves: usize = 0,
    takes: usize = 0,
    /// `driver_depth` at the last reservation: one call frame per nested
    /// drain a stack holds.
    depth_seen: usize = 0,

    fn of(ctx: *anyopaque) *Sink {
        return @ptrCast(@alignCast(ctx));
    }

    fn reserve(ctx: *anyopaque) anyerror!void {
        const self = of(ctx);
        self.reserves += 1;
        self.depth_seen = self.runtime.driver_depth;
        if (self.fail_with) |err| return err;
        if (self.refuse) return error.OutOfMemory;
    }

    fn take(ctx: *anyopaque, _: driver_core.HostAction) bool {
        of(ctx).takes += 1;
        return false;
    }

    fn install(self: *Sink) void {
        // Only a stepped Host takes an observer sink, so a blocking fixture
        // installs none and its `takes` counter is never evidence.
        if (self.runtime.drive == .blocking) return;
        self.runtime.drive.stepped.completion_sink = .{ .ctx = self, .reserve = reserve, .take = take };
    }
};

/// How a fixture drives its runtime and what its resident can do.
pub const Mode = struct {
    /// Drive the runtime through its blocking face.
    blocking: bool = false,
    /// A resident whose close the carrier deadline can abort.
    abortable: bool = false,
};

/// A stepped runtime over the scripted resident, on a clock the test moves.
pub const Fixture = struct {
    threaded: std.Io.Threaded,
    clock: SteppedClock,
    resident: AcceptOwnershipResident,
    observed: ObservedOpen = .{},
    runtime: HostRuntime,
    /// The mode the fixture started in, set by `startUsing`.
    blocking: bool,
    abortable: bool,
    sink: Sink,

    pub fn start(self: *Fixture, handshake: @FieldType(driver.SessionOptions, "handshake")) !void {
        return self.startRetrying(handshake, .{ .max_attempts = 1 });
    }

    pub fn startRetrying(
        self: *Fixture,
        handshake: @FieldType(driver.SessionOptions, "handshake"),
        policy: @FieldType(driver.SessionOptions, "dial_retry"),
    ) !void {
        return self.startUsing(std.testing.allocator, .{}, handshake, policy);
    }

    /// `startRetrying` with the allocator the runtime and its core draw from,
    /// so a scenario refuses their allocations apart from the fixture's own,
    /// and with an explicit mode. Every field is set here, so a caller may
    /// start a fixture it declared `undefined`.
    pub fn startUsing(
        self: *Fixture,
        runtime_allocator: std.mem.Allocator,
        mode: Mode,
        handshake: @FieldType(driver.SessionOptions, "handshake"),
        policy: @FieldType(driver.SessionOptions, "dial_retry"),
    ) !void {
        self.blocking = mode.blocking;
        self.abortable = mode.abortable;
        self.observed = .{};
        self.threaded = std.Io.Threaded.init(std.testing.allocator, .{});
        self.clock = SteppedClock.init(self.threaded.io(), 0, std.time.ns_per_us);
        self.resident = try AcceptOwnershipResident.init();
        self.resident.abortable = self.abortable;
        var options = if (self.blocking) fixtures.opts else self.observed.steppedOpts();
        options.handshake = handshake;
        options.dial_retry = policy;
        self.runtime = try HostRuntime.init(runtime_allocator, self.clock.io(), .{}, .ephemeral, options);
        _ = try self.runtime.addResident(
            .{ .symbol = transport, .designator_scheme = .address },
            self.resident.multiplexedResident(),
        );
        try self.runtime.core.ensureAdvertisedLocator(transport);
        self.sink = .{ .runtime = &self.runtime };
        self.sink.install();
    }

    pub fn stop(self: *Fixture) void {
        self.runtime.deinit();
        self.resident.deinit();
        self.threaded.deinit();
    }

    pub fn locator() model.PeerLocator {
        return .{ .transport = transport, .designator = "remote.test:1", .hints = model.Hints.emptyFalse() };
    }

    /// Ask the core to dial the peer: a redeem open with no other route.
    pub fn enliven(self: *Fixture) !void {
        _ = try self.runtime.core.enlivenSelectOrDial(.{ .peer = locator(), .swissnum = "not-published" });
    }

    /// The fixture peer's URI with three more routes behind the first, so a
    /// failed route has a next dial for the core to queue even after one more
    /// failure. The caller frees it.
    pub fn alternativeLocatorUri(allocator: std.mem.Allocator) ![]u8 {
        var routes: [3][]u8 = undefined;
        const designators = [_][]const u8{ "alt.test:1", "alt2.test:1", "alt3.test:1" };
        for (&routes, designators) |*route, designator| route.* = try model.uri.writePeer(allocator, .{
            .transport = transport,
            .designator = designator,
            .hints = model.Hints.emptyFalse(),
        });
        defer for (routes) |route| allocator.free(route);
        const list = try std.mem.join(allocator, "|", &routes);
        defer allocator.free(list);
        const hints = [_]model.HintEntry{.{
            .name = model.transport.hint_alt_locators,
            .value = .{ .string = list },
        }};
        var peer = locator();
        peer.hints = .{ .entries = &hints };
        return model.uri.writePeer(allocator, peer);
    }

    /// The same, toward a second peer.
    pub fn enlivenOther(self: *Fixture) !void {
        var peer = locator();
        peer.designator = "other.test:1";
        _ = try self.runtime.core.enlivenSelectOrDial(.{ .peer = peer, .swissnum = "not-published" });
    }

    pub fn startDial(self: *Fixture) !void {
        try self.runtime.startDial(locator(), .inherit, 5, .{
            .ctx = &self.observed,
            .reserve = ObservedOpen.reserve,
            .release = ObservedOpen.release,
            .opened = ObservedOpen.opened,
            .failed = ObservedOpen.failed,
        });
    }
};

pub fn refuseDial(resident: *AcceptOwnershipResident) void {
    var chain = glowcap.foundation.FailureChain.initNamed(error.ProviderIo, "ImmediateRefusal");
    chain.noteChain(.initNamed(error.ProviderIo, "Cleanup"));
    resident.dial_failure = .fromChain(error.ConnectionRefused, chain);
}
