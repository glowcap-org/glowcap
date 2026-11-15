//! The exports the Rust FFI table leaves out beyond those in `shared.zig`, each
//! with the reason for that decision. Signatures and row order come from the C
//! inventories.
//!
//! An entry is `.{ .name = "<export>", .reason = "<why>" }`. A generator
//! refuses a name with no export in its archives, a name more than one
//! archive declares, a name repeated here or in `shared.zig`, and an empty
//! reason, and its refusal names the entry and the file that holds it.

const next_action = "The Rust binding drains actions through the hook pump (pump_drain). The pull queue serves an embedder that cannot install hooks.";
const next_trace = "The Rust binding installs the trace callback. The drained trace ring serves an embedder that cannot take a callback.";
const transport_allocator = "A caller-supplied Context allocator for a transport handle serves a C embedder. The Rust binding builds transports on the library allocator.";
const peer_allocator = "A caller-supplied Context allocator for a WebRTC peer serves a C embedder. The Rust binding keeps peers on their netlayer's allocator.";

pub const omissions = .{
    // host
    .{ .name = "glowcap_host_next_action", .reason = next_action },
    .{ .name = "glowcap_host_next_trace", .reason = next_trace },
    .{ .name = "glowcap_host_set_trace_queue", .reason = next_trace },
    // net_transport/iroh
    .{ .name = "glowcap_iroh_netlayer_new_in", .reason = transport_allocator },
    // net_transport/webrtc
    .{ .name = "glowcap_webrtc_peer_new_in", .reason = peer_allocator },
};
