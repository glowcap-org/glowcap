//! Protocol and resource refusals owned by Session authority.
//!
//! These errors are semantic outcomes of session admission, validation, or
//! bounded retention. Codecs and adapters project them. They do not define or
//! reinterpret them.

pub const Error = error{
    /// A caller-chosen mutable bootstrap name lies inside the reserved
    /// durable swiss namespace (ADR-0098). Only the Host's durable mint may
    /// produce such names.
    ReservedDurableNamespace,
    MalformedMessage,
    /// A reference or position claim that does not exist for this session: an
    /// unheld import/export named where a held one is required, or an unknown
    /// answer.
    InvalidReference,
    FeatureNotNegotiated,
    SessionClosed,
    InvalidGift,
    HandoffReplay,
    /// A `desc:handoff-receive` named a receiving session or side that is not
    /// the one derived from the give's recipient key and this node's own
    /// session key. The receiving `Peer` owns one scalar replay guard, so these
    /// names are checked against the live session derivation rather than trusted
    /// from the wire (ADR-0009).
    InvalidHandoffSession,
    /// A wire-delta GC message (`op:gc-exports` / `op:gc-answers`) tried to
    /// decrement a refcount below zero, release an id the table never held,
    /// or sum deltas past what any held count could cover. Per ADR-0008
    /// wire-delta reference counting this is a loud protocol error, never a
    /// silent clamp.
    GcUnderflow,
    /// A wire retain or a summed delta would carry a count past what its
    /// `u64` holds. The same loud refusal as underflow, since the accounting
    /// can no longer be exact.
    GcOverflow,
    /// A message arrived (or was sent) in a state that does not admit it:
    /// `op:start-session` outside `negotiating`, or non-handshake traffic
    /// before the session reaches `open` (ADR-0006).
    UnexpectedMessage,
    /// A second `op:start-session` was observed on the same half of the
    /// handshake (already sent locally, or already received from the partner).
    DuplicateStartSession,
    /// The partner's `op:start-session` declared a CapTP version that does not
    /// match this session's negotiated `model.CaptpVersion` version.
    CaptpVersionMismatch,
    /// A pipelined-call queue for one answer exceeded `SessionLimits.queue_cap`
    /// (ADR-0007). A loud bound on a partner flooding calls against a promise it
    /// never resolves, never a silent drop.
    QueueCapExceeded,
    /// The inbound answer table exceeded `SessionLimits.max_inbound_answers`.
    InboundAnswerCapExceeded,
    /// Sent inbound-answer rows would retain more owned resolution bytes than
    /// `SessionLimits.max_retained_sent_answer_bytes`. The answer store cannot
    /// evict authority, so overflow is a loud session refusal.
    RetainedAnswerCapExceeded,
    /// One target's listener list exceeded
    /// `SessionLimits.max_listeners_per_target`.
    ListenerCapExceeded,
    /// One answer's `op:get` / `op:index` projection list exceeded
    /// `SessionLimits.max_listeners_per_target` (the same partner-driven
    /// fan-out class as listeners, bounded by the same knob, ADR-0050).
    ProjectionCapExceeded,
    /// The import table exceeded `SessionLimits.max_imports`. A loud bound on a
    /// partner introducing unboundedly many imports (ADR-0025). Never a silent
    /// drop. Projects to a `ResourceExhausted` abort.
    ImportCapExceeded,
    /// The deposited-gift owner (`engine.bootstrap.gifts.GiftRegistry`) exceeded
    /// its row or cumulative retained-byte `SessionLimits` cap, bounds against
    /// deposit-without-withdraw and oversized retained payloads (ADR-0025).
    DepositedGiftCapExceeded,
    /// The parked-withdraw table exceeded `SessionLimits.max_pending_withdraws`
    /// the bound against a partner flooding `withdraw-gift`s whose deposits
    /// never arrive (each parks until its gift is deposited, ADR-0100).
    PendingWithdrawCapExceeded,
    /// An inbound argument tree nested deeper than
    /// `SessionLimits.max_nesting_depth`. The recursive validate / install walk
    /// is bounded so a deeply nested frame fails loud instead of
    /// overflowing the native stack. Projects to `resource_exhausted`.
    NestingTooDeep,
    /// One inbound message asked for more equality-comparison work than
    /// `SessionLimits.max_compare_visits` allows. Comparing two sets is
    /// comparing two multisets, so a pair of equal-hashed wide sets costs on
    /// the order of the square of their width, and the commutative set hash
    /// lets a partner construct that pair. The bound is what keeps a single
    /// frame from buying unbounded CPU. Projects to `resource_exhausted`.
    CompareBudgetExhausted,
    /// This session handed out every export position in the range its host
    /// gave it. The range is what keeps one session's capabilities from
    /// naming another's, so walking past it is refused rather than allowed to
    /// alias. Projects to `resource_exhausted`.
    ExportRangeExhausted,
    /// This session minted every virtual answer identity available to V1.0
    /// resolver-only calls. Refusal preserves monotonic identity instead of
    /// wrapping onto a stale local answer.
    VirtualAnswerSpaceExhausted,
    /// A set argument carried two Equal elements. A set admits each member
    /// once, so a duplicate is a second wire encoding of one value and is
    /// refused rather than admitted: inbound as the codec-neutral twin of the
    /// Syrup decoder's ascending-element byte refusal (projects to
    /// `protocol_error`), and on send pre-commit, before send-side export
    /// accounting records wire deltas. The send fold is at least as strict as the
    /// encoders' byte-level refusal (ADR-0003): Equal-but-byte-distinct
    /// forms refuse only in validation, matching the inbound rule. The answer
    /// store holds the same rule before a settlement commits
    /// (`validateSentResolutionValue`).
    DuplicateSetElement,
    /// A send-side struct argument carried two entries with the same key.
    /// Same contract as `DuplicateSetElement`'s send arm: the canonical-order
    /// encoders refuse the duplicate anyway, so validation refuses it before
    /// any authority commits. Inbound duplicates never reach the session:
    /// both codecs refuse non-ascending keys at decode.
    DuplicateStructKey,
};
