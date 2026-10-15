//! Decode the one C provider teardown contract into Zig outcomes.
//!
//! Status controls progress. Structured failure data preserves identity. The
//! registry decides how a contract violation affects its Runtime.

const foundation = @import("foundation");
const net = @import("net");
const shared = @import("c_abi_shared");
const provider_failure = @import("../provider_failure.zig");

pub fn append(target: *?foundation.FailureChain, later: foundation.FailureChain) void {
    if (target.*) |*first|
        first.noteChain(later)
    else
        target.* = later;
}

pub fn failure(
    code: i32,
    report: shared.GlowcapProviderFailure,
) error{ProviderContract}!?foundation.FailureChain {
    if (code == shared.GLOWCAP_OK) {
        if (provider_failure.isEmpty(report)) return null;
    } else if (!provider_failure.isEmpty(report)) {
        return provider_failure.chain(code, report) catch error.ProviderContract;
    }
    return error.ProviderContract;
}

pub fn outcome(
    code: i32,
    report: shared.GlowcapProviderFailure,
) error{ProviderContract}!net.multiplexed_resident.TeardownOutcome {
    if (code == shared.GLOWCAP_ERR_WOULD_BLOCK and provider_failure.isEmpty(report))
        return .pending;
    if (try failure(code, report)) |reported| return .{ .failed = reported };
    return .complete;
}
