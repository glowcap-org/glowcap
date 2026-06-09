//! Bringing a sturdyref to life: turning a saved `(peer, swissnum)` into a live
//! `Reference` on the open session (ADR-0012).
//!
//! Underneath, this is just bootstrap-fetch again (`engine.fetch`). Enlivening a
//! sturdyref is a fetch for its swissnum against `<desc:export 0>`, and the
//! partner's reply is recognized by the same `tryMatchFetchOutcome`. What this
//! module adds is only the enliven-specific bookkeeping the sync core owns.
//!
//! First, a precondition (`checkEnlivenPreconditions`): the session has to have
//! negotiated the sturdyref feature and be open. (Whether the sturdyref's peer is
//! actually this session's remote is the adapter's problem. The core tracks no
//! remote locator and never dials anyone.)
//!
//! Second, deduplication (ADR-0012). Once an enliven resolves, we cache the result
//! on the session, swissnum to `(import_id, kind)`, so doing it again
//! short-circuits with no wire traffic (`sturdyrefCacheHit`). And two enlivens for
//! the same swissnum in flight at once collapse onto the one outstanding answer.
//!
//! Third, starting and settling (`prepareEnliven` and `recordEnlivenment`). A
//! cache miss kicks off a fresh bootstrap-fetch; the adapter runs the wire loop
//! and feeds the answer back, and we cache it with its kind preserved.
//!
//! As with `engine.fetch`, running the wire loop itself, sending the deliver and
//! routing replies to the matcher, is the adapter's job. The core ships the no-I/O
//! halves.

const std = @import("std");

const model = @import("../model/mod.zig");
const session_mod = @import("../session/mod.zig");
const fetch = @import("fetch.zig");

pub const Error = error{
    /// The session did not negotiate `FeatureSet.sturdyref`; sturdyref enlivenment
    /// requires a positive handshake (ADR-0012 § The `sturdyref` feature gate).
    SturdyrefsNotNegotiated,
    /// Enliven was attempted on a session that is not `open`.
    SessionNotOpen,
    /// The partner settled the bootstrap-fetch answer as a `break`, or with a
    /// non-`Reference` fulfillment — the swiss-number could not be enlivened
    /// (ADR-0012 § Enliven over bootstrap-fetch).
    EnlivenmentBroke,
};

/// What an [`prepareEnliven`] call resolves to before any wire traffic.
pub const EnlivenStart = union(enum) {
    /// ADR-0012 cache hit: the swiss-number was already enlivened on this session.
    /// Carries the reconstructed `Reference.far` (kind preserved). No wire traffic;
    /// nothing to send.
    cached: model.Reference,
    /// An enliven for this swiss-number is already in flight on `answer_id`; this
    /// call collapsed onto it (ADR-0012 in-flight dedup). Nothing new to send.
    in_flight: u64,
    /// Cache + in-flight miss: a fresh bootstrap-fetch. The adapter sends
    /// `prepared.message` (move it into `Peer.send`), drives the wire loop, and
    /// feeds the settlement to [`recordEnlivenment`]. Owns `prepared.message`.
    fresh: fetch.PreparedFetch,
};

/// Check the enliven preconditions (ADR-0012 § Enliven over bootstrap-fetch
/// steps 1-2, minus the
/// locator-match that is an adapter/dial concern in the Zig core): the session
/// negotiated `FeatureSet.sturdyref` and is open.
pub fn checkEnlivenPreconditions(session: *session_mod.Session) Error!void {
    if (!session.features.sturdyref) return Error.SturdyrefsNotNegotiated;
    if (session.state != .open) return Error.SessionNotOpen;
}

/// ADR-0012 cache short-circuit: if `sturdyref.swissnum` was already enlivened on
/// `session`, rebuild the cached `Reference.far` (kind preserved, ADR-0010
/// § The far-kind is preserved across enliven) without wire traffic. Returns
/// null on a cache miss; callers fall
/// through to a fresh enliven. The returned reference is POD (no allocation).
pub fn sturdyrefCacheHit(session: *session_mod.Session, sturdyref: model.SturdyRef) ?model.Reference {
    const import_id = session.sturdyrefImportFor(sturdyref.swissnum) orelse return null;
    const kind = session.sturdyrefKindFor(sturdyref.swissnum) orelse .object;
    return .{ .far = .{ .import_id = import_id, .kind = kind } };
}

/// Begin an enliven for `sturdyref`. Checks preconditions, then resolves to a
/// cache hit, an in-flight collapse, or a fresh bootstrap-fetch (ADR-0012). On
/// the fresh path the in-flight marker is recorded so a concurrent enliven for
/// the same swiss-number collapses; on any allocation failure every allocation
/// is released and the marker is not left dangling.
pub fn prepareEnliven(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    sturdyref: model.SturdyRef,
) !EnlivenStart {
    try checkEnlivenPreconditions(session);

    if (sturdyrefCacheHit(session, sturdyref)) |reference| {
        return .{ .cached = reference };
    }
    if (session.pendingEnlivenAnswer(sturdyref.swissnum)) |answer| {
        return .{ .in_flight = answer };
    }

    const prepared = try fetch.prepareFetchSwissnum(allocator, session, sturdyref.swissnum);
    errdefer model.freeMessage(allocator, prepared.message);
    errdefer session.releaseUnsharedExport(prepared.resolver_export);
    try session.notePendingEnliven(sturdyref.swissnum, prepared.answer_id);
    return .{ .fresh = prepared };
}

/// Settle a fresh enliven from its bootstrap-fetch [`fetch.FetchOutcome`], taking
/// ownership of `outcome`. Clears the in-flight marker for `swissnum`, then:
///
/// - `fulfilled(Reference.far)`: caches `(import_id, kind)` (ADR-0012) and returns
///   the reference (moved out — the caller owns it).
/// - `fulfilled(non-far)` / `broken` / `malformed`: releases any owned payload and
///   returns [`Error.EnlivenmentBroke`].
///
/// A non-`far` fulfillment can't be cached (the cache keys on import id + wire
/// kind) and isn't a usable enlivenment result, so it fails loud rather than
/// surfacing an unreachable reference.
pub fn recordEnlivenment(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    swissnum: []const u8,
    outcome: fetch.FetchOutcome,
) Error!model.Reference {
    session.finishPendingEnliven(swissnum);
    switch (outcome) {
        .fulfilled => |reference| switch (reference) {
            .far => |far| {
                session.cacheSturdyrefEnlivenment(swissnum, far.import_id, far.kind) catch {
                    // The cache is non-load-bearing; a failed insert costs a future
                    // round-trip, not correctness. Keep the live reference.
                };
                return reference;
            },
            else => {
                model.freeReference(allocator, reference);
                return Error.EnlivenmentBroke;
            },
        },
        .broken => |reason| {
            allocator.free(reason);
            return Error.EnlivenmentBroke;
        },
        .malformed => return Error.EnlivenmentBroke,
    }
}
