//! Product CapTP wait budgets and the CLI's callerless-failure recipient.
//!
//! Budgets stay here so listen and dial share one construction without importing
//! the command surface. `unhandled_failure` is the driver's observer for a
//! failure whose last deterministic return is gone. It writes the process
//! context so a later close can still name the exact primary.

const glowcap = @import("glowcap");
const Ctx = @import("../ctx.zig").Ctx;

const driver = glowcap.driver;

/// Product CapTP deadlines (ADR-0030). `.unbounded` parks a silent peer. A
/// `.ms` of zero or less has already expired and times out immediately.
pub const default_handshake_timeout_ms = driver.default_handshake_timeout_ms;
pub const default_settle_timeout_ms: i32 = 30_000;

pub fn sessionOpts() driver.SessionOptions {
    return .{
        .handshake = .{ .ms = default_handshake_timeout_ms },
        .settle = .{ .ms = default_settle_timeout_ms },
    };
}

/// Same budgets as `sessionOpts`, with the process context as the surviving
/// recipient for callerless Runtime leftovers.
pub fn sessionOptsReporting(ctx: *Ctx) driver.SessionOptions {
    return withRecipient(ctx, sessionOpts());
}

/// Attach the context recipient unless the caller already named one.
pub fn withRecipient(ctx: *Ctx, opts: driver.SessionOptions) driver.SessionOptions {
    if (opts.unhandled_failure != null) return opts;
    var out = opts;
    out.unhandled_failure = .{
        .ctx = @ptrCast(ctx),
        .report = Ctx.reportUnhandledFailure,
    };
    return out;
}
