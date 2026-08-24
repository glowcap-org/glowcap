//! Relayed imported-promise settlement and pressure-safe listener publication.
//!
//! A relayed resolution bypasses `send`, so this module owns its complete
//! lower-validate-store-fire transaction. Session remains the resolution
//! authority; Peer retains only the bounded retry count for a store that had
//! to commit after the source fire became terminal.

const std = @import("std");
const model = @import("model");
const session = @import("session");

const engine = @import("../mod.zig");
const lower = @import("../lower.zig");
const pipeline = @import("../pipeline.zig");

const Peer = engine.Peer;

/// Apply one forwarded resolution (ADR-0009), taking ownership on every
/// outcome. Store it first, then fire listeners as POD carriers borrowing the
/// store. No resolution clone occurs on this path.
///
/// Application-supplied foreign-import tokens are lowered here because this
/// path bypasses `send`'s ordinary lowering chokepoint (ADR-0069).
/// `Node.RelayRecipient.adopt` is the production caller and supplies the
/// enrollment-stamped `row_id`; the node tests pin that a routing token is
/// emitted as its wire import position rather than leaking onto the wire.
pub fn applyRelayedResolution(
    self: *Peer,
    import_position: model.ImportPosition,
    row_id: u64,
    resolution: model.Resolution,
) !void {
    return applyRelayedResolutionWithPolicy(
        self,
        import_position,
        row_id,
        resolution,
        false,
    );
}

/// Terminal Node relay: the source fire is consumed, so allocator or outbound
/// pressure may delay listener carriers but may not delay the recipient store.
pub fn applyRelayedResolutionGuaranteed(
    self: *Peer,
    import_position: model.ImportPosition,
    row_id: u64,
    resolution: model.Resolution,
) !void {
    return applyRelayedResolutionWithPolicy(
        self,
        import_position,
        row_id,
        resolution,
        true,
    );
}

fn applyRelayedResolutionWithPolicy(
    self: *Peer,
    import_position: model.ImportPosition,
    row_id: u64,
    resolution_in: model.Resolution,
    commit_under_pressure: bool,
) !void {
    var resolution = resolution_in;
    self.session_state.rewriteShortenedResolution(&resolution);
    if (self.node_services) |services| {
        if (services.lowering_active.*) lower.lowerResolution(services, &resolution) catch |err| {
            model.freeResolution(self.allocator, resolution);
            return err;
        };
    }
    // This is the only application-supplied store path outside send. Hold it
    // to send's same depth and uniqueness pre-commit rules, so no refusable
    // value commits and later aborts from a queued fire's accounting.
    self.session_state.validateStoredResolution(resolution) catch |err| {
        model.freeResolution(self.allocator, resolution);
        return err;
    };
    const row = self.session_state.findImportedPromise(import_position) orelse {
        model.freeResolution(self.allocator, resolution);
        return session.Error.InvalidReference;
    };
    if (row.cell.row_id != row_id) {
        model.freeResolution(self.allocator, resolution);
        return;
    }
    if (row.cell.resolution != null) {
        model.freeResolution(self.allocator, resolution);
        return session.Error.UnexpectedMessage;
    }

    // Detach listeners reversibly and reserve every fire before the store
    // moves `resolution`. From store commit onward listener accounting and
    // carrier publication are allocation-free.
    var prepared_fires = pipeline.prepareImportedPromiseFires(
        self,
        import_position,
        row_id,
        resolution,
    ) catch |err| {
        if (commit_under_pressure and
            (err == error.OutOfMemory or err == error.OutboundBackpressure))
        {
            // Preparation restored the listener list. Recording owns the
            // preowned resolution on every outcome. Preserve typed invariant
            // refusals rather than trapping on an owner's violated contract.
            const stored = try self.session_state.recordRelayedResolution(
                import_position,
                row_id,
                resolution,
            );
            if (!stored) return;
            std.debug.assert(self.pending_imported_fire_retries < std.math.maxInt(u32));
            self.pending_imported_fire_retries += 1;
            return;
        }
        model.freeResolution(self.allocator, resolution);
        return err;
    };
    errdefer prepared_fires.abandon(self);
    // A stamp mismatch means a different promise reused this position; the
    // stale relay is moot, as with a listener-fire carrier whose stamp misses.
    if (!(try self.session_state.recordRelayedResolution(
        import_position,
        row_id,
        resolution,
    ))) {
        prepared_fires.abandon(self);
        return;
    }
    prepared_fires.commit(self);
}

/// Retry one listener batch whose store committed under terminal pressure. OOM
/// leaves the stored resolution and listener list untouched for another step.
pub fn retryImportedPromiseFire(self: *Peer) !bool {
    if (self.pending_imported_fire_retries == 0) return false;
    const import_position = self.session_state.pendingImportedPromiseFire() orelse {
        self.pending_imported_fire_retries = 0;
        return false;
    };
    try pipeline.fireImportedPromiseListeners(self, import_position);
    self.pending_imported_fire_retries -= 1;
    return true;
}
