//! The cross-peer seams a multi-session host plugs into.
//!
//! A `Peer` only ever owns one direct session, so anything that spans
//! sessions — a three-party handoff, a third-party promise's forwarded
//! resolution — is driven by the host that holds the peers. The engine's share
//! of that work is here: the relayed-resolution drain that completes
//! `Peer.relayResolution`, and the `SignatureVerifier` hook a host injects so
//! the no-I/O core never depends on crypto. The frame routing itself (deposit
//! the give with the exporter, send the receive, pump the frames) is host
//! choreography, not engine semantics; the in-repo harness for it lives in
//! `test/support/cross_peer.zig`.

const model = @import("model");
const engine = @import("mod.zig");

const Peer = engine.Peer;

/// One queued relayed resolution for a handoff-imported promise (ADR-0009
/// § `op:listen` on `desc:import-promise`). The introducing session forwards the
/// resolution of a third-party-hosted promise; `drainRelayedResolutions`
/// records it on the target session, drains the imported-promise listeners, and
/// synthesizes a fire `op:deliver` for each. Owns its `resolution` until drained.
pub const PendingRelayedResolution = struct {
    import_position: model.ImportId,
    resolution: model.Resolution,
};

/// Drain `peer.pending_relayed_resolutions`. For each entry, fire the listeners
/// installed on that third-party import with the forwarded resolution, then
/// store the resolution so a late `op:listen` fires immediately (ADR-0009).
/// Returns whether any entry was processed.
///
/// Single-peer today (every entry mutates one session). Cross-session
/// forwarding — an entry that also takes the introducing session — is not
/// implemented.
pub fn drainRelayedResolutions(peer: *Peer) !bool {
    if (peer.pending_relayed_resolutions.items.len == 0) return false;
    const pending = try peer.pending_relayed_resolutions.toOwnedSlice(peer.allocator);
    defer peer.allocator.free(pending);

    var index: usize = 0;
    // `applyRelayedResolution` owns each entry's resolution on both outcomes;
    // the errdefer releases the resolutions not yet applied.
    errdefer for (pending[index..]) |entry| model.freeResolution(peer.allocator, entry.resolution);
    while (index < pending.len) {
        const entry = pending[index];
        index += 1;
        try peer.applyRelayedResolution(entry.import_position, entry.resolution);
    }
    return true;
}

/// An injected signature-verification hook. The core treats signatures as opaque
/// bytes and defers the cryptographic decision to the caller's substrate. A
/// verifier that needs no state passes a null `context`.
pub const SignatureVerifier = struct {
    context: ?*anyopaque,
    verify_fn: *const fn (context: ?*anyopaque, payload: []const u8, signature: []const u8) bool,

    pub fn verify(self: SignatureVerifier, payload: []const u8, signature: []const u8) bool {
        return self.verify_fn(self.context, payload, signature);
    }
};
