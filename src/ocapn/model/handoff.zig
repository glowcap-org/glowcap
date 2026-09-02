//! The three-party handoff payloads.
//!
//! When a gifter introduces a recipient to an exporter, these are the signed
//! gift and the recipient's redemption of it (ADR-0009). They are pure value
//! shapes, byte slices and counts, no codec, no signature verification, no
//! allocation. The session is what mints, signs, and checks them; `codec` is
//! what frames them as `<desc:sig-envelope …>` records.

const peer_locator = @import("peer_locator.zig");

/// Width of the random gift identifier the draft specifies, and what glowcap
/// mints on every profile. Session admission requires it inbound on
/// `glowcap-next`, where both ends are glowcap's own, and admits a wider domain
/// on `1.0`, which has to interoperate with peers that mint narrower ids
/// (`conformance/ocapn-findings`, gift-id width).
pub const GIFT_ID_BYTES: usize = 32;

/// The gifter's signed gift: who may redeem it (`recipient_key`), where the
/// exporter lives (`exporter`), and the bookkeeping that ties the gift to one
/// exporter session so it cannot be replayed elsewhere.
pub const HandoffGive = struct {
    recipient_key: []const u8,
    /// Structural peer locator (transport, designator, hints) — the same shape
    /// Cap'n Proto and Syrup carry for sturdyrefs / start-session, so `#f` and
    /// dial hints survive without a flattened `transport:designator` sidecar.
    exporter: peer_locator.PeerLocator,
    gifter_exporter_session: []const u8,
    gifter_side: []const u8,
    gift_id: []const u8,
    signature: []const u8,
    /// Optional verbatim `<desc:sig-envelope <desc:handoff-give …> <sig-val …>>`
    /// bytes. When set, the encoder emits these exactly instead of re-encoding the
    /// fields above. A recipient forwarding a gifter's give to the exporter uses
    /// this so the exporter re-verifies the gifter's signature over the *exact*
    /// bytes the gifter signed, re-encoding could differ (e.g. `#f` vs `{}` hints)
    /// and fail verification.
    raw_signed: ?[]const u8 = null,
};

/// The recipient's redemption of a `HandoffGive` against the exporter, signed
/// under the recipient's own session key.
pub const HandoffReceive = struct {
    receiving_session: []const u8,
    receiving_side: []const u8,
    handoff_count: u64,
    signed_give: HandoffGive,
    signature: []const u8,
};

pub const Handoff = union(enum) {
    give: HandoffGive,
    receive: HandoffReceive,
};
