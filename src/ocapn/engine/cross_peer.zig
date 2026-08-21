//! The cross-peer seams a multi-session host plugs into.
//!
//! A `Peer` only ever owns one direct session, so anything that spans
//! sessions — a three-party handoff, a third-party promise's forwarded
//! resolution — is driven by the host that holds the peers. The engine's share
//! of that work that still lives here is the `SignatureVerifier` hook a host
//! injects when it routes handoff frames itself, so it can plug its own
//! certificate verification into that boundary. The engine's own router does
//! not need the hook: it verifies handoff and start-session certificates
//! directly with `foundation.crypto`, which is pure byte math and so lives in
//! the deterministic core. The frame routing itself (deposit the give with the
//! exporter, send the receive, pump the frames) is host choreography, not
//! engine semantics; the in-repo harness for it lives in
//! `test/support/cross_peer.zig`. Introducing-session foreign-promise relay
//! (`installThirdPartyImport` / `Peer.applyRelayedResolution`, driven by
//! `proxy_admission.foreignPromiseFulfill`) lives on `engine.Node` /
//! `driver_core.Host`.

/// An injected signature-verification hook for a host that drives cross-peer
/// handoff routing itself: it decides whether a give or receive certificate is
/// authentic at the routing boundary. The engine's own router does not use this
/// hook; it verifies certificates directly with `foundation.crypto`. Test
/// support may stub the check (`test/support/cross_peer.zig`'s
/// `testOnlyAcceptingVerifier`); that stub is not a production default. A
/// verifier that needs no state passes a null `context`.
pub const SignatureVerifier = struct {
    context: ?*anyopaque,
    verify_fn: *const fn (context: ?*anyopaque, payload: []const u8, signature: []const u8) bool,

    pub fn verify(self: SignatureVerifier, payload: []const u8, signature: []const u8) bool {
        return self.verify_fn(self.context, payload, signature);
    }
};
