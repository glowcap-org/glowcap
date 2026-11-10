//! Symbols the Racket FFI table omits and the reason for each decision.
//! Signatures, crossing metadata and output order come from the C inventories.

const last_error = "unused: the Racket binding reads the slot after a failing call and never resets it";
const transport_allocator = "unused: the Racket binding keeps its transports on the library allocator";
const transport_runtime_allocator = "unused: the Racket binding keeps transport runtimes on the library allocator";

pub const omissions = .{
    // host
    .{ .name = "glowcap_host_clear_last_error", .reason = last_error },
    .{ .name = "glowcap_host_ensure_advertised_locator", .reason = "the dialed and accepted opens retain the transport default in Zig; route policy uses set/remove" },
    .{ .name = "glowcap_host_lifecycle_state", .reason = "close_progress already returns the terminal state while supplying the clock; the Racket binding needs no second observation call" },
    .{ .name = "glowcap_host_new", .reason = "Racket gives every Host an explicit GlowcapContext so Zig callerless diagnostics have one claim owner" },
    .{ .name = "glowcap_host_next_action", .reason = "the Racket binding drains actions through the C hook pump (pump_drain), never the pull queue" },
    .{ .name = "glowcap_host_next_trace", .reason = "no queue to drain: the Racket veneer installs the trace callback" },
    .{ .name = "glowcap_host_pending_dial_introducer", .reason = "Racket has no directory-scoped signaling connector; Zig provider dials do not use this byte-fed projection" },
    .{ .name = "glowcap_host_plan_dial", .reason = "transport packages interpret their own locators; the generic Runtime retains only providers and connectors" },
    .{ .name = "glowcap_host_ref_retain", .reason = "independent prepared reference captures are not exposed by the Racket binding" },
    .{ .name = "glowcap_host_release_on_drop", .reason = "the Racket release rides a finalizer, so the Host is built with the setting off and the per-session opt-in stays" },
    .{ .name = "glowcap_host_resolver_fulfill_value", .reason = "the explicit resolver in this binding uses the plain-data seam" },
    .{ .name = "glowcap_host_send", .reason = "sessionless owning-value delivery serves the Rust Loam executor; Racket uses Session sends and has no Loam hosting profile" },
    .{ .name = "glowcap_host_session_feed", .reason = "the Racket pump feeds raw bytes (feed_bytes); no GlowcapFrame is built binding-side" },
    .{ .name = "glowcap_host_session_feed_packet", .reason = "the Racket pump still drives the stream-specific byte seam until its WebRTC adapter exists" },
    .{ .name = "glowcap_host_session_partner_abort", .reason = "the Racket surface reads the retained abort through session_last_abort's struct view alone" },
    .{ .name = "glowcap_host_session_resolve", .reason = "generic opaque capability resolution is consumed by Rust Rooms; this binding currently exposes the wire listen operation" },
    .{ .name = "glowcap_host_session_take_packet", .reason = "the Racket pump still drains the stream-specific byte seam until its WebRTC adapter exists" },
    .{ .name = "glowcap_host_set_release_on_drop", .reason = "the Racket release rides a finalizer, so the Host is built with the setting off and the per-session opt-in stays" },
    .{ .name = "glowcap_host_set_trace_queue", .reason = "the Racket veneer installs the trace callback; the drained ring is the seam for an embedder that cannot take one" },
    .{ .name = "glowcap_host_spawn", .reason = "Ordinary Host actor hosting currently has a Rust front; Racket retains its session-owned spawn front" },
    .{ .name = "glowcap_host_tell", .reason = "sessionless delivery serves Rust managed hosting; Racket uses Session notifications" },
    .{ .name = "glowcap_host_turn_send", .reason = "a Racket behavior sends through the session verbs" },
    .{ .name = "glowcap_host_turn_tell", .reason = "a Racket behavior tells through the session verbs" },
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
    .{ .name = "glowcap_webrtc_netlayer_new_in", .reason = "unused: the Racket binding keeps its webrtc netlayer on the library allocator" },
    .{ .name = "glowcap_webrtc_peer_new_in", .reason = "unused: the Racket binding keeps its webrtc peers on the netlayer allocator" },
    // ocapn
    .{ .name = "glowcap_clear_last_error", .reason = last_error },
    .{ .name = "glowcap_context_allocate_lifecycle_id", .reason = "Zig Host construction assigns Host identity; Racket currently owns no other Context-scoped diagnostic lifecycle" },
    .{ .name = "glowcap_context_new_with_allocator", .reason = "unused: the Racket binding keeps every archive on the library allocator" },
    .{ .name = "glowcap_locator_hint", .reason = "the Racket surface walks hints through hint_count/hint_at; the single-lookup accessor is unused" },
    .{ .name = "glowcap_locator_host_port", .reason = "the Racket surface resolves host:port through designator_host_port" },
};
