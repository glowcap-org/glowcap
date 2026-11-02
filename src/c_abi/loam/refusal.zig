//! Refusal projection for the Loam C boundary: an error's C return code, with
//! its name recorded for the last-error slot.

const shared = @import("c_abi_shared");

pub fn code(err: anyerror) i32 {
    shared.setLastError("loam: {s}", .{@errorName(err)});
    return switch (err) {
        error.NullPointer => shared.GLOWCAP_ERR_NULL_POINTER,
        error.Busy, error.CustodyUnavailable, error.RecordUnloaded, error.PendingRead, error.ReaderCapacity, error.StartupPending => shared.GLOWCAP_ERR_WOULD_BLOCK,
        error.OutOfMemory => shared.GLOWCAP_ERR_INTERNAL,
        // The engine stopped admitting work, so close and reopen it.
        error.StorageFailure, error.OpenOutcomeUnknown, error.ReopenRequired, error.Closed => shared.GLOWCAP_ERR_IO,
        error.Corrupt => @import("mod.zig").GLOWCAP_LOAM_ERR_CORRUPT,
        error.Gone, error.MissingStore, error.FileNotFound => shared.GLOWCAP_ERR_NOT_FOUND,
        error.RecoveryRequired, error.OutcomeUnknown => @import("mod.zig").GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED,
        error.StaleCompletion, error.WorkerNotRetired => @import("mod.zig").GLOWCAP_LOAM_ERR_STALE_COMPLETION,
        error.Denied, error.Paused, error.Revoked, error.OutOfScope, error.CeilingExceeded, error.DelegationDenied => @import("mod.zig").GLOWCAP_LOAM_ERR_DENIED,
        error.WriteNotCommitted => @import("mod.zig").GLOWCAP_LOAM_ERR_UNCHANGED,
        error.ApplicationRefused, error.MissingReply => @import("mod.zig").GLOWCAP_LOAM_ERR_APPLICATION,
        else => shared.GLOWCAP_ERR_INVALID_ARGUMENT,
    };
}
