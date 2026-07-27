//! Pure dial and accept planning: the transport dispatch, designator
//! validation, host:port resolution, and reachability decision that every
//! language binding used to re-express in its own `connect` / `dial_exporter`
//! and `Server.accept`. It is sans-io — it decides *what* to dial or sign, and
//! the caller opens the byte channel — so it lives in `driver_core` under the
//! I/O ban and reuses the one policy table `vocab` already owns
//! (`designatorSchemeForTransport`, `requiresDirectAddressesHint`), the one
//! TCP host:port admission `model.uri.tcpConnectHostPort`, and the one key
//! designator predicate `foundation.crypto.PeerKey.fromDesignator`. Nothing
//! here parses a URI or re-encodes those rules; it composes them. The native
//! `tcp.DialResolver` / `iroh.DialResolver` call the same hostport / key
//! helpers, so this is that path's byte-fed twin, not a second copy of its
//! rules.
//!
//! Open shapes are `host_port` (tcp / keyed-tcp), `peer_id` (iroh), and
//! `signaling` (webrtc, which names no dialable address). The product string
//! stays in the policy table; the plan tag names what to open, not which
//! netlayer archive opens it.
//!
//! Every returned view borrows the caller's `transport` / `designator` / hint
//! buffers (or, for a missing accept address, a static placeholder). The plan
//! is a value; the caller holds the inputs across the open.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const vocab = @import("vocab.zig");

const crypto = foundation.crypto;

pub const Error = error{
    /// The locator names a transport this planner does not dial (only `tcp`,
    /// `keyed-tcp`, `iroh`, and `webrtc` are admitted here).
    UnknownTransport,
    /// A `tcp` designator, or the first entry of a `keyed-tcp` direct-addresses
    /// hint, is not the `host:port` grammar.
    DesignatorNotHostPort,
    /// A `keyed-tcp` or `iroh` designator is not a canonical Ed25519 key
    /// (lowercase hex of the fixed designator length).
    DesignatorNotPeerKey,
    /// A `keyed-tcp` dial has no direct-addresses hint to dial: the key
    /// designator says who to trust, and the hint says where to reach them, so
    /// a keyed-tcp dial cannot proceed without it.
    MissingDirectAddressesHint,
    /// A peer-id open (`iroh` locator) `connect` named no reachability posture.
    /// There is no default: a caller must choose how the endpoint becomes
    /// reachable.
    ReachabilityRequired,
};

/// Reachability posture for a peer-id open. The planner makes the decision every
/// binding used to duplicate; the caller maps each arm onto its own reachability
/// value. `direct` is the relay-less posture a hinted redeem takes; `configured`
/// is the node's own redeem posture, which is caller state the planner cannot
/// see; `explicit` is the posture a `connect` caller named.
pub const Reach = union(enum) {
    direct,
    configured,
    explicit: u32,
};

/// A resolved dial: what to open and how. Views borrow the planner's inputs;
/// transport and designator stay with the caller.
pub const DialPlan = union(enum) {
    host_port: struct {
        host: []const u8,
        port: u16,
    },
    peer_id: struct {
        addresses: []const u8,
        reach: Reach,
    },
    /// A signaling-mediated transport (webrtc). No dialable address: the channel
    /// is brought up through a signaling exchange (offer, answer, ICE candidates)
    /// before the keyed handshake runs over the open DataChannel. The plan exists
    /// so `planDial` recognizes the transport symbol and validates the key
    /// designator; the signaling reference arrives through the handoff mechanism
    /// (ADR-0089).
    signaling,
};

/// Tag of `DialPlan` — the C ABI's `PANCAKE_DIAL_SHAPE_*` mirror.
pub const Shape = std.meta.Tag(DialPlan);

/// The reachability policy the two dial spines differ on. A redeem (a DIAL
/// action) takes the relay-less `direct` posture when it has a hint and the
/// node's configured posture otherwise; a `connect` takes the caller's posture
/// (`explicit`) or refuses when none was named (`explicit_none`).
pub const Posture = union(enum) {
    redeem,
    explicit: u32,
    explicit_none,
};

/// Resolve a dial. `transport` and `designator` are the locator's pieces (a
/// DIAL action's binding half borrows the pending URI and parses first);
/// `direct_addresses_hint` is the locator's `direct-addresses` hint, empty when
/// there is none; `posture` selects the peer-id reachability policy.
pub fn planDial(
    transport: []const u8,
    designator: []const u8,
    direct_addresses_hint: []const u8,
    posture: Posture,
) Error!DialPlan {
    if (std.mem.eql(u8, transport, model.transport.tcp) or
        std.mem.eql(u8, transport, model.transport.keyed_tcp))
    {
        if (std.mem.eql(u8, transport, model.transport.keyed_tcp)) {
            if (crypto.PeerKey.fromDesignator(designator) == null)
                return Error.DesignatorNotPeerKey;
        }
        const hp = model.uri.tcpConnectHostPort(transport, designator, direct_addresses_hint) catch |err| switch (err) {
            error.UnknownTransport => return Error.UnknownTransport,
            error.MissingDirectAddressesHint => return Error.MissingDirectAddressesHint,
            error.InvalidHostPort => return Error.DesignatorNotHostPort,
            else => unreachable, // helper only returns the three above
        };
        return .{ .host_port = .{ .host = hp.host, .port = hp.port } };
    }

    if (std.mem.eql(u8, transport, model.transport.iroh)) {
        if (crypto.PeerKey.fromDesignator(designator) == null)
            return Error.DesignatorNotPeerKey;
        // The key designator is the node id (caller retains it); the direct
        // addresses ride the hint verbatim, and the reachability posture
        // follows the caller's policy.
        const reach: Reach = switch (posture) {
            .redeem => if (direct_addresses_hint.len != 0) .direct else .configured,
            .explicit => |v| .{ .explicit = v },
            .explicit_none => return Error.ReachabilityRequired,
        };
        return .{ .peer_id = .{ .addresses = direct_addresses_hint, .reach = reach } };
    }

    if (std.mem.eql(u8, transport, model.transport.webrtc)) {
        // No dialable address; validate the key designator and hand back the
        // signaling plan.
        if (crypto.PeerKey.fromDesignator(designator) == null)
            return Error.DesignatorNotPeerKey;
        return .signaling;
    }

    return Error.UnknownTransport;
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
/// listener's own signing designator (its key for a key transport; unused for
/// an address transport, which signs the accepted address). `accepted_local_addr`
/// is the address the accept reported, empty when unavailable.
///
/// An address transport (`tcp`, `inproc`) signs the accepted address itself, or
/// the unreachable-client placeholder when the accept reported none, and carries
/// no hint. A key transport signs its own key designator; `keyed-tcp` puts the
/// accepted address in the hint (a partner dials it there), while `iroh` carries
/// no hint (discovery resolves the node id).
pub fn planAccept(
    transport: []const u8,
    server_designator: []const u8,
    accepted_local_addr: []const u8,
) AcceptPlan {
    return switch (vocab.designatorSchemeForTransport(transport)) {
        .address => .{
            .designator = if (accepted_local_addr.len != 0)
                accepted_local_addr
            else
                vocab.unreachable_client_designator,
        },
        .key => .{
            .designator = server_designator,
            .direct_addresses_hint = if (vocab.requiresDirectAddressesHint(transport))
                accepted_local_addr
            else
                &.{},
        },
    };
}
