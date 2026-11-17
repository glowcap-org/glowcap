//! The shared rig for retained-redeem-report scenarios: a fixture drawing from a
//! refusing allocator, plus the raw acceptor whose hello opens the redeem.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const net = glowcap.net;
const fx = @import("open_fixture.zig");
const Fixture = fx.Fixture;
const retry_ms = fx.retry_ms;
const harness = @import("../../engine/node/harness.zig");
const RawPartner = @import("raw_partner.zig").RawPartner;
const AcceptOwnershipResident = @import("../host_runtime_multiplexed/residents.zig").AcceptOwnershipResident;
const FailingOnce = @import("../../support/failing_once.zig").FailingOnce;

pub const never = std.math.maxInt(usize);
pub const sweep_bound = 96;

/// One redeem scenario: a fixture drawing from a refusing allocator, and the
/// raw acceptor whose hello opens the redeem session.
pub const Rig = struct {
    failing: FailingOnce,
    f: Fixture,
    partner: RawPartner,
    hello: std.ArrayList(u8),
    recipient: glowcap.ocapn.engine.PeerHandle = undefined,
    has_recipient: bool = false,
    deinited: bool = false,

    pub fn init(self: *Rig, handshake: @FieldType(driver.SessionOptions, "handshake")) !void {
        try self.initRetrying(.{}, handshake, .{ .max_attempts = 1 });
    }

    /// Either face with a resident that aborts a close its partner never reads.
    pub fn initAbortable(self: *Rig, blocking: bool, handshake: @FieldType(driver.SessionOptions, "handshake")) !void {
        try self.initRetrying(.{ .blocking = blocking, .abortable = true }, handshake, .{ .max_attempts = 1 });
    }

    /// Either face, named by `blocking`.
    pub fn initOn(self: *Rig, blocking: bool, handshake: @FieldType(driver.SessionOptions, "handshake")) !void {
        try self.initRetrying(.{ .blocking = blocking }, handshake, .{ .max_attempts = 1 });
    }

    /// The one constructor: it initializes every field the scenario reads, so
    /// a `Rig` declared `undefined` starts from nothing.
    pub fn initRetrying(
        self: *Rig,
        mode: fx.Mode,
        handshake: @FieldType(driver.SessionOptions, "handshake"),
        policy: @FieldType(driver.SessionOptions, "dial_retry"),
    ) !void {
        self.has_recipient = false;
        self.deinited = false;
        self.failing = FailingOnce.init(std.testing.allocator, never);
        try self.f.startUsing(self.failing.allocator(), mode, handshake, policy);
        try std.testing.expectEqual(mode.blocking, self.f.runtime.drive == .blocking);
        try std.testing.expectEqual(mode.abortable, self.f.resident.abortable);
        const profile: model.transport.Metadata = .{ .symbol = fx.transport, .designator_scheme = .address };
        self.partner = try RawPartner.init(std.testing.allocator, self.f.threaded.io(), null, .acceptor, fx.transport, profile, "remote.test:1");
        self.hello = .empty;
        try self.partner.takeWire(&self.hello);
    }

    /// Idempotent, so a scenario may tear down at a named point and still
    /// defer the call.
    pub fn deinit(self: *Rig) void {
        if (self.deinited) return;
        self.deinited = true;
        self.partner.deinit();
        self.hello.deinit(std.testing.allocator);
        self.f.stop();
        std.testing.expect(self.failing.balanced()) catch @panic("the runtime kept memory after teardown");
    }

    /// Refuse the allocation `k` places after the next one.
    pub fn arm(self: *Rig, k: usize) void {
        self.failing.induced = false;
        self.failing.fail_index = self.failing.alloc_index + k;
    }

    pub fn restore(self: *Rig) void {
        self.failing.fail_index = never;
    }

    /// A step that tolerates only a memory refusal.
    pub fn step(self: *Rig) !void {
        _ = self.f.runtime.stepAny(0) catch |err| if (err != error.OutOfMemory) return err;
    }

    /// Hold the memory retry deadline in the future, as a prior refusal does,
    /// so a verdict produced now waits for the pass the next due attempt runs.
    pub fn holdDeadline(self: *Rig) void {
        self.f.runtime.core.memory_retry_due_ms = self.f.runtime.nowMs() + retry_ms;
    }

    /// The armed memory deadline gates the Host's runnable-work predicate, the
    /// one fact the C driver step and Loam progress loops read.
    pub fn expectGated(self: *const Rig) !void {
        const core = self.f.runtime.core;
        try std.testing.expect(core.memory_retry_due_ms != null);
        try std.testing.expect(!core.hasRunnableWork());
    }

    /// Let the held deadline fall due.
    pub fn becomeDue(self: *Rig) void {
        self.f.clock.advanceMs(retry_ms + 1);
    }

    /// The seats the core promised to admitted waiters, and the action queue's
    /// live length and capacity, read from the core's own counters.
    pub fn promised(self: *const Rig) usize {
        return self.f.runtime.core.node.redeems.promisedActions();
    }

    pub fn queueCapacity(self: *const Rig) usize {
        return self.f.runtime.core.node.actions.queue.list.capacity;
    }

    pub fn queueLen(self: *const Rig) usize {
        return self.f.runtime.core.node.actions.queue.liveLen();
    }

    /// Admit one more waiter on the fixture peer's pending exporter: a signed
    /// give redeemed through the public `Node.acceptGive`, each on its own held
    /// answer so the node never deduplicates it. The first call stages the
    /// dial, and every later call joins it and promises one more action seat.
    pub fn giveWaiter(self: *Rig, index: usize) !void {
        const node = &self.f.runtime.core.node;
        if (!self.has_recipient) {
            self.recipient = try node.registerPeer(.{});
            self.has_recipient = true;
        }
        const uri = try Fixture.alternativeLocatorUri(std.testing.allocator);
        defer std.testing.allocator.free(uri);
        var give: [24]u8 = undefined;
        const bytes = try std.mem.print(&give, "give-{d}", .{index});
        const target = try harness.holdAnswer(node, self.recipient, 100 + index);
        try node.acceptGive(self.recipient, target, bytes, uri);
    }

    /// Join further waiters until their promised seats fill the queue's
    /// current capacity, and return how many joined. The next-route report
    /// then needs one seat more than the queue holds, so its reserve must
    /// allocate. Each join is a public admission with no step between, and the
    /// queue stays empty, so no escrow is touched.
    pub fn fillPromisedSeats(self: *Rig, first_index: usize) !usize {
        var admitted: usize = 0;
        while (self.promised() < self.queueCapacity()) : (admitted += 1) {
            try std.testing.expect(admitted < 256);
            try self.giveWaiter(first_index + admitted);
        }
        try std.testing.expectEqual(self.queueCapacity(), self.promised());
        try std.testing.expectEqual(@as(usize, 0), self.queueLen());
        return admitted;
    }

    /// Open the redeem's connect so the row sits in its handshake with a wire.
    pub fn connect(self: *Rig) !void {
        self.f.resident.hold_connect = true;
        self.f.resident.connect_ready_at_start = true;
        self.f.resident.connect_succeeds = true;
        try self.f.enliven();
        try self.step();
        try std.testing.expectEqual(@as(usize, 1), self.rows());
        try std.testing.expect(self.stage() == .handshake);
    }

    /// Hand the session the partner's hello, which opens it.
    pub fn deliverHello(self: *Rig) !void {
        self.f.resident.read_once = self.hello.items;
        self.f.resident.held_record = .{
            .subject = AcceptOwnershipResident.conn_id,
            .events = net.multiplexed_resident.ev_readable,
        };
        _ = try self.f.resident.wake.nudge();
    }

    /// Open the redeem and leave its opened report ready behind a held
    /// deadline, owning its session and wire.
    pub fn readyOpened(self: *Rig) !void {
        try self.connect();
        self.holdDeadline();
        try self.deliverHello();
        try self.step();
        try std.testing.expectEqual(@as(usize, 1), self.rows());
        try std.testing.expect(self.stage() == .opened_report);
        try std.testing.expect(self.f.runtime.pending_opens.items[0].stage.opened_report.wait == .ready);
    }

    /// The resident reports the connection closed.
    pub fn closeEvent(self: *Rig) !void {
        self.f.resident.held_record = .{
            .subject = AcceptOwnershipResident.conn_id,
            .events = net.multiplexed_resident.ev_closed,
        };
        _ = try self.f.resident.wake.nudge();
    }

    /// The partner's end of stream reaches the session.
    pub fn endOfStream(self: *Rig) !void {
        self.f.resident.read_result = 0;
        self.f.resident.held_record = .{
            .subject = AcceptOwnershipResident.conn_id,
            .events = net.multiplexed_resident.ev_readable,
        };
        _ = try self.f.resident.wake.nudge();
    }

    /// Stop the scripted connect from completing for later dials.
    pub fn quietConnects(self: *Rig) void {
        self.f.resident.connect_ready_at_start = false;
        self.f.resident.connect_succeeds = false;
    }

    pub fn rows(self: *const Rig) usize {
        return self.f.runtime.pending_opens.items.len;
    }

    pub fn stage(self: *const Rig) std.meta.Tag(@TypeOf(self.f.runtime.pending_opens.items[0].stage)) {
        return self.f.runtime.pending_opens.items[0].stage;
    }

    /// Whether the first row is retained for the memory clock.
    pub fn memoryRefused(self: *const Rig) bool {
        if (self.rows() == 0) return false;
        return switch (self.f.runtime.pending_opens.items[0].stage) {
            .opened_report => |report| report.wait == .memory_refused,
            .failed_report => |report| report.wait == .memory_refused,
            else => false,
        };
    }

    /// Return memory and step through due attempts, leaving the row set as it is.
    pub fn settleFor(self: *Rig, rounds: usize) !void {
        self.restore();
        for (0..rounds) |_| {
            self.becomeDue();
            try self.step();
        }
    }

    /// Return memory, then step through due attempts until the row settles.
    pub fn settle(self: *Rig) !void {
        self.restore();
        var rounds: usize = 0;
        while (self.rows() != 0 and rounds < 16) : (rounds += 1) {
            self.becomeDue();
            try self.step();
        }
        try std.testing.expectEqual(@as(usize, 0), self.rows());
    }
};
