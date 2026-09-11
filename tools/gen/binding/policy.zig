//! Binding-owned policy constants shared by generated mirrors.
//!
//! These values are not C ABI declarations. They belong here when the bindings
//! share a host-language resource policy that the core and C surface do not own.

/// Settled Host vow outcomes retained for a caller that has not awaited yet.
pub const unobserved_outcome_cap: usize = 1024;

/// Readiness records a binding pulls from a transport endpoint per drain call.
pub const readiness_drain_cap: usize = 64;

/// Bytes one binding-owned byte-stream read asks its language runtime for.
pub const stream_read_chunk_bytes: usize = 64 * 1024;

/// Default message-frame bytes a binding trace producer forwards per event.
pub const trace_payload_cap_bytes: usize = 4096;

/// Exact cleanup/consequence failures retained beside a primary binding error.
pub const secondary_failure_cap: usize = 64;

/// Reference relay idle timeout; tests override it through GLOWCAP_RELAY_IDLE_MS.
pub const relay_idle_timeout_ms: usize = 60 * 1000;

/// Bytes relayed over one reference-relay session before the runaway backstop fires.
pub const relay_max_bytes_per_session: usize = 1024 * 1024 * 1024;

/// Bytes one reference-relay target-channel read asks its runtime for.
pub const relay_read_chunk_bytes: usize = stream_read_chunk_bytes;

/// Reference relay TCP connect deadline.
pub const relay_tcp_dial_timeout_ms: usize = 5 * 1000;

/// Per-connection WebSocket read/write buffers used by the standalone Rust relay.
pub const relay_websocket_buffer_bytes: usize = 16 * 1024;

/// Largest WebSocket transport message a binding adapter admits.
pub const websocket_message_cap_bytes: usize = 1024 * 1024;

/// WebSocket send buffer waterline before the shared adapter parks another write.
pub const websocket_send_high_water_bytes: usize = 1024 * 1024;

/// Poll interval while waiting for a WebSocket send buffer to drain.
pub const websocket_drain_poll_ms: usize = 4;

/// Deadline for observing retirement of an embedder-owned browser channel.
pub const browser_channel_close_timeout_ms: usize = relay_tcp_dial_timeout_ms;

/// WebSocket bindings use the same browser channel retirement policy.
pub const websocket_close_timeout_ms: usize = browser_channel_close_timeout_ms;

/// Default retained inbound WebSocket bytes before the shared adapter closes.
pub const websocket_inbound_high_water_bytes: usize = 1024 * 1024;
