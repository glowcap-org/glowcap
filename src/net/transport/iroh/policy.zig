//! Shared iroh transport policy that must cross the Zig/Rust sidecar boundary.

/// Accepted loop connections each endpoint may retain before the completion
/// backend claims them. The Rust sidecar producer queue and Zig backend stash
/// share this admission posture.
pub const accept_queue_bound: usize = 128;

/// Raw bytes a non-blocking iroh reader asks from one QUIC chunk at a time.
/// The sidecar uses it as its zero-copy `read_chunk` cap, and bindings use the
/// generated mirror for their C-facing read buffers.
pub const read_chunk_bytes: usize = 64 * 1024;
