//! Shared owner context for driver-side provider adapters.
//!
//! The registry owns package validation and publication. Adapter leaves borrow
//! this context for allocation, runtime failure reporting, and exact C callback
//! contract handling without importing the registry facade back.

const std = @import("std");

const foundation = @import("foundation");
const net = @import("net");
const driver = @import("driver");
const provider_failure = @import("../provider_failure.zig");

const shared = @import("c_abi_shared");

const PANCAKE_OK = shared.PANCAKE_OK;

pub const operationFailureFromProvider = provider_failure.operation;
pub const failureChainFromProvider = provider_failure.chain;
pub const dialErrorFromCode = provider_failure.dialError;
pub const dialFailureFromProvider = provider_failure.dial;
pub const providerFailureIsEmpty = provider_failure.isEmpty;

pub const Owner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: *driver.HostRuntime,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, runtime: *driver.HostRuntime) Owner {
        return .{ .allocator = allocator, .io = io, .runtime = runtime };
    }

    pub fn failContract(self: *Owner, message: []const u8) void {
        self.runtime.failProviderContract();
        shared.setLastError("driver: transport provider contract violation: {s}", .{message});
    }

    /// A success status accompanied by a well-formed failure report is still a
    /// contract violation, but the report remains an observed provider fact.
    /// Retain it and any rollback consequence behind ProviderContract.
    pub fn retainContradictoryReport(
        self: *Owner,
        report: shared.PancakeProviderFailure,
        cleanup: ?foundation.FailureChain,
    ) void {
        var reported = failureChainFromProvider(report.result, report) catch {
            if (cleanup) |failure| self.runtime.noteTerminalOperationFailure(.fromChain(failure));
            return;
        };
        if (cleanup) |failure| reported.noteChain(failure);
        self.runtime.noteTerminalOperationFailure(.fromChain(reported));
    }

    pub fn providerCallbackFailure(
        self: *Owner,
        code: i32,
        report: shared.PancakeProviderFailure,
        operation: []const u8,
    ) ?driver.OperationFailure {
        if (code == PANCAKE_OK) {
            if (providerFailureIsEmpty(report)) return null;
            self.failContract("provider callback reported failure data on success");
            self.retainContradictoryReport(report, null);
            return driver.OperationFailure.fromError(error.ProviderContract);
        }
        return operationFailureFromProvider(code, report) catch {
            self.failContract("provider callback returned an invalid structured failure");
            shared.setLastError("driver: invalid structured failure from {s}", .{operation});
            return driver.OperationFailure.fromError(error.ProviderContract);
        };
    }
};

pub fn listenerRestorationOutcome(
    owner: *Owner,
    callback: shared.transport_provider.PancakeTransportListenerRestorationStateFn,
    listener_ctx: *anyopaque,
    out: []u8,
) net.netlayer.ListenerRestorationOutcome {
    var needed: usize = 0;
    var report = shared.transport_provider.emptyProviderFailure();
    const code = callback(
        listener_ctx,
        if (out.len == 0) null else out.ptr,
        out.len,
        &needed,
        &report,
    );
    const completed = (code == PANCAKE_OK and needed <= out.len) or
        (code == shared.PANCAKE_ERR_BUFFER_TOO_SMALL and needed > out.len);
    if (completed) {
        if (providerFailureIsEmpty(report)) return .{ .size = needed };
        owner.failContract("listener restoration state reported failure data on success");
        owner.retainContradictoryReport(report, null);
        return .{ .failed = .init(error.ProviderContract) };
    }
    const failure = failureChainFromProvider(code, report) catch {
        owner.failContract("listener restoration state returned an invalid structured failure");
        return .{ .failed = .init(error.ProviderContract) };
    };
    if (needed != 0) {
        owner.failContract("listener restoration state published a size on failure");
        owner.runtime.noteTerminalOperationFailure(.fromChain(failure));
    }
    return .{ .failed = failure };
}
