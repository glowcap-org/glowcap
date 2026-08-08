//! The live trace tap: the one place the Host core reports its own protocol
//! activity — a session finishing its handshake, a message passing with its
//! verb, a session closing — to whoever installed a sink. Every binding's
//! `enable_trace` and the native tier's own observer stand on this seam, so
//! the facts are produced once, by the layer that owns them: the core knows
//! the real codec, the real open transition (after crossed hellos), and
//! every deliver's verb, where a binding-side tap could only approximate
//! them from its own surface.
//!
//! The core stays sans-io and deterministic: an emit is one callback with
//! borrowed fields, valid only for the call. The sink stamps time and
//! formats — those belong to the embedder, which owns clocks and bytes. With
//! no sink installed every emit site is a single null check.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const vocab = @import("vocab.zig");

/// The OCapN **Session ID**, written as 64 lowercase hex digits.
///
/// The spec's own term, and its own value: the CapTP specification derives
/// it from the two peers' Public Identifiers, sorted, so both sides of one
/// session compute the same 32 bytes and dial order does not enter it
/// (`foundation.crypto.sessionIdFromPeerIds`).
///
/// A trace consumer that merges feeds from several producers needs this.
/// A producer's own session handle says nothing across a process boundary,
/// and the two peers of one session each report their own; this is the one
/// name they agree on, and it is protocol identity rather than a producer's
/// claim.
pub const SessionId = [64]u8;

/// Render the OCapN Session ID of the session `our_key` and `partner_key`
/// are the two ends of. Both peers pass the same pair in opposite order and
/// get the same digits.
pub fn sessionId(our_key: foundation.crypto.PeerKey, partner_key: foundation.crypto.PeerKey) SessionId {
    const session_id = foundation.crypto.sessionIdFromPeerIds(
        foundation.crypto.derivePublicIdentifier(our_key),
        foundation.crypto.derivePublicIdentifier(partner_key),
    );
    return std.fmt.bytesToHex(session_id.bytes, .lower);
}

/// One reported fact. Strings are borrowed for the callback.
pub const Event = union(enum) {
    /// A session completed its handshake and is open. `partner` is the
    /// dialed designator or the partner's claimed one.
    ///
    /// A designator is half a name. The spec is explicit that a designator
    /// and a transport together are what tell two locations apart, so the
    /// same key reached over `iroh` and over `keyed-relay` is two locators
    /// — and which transport carried the session is what decides how its
    /// name could have been proved.
    ///
    /// `provenance` says what proved the durable name rather than whether
    /// something did. The distinction is the reportable one: a sink that
    /// hears only "no" cannot tell a partner that claimed nothing from one
    /// whose claim nothing on its path was able to prove.
    session_open: struct {
        /// This producer's own handle for the session. Local, and not the
        /// OCapN Session ID below — nothing outside this host can read it.
        session: engine.PeerId,
        /// OCapN: the partner's **Designator** — the name inside the
        /// netlayer, a key spelling or an address.
        designator: []const u8,
        /// OCapN: the locator's **Transport**, the netlayer symbol
        /// (`tcp`, `keyed-tcp`, `keyed-relay`, `iroh`, `webrtc`,
        /// `inproc`). The spec requires designator and transport together
        /// to tell two locations apart, so neither travels alone.
        transport: []const u8,
        provenance: vocab.DurableProvenance,
        /// The OCapN Session ID both peers derive (empty when the partner
        /// sent no session key, so no such shared name exists).
        session_id: []const u8,
        codec: model.CodecId,
        /// The CapTP profile the session negotiated. Reported beside the
        /// codec because the two are one decision (ADR-0003): a viewer that
        /// hears only the codec has to guess the version, and guessing means
        /// stamping the floor on every session.
        captp_version: model.CaptpVersion,
    },
    /// One message crossing the wire on an open session. `outbound` reads
    /// from this host's side; `verb` is the deliver's own verb symbol;
    /// `frame` is the message's wire frame, borrowed for the callback.
    /// Both fact sites sit at the wire boundary (inbound dispatch, the
    /// outbound drain), so a near send — in-process, never encoded — is
    /// deliberately not a message fact.
    message: struct {
        session: engine.PeerId,
        outbound: bool,
        verb: []const u8,
        frame: []const u8,
        /// A tag over the wire bytes, identifying this message across the two
        /// peers that carried it.
        ///
        /// One frame crosses one wire, so both ends hold the same bytes and
        /// derive the same tag with no coordination and no counter — nothing
        /// per-session is retained for it, which is what keeps it off the
        /// footprint budget. That is what lets a consumer merge two
        /// observers' views of one session instead of discarding one, and it
        /// is derived rather than claimed: a producer cannot assert that some
        /// other message is this one without holding its bytes.
        ///
        /// Fixed-width for the reason `engine.node_services` tags a gift id
        /// the same way: the bytes are partner-influenced, and a
        /// partner-selected length must not reach coordination state.
        digest: [digest_bytes]u8,
    },
    /// The session was released or condemned. Emitted only for sessions
    /// whose open was reported.
    session_close: struct {
        session: engine.PeerId,
    },
};

/// Width of a message's wire-bytes tag. 128 bits: this identifies one frame
/// among the frames of one session, so the birthday bound over a session's
/// own traffic is what matters, not a global one.
pub const digest_bytes = 16;

/// The installed sink: `emit` is called synchronously at the fact site, on
/// the host's one thread, with fields borrowed for the call.
pub const Sink = struct {
    ctx: ?*anyopaque,
    emit: *const fn (ctx: ?*anyopaque, event: Event) void,
};
