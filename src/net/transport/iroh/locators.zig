//! The iroh locator vocabulary: the transport symbol the resident signs into
//! `op:start-session`, the reachability an endpoint is created with, and the
//! node-id designator shape a locator must carry.

const foundation = @import("foundation");
const model = @import("model");
const net = @import("net");

const crypto = foundation.crypto;

/// The transport symbol this resident registers under and signs into
/// `op:start-session`.
pub const known_transport = model.transport.Known.iroh;
pub const transport_profile = known_transport.metadata();
pub const transport_name = transport_profile.symbol;

/// How an endpoint becomes reachable, chosen explicitly when the resident is
/// created. There is no default, so enabling relays or a discovery service is
/// always the host's visible decision, never a hidden implementation detail.
/// The values mirror `GLOWCAP_IROH_REACH_*` in the sidecar header.
pub const Reachability = enum(u32) {
    /// Relay-less and lookup-less: a dial needs the partner's direct-address
    /// hints, and a hint-less dial refuses as `error.InvalidAddress`. The
    /// loopback/LAN posture.
    direct = 0,
    /// The number-0 relays plus DNS/pkarr discovery: a peer is dialable by id
    /// alone over the public internet, with hole-punching and NAT traversal.
    discovery = 1,
    /// DNS/pkarr discovery without relays, direct addresses are published and
    /// resolved, but there is no relay fallback.
    discovery_no_relay = 2,
    /// An in-process shared address book: endpoints publish and resolve by id
    /// alone with no relay, DNS, or hints. For tests and same-process
    /// embeddings, never the public internet.
    local_discovery = 3,
};

/// Whether a dial may omit the partner's direct-address hints because the
/// endpoint can resolve the partner by id. Only `direct` cannot.
pub fn resolvesById(reachability: Reachability) bool {
    return reachability != .direct;
}

/// The locator hint carrying the partner's comma-separated direct socket
/// addresses (the string `glowcap_iroh_sidecar_endpoint_direct_addrs` produces).
/// A `direct` endpoint runs no relay or lookup service, so a dial without this
/// hint cannot reach its partner and `DialResolver.resolve` / `dialRawConn` refuse
/// such a locator with `error.InvalidAddress` instead of timing out. An endpoint
/// with a discovery posture resolves the partner by id, so the hint is optional
/// there. The name
/// itself is the transport-neutral vocabulary in `net.netlayer` (keyed TCP
/// dials with the same hint), re-exported here so iroh consumers keep this
/// spelling.
pub const hint_direct_addresses = net.netlayer.hint_direct_addresses;

/// Maximum direct-address hint bytes one endpoint may publish.
pub const max_direct_address_bytes: usize = 64 * 1024;

/// An endpoint id is an Ed25519 public key printed as lowercase hex, the one
/// canonical key-designator spelling, owned by
/// `foundation.crypto.PeerKey.toDesignator`: `Resident.nodeId` produces it, and
/// `DialResolver.resolve` refuses any other shape with `error.InvalidAddress`.
pub const node_id_len = crypto.PeerKey.designator_len;

/// Build an iroh locator for an endpoint that resolves node ids through its
/// configured reachability services. The designator is borrowed and the
/// discovery form carries no direct-address hint.
pub fn locator(designator: []const u8) model.PeerLocator {
    return .hintless(transport_name, designator);
}

/// Build an iroh locator with caller-provided direct socket addresses. The
/// returned locator borrows `designator`, `direct_addresses`, and
/// `hint_storage`. Keep all three alive until the dial path has copied or
/// retained the locator.
pub fn locatorWithDirectAddresses(
    designator: []const u8,
    direct_addresses: []const u8,
    hint_storage: *[1]model.HintEntry,
) model.PeerLocator {
    return .{
        .transport = transport_name,
        .designator = designator,
        .hints = model.Hints.forDirectAddresses(direct_addresses, hint_storage),
    };
}

/// The canonical designator shape `Resident.nodeId` produces: exactly
/// `node_id_len` lowercase hex digits. One spelling, owned by
/// `foundation.crypto.PeerKey.fromDesignator`, checked before the sidecar is
/// asked to parse anything.
fn isCanonicalNodeId(designator: []const u8) bool {
    return crypto.PeerKey.fromDesignator(designator) != null;
}
/// Iroh dial target: node id + optional direct-address hints. Module-level so
/// `DialResolver` and `Backend` share one type without nesting the DialResolver on the Backend.
const connect_target = struct {
    id: []const u8,
    hints: []const u8,
};
pub const ConnectTarget = connect_target;

pub fn resolveConnectTarget(
    candidate: model.PeerLocator,
) !ConnectTarget {
    if (!std.mem.eql(u8, candidate.transport, model.transport.iroh)) return error.UnknownTransport;
    if (!isCanonicalNodeId(candidate.designator)) return error.InvalidAddress;
    return .{
        .id = candidate.designator,
        .hints = net.netlayer.directAddrHint(candidate.hints) orelse "",
    };
}
/// Admit a replacement publication for one active iroh endpoint. The endpoint
/// identity is immutable. Direct-address hints may change as reachability does.
pub fn validateListenerLocator(
    expected_designator: []const u8,
    candidate: model.PeerLocator,
) net.netlayer.ListenError!void {
    model.validatePeerLocator(candidate) catch return error.InvalidAddress;
    if (!std.mem.eql(u8, candidate.transport, transport_name) or
        !std.mem.eql(u8, candidate.designator, expected_designator))
        return error.InvalidAddress;
    _ = resolveConnectTarget(candidate) catch return error.InvalidAddress;
}
const std = @import("std");
