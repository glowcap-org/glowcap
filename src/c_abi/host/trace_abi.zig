//! Public C layout for the byte-fed Host's live trace seam.
//!
//! This leaf owns only POD vocabulary. Trace storage, delivery, and policy stay
//! with the Host implementation and its process-owner adapter.

/// One reported trace fact (`glowcap_host_set_trace`). The kind selects the
/// live fields; string views are borrowed for the callback only.
pub const GLOWCAP_TRACE_SESSION_OPEN: u32 = 0;
pub const GLOWCAP_TRACE_MESSAGE: u32 = 1;
pub const GLOWCAP_TRACE_SESSION_CLOSE: u32 = 2;

pub const GlowcapTraceEvent = extern struct {
    /// A `GLOWCAP_TRACE_*` value.
    kind: u32,
    /// The session the fact is about, stable for the session's life.
    session: u64,
    /// `GLOWCAP_TRACE_MESSAGE`: nonzero when the message left this host.
    outbound: u8,
    /// `GLOWCAP_TRACE_SESSION_OPEN`: what proved the partner's durable name,
    /// as a `GLOWCAP_DURABLE_PROVENANCE_*` value — the same fact
    /// `glowcap_host_session_partner_identity` reports, not a second
    /// spelling of it. A consumer that only asked "was it proved" cannot
    /// tell a partner claiming no durable name from one whose claim nothing
    /// on its path was able to prove.
    provenance: u32,
    /// `GLOWCAP_TRACE_SESSION_OPEN`: the negotiated `GLOWCAP_CODEC_*`, or
    /// `GLOWCAP_CODEC_UNKNOWN` when the session uses a codec this C ABI family
    /// does not name.
    codec: u32,
    /// `GLOWCAP_TRACE_SESSION_OPEN`: the negotiated `GLOWCAP_CAPTP_*`.
    captp_version: u32,
    /// `GLOWCAP_TRACE_SESSION_OPEN`: the partner's OCapN Designator —
    /// dialed, or claimed by its hello. Borrowed.
    ///
    /// Half a name on its own. OCapN requires a designator and a transport
    /// together to tell two locations apart, so the same key reached over
    /// `iroh` and over `keyed-relay` is two locators — and which one
    /// carried the session decides how the name could have been proved.
    designator: ?[*]const u8,
    designator_len: usize,
    /// `GLOWCAP_TRACE_SESSION_OPEN`: the netlayer transport symbol this
    /// session runs over (`tcp`, `keyed-tcp`, `keyed-relay`, `iroh`,
    /// `webrtc`, `inproc`). Borrowed.
    transport: ?[*]const u8,
    transport_len: usize,
    /// `GLOWCAP_TRACE_SESSION_OPEN`: the OCapN Session ID, 64 lowercase hex
    /// digits, which BOTH peers of this session derive to the same value.
    /// Empty when the partner sent no session key. Borrowed.
    ///
    /// Not `session` above: that is this host's own handle and means
    /// nothing to anyone else, while this is the name the two ends agree
    /// on and the only one that merges two producers' feeds.
    session_id: ?[*]const u8,
    session_id_len: usize,
    /// `GLOWCAP_TRACE_MESSAGE`: the deliver's verb. Borrowed.
    verb: ?[*]const u8,
    verb_len: usize,
    /// `GLOWCAP_TRACE_MESSAGE`: the message's wire frame, borrowed. Both
    /// directions carry it — the fact sites sit at the wire boundary
    /// (inbound dispatch, the outbound drain).
    frame: ?[*]const u8,
    frame_len: usize,
    /// `GLOWCAP_TRACE_MESSAGE`: how long the frame really was. Equal to
    /// `frame_len` on the callback seam, which borrows the frame where it
    /// sits; larger when a queued record clipped the frame to its payload
    /// window (`glowcap_host_set_trace_queue`).
    frame_total_len: usize,
    /// Records the host dropped between the previous record and this one.
    /// Always zero on the callback seam, which drops nothing; a queued
    /// record reports the gap its ring could not hold.
    dropped: u64,
    /// `GLOWCAP_TRACE_MESSAGE`: a tag over the frame's bytes, naming this one
    /// message across the two peers that carried it. One frame crosses one
    /// wire, so both ends derive the same tag from the bytes they hold,
    /// without coordinating and without either of them retaining anything.
    /// A consumer merging two observers of one session folds their two
    /// sightings of a message into one on this. Zero on the other kinds.
    digest: [GLOWCAP_TRACE_DIGEST_BYTES]u8,
};

/// Width of `GlowcapTraceEvent.digest`. 128 bits: the tag separates the
/// messages of one session from each other, so the birthday bound that
/// matters is over one session's own traffic rather than over every message
/// a consumer ever sees.
pub const GLOWCAP_TRACE_DIGEST_BYTES: usize = 16;

/// The trace callback: called synchronously at the fact site, on the host's
/// one thread, with `event` and its views borrowed for the call. Must call no
/// host-driving verb.
pub const GlowcapTraceCallback = *const fn (
    ctx: ?*anyopaque,
    event: *const GlowcapTraceEvent,
) callconv(.c) void;
