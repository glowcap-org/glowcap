//! Host-owned refusal vocabulary.
//!
//! These errors name the sans-I/O multi-session product boundary. Protocol
//! errors remain owned by the session/engine layers. Adapters project this
//! exact set without inventing failure policy.

const actors = @import("actors");

/// The typed refusals the byte-fed host adds over the shared driver vocabulary.
pub const HostError = error{
    /// Deferred Host work could not allocate. No action or authority is lost.
    /// Retry the action drain after allocator pressure subsides.
    OutOfMemory,
    /// The Host has crossed its close admission barrier. Existing protocol
    /// work may still be driven to its terminal barrier, but no application
    /// operation or session open may begin after this point (ADR-0030).
    HostClosing,
    /// This session is finishing or terminating and no longer admits application status-allow: lifecycle transition
    /// operations, while protocol progress remains legal during finish.
    SessionClosing,
    /// This session already owns every operation slot representable by its
    /// compact control word. The attempted operation has not committed any
    /// effect. Settle existing work and retry.
    SessionOperationLimitReached,
    /// The session lost the crossed-hellos tiebreak (ADR-0012) and is
    /// condemned: its typed abort is queued for the embedder to drain, and no
    /// further verb may ride it.
    SessionCondemned,
    /// A top-level (host-driving) verb was re-entered from inside a listener or
    /// behavior callback. Every public verb is one of two kinds: top-level
    /// verbs refuse this error under the latch, and the enqueueing verbs
    /// (`send`/`tell`, `listenTo`, the vow verbs, `releaseCapability`,
    /// `setExporterLocation`) are legal there, their effects encoded and pumped
    /// when the enclosing top-level verb unwinds.
    ReenteredHost,
    /// A single-thread Host verb ran from a thread other than the current
    /// driver owner. The caller may retry after the owner explicitly releases
    /// its claim at a quiescent boundary. The refused call commits nothing.
    WrongThread,
    /// A host vow id names no live row: never minted, or its session was
    /// released.
    NoSuchVow,
    /// A resolver id this Host never minted. A minted resolver that was
    /// consumed, by its settle or by its session's release, refuses
    /// `AlreadySettled` instead.
    NoSuchResolver,
    /// A session-scoped vow verb (a listener, a pipelined send or
    /// projection, `vowSession`) was called on a resolver vow, which belongs
    /// to no session (ADR-0014): its whole surface is the turn-scoped
    /// forward and the resolver settle verbs.
    SessionlessVow,
    /// A turn-scoped forward-to-vow named a wire vow. A wire answer belongs to
    /// the session that minted it and settles through that session's own
    /// machinery. Only a local resolver vow (ADR-0014) can carry a deferred
    /// answer.
    NotALocalVow,
    /// A send argument is a capability foreign to the session the send rides,
    /// which would mis-encode the reference for that partner, or a capability
    /// appeared in a resolver settle, whose plain-data contract has no session
    /// to home one (ADR-0014). The verb is refused whole.
    ForeignArgument,
    /// `deferTurn` was given a turn or session not owned by this Host, or a
    /// turn whose Vat/Port/ingress provenance disagrees with that session.
    /// Resolver authority is never minted across Host boundaries.
    ForeignTurn,
    /// `deferTurn` was called for a served tell. A tell carries no answer to
    /// defer, so minting a resolver would create authority with no effect.
    NoAnswer,
    /// The target capability route's exporter session is gone. The send is
    /// dropped, not mis-sent (the node's fail-closed contract).
    CapabilityRouteUnavailable,
    /// `partnerIdentity` was asked for an identity the partner has not sent
    /// yet: its `op:start-session` has not arrived with a key. status-allow: pending state or quoted runtime label
    HandshakeIncomplete,
    /// `partnerIdentity` was asked on a session opened with
    /// `Options.verify_partner` off. Nothing about the partner was proved, so
    /// there is no verified identity to report rather than an unchecked one.
    PartnerUnverified,
    /// A locator on a key-designator transport named a durable key this host
    /// does not hold (ADR-0028). A peer cannot publish another node's identity.
    UnheldIdentity,
    /// No acceptable location has been selected. Dial targets do not supply
    /// this host's route. Adapters must publish one explicitly before opening a
    /// session (ADR-0028).
    MissingAdvertisedLocator,
    /// A CapTP session for this partner is already enrolled (ADR-0007):
    /// dial-to-dial by our dial target, or by a durable peer identity that a
    /// matching channel proof authenticated. A partner's locator claim alone
    /// never enters the durable-peer index. Identity-routed pending dials may
    /// pass a concrete-route match only when the existing session has not
    /// authenticated the demanded key. Crossed hellos may still open an
    /// accepted session while a dial is in flight. Authenticated pairs then
    /// keep at most one non-condemned session (ADR-0026).
    SessionPairExists,
    /// One live import position was observed under both reference kinds. The
    /// first lift established its canonical Host identity. Accepting the
    /// conflicting observation would make one wire name identify two targets.
    ImportKindConflict,
    /// An eventual send targeted a Host promise before its handoff redemption
    /// completed. Promise-aware verbs queue at this boundary. Direct routing
    /// reports the still-pending state rather than guessing a session.
    PromisePending,
    /// A Host promise's handoff redemption settled broken.
    PromiseBroken,
    /// Every export range in this host's slot is held by a live session, so a
    /// new one cannot be given numbers of its own. The mint is refused rather
    /// than handed a range another session is already using: the point of the
    /// ranges is that a capability offered to the wrong session is refused, and
    /// a shared range gives that back silently.
    ExportRangeExhausted,
    /// A Host verb was given a session owned by another Host. Peer ids and wire
    /// positions are Host/session-scoped and must never be resolved through a
    /// caller-selected owner.
    ForeignSession,
    /// The embedder has not drained enough encoded outbound bytes from this
    /// session. Drain `takeOutbound`, write those bytes, then retry the
    /// host-driving verb.
    OutboundBackpressure,
    /// Lift was called again for an import whose wire retains have all already
    /// been surfaced as Host handles.
    NoUnliftedImportRetain,
    /// A sturdyref's `(transport, designator)` does not name the selected
    /// session. The swiss is never interpreted outside its peer namespace.
    PeerIdentityMismatch,
    /// The selected session carries only a partner assertion, not provenance
    /// strong enough for default sturdyref enlivenment.
    PeerIdentityUnverified,
    /// `bindVerifiedChannelKey` was given a designator that does not name a
    /// durable key. A realizer's proof names a key. A transport that proves an
    /// address has nothing to assert here.
    InvalidChannelKey,
    /// `bindVerifiedChannelKey` named a durable key different from one this
    /// connection's realizer already asserted. One connection has one realizer
    /// and one far end, so the two statements cannot both be true, and the
    /// second is refused rather than allowed to overwrite the first.
    ChannelKeyConflict,
    /// `bindVerifiedChannelKey` arrived after the partner's `op:start-session`
    /// was applied. The chokepoint that weighs a partner's durable claim has
    /// already run, so this proof is too late to be the evidence it was for.
    /// The mirror of `HandshakeIncomplete`: one names a fact not yet knowable, status-allow: pending state or quoted runtime label
    /// this one a fact stated too late to count.
    HandshakeAlreadyApplied,
    /// `feed` or another whole-frame verb was aimed at a sealed session. The
    /// sealed channel owns that session's wire: inbound arrives as wire bytes
    /// through `feedBytes` and outbound leaves through
    /// `HostSession.takeTransportOutbound` as sealed bytes written verbatim.
    SealedSessionBytesOnly,
    /// The session's sealed channel refused: a handshake message or record that
    /// did not verify, or a seal that could not complete. The session is
    /// condemned without an `op:abort` echo (no plaintext may follow) and the
    /// embedder's close action names it.
    SealedChannelFailed,
    /// A transport extension was used before a provider registered its
    /// designation semantics. Unknown symbols never inherit address semantics.
    UnknownTransport,
    /// A provider contradicted the built-in semantics of its transport symbol.
    TransportSemanticsConflict,
    /// A second provider attempted to own a transport symbol already registered
    /// on this Host.
    TransportAlreadyRegistered,
    /// A provider attempted to register the empty transport symbol.
    InvalidTransportName,
};

/// Refusals from `Host.releaseSession`. Every error is pre-commit: the session
/// remains owned and may be retried or released with its Host. Ingress errors
/// name an internal lifecycle disagreement without converting it into process
/// policy. The release does not free a shell its Vat may still reference.
pub const SessionReleaseError = HostError || actors.IngressCancellationError;
