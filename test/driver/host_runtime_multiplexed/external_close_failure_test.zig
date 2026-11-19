//! A foreign stream provider's `conn_close` failure on a session the
//! application closes or drops, driven through `HostRuntime` over a real
//! dialed wire. A close the application awaits reaches the stepped close
//! observer once, with the provider's primary, carrier phase and secondary.
//! An application that releases the session leaves the provider's sink the
//! one recipient: `releaseWire` submits the awaited close and `dropWire`
//! detaches the wire, so the sink reports to the runtime's unhandled-failure
//! observer once. A step runs a submitted close to its claim, so the state in
//! between is read in `test/net/external_close_claim_test.zig`.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");
const c = @import("c_abi_shared");
const tcp_provider = @import("c_abi_net_transport_tcp");
const stream_completion = @import("c_abi_driver").stream_completion;
const harness = @import("../host_runtime_step/harness.zig");
const SteppedClock = @import("../../support/stepped_clock.zig").SteppedClock;

const driver = glowcap.driver;
const driver_core = driver.core;
const model = glowcap.ocapn.model;
const net = glowcap.net;
const external = net.external_completion;

const ExternalBackend = external.CompletionBackend(net.Backend);
const ExternalResident = net.completion_resident.Resident(ExternalBackend, external.ResidentPolicy(ExternalBackend, external.PlatformRefused(net.Backend)));

const CloseFn = @TypeOf(@as(c.GlowcapStreamTransport, undefined).conn_close);
var real_close: CloseFn = null;
var failing_closes: usize = 0;

const WriteFn = @TypeOf(@as(c.GlowcapStreamTransport, undefined).try_write);
var real_write: WriteFn = null;
/// Write attempts the provider refuses before it takes bytes again.
var held_writes: usize = 0;
var refused_writes: usize = 0;
/// The next write can fail once and return its own structured cause.
var next_write: DrainWrite = .{ .fail = false };
var failed_writes: usize = 0;
var write_calls: usize = 0;
/// A pre-existing connection report has a separate lifetime from a transfer.
var take_name: ?[]const u8 = null;
var take_calls: usize = 0;
const TakeFn = @TypeOf(@as(c.GlowcapStreamTransport, undefined).conn_take_failure);
var real_take: TakeFn = null;
/// A healthy `conn_close` returns the real close unchanged.
var healthy_close: bool = false;
var close_calls: usize = 0;

fn heldWrite(ctx: ?*anyopaque, conn: ?*anyopaque, bytes: ?[*]const u8, len: usize, detail: ?*c.GlowcapProviderFailure) callconv(.c) isize {
    if (held_writes != 0) {
        held_writes -= 1;
        refused_writes += 1;
        return c.GLOWCAP_TRANSPORT_WOULD_BLOCK;
    }
    write_calls += 1;
    if (next_write.fail) {
        if (next_write.kept) |reason| if (detail) |out| {
            out.* = c.transport_provider.emptyProviderFailure();
            out.result = c.GLOWCAP_ERR_IO;
            out.carrier_phase = c.transport_provider.GLOWCAP_CARRIER_PHASE_TRANSMIT;
            out.carrier_detail_flags = c.transport_provider.GLOWCAP_CARRIER_DETAIL_ENGINE_CODE;
            out.carrier_engine_code = -19;
            out.primary_name = reason.ptr;
            out.primary_name_len = reason.len;
        };
        next_write = .{ .fail = false };
        failed_writes += 1;
        return -1;
    }
    return real_write.?(ctx, conn, bytes, len, detail);
}

fn keptTake(ctx: ?*anyopaque, conn: ?*anyopaque, out: ?*c.GlowcapProviderFailure) callconv(.c) void {
    take_calls += 1;
    const name = take_name orelse {
        if (real_take) |take| take(ctx, conn, out);
        return;
    };
    take_name = null;
    const report = out orelse return;
    report.* = c.transport_provider.emptyProviderFailure();
    report.result = c.GLOWCAP_ERR_IO;
    report.carrier_phase = c.transport_provider.GLOWCAP_CARRIER_PHASE_RECEIVE;
    report.carrier_detail_flags = c.transport_provider.GLOWCAP_CARRIER_DETAIL_ENGINE_CODE;
    report.carrier_engine_code = -12;
    report.primary_name = name.ptr;
    report.primary_name_len = name.len;
}

/// The real close, then a typed cleanup failure with a secondary in its place.
fn failingClose(ctx: ?*anyopaque, conn: ?*anyopaque, out: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    const rc = real_close.?(ctx, conn, out);
    close_calls += 1;
    if (rc != c.GLOWCAP_OK or healthy_close) return rc;
    failing_closes += 1;
    const report = out orelse return c.GLOWCAP_ERR_IO;
    report.* = c.transport_provider.emptyProviderFailure();
    report.result = c.GLOWCAP_ERR_IO;
    const primary = "LiveCloseFailed";
    report.primary_name = primary.ptr;
    report.primary_name_len = primary.len;
    report.carrier_phase = c.transport_provider.GLOWCAP_CARRIER_PHASE_SHUTDOWN;
    const secondary = "LiveCloseCleanup";
    report.secondary_result = c.GLOWCAP_ERR_CLOSED;
    report.secondary_name = secondary.ptr;
    report.secondary_name_len = secondary.len;
    report.secondary_count = 1;
    return c.GLOWCAP_ERR_IO;
}

/// What the runtime's two failure recipients heard.
const Recipients = struct {
    unhandled: usize = 0,
    unhandled_failure: ?driver.OperationFailure = null,
    closed: usize = 0,
    closed_failure: ?driver.OperationFailure = null,

    fn report(ctx: *anyopaque, failure: driver.OperationFailure) void {
        const self: *Recipients = @ptrCast(@alignCast(ctx));
        self.unhandled += 1;
        self.unhandled_failure = failure;
    }

    fn reserve(_: *anyopaque) anyerror!void {}

    fn release(_: *anyopaque) void {}

    fn closedSession(ctx: *anyopaque, _: *driver_core.HostSession, failure: ?driver.OperationFailure) void {
        const self: *Recipients = @ptrCast(@alignCast(ctx));
        self.closed += 1;
        self.closed_failure = failure;
    }

    fn discard(_: *anyopaque, _: driver_core.HostAction) bool {
        return false;
    }
};

/// The provider's sink: its teardown reaches the runtime's observer, as the
/// C driver's stream resident does when no release owns the failure.
const Sink = struct {
    runtime: ?*driver.HostRuntime = null,
    violations: usize = 0,
    teardowns: usize = 0,

    fn violation(ctx: *anyopaque, _: []const u8) void {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        self.violations += 1;
    }

    fn teardown(ctx: *anyopaque, failure: driver.OperationFailure) void {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        self.teardowns += 1;
        self.runtime.?.reportUnhandledFailure(failure);
    }
};

/// A listening peer, a client runtime whose tcp resident is the external
/// adapter over the C tcp provider with a failing `conn_close`, and one
/// established client session.
const Fixture = struct {
    threaded: std.Io.Threaded,
    /// The client runtime's clock: it moves only when read, so a test crosses
    /// the carrier-close deadline at the moment it names.
    clock: SteppedClock = undefined,
    netlayer: ?*tcp_provider.GlowcapTcpNetlayer = null,
    sink: Sink = .{},
    recipients: Recipients = .{},
    stream: stream_completion.StreamProvider = undefined,
    providers: [1]external.Provider = undefined,
    resident: *ExternalResident = undefined,
    server: driver.HostRuntime = undefined,
    server_accepts: harness.DialRecorder = .{},
    client: driver.HostRuntime = undefined,
    dials: harness.DialRecorder = .{},
    locator: model.PeerLocator = undefined,
    allocator: std.mem.Allocator,

    fn start(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        self.threaded = std.Io.Threaded.init(allocator, .{});
        errdefer self.threaded.deinit();
        const io = self.threaded.io();

        const config: tcp_provider.GlowcapTcpConfig = .{ .stream = .{ .keepalive_idle_sec = 0, .keepalive_interval_sec = 0, .keepalive_count = 0 }, .profiles = tcp_provider.GLOWCAP_TCP_PROFILES_ALL };
        try std.testing.expectEqual(c.GLOWCAP_OK, tcp_provider.glowcap_tcp_netlayer_new(&config, &self.netlayer));
        errdefer tcp_provider.glowcap_tcp_netlayer_release(self.netlayer);
        var package: c.GlowcapTransportProvider = undefined;
        try std.testing.expectEqual(c.GLOWCAP_OK, tcp_provider.glowcap_tcp_transport_provider(self.netlayer, &package));
        var table: c.GlowcapStreamTransport = @as(*const c.GlowcapStreamTransport, @ptrCast(@alignCast(package.entries.?[0].implementation.?))).*;
        real_close = table.conn_close;
        table.conn_close = failingClose;
        real_write = table.try_write;
        table.try_write = heldWrite;
        real_take = table.conn_take_failure;
        table.conn_take_failure = keptTake;
        take_name = null;
        take_calls = 0;
        held_writes = 0;
        refused_writes = 0;
        next_write = .{ .fail = false };
        failed_writes = 0;
        write_calls = 0;
        healthy_close = false;
        close_calls = 0;
        failing_closes = 0;

        self.stream = .{
            .allocator = allocator,
            .transport = model.transport.tcp,
            .table = table,
            .sink = .{ .ctx = &self.sink, .violation = Sink.violation, .teardown = Sink.teardown },
        };
        self.providers = .{self.stream.provider()};
        const backend = try ExternalBackend.initWithPlatform(allocator, .{ .providers = &self.providers }, try net.Backend.init(allocator, 64, 16, harness.frame_cap), 16, harness.frame_cap);
        const resident = try allocator.create(ExternalResident);
        errdefer allocator.destroy(resident);
        resident.* = try ExternalResident.init(allocator, backend, .{});
        self.resident = resident;
        errdefer resident.deinit();

        self.server = try driver.HostRuntime.init(allocator, io, .{ .symbols = &.{.tcp} }, .ephemeral, harness.steppedQuiet());
        errdefer self.server.deinit();
        var listener = try self.server.bindListener(model.transport.tcp, "127.0.0.1:0", .inherit);
        var prepared = switch (self.server.prepareListenerLocatorOutcome(&listener)) {
            .ready => |value| value,
            .failed => |failure| {
                if (self.server.closeListener(&listener)) |cleanup| self.server.noteTerminalOperationFailure(cleanup);
                return failure.cause;
            },
        };
        self.locator = try model.clonePeerLocator(allocator, prepared.value);
        errdefer model.freePeerLocator(allocator, self.locator);
        try self.server.activateOwnedListener(&listener, &prepared, 1, .{
            .ctx = &self.server_accepts,
            .opened = harness.DialRecorder.opened,
            .failed = harness.DialRecorder.failed,
        });
        _ = try self.server.selectOwnedListener(1);

        var options = harness.opts;
        options.unhandled_failure = .{ .ctx = &self.recipients, .report = Recipients.report };
        options.drive = .{ .stepped = .{
            .completion_sink = .{ .ctx = &self.recipients, .take = Recipients.discard },
            .close_observer = .{
                .ctx = &self.recipients,
                .reserve = Recipients.reserve,
                .release = Recipients.release,
                .closed = Recipients.closedSession,
            },
        } };
        self.clock = SteppedClock.init(io, 0, 1);
        self.client = try driver.HostRuntime.init(allocator, self.clock.io(), .{}, .ephemeral, options);
        errdefer self.client.deinit();
        self.sink.runtime = &self.client;
        _ = try self.client.addResident(model.transport.Known.tcp.metadata(), resident.resident());

        try self.client.startDial(self.locator, .inherit, 1, .{
            .ctx = &self.dials,
            .opened = harness.DialRecorder.opened,
            .failed = harness.DialRecorder.failed,
        });
        var rounds: usize = 0;
        while (self.dials.opened_session == null and rounds < 1_000) : (rounds += 1) {
            try self.step(10);
            try std.testing.expectEqual(@as(?anyerror, null), self.dials.failed_err);
        }
        try std.testing.expect(self.dials.opened_session != null);
    }

    fn deinit(self: *Fixture) void {
        self.client.deinit();
        self.server.deinit();
        model.freePeerLocator(self.allocator, self.locator);
        self.resident.deinit();
        self.allocator.destroy(self.resident);
        tcp_provider.glowcap_tcp_netlayer_release(self.netlayer);
        self.threaded.deinit();
    }

    /// One turn of the partner, then one of the client.
    fn step(self: *Fixture, timeout_ms: i32) !void {
        while (try self.server.stepAny(0) != null) {}
        _ = try self.client.stepAny(timeout_ms);
    }

    fn session(self: *const Fixture) *driver_core.HostSession {
        return self.dials.opened_session.?;
    }

    /// The close state of the one connection the resident holds, read only.
    /// Quiet turns that would expose a stale or repeated report.
    fn stepQuiet(self: *Fixture) !void {
        for (0..10) |_| try self.step(0);
    }
};

fn skip() bool {
    return !(builtin.target.os.tag == .linux or builtin.target.os.tag.isDarwin());
}

test "a live session close reports a provider close failure to the close observer once" {
    if (skip()) return error.SkipZigTest;
    var f: Fixture = .{ .threaded = undefined, .allocator = undefined };
    try f.start(std.testing.allocator);
    defer f.deinit();

    try f.client.beginSessionClose(f.session(), .cancel);
    var rounds: usize = 0;
    while (f.recipients.closed == 0 and rounds < 1_000) : (rounds += 1) try f.step(10);
    try f.stepQuiet();

    try std.testing.expectEqual(@as(usize, 1), failing_closes);
    try std.testing.expectEqual(@as(usize, 1), f.recipients.closed);
    const failure = f.recipients.closed_failure.?;
    try std.testing.expectEqualStrings("LiveCloseFailed", failure.chain.primaryName());
    try std.testing.expectEqual(net.carrier_failure.Phase.shutdown, failure.carrier_phase.?);
    try std.testing.expectEqualStrings("LiveCloseCleanup", failure.chain.secondaryName().?);
    try std.testing.expectEqual(@as(usize, 0), f.sink.teardowns);
    try std.testing.expectEqual(@as(usize, 0), f.sink.violations);
    try std.testing.expectEqual(@as(usize, 0), f.recipients.unhandled);
}

test "a session dropped over a still-armed receive poll reports a provider close failure once" {
    if (skip()) return error.SkipZigTest;
    var f: Fixture = .{ .threaded = undefined, .allocator = undefined };
    try f.start(std.testing.allocator);
    defer f.deinit();

    // An idle parked turn leaves the receive poll armed, so `releaseWire`
    // submits its awaited close over an armed poll and the dropped wire hands
    // the close to the provider sink.
    try f.step(10);
    try f.client.releaseWire(f.session());
    // The drop itself settles the submitted close with the provider sink,
    // before any further turn.
    try std.testing.expectEqual(@as(usize, 1), failing_closes);
    try std.testing.expectEqual(@as(usize, 1), f.sink.teardowns);
    try f.stepQuiet();

    try std.testing.expectEqual(@as(usize, 1), failing_closes);
    try std.testing.expectEqual(@as(usize, 1), f.sink.teardowns);
    try std.testing.expectEqual(@as(usize, 0), f.sink.violations);
    try std.testing.expectEqual(@as(usize, 1), f.recipients.unhandled);
    const failure = f.recipients.unhandled_failure.?;
    try std.testing.expectEqualStrings("LiveCloseFailed", failure.chain.primaryName());
    try std.testing.expectEqual(net.carrier_failure.Phase.shutdown, failure.carrier_phase.?);
    try std.testing.expectEqualStrings("LiveCloseCleanup", failure.chain.secondaryName().?);
    try std.testing.expectEqual(@as(usize, 0), f.recipients.closed);
    try std.testing.expect(f.resident.drained());
}

test "releasing an open session closes its wire and reports a provider close failure once" {
    if (skip()) return error.SkipZigTest;
    var f: Fixture = .{ .threaded = undefined, .allocator = undefined };
    try f.start(std.testing.allocator);
    defer f.deinit();

    // No close was begun: the release itself submits and detaches.
    try f.client.releaseWire(f.session());
    // The drop itself settles the submitted close with the provider sink,
    // before any further turn.
    try std.testing.expectEqual(@as(usize, 1), failing_closes);
    try std.testing.expectEqual(@as(usize, 1), f.sink.teardowns);
    try f.stepQuiet();

    try std.testing.expectEqual(@as(usize, 1), failing_closes);
    try std.testing.expectEqual(@as(usize, 1), f.sink.teardowns);
    try std.testing.expectEqual(@as(usize, 1), f.recipients.unhandled);
    try std.testing.expectEqual(@as(usize, 0), f.recipients.closed);
    try std.testing.expect(f.resident.drained());
}

test "dropping a session whose admitted bytes are still draining hands the close to the sink when they drain" {
    if (skip()) return error.SkipZigTest;
    var f: Fixture = .{ .threaded = undefined, .allocator = undefined };
    try f.start(std.testing.allocator);
    defer f.deinit();

    // The session stages a request the provider keeps refusing, so the
    // connection still holds admitted bytes when the application drops it.
    held_writes = 50;
    _ = try f.client.core.fetch(f.session(), "treasure");
    try f.client.releaseWire(f.session());
    // The drop retried the refused write and left bytes admitted.
    try std.testing.expect(refused_writes != 0 and held_writes != 0);
    // No close reached the provider and no recipient heard anything yet.
    try std.testing.expectEqual(@as(usize, 0), failing_closes);
    try std.testing.expectEqual(@as(usize, 0), f.sink.teardowns);
    try std.testing.expectEqual(@as(usize, 0), f.recipients.unhandled);

    held_writes = 0;
    var rounds: usize = 0;
    while (f.recipients.unhandled == 0 and rounds < 1_000) : (rounds += 1) try f.step(10);
    try f.stepQuiet();

    try std.testing.expectEqual(@as(usize, 1), failing_closes);
    try std.testing.expectEqual(@as(usize, 1), f.sink.teardowns);
    try std.testing.expectEqual(@as(usize, 1), f.recipients.unhandled);
    try std.testing.expectEqualStrings("LiveCloseFailed", f.recipients.unhandled_failure.?.chain.primaryName());
    try std.testing.expectEqual(@as(usize, 0), f.recipients.closed);
    try std.testing.expect(f.resident.drained());
}

/// Stage a request the provider refuses, then ask for the close while those
/// bytes are still admitted: the row drains with the provider holding every
/// byte. `earlier` is a failure the provider already keeps when the runtime
/// takes its one snapshot at the close request. Returns once the close
/// request has been refused at least once.
fn holdDrainingClose(f: *Fixture, earlier: ?[]const u8) !void {
    held_writes = 50;
    _ = try f.client.core.fetch(f.session(), "treasure");
    take_name = earlier;
    try f.client.beginSessionClose(f.session(), .cancel);
    var rounds: usize = 0;
    while (refused_writes == 0 and rounds < 100) : (rounds += 1) try f.step(10);
    try std.testing.expect(refused_writes != 0 and held_writes != 0);
    try std.testing.expectEqual(@as(usize, 0), close_calls);
    try std.testing.expectEqual(@as(usize, 0), f.recipients.closed);
    // The initial live snapshot consumes any earlier independent report.
    try std.testing.expectEqual(@as(?[]const u8, null), take_name);
}

/// A failed write supplies its optional name in that operation's output.
const DrainWrite = struct { fail: bool, kept: ?[]const u8 = null };

/// Let the held refusals lapse, run the close to its observer, and read the
/// session's retained close status on the same path.
fn finishDrainingClose(f: *Fixture, write: DrainWrite) !void {
    held_writes = 0;
    next_write = write;
    try std.testing.expect(take_name == null);
    var rounds: usize = 0;
    while (f.recipients.closed == 0 and rounds < 1_000) : (rounds += 1) try f.step(10);
    try f.stepQuiet();
}

/// The observer and `sessionCloseStatus` hold the same close failure: its
/// primary and secondary names, or none.
fn expectClosedWith(f: *Fixture, primary: ?[]const u8, secondary: ?[]const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), f.recipients.closed);
    const status = try f.client.sessionCloseStatus(f.session());
    const heard = [2]?driver.OperationFailure{ f.recipients.closed_failure, status.cause };
    for (heard) |failure| {
        const expected = primary orelse {
            try std.testing.expectEqual(@as(?driver.OperationFailure, null), failure);
            continue;
        };
        const actual = failure orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected, actual.chain.primaryName());
        if (std.mem.eql(u8, expected, "DrainWriteFailed")) {
            try std.testing.expectEqual(@as(?net.carrier_failure.Phase, .transmit), actual.carrier_phase);
            try std.testing.expectEqual(@as(?i32, -19), actual.carrier_detail.engine_code);
        } else if (std.mem.eql(u8, expected, "EarlierPeerFailure")) {
            try std.testing.expectEqual(@as(?net.carrier_failure.Phase, .receive), actual.carrier_phase);
            try std.testing.expectEqual(@as(?i32, -12), actual.carrier_detail.engine_code);
        }
        try std.testing.expectEqual(secondary == null, actual.chain.secondaryName() == null);
        if (secondary) |name| try std.testing.expectEqualStrings(name, actual.chain.secondaryName().?);
    }
}

test "a healthy drain on a closing session reports no failure" {
    if (skip()) return error.SkipZigTest;
    var f: Fixture = .{ .threaded = undefined, .allocator = undefined };
    try f.start(std.testing.allocator);
    defer f.deinit();
    healthy_close = true;

    try holdDrainingClose(&f, null);
    try finishDrainingClose(&f, .{ .fail = false });
    try expectClosedWith(&f, null, null);

    try std.testing.expectEqual(@as(usize, 0), failed_writes);
    try std.testing.expectEqual(@as(usize, 1), close_calls);
    try std.testing.expectEqual(@as(usize, 0), f.recipients.unhandled);
    try std.testing.expect(f.resident.drained());
}

test "a write that fails while a close drains reaches the close observer once with the provider's cause" {
    if (skip()) return error.SkipZigTest;
    var f: Fixture = .{ .threaded = undefined, .allocator = undefined };
    try f.start(std.testing.allocator);
    defer f.deinit();
    healthy_close = true;

    try holdDrainingClose(&f, null);
    const before = write_calls;
    try finishDrainingClose(&f, .{ .fail = true, .kept = "DrainWriteFailed" });
    try expectClosedWith(&f, "DrainWriteFailed", null);

    // The provider sees exactly one further write after the held attempts.
    try std.testing.expectEqual(@as(usize, 1), failed_writes);
    try std.testing.expectEqual(before + 1, write_calls);
    try std.testing.expectEqual(@as(usize, 1), close_calls);
    try std.testing.expectEqual(@as(usize, 0), f.recipients.unhandled);
    try std.testing.expectEqual(@as(usize, 0), f.sink.teardowns);
    try std.testing.expect(f.resident.drained());
}

test "a failed drain write with no provider cause leads the later provider close failure" {
    if (skip()) return error.SkipZigTest;
    var f: Fixture = .{ .threaded = undefined, .allocator = undefined };
    try f.start(std.testing.allocator);
    defer f.deinit();

    try holdDrainingClose(&f, null);
    try finishDrainingClose(&f, .{ .fail = true });
    try expectClosedWith(&f, "WriteFailed", "LiveCloseFailed");

    try std.testing.expectEqual(@as(usize, 1), failed_writes);
    try std.testing.expectEqual(@as(usize, 1), failing_closes);
    // The adapter's name for a provider write that returned -1.
    try std.testing.expectEqual(@as(usize, 0), f.recipients.unhandled);
    try std.testing.expect(f.resident.drained());
}

test "a drain write's exact report precedes the physical close and its cleanup" {
    if (skip()) return error.SkipZigTest;
    var f: Fixture = .{ .threaded = undefined, .allocator = undefined };
    try f.start(std.testing.allocator);
    defer f.deinit();

    try holdDrainingClose(&f, null);
    try finishDrainingClose(&f, .{ .fail = true, .kept = "DrainWriteFailed" });
    try expectClosedWith(&f, "DrainWriteFailed", "LiveCloseFailed");
    const status = try f.client.sessionCloseStatus(f.session());
    try std.testing.expectEqual(2, status.cause.?.chain.secondary_count);
    try std.testing.expectEqual(1, failed_writes);
    try std.testing.expectEqual(1, close_calls);
    try std.testing.expectEqual(0, f.recipients.unhandled);
}

test "a failed drain write follows a cause the close request already claimed" {
    if (skip()) return error.SkipZigTest;
    var f: Fixture = .{ .threaded = undefined, .allocator = undefined };
    try f.start(std.testing.allocator);
    defer f.deinit();
    healthy_close = true;

    // The snapshot claims the provider's earlier cause. The write fails later
    // with a cause of its own, so the claim opens again for it.
    try holdDrainingClose(&f, "EarlierPeerFailure");
    try finishDrainingClose(&f, .{ .fail = true, .kept = "DrainWriteFailed" });
    try expectClosedWith(&f, "EarlierPeerFailure", "DrainWriteFailed");

    try std.testing.expectEqual(@as(usize, 1), failed_writes);
    try std.testing.expectEqual(@as(usize, 0), f.recipients.unhandled);
    try std.testing.expect(f.resident.drained());
}

test "a dropped session's failed drain write has no recipient and leaves the close to the sink" {
    if (skip()) return error.SkipZigTest;
    var f: Fixture = .{ .threaded = undefined, .allocator = undefined };
    try f.start(std.testing.allocator);
    defer f.deinit();

    held_writes = 50;
    _ = try f.client.core.fetch(f.session(), "treasure");
    try f.client.releaseWire(f.session());
    try std.testing.expect(refused_writes != 0 and held_writes != 0);
    const takes = take_calls;
    held_writes = 0;
    next_write = .{ .fail = true, .kept = "DrainWriteFailed" };
    try std.testing.expect(take_name == null);
    var rounds: usize = 0;
    while (f.recipients.unhandled == 0 and rounds < 1_000) : (rounds += 1) try f.step(10);
    try f.stepQuiet();

    try std.testing.expectEqual(@as(usize, 1), failed_writes);
    // A detached close has no waiter to claim another independent cause.
    try std.testing.expectEqual(takes, take_calls);
    try std.testing.expect(take_name == null);
    try std.testing.expectEqual(@as(usize, 1), failing_closes);
    try std.testing.expectEqual(@as(usize, 1), f.sink.teardowns);
    try std.testing.expectEqual(@as(usize, 1), f.recipients.unhandled);
    try std.testing.expectEqualStrings("LiveCloseFailed", f.recipients.unhandled_failure.?.chain.primaryName());
    try std.testing.expectEqual(@as(usize, 0), f.recipients.closed);
    try std.testing.expect(f.resident.drained());
}

/// Past the runtime's carrier-close deadline.
const past_deadline_ms = 5_001;

test "a held close that times out before the partner reads reports the timeout and hands the physical close to the sink" {
    if (skip()) return error.SkipZigTest;
    var f: Fixture = .{ .threaded = undefined, .allocator = undefined };
    try f.start(std.testing.allocator);
    defer f.deinit();

    try holdDrainingClose(&f, null);
    f.clock.advanceMs(past_deadline_ms);
    try f.step(10);
    try f.stepQuiet();

    // The abort ended the wait before any write failed: the observer hears the
    // timeout, and the provider's close result goes to its own sink.
    try std.testing.expectEqual(@as(usize, 1), f.recipients.closed);
    try std.testing.expectEqualStrings("CloseTimedOut", f.recipients.closed_failure.?.chain.primaryName());
    try std.testing.expectEqual(@as(usize, 1), failing_closes);
    try std.testing.expectEqual(@as(usize, 1), f.sink.teardowns);
    try std.testing.expectEqual(@as(usize, 1), f.recipients.unhandled);
    try std.testing.expect(f.resident.drained());
}
