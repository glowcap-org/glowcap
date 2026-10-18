//! Peer verbs over Session-owned capability and answer namespaces.
//!
//! These projections let actors and adapters stay above the protocol tables.
//! Allocation, grant state, imports, answers, and enliven markers remain
//! authoritative in Session.

const std = @import("std");
const model = @import("model");

const engine = @import("../mod.zig");
const session = @import("session");

const Peer = engine.Peer;

/// Expose a local capability behind `swissnum` for bootstrap fetch.
pub fn registerBootstrapCap(self: *Peer, swissnum: []const u8) !u64 {
    return (try self.session_state.registerBootstrapCap(swissnum)).int();
}

/// Publish and grant a local object at export position `id` (ADR-0074).
/// The export table is a slab indexed by position (ADR-0254), so an explicit
/// position costs one slot for every position up to it: choose small, dense
/// names, and let `allocateExport` mint the rest.
pub fn exportObject(self: *Peer, id: u64) !void {
    return self.session_state.registerExport(model.ExportPosition.from(id));
}

/// Reserve export position `id` without granting partner addressability.
/// Costs the slots up to `id`, as `exportObject` does.
pub fn reserveExport(self: *Peer, id: u64) !void {
    return self.session_state.reserveExport(model.ExportPosition.from(id));
}

/// Allocate the next export reservation. First marshal or `exportObject`
/// grants it to the partner.
pub fn exportNextObject(self: *Peer) !u64 {
    return (try self.session_state.allocateExport()).int();
}

/// Register a partner-hosted object so a far send to `id` is admitted.
pub fn importObject(self: *Peer, id: u64) !void {
    return self.session_state.registerImport(model.ImportPosition.from(id));
}

/// Mint the next outbound answer position.
pub fn allocateAnswer(self: *Peer) std.mem.Allocator.Error!session.OutboundAnswerTarget {
    return self.session_state.allocateOutboundAnswer();
}

/// Clear the in-flight enliven marker once its resolution settles.
pub fn finishPendingEnliven(self: *Peer, swissnum: []const u8) void {
    self.session_state.finishPendingEnliven(swissnum);
}
