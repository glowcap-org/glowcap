//! The runtime's dial-retry seam (ADR-0082 policy, ADR-0193 execution): a
//! transient resident dial fault parks its row for the interval and
//! re-issues the same session, a re-issue that faults at start is one more
//! attempt on the same policy, a permanent fault fails at once, the attempt
//! budget exhausts, and a handshake deadline shorter than one interval
//! refuses the retry without waiting.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const net = glowcap.net;
const tcp = glowcap.net.tcp;

const harness = @import("harness.zig");
const DialRecorder = harness.DialRecorder;
const fixtures = @import("../host_runtime_multiplexed/residents.zig");
const FakeResident = fixtures.FakeResident;
const Treasure = fixtures.Treasure;

const retry_interval_ms = 30;

const OutcomeLog = struct {
    kinds: [8]driver.DialOutcome = undefined,
    attempts: [8]u32 = undefined,
    len: u32 = 0,
};

fn logOutcome(ctx: *anyopaque, outcome: driver.DialOutcome, attempt: u32) void {
    const self: *OutcomeLog = @ptrCast(@alignCast(ctx));
    if (self.len >= self.kinds.len) return;
    self.kinds[self.len] = outcome;
    self.attempts[self.len] = attempt;
    self.len += 1;
}

/// A client runtime whose dial table holds no stream netlayer, so every dial
/// rides the fake resident and its injected dial faults.
fn retryClient(
    allocator: std.mem.Allocator,
    io: std.Io,
    fake: *FakeResident,
    options: driver.SessionOptions,
) !driver.HostRuntime {
    var client = try driver.HostRuntime.init(allocator, io, .{}, .ephemeral, options);
    errdefer client.deinit();
    _ = try client.addResident(model.transport.Known.tcp.metadata(), fake.multiplexedResident());
    return client;
}

/// The partner loop: accept the re-issued dial's connection, publish the
/// treasure, and step the server while the client parks and handshakes.
fn stepServer(
    server: *driver.Server,
    served: *?*driver.Session,
) !void {
    if (served.* == null and try server.waitAcceptable(0)) {
        // A retried dial leaves its failed predecessor in the backlog. The
        // runtime fails that arrival out of its accept set, and the next
        // one is the live connection.
        if (server.accept()) |session| {
            served.* = session;
            _ = try served.*.?.publish("treasure", Treasure, .{});
            try served.*.?.attend();
        } else |_| {}
    }
    while (try server.runtime.stepAny(0) != null) {}
}

fn retryOptions(log: *OutcomeLog, policy: driver.DialPolicy) driver.SessionOptions {
    return .{
        .frame_cap = harness.opts.frame_cap,
        .handshake = harness.opts.handshake,
        .settle = harness.opts.settle,
        .dial_retry = policy,
        .dial_outcome = .{ .ctx = log, .report = logOutcome },
    };
}

test "a transient resident dial fault parks the row and connects on the next attempt" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try driver.listen(
        allocator,
        io,
        .{ .symbols = &.{.tcp} },
        model.transport.tcp,
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        harness.opts,
    );
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const designator = try allocator.dupe(u8, try server.localDesignator(&addr_buf));
    defer allocator.free(designator);

    var fake = try FakeResident.init(allocator);
    defer fake.deinit();
    fake.fail_dial_transient = 1;
    var log: OutcomeLog = .{};
    var client = try retryClient(allocator, io, &fake, retryOptions(
        &log,
        .{ .max_attempts = 5, .retry_interval_ms = retry_interval_ms },
    ));
    defer client.deinit();
    var recorder = DialRecorder{};

    try client.startDial(.{
        .transport = model.transport.tcp,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    }, .inherit, 7, .{
        .ctx = &recorder,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });

    var served: ?*driver.Session = null;
    defer if (served) |s| s.deinit();
    var rounds: usize = 0;
    while (recorder.opened_session == null and recorder.failed_err == null and rounds < 2_000) : (rounds += 1) {
        _ = try client.stepAny(retry_interval_ms * 3);
        try stepServer(server, &served);
    }
    try std.testing.expectEqual(@as(?anyerror, null), recorder.failed_err);
    const opened = recorder.opened_session orelse return error.DialNeverOpened;
    // The failed attempt's socket is gone; the re-issued one is live.
    try std.testing.expectEqual(@as(usize, 1), fake.conns.count());
    try client.releaseWire(opened);

    try std.testing.expectEqual(@as(u32, 2), log.len);
    try std.testing.expectEqual(driver.DialOutcome.transient_retry, log.kinds[0]);
    try std.testing.expectEqual(@as(u32, 1), log.attempts[0]);
    try std.testing.expectEqual(driver.DialOutcome.ok, log.kinds[1]);
    try std.testing.expectEqual(@as(u32, 2), log.attempts[1]);
}

test "a re-issued dial that faults at start parks again on the same policy" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try driver.listen(
        allocator,
        io,
        .{ .symbols = &.{.tcp} },
        model.transport.tcp,
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        harness.opts,
    );
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const designator = try allocator.dupe(u8, try server.localDesignator(&addr_buf));
    defer allocator.free(designator);

    var fake = try FakeResident.init(allocator);
    defer fake.deinit();
    // The first finish faults, the second start faults, the third connects.
    fake.fail_dial_transient = 1;
    fake.fail_start_on_call = 2;
    var log: OutcomeLog = .{};
    var client = try retryClient(allocator, io, &fake, retryOptions(
        &log,
        .{ .max_attempts = 5, .retry_interval_ms = retry_interval_ms },
    ));
    defer client.deinit();
    var recorder = DialRecorder{};

    try client.startDial(.{
        .transport = model.transport.tcp,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    }, .inherit, 8, .{
        .ctx = &recorder,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });

    var served: ?*driver.Session = null;
    defer if (served) |s| s.deinit();
    var rounds: usize = 0;
    while (recorder.opened_session == null and recorder.failed_err == null and rounds < 2_000) : (rounds += 1) {
        _ = try client.stepAny(retry_interval_ms * 3);
        try stepServer(server, &served);
    }
    try std.testing.expectEqual(@as(?anyerror, null), recorder.failed_err);
    const opened = recorder.opened_session orelse return error.DialNeverOpened;
    try std.testing.expectEqual(@as(u32, 3), fake.start_calls);
    try client.releaseWire(opened);

    try std.testing.expectEqual(@as(u32, 3), log.len);
    try std.testing.expectEqual(driver.DialOutcome.transient_retry, log.kinds[0]);
    try std.testing.expectEqual(@as(u32, 1), log.attempts[0]);
    try std.testing.expectEqual(driver.DialOutcome.transient_retry, log.kinds[1]);
    try std.testing.expectEqual(@as(u32, 2), log.attempts[1]);
    try std.testing.expectEqual(driver.DialOutcome.ok, log.kinds[2]);
    try std.testing.expectEqual(@as(u32, 3), log.attempts[2]);
}

test "a permanent resident dial fault fails at once without a retry" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try driver.listen(
        allocator,
        io,
        .{ .symbols = &.{.tcp} },
        model.transport.tcp,
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        harness.opts,
    );
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const designator = try allocator.dupe(u8, try server.localDesignator(&addr_buf));
    defer allocator.free(designator);

    var fake = try FakeResident.init(allocator);
    defer fake.deinit();
    fake.fail_dial_permanent = true;
    var log: OutcomeLog = .{};
    var client = try retryClient(allocator, io, &fake, retryOptions(
        &log,
        .{ .max_attempts = 5, .retry_interval_ms = retry_interval_ms },
    ));
    defer client.deinit();
    var recorder = DialRecorder{};

    try client.startDial(.{
        .transport = model.transport.tcp,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    }, .inherit, 8, .{
        .ctx = &recorder,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });

    var rounds: usize = 0;
    while (recorder.failed_err == null and rounds < 2_000) : (rounds += 1) {
        _ = try client.stepAny(0);
    }
    try std.testing.expectEqual(@as(?anyerror, error.ConnectionRefused), recorder.failed_err);
    try std.testing.expectEqual(@as(u32, 1), log.len);
    try std.testing.expectEqual(driver.DialOutcome.permanent, log.kinds[0]);
    try std.testing.expectEqual(@as(u32, 1), log.attempts[0]);
    try std.testing.expectEqual(@as(usize, 0), fake.conns.count());
}

test "the dial attempt budget exhausts on repeated transient faults" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try driver.listen(
        allocator,
        io,
        .{ .symbols = &.{.tcp} },
        model.transport.tcp,
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        harness.opts,
    );
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const designator = try allocator.dupe(u8, try server.localDesignator(&addr_buf));
    defer allocator.free(designator);

    var fake = try FakeResident.init(allocator);
    defer fake.deinit();
    fake.fail_dial_transient = 5;
    var log: OutcomeLog = .{};
    var client = try retryClient(allocator, io, &fake, retryOptions(
        &log,
        .{ .max_attempts = 2, .retry_interval_ms = retry_interval_ms },
    ));
    defer client.deinit();
    var recorder = DialRecorder{};

    try client.startDial(.{
        .transport = model.transport.tcp,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    }, .inherit, 9, .{
        .ctx = &recorder,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });

    const started_ms = net.clock.nowMs(io);
    var rounds: usize = 0;
    while (recorder.failed_err == null and rounds < 2_000) : (rounds += 1) {
        _ = try client.stepAny(retry_interval_ms * 3);
    }
    const elapsed_ms = net.clock.nowMs(io) - started_ms;
    try std.testing.expectEqual(@as(?anyerror, error.NetworkUnreachable), recorder.failed_err);
    try std.testing.expectEqual(@as(u32, 2), log.len);
    try std.testing.expectEqual(driver.DialOutcome.transient_retry, log.kinds[0]);
    try std.testing.expectEqual(driver.DialOutcome.exhausted, log.kinds[1]);
    try std.testing.expectEqual(@as(u32, 2), log.attempts[1]);
    // One interval elapsed between the two attempts.
    try std.testing.expect(elapsed_ms >= retry_interval_ms);
}

test "a handshake deadline shorter than one interval refuses the retry without waiting" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try driver.listen(
        allocator,
        io,
        .{ .symbols = &.{.tcp} },
        model.transport.tcp,
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        harness.opts,
    );
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const designator = try allocator.dupe(u8, try server.localDesignator(&addr_buf));
    defer allocator.free(designator);

    var fake = try FakeResident.init(allocator);
    defer fake.deinit();
    fake.fail_dial_transient = 1;
    var log: OutcomeLog = .{};
    var client = try retryClient(allocator, io, &fake, .{
        .frame_cap = harness.opts.frame_cap,
        .handshake = .{ .ms = 10 },
        .settle = harness.opts.settle,
        .dial_retry = .{ .max_attempts = 5, .retry_interval_ms = retry_interval_ms },
        .dial_outcome = .{ .ctx = &log, .report = logOutcome },
    });
    defer client.deinit();
    var recorder = DialRecorder{};

    try client.startDial(.{
        .transport = model.transport.tcp,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    }, .inherit, 10, .{
        .ctx = &recorder,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });

    const started_ms = net.clock.nowMs(io);
    var rounds: usize = 0;
    while (recorder.failed_err == null and rounds < 2_000) : (rounds += 1) {
        _ = try client.stepAny(0);
    }
    const elapsed_ms = net.clock.nowMs(io) - started_ms;
    // The dial fault itself is the failure; the retry never ran, so no
    // interval passed waiting for it.
    try std.testing.expectEqual(@as(?anyerror, error.NetworkUnreachable), recorder.failed_err);
    try std.testing.expectEqual(@as(u32, 1), log.len);
    try std.testing.expectEqual(driver.DialOutcome.permanent, log.kinds[0]);
    try std.testing.expect(elapsed_ms < retry_interval_ms);
}
