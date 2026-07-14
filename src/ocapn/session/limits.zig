//! Resource bounds a session enforces against a partner.
//!
//! Every field is a loud cap, not a silent clamp: a partner that pipelines,
//! listens, imports, or deposits without bound trips one of these and the
//! session refuses with a typed error. The session enforces most of them
//! directly; `max_local_deliveries` is enforced by the engine's resolution
//! drain. These are session authority, so they live beside the session rather
//! than at any adapter boundary.

/// Default inbound frame cap (1 MiB). SessionLimits uses this for
/// `max_frame_bytes`; the driver C ABI publishes the same value as
/// `PANCAKE_DEFAULT_FRAME_CAP` so bindings stop hardcoding the shift.
pub const default_max_frame_bytes: usize = 1 << 20;

/// Bounds on pipelining state (ADR-0007), keeping a peer from being driven into
/// unbounded memory by a partner that pipelines or listens without ever
/// resolving. Each overflow is a loud session error, never a silent drop. The
/// `max_local_deliveries` bound is enforced by the engine's resolution drain;
/// the rest are enforced here in the session. Defaults mirror the canonical
/// engine's `SessionLimits`.
pub const SessionLimits = struct {
    /// Max pipelined calls queued against a single pending answer.
    queue_cap: usize = 1024,
    /// Max inbound answer rows held at once.
    max_inbound_answers: usize = 65_536,
    /// Max listeners registered against a single target. Also bounds the
    /// `op:get` / `op:index` projections anchored on a single answer — the
    /// same partner-driven fan-out class (ADR-0050).
    max_listeners_per_target: usize = 64,
    /// Max re-anchor hops one `op:get` / `op:index` projection may walk
    /// through *stored* resolutions (ADR-0050). A settled answer whose stored
    /// resolution is itself a promise re-anchors the projection on that
    /// promise's answer synchronously; past this bound the projected answer
    /// breaks, so a cyclic stored-resolution chain fails loud instead of
    /// spinning.
    max_projection_chain: usize = 64,
    /// Max local deliveries surfaced from one resolution drain (engine-enforced).
    max_local_deliveries: usize = 4096,
    /// Max import-table rows — bounds a partner introducing unboundedly many
    /// imports (ADR-0025). Each new partner-driven import registration checks it;
    /// locally-allocated exports are bounded by our own sends, so exports are
    /// uncapped.
    max_imports: usize = 1_048_576,
    /// Max distinct Exporter-to-Receiver session ids tracked in the vat's
    /// handoff replay set (`engine.bootstrap.GiftRegistry`, ADR-0025). Each row
    /// holds one monotonic `last_count`.
    max_seen_handoff_counts: usize = 16_384,
    /// Max deposited-gift rows in the vat's gift registry — load-bearing against
    /// a gifter depositing gifts that are never withdrawn (ADR-0025).
    max_deposited_gifts: usize = 65_536,
    /// Max `withdraw-gift`s parked awaiting their deposit (ADR-0056). The
    /// deposit travels on a different session than the withdraw, so the order
    /// is not guaranteed and an exporter parks an early withdraw; this bounds a
    /// partner whose deposits never arrive.
    max_pending_withdraws: usize = 4_096,
    /// Max resolved sturdyref enlivenments cached for dedup (ADR-0012). The cache
    /// is non-load-bearing — a miss costs one extra bootstrap-fetch round-trip,
    /// never correctness — so an overflow evicts the oldest entry instead of
    /// erroring. A cap of 0 disables caching.
    max_sturdyref_cache_entries: usize = 256,
    /// Max nesting depth of an inbound argument tree (`list` / `set` / `tagged`).
    /// The value tree is attacker-controlled until validated, and the validate /
    /// install walk recurses per level, so an unbounded depth is a one-frame
    /// native-stack overflow (a few KB of nested `[` markers). A loud bound,
    /// projecting to `resource_exhausted`, sibling to the ADR-0025 table caps.
    max_nesting_depth: usize = 64,
    /// Max bytes in a single inbound frame admitted off a byte stream. The
    /// stream framer caps a frame at this size *during* decode (cap-on-parse),
    /// so a hostile length claim or never-completing frame fails loud as
    /// `resource_exhausted` rather than growing a buffer without bound. A
    /// byte-stream adapter sizes its steady-state read buffer below this cap; a
    /// frame larger than the buffer pays one bounded spill (`net.Spill`,
    /// ADR-0041). Not consulted by the frame boundary, which is
    /// handed an already-framed buffer.
    max_frame_bytes: usize = default_max_frame_bytes,
};
