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
    failure: c.PancakeProviderFailure = std.mem.zeroes(c.PancakeProviderFailure),
};

pub const NetlayerPayload = struct {
    resident: webrtc.Resident,
    allocator: std.mem.Allocator,
    references: usize = 1,
    peers: std.AutoHashMapUnmanaged(usize, *PeerPayload) = .{},
    provider_profile: c.PancakeTransportProfile = undefined,
    multiplexed_transport: c.PancakeMultiplexedTransport = undefined,
    provider_entry: c.PancakeTransportProviderEntry = undefined,
    provider_initialized: bool = false,
};

pub fn retainNetlayer(payload: *NetlayerPayload) void {
    std.debug.assert(payload.references != 0);
    payload.references += 1;
}

/// Roll back an unpublished retain. The caller's original lease proves this
/// decrement cannot run final teardown, so there is no cleanup outcome to lose.
pub fn undoNetlayerRetain(payload: *NetlayerPayload) void {
    std.debug.assert(payload.references > 1);
    payload.references -= 1;
}

pub fn releaseNetlayer(payload: *NetlayerPayload) ?anyerror {
    std.debug.assert(payload.references != 0);
    payload.references -= 1;
    if (payload.references != 0) return null;
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
