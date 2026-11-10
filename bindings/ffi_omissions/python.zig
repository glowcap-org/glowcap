//! Symbols the Python FFI table omits and the reason for each decision.
//! Signatures, crossing metadata and output order come from the C inventories.

const last_error = "unused: the Python binding reads the slot after a failing call and never resets it";
const transport_allocator = "unused: the Python binding keeps its transports on the library allocator";
const transport_runtime_allocator = "unused: the Python binding keeps transport runtimes on the library allocator";

pub const omissions = .{
    // host
    .{ .name = "glowcap_host_resolver_fulfill", .reason = "behavior replies use resolver_fulfill_value so deferred values can carry capabilities" },
    .{ .name = "glowcap_host_clear_last_error", .reason = last_error },
    .{ .name = "glowcap_host_ensure_advertised_locator", .reason = "the dialed and accepted opens retain the transport default in Zig; route policy uses set/remove" },
    .{ .name = "glowcap_host_lifecycle_state", .reason = "close_progress already returns the terminal state while supplying the clock; the Python binding needs no second observation call" },
    .{ .name = "glowcap_host_new", .reason = "Python gives every Host an explicit GlowcapContext so Zig callerless diagnostics have one claim owner" },
    .{ .name = "glowcap_host_next_action", .reason = "the Python binding drains actions through the C hook pump (pump_drain), never the pull queue" },
    .{ .name = "glowcap_host_next_trace", .reason = "no queue to drain: the Python veneer installs the trace callback" },
    .{ .name = "glowcap_host_pending_dial_introducer", .reason = "the C WebRTC provider supplies introducer context to its signaling callback; stream connectors do not use this byte-fed projection" },
    .{ .name = "glowcap_host_plan_dial", .reason = "transport packages interpret their own locators; the generic Runtime retains only providers and connectors" },
    .{ .name = "glowcap_host_release_on_drop", .reason = "the Python release rides a finalizer, so the Host is built with the setting off and the per-session opt-in stays" },
    .{ .name = "glowcap_host_resolver_break", .reason = "automatic awaitable rejection uses resolver_abandon because its session may already have retired the deferred answer; no manual resolver is exposed" },
    .{ .name = "glowcap_host_send", .reason = "session-independent Host actors are an adapter gap tracked in docs/roadmap.md; this binding uses Session actor operations" },
    .{ .name = "glowcap_host_session_break_far_vows", .reason = "the Python binding reports physical EOF through session_transport_closed; it has no separate manual far-vow break surface" },
    .{ .name = "glowcap_host_session_feed", .reason = "the Python pump feeds raw bytes (feed_bytes); no GlowcapFrame is built binding-side" },
    .{ .name = "glowcap_host_session_feed_packet", .reason = "byte-fed connectors feed stream bytes; the C WebRTC provider owns packet framing" },
    .{ .name = "glowcap_host_session_partner_abort", .reason = "the Python surface reads the retained abort through session_last_abort's struct view alone" },
    .{ .name = "glowcap_host_session_take_packet", .reason = "byte-fed connectors drain stream bytes; the C WebRTC provider owns packet framing" },
    .{ .name = "glowcap_host_set_release_on_drop", .reason = "the Python release rides a finalizer, so the Host is built with the setting off and the per-session opt-in stays" },
    .{ .name = "glowcap_host_set_trace_queue", .reason = "the Python veneer installs the trace callback; the drained ring is the seam for an embedder that cannot take one" },
    .{ .name = "glowcap_host_spawn", .reason = "session-independent Host actors are an adapter gap tracked in docs/roadmap.md; this binding uses Session actor operations" },
    .{ .name = "glowcap_host_tell", .reason = "session-independent Host actors are an adapter gap tracked in docs/roadmap.md; this binding uses Session actor operations" },
    .{ .name = "glowcap_host_turn_defer_if_answer", .reason = "automatic coroutine deferral requires an answer; optional deferral needs an explicit callback lifetime owner" },
    .{ .name = "glowcap_host_turn_send", .reason = "session-independent Host actors are an adapter gap tracked in docs/roadmap.md; this binding uses Session actor operations" },
    .{ .name = "glowcap_host_turn_tell", .reason = "session-independent Host actors are an adapter gap tracked in docs/roadmap.md; this binding uses Session actor operations" },
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
    .{ .name = "glowcap_relay_runtime_new_in", .reason = transport_runtime_allocator },
    // net_transport/tcp
    .{ .name = "glowcap_tcp_clear_last_error", .reason = last_error },
    .{ .name = "glowcap_tcp_netlayer_new_in", .reason = transport_allocator },
    // net_transport/webrtc
    .{ .name = "glowcap_webrtc_clear_last_error", .reason = last_error },
    .{ .name = "glowcap_webrtc_netlayer_new_in", .reason = "unused: the Python binding keeps its webrtc netlayer on the library allocator" },
    .{ .name = "glowcap_webrtc_peer_new_in", .reason = "unused: the Python binding keeps its webrtc peers on the netlayer allocator" },
    // ocapn
    .{ .name = "glowcap_clear_last_error", .reason = last_error },
    .{ .name = "glowcap_context_allocate_lifecycle_id", .reason = "Zig Host construction assigns Host identity; Python currently owns no other Context-scoped diagnostic lifecycle" },
    .{ .name = "glowcap_locator_hint", .reason = "the Python surface walks hints through hint_count/hint_at; the single-lookup accessor is unused" },
    .{ .name = "glowcap_locator_host_port", .reason = "the Python surface resolves host:port through designator_host_port" },
};
