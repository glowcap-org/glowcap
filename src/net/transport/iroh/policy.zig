//! Shared iroh transport policy that must cross the Zig/Rust sidecar boundary.

/// Accepted loop connections each endpoint may retain before the completion
/// backend claims them. The Rust sidecar producer queue and Zig backend stash
/// share this admission posture.
pub const accept_queue_bound: usize = 128;

/// Raw bytes a non-blocking iroh reader asks from one QUIC chunk at a time.
/// The sidecar uses it as its zero-copy `read_chunk` cap, and bindings use the
/// generated mirror for their C-facing read buffers.
pub const read_chunk_bytes: usize = 64 * 1024;

/// How an endpoint becomes reachable, chosen explicitly when the resident is
/// created. There is no default, so enabling relays or a discovery service is
/// always the host's visible decision, never a hidden implementation detail.
/// The Rust crate's `REACH_*` constants are generated from these tags and the
/// header's `GLOWCAP_IROH_REACH_*` defines are checked against them.
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
