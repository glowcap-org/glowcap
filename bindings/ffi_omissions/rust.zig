//! Symbols the Rust FFI table omits and the reason for each decision.
//! Signatures, crossing metadata and output order come from the C inventories.

const last_error = "unused: the Rust binding reads the slot after a failing call and never resets it";
const transport_allocator = "unused: the Rust binding keeps its transports on the library allocator";

pub const omissions = .{
    // host
    .{ .name = "glowcap_host_clear_last_error", .reason = last_error },
    .{ .name = "glowcap_host_ensure_advertised_locator", .reason = "the dialed and accepted opens retain the transport default in Zig; route policy uses set/remove" },
    .{ .name = "glowcap_host_lifecycle_state", .reason = "close_progress already returns the terminal state while supplying the clock; the Rust binding needs no second observation call" },
    .{ .name = "glowcap_host_next_action", .reason = "the Rust binding drains actions through the C hook pump (pump_drain), never the pull queue" },
    .{ .name = "glowcap_host_next_trace", .reason = "no queue to drain: the Rust veneer installs the trace callback" },
    .{ .name = "glowcap_host_plan_dial", .reason = "transport packages interpret their own locators; the generic Runtime retains only providers and connectors" },
    .{ .name = "glowcap_host_session_break_far_vows", .reason = "the Rust binding reports physical EOF through session_transport_closed; it has no separate manual far-vow break surface" },
    .{ .name = "glowcap_host_session_feed", .reason = "the Rust pump feeds raw bytes (feed_bytes); no GlowcapFrame is built binding-side" },
    .{ .name = "glowcap_host_session_partner_abort", .reason = "the Rust surface reads the retained abort through session_last_abort's struct view alone" },
    .{ .name = "glowcap_host_set_trace_queue", .reason = "the Rust veneer installs the trace callback; the drained ring is the seam for an embedder that cannot take one" },
    .{ .name = "glowcap_host_turn_send", .reason = "a Rust behavior sends through the session verbs" },
    .{ .name = "glowcap_host_turn_tell", .reason = "a Rust behavior tells through the session verbs" },
    // net_transport/iroh
    .{ .name = "glowcap_iroh_netlayer_new_in", .reason = transport_allocator },
    // net_transport/webrtc
    .{ .name = "glowcap_webrtc_netlayer_new_in", .reason = "unused: the Rust binding keeps its webrtc netlayer on the library allocator" },
    .{ .name = "glowcap_webrtc_peer_new_in", .reason = "unused: the Rust binding keeps its webrtc peers on the netlayer allocator" },
    // ocapn
    .{ .name = "glowcap_context_allocate_lifecycle_id", .reason = "Zig Host construction assigns Host identity; Rust currently owns no other Context-scoped diagnostic lifecycle" },
};
