//! Errors minted by the engine dispatch and step spine.
//!
//! Codec and Session refusals pass through the engine but are not redefined
//! here. Keeping the engine-owned set explicit lets the abort taxonomy gate
//! refuse any new error that has no deliberate protocol projection.

pub const Error = error{
    /// One resolution's drain produced more local deliveries than
    /// `SessionLimits.max_local_deliveries` admits.
    LocalDeliveryCapExceeded,
    /// The partner's `op:start-session` location signature failed verification.
    InvalidStartSessionSignature,
    /// The partner selected a durable identity different from the one this
    /// dial demanded. An address route makes no durable claim and is weighed
    /// by the channel realizer instead (ADR-0028).
    PartnerDesignatorMismatch,
    /// The partner selected an extension transport whose designation semantics
    /// are unknown to this node.
    UnknownTransportSemantics,
    /// An inbound frame exceeded `SessionLimits.max_frame_bytes`.
    FrameTooLarge,
    /// Staged messages plus encoded frames reached the outbound waterline.
    /// This is local backpressure: no protocol state was discarded, and the
    /// caller must drain frames before retrying.
    OutboundBackpressure,
};
