//! Peer verbs over Session-owned capability and answer namespaces.
//!
//! These projections let actors and adapters stay above the protocol tables;
//! allocation, grant state, imports, answers, and enliven markers remain
//! authoritative in Session.

const model = @import("model");

const bootstrap = @import("../bootstrap.zig");
const engine = @import("../mod.zig");

const Peer = engine.Peer;

/// Expose a local capability behind `swissnum` for bootstrap fetch.
pub fn registerBootstrapCap(self: *Peer, swissnum: []const u8) !u64 {
    return (try self.session_state.registerBootstrapCap(swissnum)).int();
}

/// Publish and grant a local object at export position `id` (ADR-0074).
pub fn exportObject(self: *Peer, id: u64) !void {
    return self.session_state.registerExport(model.ExportPosition.from(id));
}

/// Reserve export position `id` without granting partner addressability.
pub fn reserveExport(self: *Peer, id: u64) !void {
    return self.session_state.reserveExport(model.ExportPosition.from(id));
}

/// Allocate the next export reservation; first marshal or `exportObject`
/// grants it to the partner.
pub fn exportNextObject(self: *Peer) !u64 {
    return (try self.session_state.allocateExport()).int();
}

/// Register a partner-hosted object so a far send to `id` is admitted.
pub fn importObject(self: *Peer, id: u64) !void {
    return self.session_state.registerImport(model.ImportPosition.from(id));
}

/// Allocate the next outbound answer position.
pub fn allocateAnswer(self: *Peer) error{OutboundAnswerSpaceExhausted}!u64 {
    const answer = self.session_state.allocateOutboundAnswer() catch |err| switch (err) {
        error.OutboundAnswerSpaceExhausted => return error.OutboundAnswerSpaceExhausted,
        else => unreachable,
    };
    return answer.int();
}

/// Inbound answer associated with a V1.0 resolver import (ADR-0065).
pub fn answerForResolverImport(
    self: *const Peer,
    resolver_import: model.ImportPosition,
) ?model.AnswerName {
    return self.session_state.answerForResolverImport(resolver_import);
}

/// Answer a deliver settles: its wire answer or the virtual V1.0 resolver-only
/// answer. Generic over borrowed and owned deliver shapes.
pub fn answerForDeliver(self: *const Peer, deliver: anytype) ?model.AnswerName {
    return bootstrap.answerForDeliver(deliver, &self.session_state);
}

/// Clear the in-flight enliven marker once its resolution settles.
pub fn finishPendingEnliven(self: *Peer, swissnum: []const u8) void {
    self.session_state.finishPendingEnliven(swissnum);
}
