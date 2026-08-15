//! Archive-neutral C layout for terminal owner-close policy.
//!
//! This leaf carries vocabulary only. Each archive face validates the record
//! and projects it onto `driver_core.PendingWork` at its own crossing.

const std = @import("std");

/// `PancakeCloseOptions.pending`: cancel admitted work before terminal close.
pub const PANCAKE_PENDING_CANCEL: u32 = 0;
/// `PancakeCloseOptions.pending`: finish admitted work before terminal close.
pub const PANCAKE_PENDING_FINISH: u32 = 1;

/// Current layout version for `PancakeCloseOptions`.
pub const PANCAKE_CLOSE_OPTIONS_ABI_VERSION: u32 = 1;
/// Largest finite grace budget representable by the shared Zig policy.
pub const PANCAKE_CLOSE_MAX_GRACE_MS: u32 = std.math.maxInt(u32);
/// `PancakeCloseOptions.grace_mode`: no grace argument was supplied.
pub const PANCAKE_CLOSE_GRACE_UNSPECIFIED: u32 = 0;
/// `PancakeCloseOptions.grace_mode`: `grace_ms` is a finite grace budget.
pub const PANCAKE_CLOSE_GRACE_FINITE: u32 = 1;
/// `PancakeCloseOptions.grace_mode`: finish has no grace deadline.
pub const PANCAKE_CLOSE_GRACE_UNBOUNDED: u32 = 2;

/// Terminal owner-close policy shared by byte-fed Hosts and native drivers.
/// `pending` is `PANCAKE_PENDING_CANCEL` or `PANCAKE_PENDING_FINISH`. FINISH
/// additionally reads `grace_mode`: FINITE uses `grace_ms` (zero expires
/// immediately); UNBOUNDED requires `grace_ms == 0`. CANCEL requires
/// UNSPECIFIED, which also requires `grace_ms == 0`.
pub const PancakeCloseOptions = extern struct {
    abi_version: u32,
    struct_size: usize,
    pending: u32,
    grace_mode: u32,
    grace_ms: u32,
};
