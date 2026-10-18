//! Heap-pinned WebRTC peer and netlayer ownership.
//!
//! The public signaling ABI and the generic driver provider are two projections
//! of these same leases. Their retain/release transaction lives here, so
//! neither projection has a second lifetime authority.

const std = @import("std");

const crypto = @import("foundation").crypto;
const c = @import("c_abi_shared");
const webrtc = @import("webrtc");
const exchange = @import("exchange.zig");

/// One WebRTC peer: its `RTCPeerConnection` and single data channel, wrapping
/// the netlayer resident's byte-fed `Peer`. Owned by the caller. Released with
/// `glowcap_webrtc_peer_release`.
pub const GlowcapWebrtcPeer = opaque {};
pub const GlowcapWebrtcNetlayer = opaque {};

/// A managed exchange in flight: its id, which side of it this peer is, and
/// how far it has come. A dial's id is the driver's request id, and an
/// accept's is one this netlayer minted with `accept.accept_id_bit` set.
/// `signaling` pumps candidates and waits for the channel. `open` has sent
/// the driver its connect or accept record and passes I/O readiness through
/// until `finish_connect` or `finish_accept` claims the peer. `failed` is a
/// dial that has sent that record too, with the cause kept in
/// `PeerPayload.failure` for `finish_connect` to report. An accept that fails
/// is released at once instead.
pub const Exchange = struct {
    id: u64,
    role: enum { dial, accept },
    /// `refused` is the window between `glowcap_webrtc_netlayer_fail_exchange`
    /// closing the peer and the closed record that ends the exchange.
    state: enum { signaling, refused, open, failed } = .signaling,
};

/// The one active listener: the driver's route its accept records name, the
/// designator its locator advertises, and the opened accepts waiting for
/// `finish_accept`, in arrival order. One per netlayer, because a WebRTC
/// endpoint is reachable as one key.
pub const Listener = struct {
    route_id: u64,
    designator: [crypto.PeerKey.designator_len]u8,
    ready: std.ArrayListUnmanaged(*PeerPayload),
};

pub const PeerPayload = struct {
    peer: webrtc.Peer,
    allocator: std.mem.Allocator,
    netlayer: *NetlayerPayload,
    references: usize = 1,
    provider_claimed: bool = false,
    /// Set while the provider runs this peer's exchange on the driver's
    /// behalf. A peer the caller created by hand never has one.
    exchange: ?Exchange = null,
    failure: c.GlowcapProviderFailure = std.mem.zeroes(c.GlowcapProviderFailure),
};

pub const NetlayerPayload = struct {
    resident: webrtc.Resident,
    allocator: std.mem.Allocator,
    /// The application's signaling callbacks, copied from the configuration.
    /// `send_offer == null` means this netlayer dials nothing, and
    /// `send_answer == null` means it accepts nothing.
    signaling: exchange.GlowcapWebrtcSignaling,
    /// Provider leases plus the construction reference, counted atomically
    /// like every sibling archive: a package retain can arrive from the driver
    /// thread while the owner releases on its own, and a retain against a
    /// count already at zero must be refused.
    references: std.atomic.Value(usize) = .init(1),
    peers: std.AutoHashMapUnmanaged(usize, *PeerPayload) = .{},
    /// Exchanges in flight by id. Every value is also in `peers` under its
    /// peer id, so readiness records find it either way.
    exchanges: std.AutoHashMapUnmanaged(u64, *PeerPayload) = .{},
    listener: ?Listener = null,
    /// The counter behind the next accept exchange id.
    next_accept: u64 = 1,
    provider_profile: c.GlowcapTransportProfile = undefined,
    multiplexed_transport: c.GlowcapMultiplexedTransport = undefined,
    provider_entry: c.GlowcapTransportProviderEntry = undefined,
    provider_initialized: bool = false,

    pub fn retain(self: *NetlayerPayload) bool {
        return c.transport_provider.retainLive(&self.references);
    }
};

pub fn payloadFromOpaque(p: ?*GlowcapWebrtcPeer) ?*PeerPayload {
    return @ptrCast(@alignCast(p orelse return null));
}

pub fn netlayerFromOpaque(p: ?*GlowcapWebrtcNetlayer) ?*NetlayerPayload {
    return @ptrCast(@alignCast(p orelse return null));
}

/// Roll back an unpublished retain. The caller's original lease proves this
/// decrement cannot run final teardown, so there is no cleanup outcome to lose.
pub fn undoNetlayerRetain(payload: *NetlayerPayload) void {
    const prior = payload.references.fetchSub(1, .acq_rel);
    std.debug.assert(prior > 1);
}

pub fn releaseNetlayer(payload: *NetlayerPayload) ?anyerror {
    const prior = payload.references.fetchSub(1, .acq_rel);
    std.debug.assert(prior != 0);
    if (prior != 1) return null;
    std.debug.assert(payload.peers.count() == 0);
    std.debug.assert(payload.exchanges.count() == 0);
    std.debug.assert(payload.listener == null);
    payload.peers.deinit(payload.allocator);
    payload.exchanges.deinit(payload.allocator);
    var failure: ?anyerror = null;
    payload.resident.deinit() catch |err| {
        failure = err;
    };
    payload.allocator.destroy(payload);
    return failure;
}

pub const CreatePeerError = error{ NetlayerReleased, OutOfMemory, PeerCreateFailed };

/// Create one peer shell in the given signaling role, holding a netlayer
/// reference and seated in `peers` under its id. The retain comes first so a
/// refusal has nothing to unwind: a netlayer whose last reference is already
/// gone admits no new peer.
pub fn createPeer(alloc: std.mem.Allocator, nl: *NetlayerPayload, is_offerer: bool) CreatePeerError!*PeerPayload {
    if (!nl.retain()) return error.NetlayerReleased;
    errdefer undoNetlayerRetain(nl);
    const payload = try alloc.create(PeerPayload);
    errdefer alloc.destroy(payload);
    payload.* = .{
        .peer = try nl.resident.newPeer(is_offerer),
        .allocator = alloc,
        .netlayer = nl,
    };
    errdefer payload.peer.deinit();
    try nl.peers.put(nl.allocator, @backingInt(payload.peer.id()), payload);
    return payload;
}

pub fn releasePeer(payload: *PeerPayload) ?anyerror {
    std.debug.assert(payload.references != 0);
    payload.references -= 1;
    if (payload.references != 0) return null;
    const allocator = payload.allocator;
    payload.peer.deinit();
    const failure = releaseNetlayer(payload.netlayer);
    allocator.destroy(payload);
    return failure;
}
