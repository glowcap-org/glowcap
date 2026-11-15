//! The exports every binding's FFI table leaves out for a reason that does
//! not depend on the binding. Each serves a C embedder, and a binding gets
//! the same effect another way. Add an export that every binding leaves out
//! here and leave it out of the binding files. A reason that names what one
//! binding does instead belongs in that binding's file.
//!
//! An entry is `.{ .name = "<export>", .reason = "<why>" }`. A generator
//! joins this table with its binding's file, refuses a name with no export in
//! its archives, a name more than one archive declares, a name repeated
//! within or across the two, and an empty reason, and its refusal names the
//! entry and the file that holds it.

const last_error = "Every export clears the error slot on entry. A binding reads the slot right after the call that failed, so an explicit reset serves only a C caller that inspects the slot between calls.";
const ensure_advertised = "Every session open a binding makes (open_dialed_locator, open_accepted) already retains this transport fallback inside the Host. set_advertised_locator and remove_advertised_locator select routes.";
const lifecycle_state = "close_progress returns the lifecycle state while it applies the clock. A binding's close driver reads it there.";
const plan_dial = "Driver providers plan dials inside Zig, and each byte-fed connector resolves the locators it advertises. plan_dial serves a C embedder that opens its own sockets.";
const session_feed = "feed_bytes delimits frames from stream bytes, and feed_packet feeds frames from transport packets. session_feed takes a prebuilt GlowcapFrame from a C embedder.";
const transport_allocator = "A caller-supplied Context allocator for a transport handle serves a C embedder. A binding builds transports on the library allocator.";
const lifecycle_id = "A binding reports callerless failures under Host scope, whose id the Host assigns (host_diagnostic_id), or under Context scope, which needs none. Allocating ids serves a C embedder that reports failures for lifecycles it owns.";
const locator_hint = "hint_count and hint_at read every hint. A lookup by key needs no second accessor.";
const locator_host_port = "designator_host_port splits a designator into its host and port.";
const locator_allocator = "A caller-supplied Context allocator for a locator serves a C embedder. A binding builds and parses locators on the library allocator.";

pub const omissions = .{
    // driver
    .{ .name = "glowcap_driver_clear_last_error", .reason = last_error },
    // host
    .{ .name = "glowcap_host_clear_last_error", .reason = last_error },
    .{ .name = "glowcap_host_ensure_advertised_locator", .reason = ensure_advertised },
    .{ .name = "glowcap_host_lifecycle_state", .reason = lifecycle_state },
    .{ .name = "glowcap_host_plan_dial", .reason = plan_dial },
    .{ .name = "glowcap_host_session_feed", .reason = session_feed },
    // net_transport/inproc
    .{ .name = "glowcap_inproc_clear_last_error", .reason = last_error },
    .{ .name = "glowcap_inproc_netlayer_new_in", .reason = transport_allocator },
    // net_transport/iroh
    .{ .name = "glowcap_iroh_clear_last_error", .reason = last_error },
    // net_transport/onion
    .{ .name = "glowcap_onion_clear_last_error", .reason = last_error },
    .{ .name = "glowcap_onion_netlayer_new_in", .reason = transport_allocator },
    // net_transport/relay
    .{ .name = "glowcap_relay_clear_last_error", .reason = last_error },
    // net_transport/tcp
    .{ .name = "glowcap_tcp_clear_last_error", .reason = last_error },
    .{ .name = "glowcap_tcp_netlayer_new_in", .reason = transport_allocator },
    // net_transport/webrtc
    .{ .name = "glowcap_webrtc_clear_last_error", .reason = last_error },
    .{ .name = "glowcap_webrtc_netlayer_new_in", .reason = transport_allocator },
    // ocapn
    .{ .name = "glowcap_clear_last_error", .reason = last_error },
    .{ .name = "glowcap_context_allocate_lifecycle_id", .reason = lifecycle_id },
    .{ .name = "glowcap_locator_clone_in", .reason = locator_allocator },
    .{ .name = "glowcap_locator_hint", .reason = locator_hint },
    .{ .name = "glowcap_locator_host_port", .reason = locator_host_port },
    .{ .name = "glowcap_locator_new_in", .reason = locator_allocator },
    .{ .name = "glowcap_uri_parse_peer_in", .reason = locator_allocator },
    .{ .name = "glowcap_uri_parse_sturdyref_in", .reason = locator_allocator },
};
