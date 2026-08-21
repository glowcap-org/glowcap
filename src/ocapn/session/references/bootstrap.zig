//! Bootstrap swiss-number namespace and publication mappings for one Session.
//!
//! The reserved durable namespace and mutable bootstrap registry meet here so
//! the mutable door cannot accidentally admit a durable name. Session owns the
//! table and arena; this module owns allocation, replacement, lookup, and the
//! infallible rollback paired with a failed publication.

const std = @import("std");
const model = @import("model");

const session = @import("../mod.zig");

const Error = session.Error;
const Session = session.Session;

/// Reserved versioned namespace for cryptographically minted durable names.
pub const durable_swiss_prefix = "pancake-durable-1-";
/// Random bytes behind the prefix, encoded as lowercase hex.
pub const durable_swiss_entropy_len = 16;
/// A minted durable swiss name's exact byte length.
pub const durable_swiss_len = durable_swiss_prefix.len + durable_swiss_entropy_len * 2;

/// Whether `swissnum` lies in the reserved durable namespace.
pub fn isDurableSwiss(swissnum: []const u8) bool {
    return std.mem.startsWith(u8, swissnum, durable_swiss_prefix);
}

/// Allocate a fresh export and publish it behind a mutable bootstrap name.
/// Re-registering replaces the discovery mapping; already-issued authority to
/// the displaced export remains valid.
pub fn register(self: *Session, swissnum: []const u8) !model.ExportPosition {
    const export_position = try self.allocateExport();
    // A mapping failure leaves no phantom export row.
    errdefer self.releaseUnsharedExport(export_position);
    try bind(self, swissnum, export_position);
    return export_position;
}

/// Bind a mutable bootstrap name to an already-held export.
pub fn bind(self: *Session, swissnum: []const u8, export_position: model.ExportPosition) !void {
    // Structural refusal, rather than a process-local tombstone, prevents an
    // old durable reference from being retargeted after restart (ADR-0098).
    if (isDurableSwiss(swissnum)) return Error.ReservedDurableNamespace;
    const gop = try self.bootstrap.getOrPut(self.allocator, swissnum);
    if (!gop.found_existing) {
        // getOrPut borrowed the caller slice. Replace it with arena ownership;
        // if that allocation fails, remove the borrowed key before returning.
        gop.key_ptr.* = self.key_arena.allocator().dupe(u8, swissnum) catch |err| {
            std.debug.assert(self.bootstrap.remove(swissnum));
            return err;
        };
    }
    gop.value_ptr.* = export_position;
}

/// The local export serving `swissnum`, or null if none is registered.
pub fn lookup(self: *const Session, swissnum: []const u8) ?model.ExportPosition {
    return self.bootstrap.get(swissnum);
}

/// Restore the mapping paired with a grant that never became observable.
///
/// This is infallible: replacement overwrites a live slot, and removing the
/// just-inserted mapping must find it. Arena-owned key bytes remain until
/// Session teardown, matching the otherwise-monotonic bootstrap registry.
pub fn restore(self: *Session, swissnum: []const u8, prior: ?model.ExportPosition) void {
    if (prior) |position| {
        self.bootstrap.getPtr(swissnum).?.* = position;
    } else {
        std.debug.assert(self.bootstrap.remove(swissnum));
    }
}
