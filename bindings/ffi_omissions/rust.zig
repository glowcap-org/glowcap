//! The exports the Rust FFI table leaves out, each with the reason for that
//! decision. Signatures and row order come from the C inventories.
//!
//! An entry is `.{ .name = "<export>", .reason = "<why>" }`. The generator
//! refuses a name with no export in its archives, a name more than one
//! archive declares, a repeated name, and an empty reason, and its refusal
//! names the entry and this file.

const last_error = "Every export clears the error slot on entry. The Rust binding reads the slot right after the call that failed, so an explicit reset serves only a C caller that inspects the slot between calls.";
const ensure_advertised = "Every session open the binding makes (open_dialed_locator, open_accepted) already retains this transport fallback inside the Host. set_advertised_locator and remove_advertised_locator select routes.";
const lifecycle_state = "close_progress returns the lifecycle state while it applies the clock. The Rust close driver reads it there.";
const next_action = "The Rust binding drains actions through the hook pump (pump_drain). The pull queue serves an embedder that cannot install hooks.";
const next_trace = "The Rust binding installs the trace callback. The drained trace ring serves an embedder that cannot take a callback.";
const plan_dial = "Driver providers plan dials inside Zig, and each byte-fed connector resolves the locators it advertises. plan_dial serves a C embedder that opens its own sockets.";
const session_feed = "feed_packet feeds frames from transport packets. session_feed takes a prebuilt GlowcapFrame from a C embedder.";
const transport_allocator = "A caller-supplied Context allocator for a transport handle serves a C embedder. The Rust binding builds transports on the library allocator.";
const peer_allocator = "A caller-supplied Context allocator for a WebRTC peer serves a C embedder. The Rust binding keeps peers on their netlayer's allocator.";
const lifecycle_id = "The Rust binding reports callerless failures under Host scope, whose id the Host assigns (host_diagnostic_id), or under Context scope, which needs none. Allocating ids serves a C embedder that reports failures for lifecycles it owns.";

pub const omissions = .{
    // host
    .{ .name = "glowcap_host_clear_last_error", .reason = last_error },
    .{ .name = "glowcap_host_ensure_advertised_locator", .reason = ensure_advertised },
    .{ .name = "glowcap_host_lifecycle_state", .reason = lifecycle_state },
    .{ .name = "glowcap_host_next_action", .reason = next_action },
    .{ .name = "glowcap_host_next_trace", .reason = next_trace },
    .{ .name = "glowcap_host_plan_dial", .reason = plan_dial },
    .{ .name = "glowcap_host_session_feed", .reason = session_feed },
    .{ .name = "glowcap_host_set_trace_queue", .reason = next_trace },
    // net_transport/iroh
    .{ .name = "glowcap_iroh_netlayer_new_in", .reason = transport_allocator },
    // net_transport/webrtc
    .{ .name = "glowcap_webrtc_netlayer_new_in", .reason = transport_allocator },
    .{ .name = "glowcap_webrtc_peer_new_in", .reason = peer_allocator },
    // ocapn
    .{ .name = "glowcap_context_allocate_lifecycle_id", .reason = lifecycle_id },
};
