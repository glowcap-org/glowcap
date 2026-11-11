//! The exports the Python FFI table leaves out, each with the reason for that
//! decision. Signatures and row order come from the C inventories.
//!
//! An entry is `.{ .name = "<export>", .reason = "<why>" }`. The generator
//! refuses a name with no export in its archives, a name more than one
//! archive declares, a repeated name, and an empty reason, and its refusal
//! names the entry and this file. A `glowcap_host_*` export missing from
//! this list needs a Python wrapper that a runtime proof reaches, which
//! `zig build source-check` holds.

const last_error = "Every export clears the error slot on entry. The Python binding reads the slot right after the call that failed, so an explicit reset serves only a C caller that inspects the slot between calls.";
const ensure_advertised = "Every session open the binding makes (open_dialed_locator, open_accepted) already retains this transport fallback inside the Host. set_advertised_locator and remove_advertised_locator select routes.";
const lifecycle_state = "close_progress returns the lifecycle state while it applies the clock. The Python close driver reads it there.";
const host_new = "host_new_in builds the Host in an explicit Context, which owns the Host's callerless failure journal.";
const next_action = "The Python binding drains actions through the hook pump (pump_drain). The pull queue serves an embedder that cannot install hooks.";
const next_trace = "The Python binding installs the trace callback. The drained trace ring serves an embedder that cannot take a callback.";
const plan_dial = "Driver providers plan dials inside Zig, and each byte-fed connector resolves the locators it advertises. plan_dial serves a C embedder that opens its own sockets.";
const release_on_drop = "The Host attaches no behavior to this setting, which records scope-end release for a binding like Rust. The Python binding releases through finalizers with the per-session opt-in.";
const resolver_break = "An async behavior's failure breaks its deferred answer through resolver_abandon with the failure message. resolver_abandon also tolerates an answer its session already retired.";
const resolver_fulfill = "resolver_fulfill_value replaces it. It settles the resolver with plain data or capabilities.";
const session_feed = "feed_bytes delimits frames from stream bytes and feeds them. session_feed takes a prebuilt GlowcapFrame from a C embedder.";
const packet_framing = "feed_bytes and take_outbound carry every stream transport the Python binding connects. Packet framing serves message transports such as WebRTC, whose C provider frames its own packets.";
const turn_defer = "turn_defer_if_answer defers an answered call onto a one-shot resolver. It also lets a told async behavior run with none.";
const transport_allocator = "A caller-supplied Context allocator for a transport handle serves a C embedder. The Python binding builds transports on the library allocator.";
const runtime_allocator = "A caller-supplied Context allocator for a relay runtime serves a C embedder. The Python binding builds relay runtimes on the library allocator.";
const peer_allocator = "A caller-supplied Context allocator for a WebRTC peer serves a C embedder. The Python binding keeps peers on their netlayer's allocator.";
const lifecycle_id = "The Python binding reports callerless failures under Host scope, whose id the Host assigns (host_diagnostic_id), or under Context scope, which needs none. Allocating ids serves a C embedder that reports failures for lifecycles it owns.";
const locator_hint = "hint_count and hint_at read every hint. A lookup by key needs no second accessor.";
const locator_host_port = "designator_host_port splits a designator into its host and port.";

pub const omissions = .{
    // host
    .{ .name = "glowcap_host_clear_last_error", .reason = last_error },
    .{ .name = "glowcap_host_ensure_advertised_locator", .reason = ensure_advertised },
    .{ .name = "glowcap_host_lifecycle_state", .reason = lifecycle_state },
    .{ .name = "glowcap_host_new", .reason = host_new },
    .{ .name = "glowcap_host_next_action", .reason = next_action },
    .{ .name = "glowcap_host_next_trace", .reason = next_trace },
    .{ .name = "glowcap_host_plan_dial", .reason = plan_dial },
    .{ .name = "glowcap_host_release_on_drop", .reason = release_on_drop },
    .{ .name = "glowcap_host_resolver_break", .reason = resolver_break },
    .{ .name = "glowcap_host_resolver_fulfill", .reason = resolver_fulfill },
    .{ .name = "glowcap_host_session_feed", .reason = session_feed },
    .{ .name = "glowcap_host_session_feed_packet", .reason = packet_framing },
    .{ .name = "glowcap_host_session_take_packet", .reason = packet_framing },
    .{ .name = "glowcap_host_set_release_on_drop", .reason = release_on_drop },
    .{ .name = "glowcap_host_set_trace_queue", .reason = next_trace },
    .{ .name = "glowcap_host_turn_defer", .reason = turn_defer },
    // net_transport/inproc
    .{ .name = "glowcap_inproc_clear_last_error", .reason = last_error },
    .{ .name = "glowcap_inproc_netlayer_new_in", .reason = transport_allocator },
    // net_transport/iroh
    .{ .name = "glowcap_iroh_clear_last_error", .reason = last_error },
    .{ .name = "glowcap_iroh_netlayer_new_in", .reason = transport_allocator },
    // net_transport/onion
    .{ .name = "glowcap_onion_clear_last_error", .reason = last_error },
    .{ .name = "glowcap_onion_netlayer_new_in", .reason = transport_allocator },
    // net_transport/relay
    .{ .name = "glowcap_relay_runtime_new_in", .reason = runtime_allocator },
    // net_transport/tcp
    .{ .name = "glowcap_tcp_clear_last_error", .reason = last_error },
    .{ .name = "glowcap_tcp_netlayer_new_in", .reason = transport_allocator },
    // net_transport/webrtc
    .{ .name = "glowcap_webrtc_clear_last_error", .reason = last_error },
    .{ .name = "glowcap_webrtc_netlayer_new_in", .reason = transport_allocator },
    .{ .name = "glowcap_webrtc_peer_new_in", .reason = peer_allocator },
    // ocapn
    .{ .name = "glowcap_clear_last_error", .reason = last_error },
    .{ .name = "glowcap_context_allocate_lifecycle_id", .reason = lifecycle_id },
    .{ .name = "glowcap_locator_hint", .reason = locator_hint },
    .{ .name = "glowcap_locator_host_port", .reason = locator_host_port },
};
