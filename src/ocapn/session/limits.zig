//! Resource bounds a session enforces against its partner.
//!
//! These are loud caps: crossing one refuses the transition with a typed error
//! instead of silently clamping state. Most are enforced by `Session`,
//! `max_local_deliveries` is enforced by the engine drain that spends it.

/// Default inbound frame cap (1 MiB). SessionLimits uses this for
/// `max_frame_bytes`. The driver C ABI publishes the same value as
/// `GLOWCAP_DEFAULT_FRAME_CAP`, and docs quote it through a value marker, so
/// it stays a plain literal.
const default_max_frame_bytes: usize = 1_048_576;

pub const SessionLimits = struct {
    /// Max pipelined calls queued against a single pending answer.
    queue_cap: usize = 1024,
    /// Max owned bytes held by pipelined calls queued against pending answers,
    /// summed across the session. `queue_cap` bounds a count, and each queued
    /// call is a frame-sized owned copy, so the count alone leaves a partner
    /// `queue_cap * max_frame_bytes` per answer it never resolves.
    max_queued_call_bytes: u32 = 1 << 24,
    /// Max live or detached inbound answer obligations held at once.
    max_inbound_answers: usize = 65_536,
    /// Max listeners or stored-answer projections anchored on one target.
    max_listeners_per_target: usize = 64,
    /// Max exact-incarnation hops through stored promise resolutions before a
    /// dependent call, projection, or listener receives a terminal break.
    /// Also bounds shortening validation and rewriting; a rewrite may stop
    /// at an intermediate promise without changing the call's authority.
    max_resolution_chain: usize = 64,
    /// Max local deliveries surfaced from one resolution drain (engine-enforced).
    max_local_deliveries: usize = 4096,
    /// Max partner-introduced imports. Locally allocated exports are bounded by
    /// our own sends, so exports do not share this cap.
    max_imports: usize = 1_048_576,
    /// Max deposited gifts waiting in this session's gift registry.
    max_deposited_gifts: u32 = 65_536,
    /// Max requested bytes retained by deposited gifts. Kept as `u32` beside
    /// the other bounded retained counts so the resource knobs fill whole
    /// session words without growing every Peer.
    max_deposited_gift_bytes: u32 = 1 << 24,
    /// Max owned resolution bytes retained across sent inbound answers. This
    /// durable table budget is separate from transient outbound flow control.
    max_retained_sent_answer_bytes: u32 = 1 << 24,
    /// Max early withdraws parked while waiting for deposits on another session.
    max_pending_withdraws: u32 = 4_096,
    /// Max pending answers of this session the Host holds as lifted capability
    /// promises at once (ADR-0068). Each holds a payload retain and a row until
    /// the answer settles, so the partner's open questions bound them, and this
    /// bounds them again when the partner passes many at once.
    max_lifted_answers: u32 = 4_096,
    /// Max resolved sturdyref enlivenments cached for dedup. Overflow evicts
    /// oldest because a miss costs one bootstrap fetch, not correctness.
    max_sturdyref_cache_entries: usize = 256,
    /// Max inbound argument nesting before validation refuses the frame.
    max_nesting_depth: usize = 64,
    /// Max element visits spent proving set/struct uniqueness after equal-hash
    /// grouping. This bounds the adversarial multiset-compare case.
    max_compare_visits: usize = 1 << 16,
    /// Max inbound frame bytes. Peer enforces this before whole-frame copying
    /// or queueing, packet admission, and stream materialization.
    max_frame_bytes: usize = default_max_frame_bytes,
};
