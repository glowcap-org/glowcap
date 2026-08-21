//! Runtime application and bounded-open admission.
//!
//! Retirement, provider fail-stop, Host lifecycle, and the pending-open ceiling
//! meet at this one pre-commit boundary. Adapters may project its errors but
//! never maintain a second admission state.

const driver_core = @import("driver_core");

const lifecycle = @import("lifecycle.zig");
const pending_state = @import("pending.zig");
const host_runtime = @import("../host_runtime.zig");

const HostRuntime = host_runtime.HostRuntime;
const Error = driver_core.Error;
const AdmissionError = Error || error{ProviderContract};
const OpenAdmission = pending_state.OpenAdmission;
const OpenAdmissionAuthority = lifecycle.OpenAdmissionAuthority;

pub fn pendingOpenSlotAvailable(self: *const HostRuntime) bool {
    return self.open_admissions < self.opts.max_pending_opens;
}

pub fn acquireOpenAdmission(self: *HostRuntime, authority: OpenAdmissionAuthority) AdmissionError!OpenAdmission {
    switch (authority) {
        .application => try checkRuntimeApplicationAdmission(self),
        .pending_dial => if (self.terminal_failure != null) return error.ProviderContract,
    }
    if (!pendingOpenSlotAvailable(self)) return Error.PendingOpenLimitReached;
    const pending_work = switch (authority) {
        .application => try self.core.admitPendingWork(),
        .pending_dial => null,
    };
    self.open_admissions += 1;
    return .{ .runtime = self, .pending_work = pending_work };
}

/// Refuse new application work after either retirement or Host close.
/// Concrete Runtime verbs own this check; adapters may project the error
/// but never need a shadow admission state.
pub fn admitApplicationOperation(self: *const HostRuntime) AdmissionError!void {
    try checkRuntimeApplicationAdmission(self);
    try self.core.admitApplicationOperation();
}

fn checkRuntimeApplicationAdmission(self: *const HostRuntime) AdmissionError!void {
    if (self.terminal_failure != null) return error.ProviderContract;
    if (self.retiring) return Error.HostClosing;
}

/// Adapter preflight for work that must inspect or retain foreign provider
/// state before it can call the Runtime transaction that consumes it.
pub fn checkApplicationAdmission(self: *const HostRuntime) AdmissionError!void {
    try admitApplicationOperation(self);
}
