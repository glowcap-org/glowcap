//! Binding-owned policy constants shared by generated mirrors.
//!
//! These values are not C ABI declarations. They belong here when the bindings
//! share a host-language resource policy that the core and C surface do not own.
//! Each value carries the sentence the generated mirrors print beside it, so
//! the mirrors and this file cannot disagree about what a value bounds.

pub const Policy = struct { value: usize, doc: []const u8 };

pub const unobserved_outcome_cap: Policy = .{ .value = 1024, .doc = "Settled Host vow outcomes retained for a caller that has not awaited yet." };

pub const readiness_drain_cap: Policy = .{ .value = 64, .doc = "Readiness records a binding pulls from a transport endpoint per drain call." };

pub const stream_read_chunk_bytes: Policy = .{ .value = 64 * 1024, .doc = "Bytes one binding-owned byte-stream read asks its language runtime for." };

pub const trace_payload_cap_bytes: Policy = .{ .value = 4096, .doc = "Default message-frame bytes a binding trace producer forwards per event." };

pub const secondary_failure_cap: Policy = .{ .value = 64, .doc = "Exact cleanup and consequence failures retained beside a primary binding error." };

pub const relay_idle_timeout_ms: Policy = .{ .value = 60 * 1000, .doc = "Reference relay idle timeout in milliseconds. Tests override it through GLOWCAP_RELAY_IDLE_MS." };

pub const relay_max_bytes_per_session: Policy = .{ .value = 1024 * 1024 * 1024, .doc = "Bytes relayed over one reference-relay session before the runaway backstop fires." };

pub const relay_read_chunk_bytes: Policy = .{ .value = stream_read_chunk_bytes.value, .doc = "Bytes one reference-relay target-channel read asks its runtime for." };

pub const relay_tcp_dial_timeout_ms: Policy = .{ .value = 5 * 1000, .doc = "Reference relay TCP connect deadline in milliseconds." };

pub const relay_websocket_buffer_bytes: Policy = .{ .value = 16 * 1024, .doc = "Per-connection WebSocket read and write buffer bytes of the standalone Rust relay." };

pub const websocket_message_cap_bytes: Policy = .{ .value = 1024 * 1024, .doc = "Largest WebSocket transport message a binding adapter admits." };

pub const websocket_send_high_water_bytes: Policy = .{ .value = 1024 * 1024, .doc = "WebSocket send buffer waterline before the shared adapter parks another write." };

pub const websocket_drain_poll_ms: Policy = .{ .value = 4, .doc = "Poll interval in milliseconds while a WebSocket send buffer drains." };

pub const browser_channel_close_timeout_ms: Policy = .{ .value = relay_tcp_dial_timeout_ms.value, .doc = "Deadline in milliseconds for observing retirement of an embedder-owned browser channel." };

pub const websocket_close_timeout_ms: Policy = .{ .value = browser_channel_close_timeout_ms.value, .doc = "WebSocket close deadline in milliseconds, the same policy as browser channel retirement." };

pub const websocket_inbound_high_water_bytes: Policy = .{ .value = 1024 * 1024, .doc = "Retained inbound WebSocket bytes before the shared adapter closes the channel." };
