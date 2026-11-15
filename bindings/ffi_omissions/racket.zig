//! The exports the Racket FFI table leaves out beyond those in
//! `shared.zig`, each with the reason for that decision. Signatures and row
//! order come from the C inventories.
//!
//! An entry is `.{ .name = "<export>", .reason = "<why>" }`. A generator
//! refuses a name with no export in its archives, a name more than one
//! archive declares, a name repeated here or in `shared.zig`, and an empty
//! reason, and its refusal names the entry and the file that holds it.
//!
//! A `glowcap_host_*` export missing from this list and from `shared.zig`
//! needs a Racket wrapper that a runtime proof reaches, which
//! `zig build source-check` holds.

const host_new = "host_new_in builds the Host in an explicit Context, which owns the Host's callerless failure journal.";
const next_action = "The Racket binding drains actions through the hook pump (pump_drain). The pull queue serves an embedder that cannot install hooks.";
const next_trace = "The Racket binding installs the trace callback. The drained trace ring serves an embedder that cannot take a callback.";
const release_on_drop = "The Host attaches no behavior to this setting, which records scope-end release for a binding like Rust. The Racket binding releases through finalizers with the per-session opt-in.";
const resolver_fulfill = "resolver_fulfill_value replaces it. It settles the resolver with plain data or capabilities.";
const packet_framing = "feed_bytes and take_outbound carry every stream transport the Racket binding connects. Packet framing serves message transports such as WebRTC, whose C provider frames its own packets.";
const transport_allocator = "A caller-supplied Context allocator for a transport handle serves a C embedder. The Racket binding builds transports on the library allocator.";
const runtime_allocator = "A caller-supplied Context allocator for a relay runtime serves a C embedder. The Racket binding builds relay runtimes on the library allocator.";
const peer_allocator = "A caller-supplied Context allocator for a WebRTC peer serves a C embedder. The Racket binding keeps peers on their netlayer's allocator.";
const context_allocator = "Caller-supplied allocator callbacks serve a C embedder. Racket Hosts and transports use a library-allocator Context.";

pub const omissions = .{
    // host
    .{ .name = "glowcap_host_new", .reason = host_new },
    .{ .name = "glowcap_host_next_action", .reason = next_action },
    .{ .name = "glowcap_host_next_trace", .reason = next_trace },
    .{ .name = "glowcap_host_release_on_drop", .reason = release_on_drop },
    .{ .name = "glowcap_host_resolver_fulfill", .reason = resolver_fulfill },
    .{ .name = "glowcap_host_session_feed_packet", .reason = packet_framing },
    .{ .name = "glowcap_host_session_take_packet", .reason = packet_framing },
    .{ .name = "glowcap_host_set_release_on_drop", .reason = release_on_drop },
    .{ .name = "glowcap_host_set_trace_queue", .reason = next_trace },
    // net_transport/iroh
    .{ .name = "glowcap_iroh_netlayer_new_in", .reason = transport_allocator },
    // net_transport/relay
    .{ .name = "glowcap_relay_runtime_new_in", .reason = runtime_allocator },
    // net_transport/webrtc
    .{ .name = "glowcap_webrtc_peer_new_in", .reason = peer_allocator },
    // ocapn
    .{ .name = "glowcap_context_new_with_allocator", .reason = context_allocator },
};
