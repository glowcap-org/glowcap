//! Dial policy vocabulary (ADR-0082): DialError classification and the
//! discovery budget lockstep with the C ABI. The runtime's retry seam is
//! proved in `host_runtime_step/dial_retry_test.zig`.

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const driver_core = glowcap.driver.core;
const c_abi_host = @import("c_abi_host");
test "discovery budget is one driver_core default projected through driver, C ABI, and DialPolicy" {
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
    try std.testing.expect(driver.isTransientDialError(error.WouldBlock));
    try std.testing.expect(!driver.isTransientDialError(error.InvalidAddress));
    try std.testing.expect(!driver.isTransientDialError(error.ConnectionRefused));
    try std.testing.expect(!driver.isTransientDialError(error.OutOfMemory));
}
