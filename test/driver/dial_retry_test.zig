//! `driver.DialRetry` (ADR-0082): DialError classification, discovery
//! budget lockstep with the C ABI, and CapTP-honest dial-retry.

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const driver_core = glowcap.driver.core;
const c_abi_host = @import("c_abi_host");
const DialError = glowcap.net.netlayer.DialError;

const RetryProbe = struct {
    hits: u32 = 0,
    fail_until: u32 = 3,
    result: u32 = 99,
};

fn probeDial(ctx: ?*anyopaque) DialError!u32 {
    const self: *RetryProbe = @ptrCast(@alignCast(ctx.?));
    self.hits += 1;
    if (self.hits < self.fail_until) return error.ConnectionLost;
    return self.result;
}

var sleep_count: u32 = 0;
fn probeSleep(ms: u64) void {
    _ = ms;
    sleep_count += 1;
}

const FatalProbe = struct { hits: u32 = 0 };

fn fatalDial(ctx: ?*anyopaque) DialError!void {
    const self: *FatalProbe = @ptrCast(@alignCast(ctx.?));
    self.hits += 1;
    return error.InvalidAddress;
}

test "discovery budget is one driver_core default projected through driver, C ABI, and DialRetry" {
    try std.testing.expectEqual(driver_core.discovery_retry_ms, driver.discovery_retry_ms);
    try std.testing.expectEqual(driver_core.discovery_max_attempts, driver.discovery_max_attempts);
    try std.testing.expectEqual(driver.discovery_retry_ms, c_abi_host.GLOWCAP_DISCOVERY_DIAL_RETRY_MS);
    try std.testing.expectEqual(driver.discovery_max_attempts, c_abi_host.GLOWCAP_DISCOVERY_DIAL_MAX_ATTEMPTS);
    const p = driver.DialPolicy.discovery();
    try std.testing.expectEqual(driver.discovery_max_attempts, p.max_attempts);
    try std.testing.expectEqual(driver.discovery_retry_ms, p.retry_interval_ms);
}

test "isTransientDialError matches ADR-0081 axis" {
    try std.testing.expect(driver.isTransientDialError(error.NetworkUnreachable));
    try std.testing.expect(driver.isTransientDialError(error.TimedOut));
    try std.testing.expect(driver.isTransientDialError(error.ConnectionLost));
    try std.testing.expect(!driver.isTransientDialError(error.InvalidAddress));
    try std.testing.expect(!driver.isTransientDialError(error.ConnectionRefused));
    try std.testing.expect(!driver.isTransientDialError(error.OutOfMemory));
}

test "DialRetry dial recovers transient then yields new result" {
    var probe: RetryProbe = .{};
    sleep_count = 0;
    const client = driver.DialRetry.init(.{ .max_attempts = 5, .retry_interval_ms = 1 });
    const got = try client.dial(u32, probeDial, &probe, probeSleep);
    try std.testing.expectEqual(@as(u32, 99), got);
    try std.testing.expectEqual(@as(u32, 3), probe.hits);
    try std.testing.expectEqual(@as(u32, 2), sleep_count);
}

test "DialRetry dial does not retry InvalidAddress" {
    var probe: FatalProbe = .{};
    sleep_count = 0;
    const client = driver.DialRetry.init(.{ .max_attempts = 5, .retry_interval_ms = 1 });
    try std.testing.expectError(error.InvalidAddress, client.dial(void, fatalDial, &probe, probeSleep));
    try std.testing.expectEqual(@as(u32, 1), probe.hits);
    try std.testing.expectEqual(@as(u32, 0), sleep_count);
}

const OutcomeLog = struct {
    kinds: [8]driver.DialOutcome = undefined,
    attempts: [8]u32 = undefined,
    len: u32 = 0,
};

fn logOutcome(ctx: ?*anyopaque, outcome: driver.DialOutcome, attempt: u32) void {
    const self: *OutcomeLog = @ptrCast(@alignCast(ctx.?));
    if (self.len >= self.kinds.len) return;
    self.kinds[self.len] = outcome;
    self.attempts[self.len] = attempt;
    self.len += 1;
}

test "DialRetry on_dial_outcome reports retry then ok" {
    var probe: RetryProbe = .{};
    var log: OutcomeLog = .{};
    sleep_count = 0;
    var client = driver.DialRetry.init(.{ .max_attempts = 5, .retry_interval_ms = 1 });
    client.on_dial_outcome = logOutcome;
    client.outcome_ctx = &log;
    _ = try client.dial(u32, probeDial, &probe, probeSleep);
    try std.testing.expectEqual(@as(u32, 3), log.len);
    try std.testing.expectEqual(driver.DialOutcome.transient_retry, log.kinds[0]);
    try std.testing.expectEqual(driver.DialOutcome.transient_retry, log.kinds[1]);
    try std.testing.expectEqual(driver.DialOutcome.ok, log.kinds[2]);
}

test "DialRetry on_dial_outcome reports permanent" {
    var probe: FatalProbe = .{};
    var log: OutcomeLog = .{};
    var client = driver.DialRetry.init(.{ .max_attempts = 5, .retry_interval_ms = 1 });
    client.on_dial_outcome = logOutcome;
    client.outcome_ctx = &log;
    _ = client.dial(void, fatalDial, &probe, probeSleep) catch {};
    try std.testing.expectEqual(@as(u32, 1), log.len);
    try std.testing.expectEqual(driver.DialOutcome.permanent, log.kinds[0]);
}
