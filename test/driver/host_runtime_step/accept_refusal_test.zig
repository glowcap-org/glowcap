//! A local failure admitting one accepted connection retires that arrival and
//! nothing else. Each sweep refuses the runtime's allocations at every index
//! one arrival reaches, in turn: one refusal, or every allocation from that
//! index on until memory comes back. After the refusal the step succeeds, the
//! claimed connection was closed once, no session, pending row, admission or
//! observer reservation survives, the listener takes the next arrival, and a
//! sibling session that was already established still answers a call.
//!
//! A provider that breaks its contract is not an arrival's failure: the
//! latch holds the exact cause and every later step reports it.

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const driver_core = driver.core;
const model = glowcap.ocapn.model;
const net = glowcap.net;
const FailingOnce = @import("../../support/failing_once.zig").FailingOnce;
const residents = @import("../host_runtime_multiplexed/residents.zig");
const pressure_rig = @import("pressure_rig.zig");
const Accepting = residents.AcceptOwnershipResident;
const Rig = pressure_rig.Rig;
const RawPartner = @import("raw_partner.zig").RawPartner;

const disabled = std.math.maxInt(usize);
const max_indexes = 256;

/// The accept observer: each reservation takes a slot from the runtime's own
/// allocator, as the C driver's event queue does, so the refusal can land on
/// the observer's reservation as well as on the runtime's.
const Arrivals = struct {
    allocator: std.mem.Allocator,
    slots: [2]?*u8 = @splat(null),
    held: usize = 0,
    reserve_refused: usize = 0,
    released: usize = 0,
    arrival_failures: usize = 0,
    arrival_cause: ?anyerror = null,
    listener_failures: usize = 0,
    /// When set, `opened` refuses the session, as a claim that cannot be made does.
    refuse_open: bool = false,
    /// When set, `reserve` refuses, as an observer whose queue cannot grow does.
    refuse_reserve: bool = false,
    opened_sessions: usize = 0,

    fn of(ctx: *anyopaque) *Arrivals {
        return @ptrCast(@alignCast(ctx));
    }

    fn reserve(ctx: *anyopaque, _: u64) anyerror!void {
        const self = of(ctx);
        if (self.refuse_reserve) return error.OutOfMemory;
        self.slots[self.held] = self.allocator.create(u8) catch |err| {
            self.reserve_refused += 1;
            return err;
        };
        self.held += 1;
    }

    fn release(ctx: *anyopaque, _: u64) void {
        const self = of(ctx);
        std.debug.assert(self.held != 0);
        self.held -= 1;
        self.allocator.destroy(self.slots[self.held].?);
        self.slots[self.held] = null;
        self.released += 1;
    }

    /// Free the slots still held when the runtime goes: a listener's seat is
    /// never released, because retiring the listener consumes it.
    fn dropSlots(self: *Arrivals) void {
        for (&self.slots) |*slot| {
            if (slot.*) |held| self.allocator.destroy(held);
            slot.* = null;
        }
        self.held = 0;
    }

    fn opened(ctx: *anyopaque, _: u64, _: *driver_core.HostSession) !void {
        const self = of(ctx);
        if (self.refuse_open) return error.OutOfMemory;
        // A session consumes its reservation, as the C driver's ACCEPTED does.
        self.held -= 1;
        self.allocator.destroy(self.slots[self.held].?);
        self.slots[self.held] = null;
        self.opened_sessions += 1;
    }

    fn arrivalFailed(ctx: *anyopaque, _: u64, failure: driver.OperationFailure) void {
        const self = of(ctx);
        self.arrival_failures += 1;
        self.arrival_cause = failure.chain.cause;
    }

    fn failed(ctx: *anyopaque, _: u64, _: driver.OperationFailure) void {
        of(ctx).listener_failures += 1;
    }

    fn observer(self: *Arrivals) driver.HostRuntime.SessionAcceptObserver {
        return .{
            .ctx = self,
            .reserve = reserve,
            .release = release,
            .abandoned = release,
            .retired = release,
            .arrival_failed = arrivalFailed,
            .opened = opened,
            .failed = failed,
        };
    }
};

/// A runtime serving one established session (the rig's) beside an accepting
/// resident whose listener reports to `Arrivals`.
const Scene = struct {
    failing: FailingOnce,
    rig: *Rig,
    accepting: Accepting,
    arrivals: Arrivals,
    /// Reservations held before any arrival: the listener's own seat.
    seat: usize = 0,

    fn create() !*Scene {
        const self = try std.testing.allocator.create(Scene);
        errdefer std.testing.allocator.destroy(self);
        self.failing = FailingOnce.init(std.testing.allocator, disabled);
        self.rig = try Rig.build(std.testing.allocator, .{ .fetches = 1, .runtime_allocator = self.failing.allocator() });
        errdefer self.rig.destroy();
        self.accepting = try Accepting.init();
        errdefer self.accepting.deinit();
        self.arrivals = .{ .allocator = self.failing.allocator() };
        const runtime = &self.rig.runtime;
        _ = try runtime.addResident(
            .{ .symbol = Accepting.transport, .designator_scheme = .address },
            self.accepting.multiplexedResident(),
        );
        var listener = try runtime.bindListener(Accepting.transport, "", .inherit);
        errdefer if (runtime.closeListener(&listener)) |failure| runtime.noteTerminalOperationFailure(failure);
        try runtime.core.setAdvertisedLocator(.{
            .transport = Accepting.transport,
            .designator = "resident.test:1",
            .hints = model.Hints.emptyFalse(),
        });
        try runtime.activateListener(&listener, 7, self.arrivals.observer());
        _ = try runtime.stepAny(0); // Warm readiness scratch before injection.
        self.seat = self.arrivals.held;
        return self;
    }

    /// Tear the runtime down, and report
    /// whether every byte the runtime and the observer took came back.
    fn destroy(self: *Scene) bool {
        self.rig.destroy();
        self.accepting.deinit();
        self.arrivals.dropSlots();
        const balanced = self.failing.balanced();
        std.testing.allocator.destroy(self);
        return balanced;
    }

    /// Refuse the allocations from `offset` into the next arrival on, until
    /// `restore`.
    fn refuseFrom(self: *Scene, offset: usize, lasting: bool) void {
        self.failing.induced = false;
        self.failing.lasting = lasting;
        self.failing.fail_index = self.failing.alloc_index + offset;
    }

    fn restore(self: *Scene) void {
        self.failing.fail_index = disabled;
        self.failing.lasting = false;
    }

    fn arrive(self: *Scene) !void {
        self.accepting.announceAccept();
        _ = try self.rig.runtime.stepAny(0);
    }

    /// The sibling session still answers a fetch.
    fn expectSiblingServes(self: *Scene) !void {
        self.rig.offerNext();
        _ = try self.rig.step();
        try self.rig.expectAnswersInOrder();
    }
};

const Tally = struct {
    /// Indexes at which the runtime refused an arrival allocation.
    refused: usize = 0,
    /// Of those, the observer's own reservation.
    reserve_refused: usize = 0,
    /// Refusals that landed on a wire record, one of the adoption's allocations.
    wire_record_refused: usize = 0,
    /// Refusals that landed on the core's session record.
    session_record_refused: usize = 0,
    /// Refusals that landed on the pending-open row.
    pending_row_refused: usize = 0,
    /// Distinct sizes of the refused allocations.
    sizes: [32]usize = @splat(0),
    size_count: usize = 0,

    fn noteSize(self: *Tally, len: usize) void {
        for (self.sizes[0..self.size_count]) |seen| if (seen == len) return;
        if (self.size_count == self.sizes.len) return;
        self.sizes[self.size_count] = len;
        self.size_count += 1;
    }
};

fn sweep(lasting: bool) !Tally {
    var tally: Tally = .{};
    var reached_clean = false;
    for (0..max_indexes) |offset| {
        const scene = try Scene.create();
        scene.refuseFrom(offset, lasting);
        // One arrival: the step must succeed whatever the refusal hit.
        scene.accepting.announceAccept();
        const stepped = scene.rig.runtime.stepAny(0);
        scene.restore();
        const refused = scene.failing.induced;
        _ = try stepped;
        const runtime = &scene.rig.runtime;
        try std.testing.expect(runtime.terminal_failure == null);
        try std.testing.expectEqual(@as(usize, 0), scene.arrivals.listener_failures);
        if (!refused) {
            // Memory never ran short here: the arrival is admitted and parked
            // in its handshake, which is the shape the refused runs must reach
            // on their next healthy arrival.
            try std.testing.expectEqual(@as(usize, 1), runtime.pending_opens.items.len);
            try std.testing.expectEqual(scene.seat + 1, scene.arrivals.held);
            try std.testing.expectEqual(@as(usize, 0), scene.accepting.close_calls);
            try std.testing.expectEqual(@as(usize, 0), scene.arrivals.arrival_failures);
            reached_clean = true;
            try std.testing.expect(scene.destroy());
            break;
        }
        tally.refused += 1;
        tally.noteSize(scene.failing.refused_len);
        if (scene.arrivals.reserve_refused != 0) tally.reserve_refused += 1;
        if (scene.failing.refused_len == @sizeOf(driver.HostRuntime.Wire)) tally.wire_record_refused += 1;
        if (scene.failing.refused_len == @sizeOf(driver_core.HostSession)) tally.session_record_refused += 1;
        const Row = @typeInfo(@typeInfo(@TypeOf(runtime.pending_opens.items)).pointer.child).pointer.child;
        if (scene.failing.refused_len == @sizeOf(Row)) tally.pending_row_refused += 1;

        // The arrival is retired: closed once, with nothing of it left.
        try std.testing.expectEqual(@as(usize, 1), scene.accepting.close_calls);
        try std.testing.expectEqual(@as(usize, 0), runtime.pending_opens.items.len);
        try std.testing.expectEqual(@as(usize, 0), runtime.open_admissions);
        try std.testing.expectEqual(@as(usize, 1), runtime.resident_wires.count());
        try std.testing.expectEqual(scene.seat, scene.arrivals.held);
        try std.testing.expectEqual(@as(usize, 1), scene.arrivals.arrival_failures);
        try std.testing.expectEqual(error.OutOfMemory, scene.arrivals.arrival_cause.?);

        // The established sibling serves, and the listener takes the next
        // arrival, which is closed by nobody.
        try scene.expectSiblingServes();
        scene.accepting.claimed = false;
        try scene.arrive();
        try std.testing.expectEqual(@as(usize, 1), runtime.pending_opens.items.len);
        try std.testing.expectEqual(scene.seat + 1, scene.arrivals.held);
        try std.testing.expectEqual(@as(usize, 1), scene.accepting.close_calls);
        try std.testing.expectEqual(@as(usize, 2), runtime.resident_wires.count());
        try std.testing.expect(runtime.terminal_failure == null);
        try std.testing.expect(scene.destroy());
    }
    try std.testing.expect(reached_clean);
    return tally;
}

fn expectCoverage(tally: Tally) !void {
    // Every named allocation one arrival makes was refused at least once:
    // the observer's reservation, the core's session, the wire record, and
    // the pending-open row. A stage is matched by the refused allocation's
    // size, which is a probe for this fixture's types, not a classifier.
    try std.testing.expect(tally.reserve_refused >= 1);
    try std.testing.expect(tally.session_record_refused >= 1);
    try std.testing.expect(tally.wire_record_refused >= 1);
    try std.testing.expect(tally.pending_row_refused >= 1);
}

test "one refusal at every allocation an arrival makes retires that arrival alone" {
    try expectCoverage(try sweep(false));
}

test "a lasting shortage during an arrival retires that arrival alone" {
    try expectCoverage(try sweep(true));
}

/// A runtime over one accepting resident, whose listener reports to
/// `arrivals`, for the provider-contract cases.
const Provider = struct {
    threaded: std.Io.Threaded,
    resident: Accepting,
    arrivals: Arrivals,
    seat: usize = 0,
    runtime: driver.HostRuntime,
    vtable: net.MultiplexedResident.VTable,

    fn create(self: *Provider, dialer: bool) !void {
        const allocator = std.testing.allocator;
        self.threaded = std.Io.Threaded.init(allocator, .{});
        errdefer self.threaded.deinit();
        self.resident = try Accepting.init();
        errdefer self.resident.deinit();
        self.arrivals = .{ .allocator = allocator };
        self.vtable = Accepting.vtable;
        if (!dialer) self.vtable.dial = null;
        self.runtime = try driver.HostRuntime.init(allocator, self.threaded.io(), .{}, .ephemeral, residents.opts);
        errdefer self.runtime.deinit();
        _ = try self.runtime.addResident(
            .{ .symbol = Accepting.transport, .designator_scheme = .address },
            .{ .ctx = &self.resident, .vtable = &self.vtable },
        );
        var listener = try self.runtime.bindListener(Accepting.transport, "", .inherit);
        errdefer if (self.runtime.closeListener(&listener)) |failure| self.runtime.noteTerminalOperationFailure(failure);
        try self.runtime.core.setAdvertisedLocator(.{
            .transport = Accepting.transport,
            .designator = "resident.test:1",
            .hints = model.Hints.emptyFalse(),
        });
        try self.runtime.activateListener(&listener, 7, self.arrivals.observer());
        _ = try self.runtime.stepAny(0);
        self.seat = self.arrivals.held;
    }

    fn destroy(self: *Provider) void {
        self.runtime.deinit();
        self.arrivals.dropSlots();
        self.resident.deinit();
        self.threaded.deinit();
    }

    /// The latched chain, and every later step reports the same cause.
    fn expectLatched(self: *Provider, cause: anyerror) !void {
        const latched = self.runtime.terminal_failure orelse return error.NotLatched;
        try std.testing.expectEqual(cause, latched.chain.cause);
        try std.testing.expectEqual(@as(?anyerror, null), latched.chain.secondary_cause);
        try std.testing.expectEqual(@as(u16, 0), latched.chain.secondary_count);
        try std.testing.expectError(cause, self.runtime.stepAny(0));
        try std.testing.expectError(cause, self.runtime.stepAny(0));
    }
};

test "a provider that fails the accepted connection's remote key latches and closes that arrival once" {
    var provider: Provider = undefined;
    try provider.create(true);
    defer provider.destroy();
    provider.resident.fail_remote_key = true;

    provider.resident.announceAccept();
    try std.testing.expectError(error.ProviderContract, provider.runtime.stepAny(0));
    try provider.expectLatched(error.ProviderContract);
    // The violation is the provider's, so the arrival is not also reported as
    // a local refusal, but its connection, session, row and reservation are gone.
    try std.testing.expectEqual(@as(usize, 0), provider.arrivals.arrival_failures);
    try std.testing.expectEqual(@as(usize, 1), provider.resident.close_calls);
    try std.testing.expectEqual(@as(usize, 0), provider.runtime.pending_opens.items.len);
    try std.testing.expectEqual(@as(usize, 0), provider.runtime.open_admissions);
    try std.testing.expectEqual(@as(usize, 0), provider.runtime.resident_wires.count());
    try std.testing.expectEqual(provider.seat, provider.arrivals.held);
}

test "a connect record from a resident that has no dialer latches" {
    var provider: Provider = undefined;
    try provider.create(false);
    defer provider.destroy();

    provider.resident.held_record = .{ .subject = 5, .events = net.multiplexed_resident.ev_connect };
    _ = try provider.resident.wake.nudge();
    try std.testing.expectError(error.ProviderContract, provider.runtime.stepAny(0));
    try provider.expectLatched(error.ProviderContract);
}

test "a drain that reports more records than its buffer holds latches" {
    var provider: Provider = undefined;
    try provider.create(true);
    defer provider.destroy();

    provider.resident.overreport_drain = true;
    _ = try provider.resident.wake.nudge();
    try std.testing.expectError(error.ProviderContract, provider.runtime.stepAny(0));
    try provider.expectLatched(error.ProviderContract);
}

test "a session its listener's observer refuses retires that arrival and leaves the listener open" {
    var provider: Provider = undefined;
    try provider.create(true);
    defer provider.destroy();
    const allocator = std.testing.allocator;

    // The partner's hello is what the accepted wire reads at adoption, so the
    // handshake completes in the same step that adopts the connection.
    const profile: model.transport.Metadata = .{
        .symbol = Accepting.transport,
        .designator_scheme = .address,
        .wire_framing = .byte_stream,
        .max_packet_bytes = residents.frame_cap + 2048,
    };
    var partner = try RawPartner.init(allocator, provider.threaded.io(), null, .dialer, Accepting.transport, profile, "resident.test:1");
    defer partner.deinit();
    var hello: std.ArrayList(u8) = .empty;
    defer hello.deinit(allocator);
    try partner.takeWire(&hello);

    provider.arrivals.refuse_open = true;
    provider.resident.read_once = hello.items;
    provider.resident.announceAccept();
    _ = try provider.runtime.stepAny(0);
    try std.testing.expect(provider.runtime.terminal_failure == null);
    try std.testing.expectEqual(@as(usize, 1), provider.arrivals.arrival_failures);
    try std.testing.expectEqual(error.OutOfMemory, provider.arrivals.arrival_cause.?);
    // The listener neither failed nor retired: no event named it.
    try std.testing.expectEqual(@as(usize, 0), provider.arrivals.listener_failures);
    try std.testing.expectEqual(provider.seat, provider.arrivals.held);
    try std.testing.expectEqual(@as(usize, 0), provider.runtime.pending_opens.items.len);
    try std.testing.expectEqual(@as(usize, 0), provider.runtime.open_admissions);
    try std.testing.expectEqual(@as(usize, 1), provider.resident.close_calls);
    try std.testing.expectEqual(@as(usize, 0), provider.runtime.resident_wires.count());

    // The next arrival takes the same listener and opens.
    provider.arrivals.refuse_open = false;
    provider.resident.claimed = false;
    provider.resident.read_once = hello.items;
    provider.resident.announceAccept();
    _ = try provider.runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 1), provider.arrivals.opened_sessions);
    try std.testing.expectEqual(@as(usize, 1), provider.arrivals.arrival_failures);
    try std.testing.expectEqual(@as(usize, 0), provider.arrivals.listener_failures);
    try std.testing.expectEqual(@as(usize, 1), provider.runtime.resident_wires.count());
    try std.testing.expect(provider.runtime.terminal_failure == null);
}

test "a retired arrival whose close fails keeps the failure first and a later violation in the batch joins it" {
    var provider: Provider = undefined;
    try provider.create(false);
    defer provider.destroy();

    // The observer cannot reserve, so the arrival retires locally and its
    // connection closes, and that close fails. The same drained batch then
    // reports a connect record the dialer-less resident cannot own.
    provider.arrivals.refuse_reserve = true;
    provider.resident.close_failure = .init(error.ConnectionLost);
    provider.resident.trailing_record = .{ .subject = 5, .events = net.multiplexed_resident.ev_connect };
    provider.resident.announceAccept();
    // The step that served the batch reports the violation it found, and the
    // latch keeps the close failure as the cause every later step reports.
    try std.testing.expectError(error.ProviderContract, provider.runtime.stepAny(0));
    const latched = provider.runtime.terminal_failure orelse return error.NotLatched;
    try std.testing.expectEqual(error.ConnectionLost, latched.chain.cause);
    try std.testing.expectEqual(@as(?anyerror, error.ProviderContract), latched.chain.secondary_cause);
    try std.testing.expectEqual(@as(u16, 1), latched.chain.secondary_count);
    // The arrival was retired before the close failed, and released once.
    try std.testing.expectEqual(@as(usize, 1), provider.arrivals.arrival_failures);
    try std.testing.expectEqual(error.OutOfMemory, provider.arrivals.arrival_cause.?);
    try std.testing.expectEqual(@as(usize, 1), provider.resident.close_calls);
    try std.testing.expectEqual(@as(usize, 0), provider.runtime.pending_opens.items.len);
    try std.testing.expectEqual(@as(usize, 0), provider.runtime.resident_wires.count());
    try std.testing.expectEqual(provider.seat, provider.arrivals.held);
    try std.testing.expectError(error.ConnectionLost, provider.runtime.stepAny(0));
}

test "a contract violation on an accepted connection keeps its close failure as the consequence" {
    var provider: Provider = undefined;
    try provider.create(true);
    defer provider.destroy();

    provider.resident.fail_remote_key = true;
    provider.resident.close_failure = .init(error.ConnectionLost);
    provider.resident.announceAccept();
    try std.testing.expectError(error.ProviderContract, provider.runtime.stepAny(0));
    const latched = provider.runtime.terminal_failure orelse return error.NotLatched;
    try std.testing.expectEqual(error.ProviderContract, latched.chain.cause);
    try std.testing.expectEqual(@as(?anyerror, error.ConnectionLost), latched.chain.secondary_cause);
    try std.testing.expectEqual(@as(u16, 1), latched.chain.secondary_count);
    try std.testing.expectEqual(@as(usize, 1), provider.resident.close_calls);
    try std.testing.expectEqual(@as(usize, 0), provider.runtime.resident_wires.count());
    try std.testing.expectEqual(provider.seat, provider.arrivals.held);
    try std.testing.expectError(error.ProviderContract, provider.runtime.stepAny(0));
}

/// Step a session-scoped wait until it stops with an error, a few times at most: the
/// rig's own resident may be the ready source in a given step.
fn stepSessionUntilStop(scene: *Scene) !void {
    for (0..8) |_| _ = try scene.rig.runtime.stepSession(scene.rig.session, 0);
    return error.NoStopReported;
}

/// A bounded `pumpUntilFlag` that nothing sets: it ends on a failure, or on
/// the deadline.
fn pumpBounded(scene: *Scene, budget_ms: i32) !void {
    var never = false;
    try scene.rig.runtime.pumpUntilFlag(scene.rig.session, &never, .{ .ms = budget_ms });
}

test "latched in a batch: a session wait stops on an accepted connection's contract violation" {
    const scene = try Scene.create();
    defer std.testing.expect(scene.destroy()) catch @panic("allocator unbalanced");
    scene.accepting.fail_remote_key = true;
    scene.accepting.announceAccept();
    try std.testing.expectError(error.ProviderContract, stepSessionUntilStop(scene));
    const latched = scene.rig.runtime.terminal_failure orelse return error.NotLatched;
    try std.testing.expectEqual(error.ProviderContract, latched.chain.cause);
}

test "latched in a batch: a pump wait stops on an accepted connection's contract violation" {
    const scene = try Scene.create();
    defer std.testing.expect(scene.destroy()) catch @panic("allocator unbalanced");
    scene.accepting.fail_remote_key = true;
    scene.accepting.announceAccept();
    try std.testing.expectError(error.ProviderContract, pumpBounded(scene, 2_000));
}

test "latched in a batch: a session wait stops on a retired arrival's failed close" {
    const scene = try Scene.create();
    defer std.testing.expect(scene.destroy()) catch @panic("allocator unbalanced");
    scene.arrivals.refuse_reserve = true;
    scene.accepting.close_failure = .init(error.ConnectionLost);
    scene.accepting.announceAccept();
    try std.testing.expectError(error.ConnectionLost, stepSessionUntilStop(scene));
    try std.testing.expectEqual(@as(usize, 1), scene.arrivals.arrival_failures);
    try std.testing.expectEqual(@as(usize, 1), scene.accepting.close_calls);
}

test "latched in a batch: a pump wait stops on a retired arrival's failed close" {
    const scene = try Scene.create();
    defer std.testing.expect(scene.destroy()) catch @panic("allocator unbalanced");
    scene.arrivals.refuse_reserve = true;
    scene.accepting.close_failure = .init(error.ConnectionLost);
    scene.accepting.announceAccept();
    try std.testing.expectError(error.ConnectionLost, pumpBounded(scene, 2_000));
    try std.testing.expectEqual(@as(usize, 1), scene.arrivals.arrival_failures);
}

test "latched in a batch: session waits keep running through an ordinary arrival refusal" {
    const scene = try Scene.create();
    defer std.testing.expect(scene.destroy()) catch @panic("allocator unbalanced");
    scene.arrivals.refuse_reserve = true;
    scene.accepting.announceAccept();
    for (0..4) |_| _ = try scene.rig.runtime.stepSession(scene.rig.session, 0);
    try std.testing.expectEqual(@as(usize, 1), scene.arrivals.arrival_failures);
    try std.testing.expect(scene.rig.runtime.terminal_failure == null);
    // A pump wait reaches its own deadline, not a failure, and the sibling serves.
    try std.testing.expectError(error.WaitTimedOut, pumpBounded(scene, 100));
    try scene.expectSiblingServes();
}
