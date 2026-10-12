//! Public C layout for byte-channel planning and proved partner identity.
//!
//! These records report core facts to an embedder. Opening sockets and choosing
//! process policy remain outside this vocabulary leaf.

/// GlowcapDialPlan.shape: open a TCP socket to host:port (tcp, keyed-tcp).
pub const GLOWCAP_DIAL_SHAPE_HOST_PORT: u32 = 0;
/// GlowcapDialPlan.shape: peer-id open (node-id designator + addresses + reach).
/// Produced only by the `iroh` locator scheme. The tag names the open
/// shape, not the netlayer archive.
pub const GLOWCAP_DIAL_SHAPE_PEER_ID: u32 = 1;
/// GlowcapDialPlan.shape: signaling-mediated open (webrtc). No dialable address.
/// The channel comes up through an offer/answer/ICE exchange before the keyed
/// handshake. The signaling reference arrives through the handoff mechanism
/// (ADR-0089).
pub const GLOWCAP_DIAL_SHAPE_SIGNALING: u32 = 2;
/// GlowcapDialPlan.shape: rendezvous-bridged open (keyed-relay). No dialable
/// address. The peer holds an inbound socket at a relay under its key
/// designator, and the dialer opens the relay rendezvous leg its host is
/// configured for (ADR-0088).
pub const GLOWCAP_DIAL_SHAPE_RENDEZVOUS: u32 = 3;

/// GlowcapDialPlan.reach_kind (peer-id shape): the relay-less direct posture.
pub const GLOWCAP_DIAL_REACH_DIRECT: u32 = 0;
/// GlowcapDialPlan.reach_kind (peer-id shape): the node's own configured redeem posture.
pub const GLOWCAP_DIAL_REACH_CONFIGURED: u32 = 1;
/// GlowcapDialPlan.reach_kind (peer-id shape): the caller posture in reach_value.
pub const GLOWCAP_DIAL_REACH_EXPLICIT: u32 = 2;

/// glowcap_host_plan_dial posture_policy: a redeem (a DIAL action), direct when
/// a hint is present, else the node's configured posture. posture_value ignored.
pub const GLOWCAP_DIAL_POSTURE_REDEEM: u32 = 0;
/// glowcap_host_plan_dial posture_policy: a connect with a posture in posture_value.
pub const GLOWCAP_DIAL_POSTURE_EXPLICIT: u32 = 1;
/// glowcap_host_plan_dial posture_policy: a connect that named no posture. A
/// peer-id dial refuses GLOWCAP_ERR_INVALID_ARGUMENT (a posture is required).
pub const GLOWCAP_DIAL_POSTURE_EXPLICIT_NONE: u32 = 2;

/// A resolved dial: what byte channel to open and how. shape selects the live
/// fields. Every view borrows the caller's transport/designator/hint input, so
/// the plan is valid only while those buffers are.
pub const GlowcapDialPlan = extern struct {
    shape: u32,
    host: ?[*]const u8,
    host_len: usize,
    port: u16,
    addresses: ?[*]const u8,
    addresses_len: usize,
    reach_kind: u32,
    reach_value: u32,
};

/// The partner identity this session's handshake proved: the partner's session
/// public key, the location designator it signed, and the verbatim
/// `<ocapn-peer …>` record those came from.
///
/// This answers "who am I talking to" without taking the partner's word for it.
/// A keyed `op:start-session` carries an Ed25519 signature over the partner's
/// own `<my-location …>` record, and the engine verifies that signature before
/// the session opens and before any of these bytes are learned. The signed span
/// covers the whole location record, so `designator` is bound to `session_key`
/// by the same signature. An application can require that a locator a caller
/// *claims* names the key that caller actually proved, and refuse a mismatch.
///
/// Views are session-owned. The bytes live in the session's key arena, are
/// written once when the partner's handshake half arrives, and are never
/// rewritten. They stay valid until `glowcap_host_session_release`, or until the
/// host is torn down. `session_key` is always present when the read returns
/// `GLOWCAP_OK`. `designator` and `locator_record` are NULL when the partner's
/// signed location carried no designator, or when the apply path captured no
/// verbatim record.
pub const GlowcapPartnerIdentity = extern struct {
    session_key: ?[*]const u8,
    session_key_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    locator_record: ?[*]const u8,
    locator_record_len: usize,
    /// How the durable identity in `designator` was authenticated, one of the
    /// `GLOWCAP_DURABLE_PROVENANCE_*` values. It is derived from the evidence
    /// this one session holds, never from its transport's name (ADR-0105), so
    /// two sessions on the same transport can answer differently.
    ///
    /// Session identity, durable identity, and this provenance are three
    /// separate facts: a caller that requires a proved durable peer reads
    /// this, never a comparison of `designator` against `session_key`. Each
    /// session draws its own signing key, so a session key is not an
    /// identity and the two never match.
    provenance: u32,
};

/// A lower layer proved the partner holds the durable key it claims, and that
/// key names the far end of the byte channel this session runs over, so the
/// partner and the endpoint this session is encrypted to are one node.
pub const GLOWCAP_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT: u32 = 0;
/// Nothing proved the name. A partner that claimed no durable identity at all
/// lands here too, having no identity to have authenticated.
pub const GLOWCAP_DURABLE_PROVENANCE_UNAUTHENTICATED: u32 = 1;
