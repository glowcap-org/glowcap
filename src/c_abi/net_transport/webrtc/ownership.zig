//! Heap-pinned WebRTC peer and netlayer ownership.
//!
//! The public signaling ABI and the generic driver provider are two projections
//! of these same leases. Keeping their retain/release transaction here prevents
//! either projection from inventing a second lifetime authority.

const std = @import("std");

const c = @import("c_abi_shared");
const webrtc = @import("webrtc");

pub const PeerPayload = struct {
    peer: webrtc.Peer,
    allocator: std.mem.Allocator,
    netlayer: *NetlayerPayload,
    references: usize = 1,
    provider_claimed: bool = false,
    failure: c.GlowcapProviderFailure = std.mem.zeroes(c.GlowcapProviderFailure),
};

pub const NetlayerPayload = struct {
    resident: webrtc.Resident,
    allocator: std.mem.Allocator,
    /// Provider leases plus the construction reference, counted atomically
    /// like every sibling archive: a package retain can arrive from the driver
    /// thread while the owner releases on its own, and a retain against a
    /// count already at zero must be refused, never revived.
    references: std.atomic.Value(usize) = .init(1),
    peers: std.AutoHashMapUnmanaged(usize, *PeerPayload) = .{},
    provider_profile: c.GlowcapTransportProfile = undefined,
    multiplexed_transport: c.GlowcapMultiplexedTransport = undefined,
    provider_entry: c.GlowcapTransportProviderEntry = undefined,
    provider_initialized: bool = false,
};

/// Take one more reference, or refuse when the last one is already gone: a
/// netlayer whose count reached zero is being torn down, and reviving it from
/// a late retain would hand the caller a payload about to be destroyed.
pub fn retainNetlayer(payload: *NetlayerPayload) bool {
    var current = payload.references.load(.acquire);
    while (current != 0) {
        if (payload.references.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |observed| {
            current = observed;
        } else return true;
    }
    return false;
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
    payload.peers.deinit(payload.allocator);
    var failure: ?anyerror = null;
    payload.resident.deinit() catch |err| {
        failure = err;
    };
    payload.allocator.destroy(payload);
    return failure;
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
