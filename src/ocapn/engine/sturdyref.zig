//! Bringing a sturdyref to life: turning a saved `(peer, swissnum)` into a live
//! `Reference` on the open session (ADR-0007).
//!
//! Underneath, this is just bootstrap-fetch again (`engine.fetch`). Enlivening a
//! sturdyref is a fetch for its swissnum against `<desc:export 0>`, and the
//! partner's reply is recognized by the same `tryMatchFetchOutcome`. What this
//! module adds is only the enliven-specific bookkeeping the sync core owns.
//!
//! First, a precondition (`checkEnlivenPreconditions`): the session has to have
//! negotiated the sturdyref feature and be open. (Whether the sturdyref's peer is
//! this session's remote is the adapter's problem. The core tracks no
//! remote locator and never dials anyone.)
//!
//! Second, deduplication (ADR-0007). Once an enliven resolves, we cache the result
//! on the session, swissnum to `(import_position, kind)`, so doing it again
//! short-circuits with no wire traffic (`sturdyrefCacheHit`). And two enlivens for
//! the same swissnum in flight at once collapse onto the one outstanding answer.
//!
//! Third, starting and settling (`prepareEnliven` and `recordEnlivenment`). A
//! cache miss kicks off a fresh bootstrap-fetch. The adapter runs the wire loop
//! and feeds the answer back, and we cache it with its kind preserved.
//!
//! As with `engine.fetch`, running the wire loop itself, sending the deliver and
//! routing replies to the matcher, is the adapter's job. The core ships the no-I/O
//! halves.

const std = @import("std");

const model = @import("model");
const session_mod = @import("session");
const fetch = @import("fetch.zig");

pub const Error = error{
    /// The session did not negotiate `FeatureSet.sturdyref`. Sturdyref enlivenment
    /// requires a positive handshake (ADR-0007).
    SturdyrefsNotNegotiated,
    /// Enliven was attempted on a session that is not `open`.
    SessionNotOpen,
    /// The partner settled the bootstrap-fetch answer as a `break`, or with a
    /// non-`Reference` fulfillment, the swiss-number could not be enlivened
    /// (ADR-0007).
    EnlivenmentBroke,
};

/// What an `prepareEnliven` call resolves to before any wire traffic.
pub const EnlivenStart = union(enum) {
    /// ADR-0007 cache hit: the swiss-number was already enlivened on this session.
    /// Carries the reconstructed `Reference.far` (kind preserved). No wire traffic.
    /// Nothing to send.
    cached: model.Reference,
    /// An enliven for this swiss-number is already in flight on this question.
    /// This call collapsed onto it (ADR-0007 in-flight dedup). Nothing new to
    /// send.
    in_flight: session_mod.OutboundAnswerTarget,
    /// Cache + in-flight miss: a fresh bootstrap-fetch. The adapter sends
    /// `prepared.message` (move it into `Peer.send`), drives the wire loop, and
    /// feeds the settlement to `recordEnlivenment`. Owns `prepared.message`.
    fresh: fetch.PreparedFetch,
};

/// Check the session-local enliven preconditions (ADR-0007): the session
/// negotiated `FeatureSet.sturdyref` and is open.
pub fn checkEnlivenPreconditions(session: *session_mod.Session) Error!void {
    if (!session.features.sturdyref) return error.SturdyrefsNotNegotiated;
    if (session.state != .open) return error.SessionNotOpen;
}

/// ADR-0007 cache short-circuit: if `swissnum` was already enlivened on
/// `session`, rebuild the cached `Reference.far` (kind preserved, ADR-0006)
/// without wire traffic. Returns null on a cache miss. Callers fall through
/// to a fresh enliven. The returned reference is POD (no allocation).
///
/// The swiss-number is the whole enliven key: a sturdyref's peer locator
/// carries no authority here (whether it names this session's remote is the
/// adapter's dial concern), so the core never takes one.
pub fn sturdyrefCacheHit(session: *session_mod.Session, swissnum: []const u8) ?model.Reference {
    const entry = session.sturdyrefCacheLookup(swissnum) orelse return null;
    return .{ .far = entry.far };
}

/// Begin an enliven for `swissnum`. Checks preconditions, then resolves to a
/// cache hit, an in-flight collapse, or a fresh bootstrap-fetch (ADR-0007). On
/// the fresh path the in-flight marker is recorded so a concurrent enliven for
/// the same swiss-number collapses. On any allocation failure every allocation
/// is released and the marker is not left dangling.
pub fn prepareEnliven(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    swissnum: []const u8,
) !EnlivenStart {
    try checkEnlivenPreconditions(session);

    if (sturdyrefCacheHit(session, swissnum)) |reference| {
        return .{ .cached = reference };
    }
    if (session.pendingEnlivenAnswer(swissnum)) |answer| {
        // The pending row leaves with the fetch's settlement, so its answer is live.
        return .{ .in_flight = session.outboundAnswerTarget(answer) orelse unreachable };
    }

    const prepared = try fetch.prepareFetchSwissnum(allocator, session, swissnum);
    errdefer model.freeMessage(allocator, prepared.message);
    errdefer if (prepared.resolver_export) |position| session.releaseUnsharedExport(position);
    try session.notePendingEnliven(swissnum, prepared.answer.position);
    return .{ .fresh = prepared };
}

/// Settle a fresh enliven from its bootstrap-fetch `fetch.FetchOutcome`, taking
/// ownership of `outcome`. Clears the in-flight marker for `swissnum`, then:
///
/// - `fulfilled(Reference.far)`: moves the pending swissnum into the cache
///   (ADR-0007) and returns the reference (moved out, the caller owns it).
/// - `fulfilled(non-far)` / `broken` / `malformed`: releases any owned payload and
///   returns `Error.EnlivenmentBroke`.
///
/// A non-`far` fulfillment can't be cached (the cache keys on import position + wire
/// kind) and isn't a usable enlivenment result, so it fails loud rather than
/// surfacing an unreachable reference.
pub fn recordEnlivenment(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    swissnum: []const u8,
    outcome: fetch.FetchOutcome,
) Error!model.Reference {
    switch (outcome) {
        .fulfilled => |reference| switch (reference) {
            .far => |far| {
                session.settlePendingEnlivenIntoCache(swissnum, far);
                return reference;
            },
            else => {
                session.finishPendingEnliven(swissnum);
                model.freeReference(allocator, reference);
                return error.EnlivenmentBroke;
            },
        },
        .broken => |reason| {
            session.finishPendingEnliven(swissnum);
            allocator.free(reason);
            return error.EnlivenmentBroke;
        },
        .malformed => {
            session.finishPendingEnliven(swissnum);
            return error.EnlivenmentBroke;
        },
    }
}
