//! Pure dial and accept planning: the transport dispatch, designator
//! validation, host:port resolution, and reachability decision that
//! every language binding's `connect` / `dial_exporter` and `Server.accept`
//! shares. It is sans-io: it decides *what* to dial or sign and
//! the caller opens the byte channel, so it lives in `driver_core` under the
//! I/O ban and reuses `model.transport.Known` for transport posture, the one
//! TCP host:port admission `model.uri.tcpConnectHostPort`, and the one key
//! designator predicate `foundation.crypto.PeerKey.fromDesignator`. Nothing
//! here parses a URI or re-encodes those rules. It composes them. The Zig
//! `tcp.DialResolver` / `iroh.DialResolver` call the same hostport / key
//! helpers, so this is that path's byte-fed twin, not a second copy of its
//! rules.
//!
//! Open shapes are `host_port` (tcp / keyed-tcp / noise-tcp), `peer_id` (iroh),
//! `signaling` (webrtc, which names no dialable address), and `rendezvous`
//! (keyed-relay / noise-relay, whose byte path is a relay rendezvous bridge).
//! Route-bundle transports are expanded before this single-path planner. The
//! one `model.transport` metadata definition maps product symbols to these
//! shapes. A plan tag names host integration, not which provider implements it.
//!
//! Every returned view borrows the caller's `transport` / `designator` / hint
//! buffers (or, for a missing accept address, a static placeholder). The plan
//! is a value. The caller holds the inputs across the open.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const vocab = @import("vocab.zig");

const crypto = foundation.crypto;

pub const Error = error{
    /// The locator names a transport this single-path planner does not dial.
    UnknownTransport,
    /// A `tcp` designator, or the first entry of a keyed-transport
    /// direct-addresses hint, is not the `host:port` grammar.
    DesignatorNotHostPort,
    /// A key-designator transport's designator is not a canonical Ed25519 key
    /// (lowercase hex of the fixed designator length).
    DesignatorNotPeerKey,
    /// A `keyed-tcp` or `noise-tcp` dial has no direct-addresses hint to
    /// dial: the key designator says who to trust, and the hint says where to
    /// reach them, so the dial cannot proceed without it.
    MissingDirectAddressesHint,
    /// A peer-id open (`iroh` locator) `connect` named no reachability posture.
    /// There is no default: a caller must choose how the endpoint becomes
    /// reachable.
    ReachabilityRequired,
};

/// Reachability posture for a peer-id open. The planner makes the decision
/// so no binding duplicates it. The caller maps each arm onto its own
/// reachability value. `direct` is the relay-less posture a hinted redeem
/// takes. `configured` is the node's own redeem posture, which is caller state
/// the planner cannot see. `explicit` is the posture a `connect` caller named.
pub const Reach = union(enum) {
    direct,
    configured,
    explicit: u32,
};

/// A resolved dial: what to open and how. Views borrow the planner's inputs.
/// Transport and designator stay with the caller.
pub const DialPlan = union(enum) {
    host_port: struct {
        host: []const u8,
        port: u16,
    },
    peer_id: struct {
        addresses: []const u8,
        reach: Reach,
    },
    /// A signaling-mediated transport (webrtc). No dialable address: the
    /// channel is brought up through a signaling exchange (offer, answer, ICE
    /// candidates) before the keyed handshake runs over the open DataChannel.
    /// The plan exists so `planDial` recognizes the transport symbol and
    /// validates the key designator. The signaling reference arrives through
    /// the handoff mechanism (ADR-0089).
    signaling,
    /// A rendezvous-bridged transport (keyed-relay). No dialable address: the
    /// peer holds an inbound socket at a relay under its key designator, and
    /// the dialer opens the relay's rendezvous leg it is configured for
    /// (ADR-0088). Like `signaling`, the plan validates the key designator and
    /// names the shape. The relay mapping is the dialing host's deployment
    /// configuration, never locator bytes.
    rendezvous,
};

/// Tag of `DialPlan`, the C ABI's `GLOWCAP_DIAL_SHAPE_*` mirror.
pub const Shape = std.meta.Tag(DialPlan);

/// The reachability policy the two dial spines differ on. A redeem (a DIAL
/// action) takes the relay-less `direct` posture when it has a hint and the
/// node's configured posture otherwise. A `connect` takes the caller's posture
/// (`explicit`) or refuses when none was named (`explicit_none`).
pub const Posture = union(enum) {
    redeem,
    explicit: u32,
    explicit_none,
};

/// What every dial settles before it opens a byte channel, decided from the
/// provider's profile alone so no dial path can drift from it: whether the
/// channel must be sealed, and which durable key the partner has to prove
/// because the designator names it.
pub const DialAdmission = struct {
    /// The transport seals its channel end to end (ADR-0107), so the Host
    /// seals the admitted wire before CapTP speaks on it.
    sealed_channel: bool,
    /// The partner's durable key on a key-designator transport, demanded of the
    /// hello before any bytes move. Null when the designator is an address.
    demanded_key: ?crypto.PeerKey,
};

pub const AdmitError = error{
    /// A route-bundle profile is expanded before any single-path dial. A tier
    /// handed one unexpanded has no single channel to open.
    UnknownTransport,
    /// A key-designator transport whose designator is not a canonical key.
    InvalidAddress,
};

/// Admit one single-path dial against the profile that will realize it. Pure:
/// the caller opens the channel, seals it if `sealed_channel` says so, and
/// demands `demanded_key` of the partner's hello.
pub fn admitDial(metadata: model.transport.Metadata, designator: []const u8) AdmitError!DialAdmission {
    if (metadata.dial_shape == .route_bundle) return AdmitError.UnknownTransport;
    const demanded_key: ?crypto.PeerKey = if (metadata.designator_scheme == .key)
        crypto.PeerKey.fromDesignator(designator) orelse return AdmitError.InvalidAddress
    else
        null;
    return .{ .sealed_channel = metadata.sealed_channel, .demanded_key = demanded_key };
}

/// Resolve a dial. `transport` and `designator` are the locator's pieces (a
/// DIAL action's binding half borrows the pending URI and parses first).
/// `direct_addresses_hint` is the locator's `direct-addresses` hint, empty when
/// there is none. `posture` selects the peer-id reachability policy.
pub fn planDial(
    transport: []const u8,
    designator: []const u8,
    direct_addresses_hint: []const u8,
    posture: Posture,
) Error!DialPlan {
    const known = model.transport.parseKnown(transport) orelse return Error.UnknownTransport;
    return planDialProfile(known.metadata(), designator, direct_addresses_hint, posture);
}

/// Resolve a dial from the profile registered by the provider that will realize
/// it. This is the extension-capable authority path. The symbol-only wrapper
/// above exists for callers planning canonical built-ins.
pub fn planDialProfile(
    metadata: model.transport.Metadata,
    designator: []const u8,
    direct_addresses_hint: []const u8,
    posture: Posture,
) Error!DialPlan {
    switch (metadata.dial_shape) {
        .host_port => {
            if (metadata.designator_scheme == .key) {
                if (crypto.PeerKey.fromDesignator(designator) == null)
                    return Error.DesignatorNotPeerKey;
            }
            const hp = model.uri.connectHostPort(metadata, designator, direct_addresses_hint) catch |err| switch (err) {
                error.UnknownTransport => return Error.UnknownTransport,
                error.MissingDirectAddressesHint => return Error.MissingDirectAddressesHint,
                error.InvalidHostPort => return Error.DesignatorNotHostPort,
                else => unreachable, // helper only returns the three above
            };
            return .{ .host_port = .{ .host = hp.host, .port = hp.port } };
        },
        .peer_id => {
            if (crypto.PeerKey.fromDesignator(designator) == null)
                return Error.DesignatorNotPeerKey;
            // The key designator is the provider's peer id (caller retains it);
            // direct addresses ride the hint verbatim, and reachability follows
            // the caller's policy.
            const reach: Reach = switch (posture) {
                .redeem => if (direct_addresses_hint.len != 0) .direct else .configured,
                .explicit => |v| .{ .explicit = v },
                .explicit_none => return Error.ReachabilityRequired,
            };
            return .{ .peer_id = .{ .addresses = direct_addresses_hint, .reach = reach } };
        },
        .signaling, .rendezvous => {
            if (crypto.PeerKey.fromDesignator(designator) == null)
                return Error.DesignatorNotPeerKey;
            return if (metadata.dial_shape == .signaling) .signaling else .rendezvous;
        },
        .route_bundle, .unsupported => return Error.UnknownTransport,
    }
}

/// What an accepted CapTP session signs as its own locator: the designator a
/// partner names it by, and the direct-addresses hint that names where to reach
/// it. Views borrow the caller's inputs, except the address-transport
/// empty-address fallback, which is the static unreachable-client placeholder.
pub const AcceptPlan = struct {
    designator: []const u8,
    direct_addresses_hint: []const u8 = &.{},
};

/// Resolve what an accepted CapTP session signs. `server_designator` is the
/// listener's own signing designator (its key for a key transport, unused for
/// an address transport, which signs the accepted address).
/// `accepted_local_addr` is where this side of the connection is reachable,
/// empty when unavailable: the address the accept reported on an address or
/// `keyed-tcp` transport, and the endpoint's own direct addresses on `iroh`,
/// which has no per-accept address of its own.
///
/// An address transport (`tcp`, `inproc`) signs the accepted address itself, or
/// the unreachable-client placeholder when the accept reported none, and carries
/// no hint: its designator already says where to dial.
///
/// A key transport signs its own key designator and publishes whatever dial
/// addresses the caller gave, because a key says who a peer is and not where it
/// is. A partner that already arrived needed no address, but a third party
/// handed this locator in a handoff has never spoken to the peer and still has
/// to dial it, so a hello that knows its addresses publishes them. Where the
/// netlayer has none to give, such as `webrtc` and `keyed-relay` (reached by
/// signaling and by rendezvous), the hint stays empty without a table here to
/// say so.
pub fn planAccept(
    scheme: model.transport.DesignatorScheme,
    server_designator: []const u8,
    accepted_local_addr: []const u8,
) AcceptPlan {
    return switch (scheme) {
        .address => .{
            .designator = if (accepted_local_addr.len != 0)
                accepted_local_addr
            else
                vocab.unreachable_client_designator,
        },
        .key => .{
            .designator = server_designator,
            // Passed through, not filtered by transport: which hints a locator
            // carries is the netlayer's business, and it has already answered by
            // what it wrote here.
            .direct_addresses_hint = accepted_local_addr,
        },
    };
}
