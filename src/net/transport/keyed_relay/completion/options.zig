//! Retained-memory policy for one completion-backed relay connection.

const protocol = @import("../../../websocket.zig").client_protocol;
const tls_runtime_owner = @import("../../../tls/runtime_owner.zig");

/// Default per-connection storage for one masked WebSocket send. This includes
/// the frame header and payload; callers may trade a different explicit memory
/// commitment for larger or smaller application chunks.
pub const default_send_staging_bytes: usize = 4096;
pub const minimum_send_staging_bytes: usize =
    protocol.max_header_len + protocol.max_control_payload;

/// A wrapped close or secure send submission can be refused under transient
/// backend pressure. Bound the next wait while one is owed so retry cannot
/// sleep behind work that only the retry itself can admit.
pub const operation_retry_ms: i32 = 50;
/// Bound close-resubmission work per loop turn. A mass disconnect under a full
/// platform queue must not turn one poll into an O(all-connections) retry storm;
/// the intrusive FIFO rotates the remaining debt across later turns.
pub const close_retry_batch: usize = 256;

pub const RelayOptions = struct {
    url: []const u8,
    entropy_seed: [@import("std").Random.DefaultCsprng.secret_seed_length]u8,
    /// Environment-owned async I/O used only for DNS lookup. IP-literal
    /// routes need no resolver. The completion backend races returned
    /// addresses itself; this handle never owns a connect socket.
    resolver_io: ?@import("std").Io = null,
    /// Optional process-owned TLS runtime. Initialization takes one child
    /// lease; the caller retains the Owner as the deterministic final barrier.
    /// Clear relay connections pay no TLS state or runtime lease.
    tls_owner: ?tls_runtime_owner.Owner = null,
    /// Total retained storage for one masked WebSocket frame, including its
    /// header. This is transport staging, never an application or CapTP frame
    /// limit.
    send_staging_bytes: usize = default_send_staging_bytes,
    /// Hold a registration at a relay so dialers of `identity` reach this
    /// backend's listener. Without it, `openListener` serves the platform.
    registration: ?Registration = null,
};

/// The key dialers name is the listening Host's, which the listen supplies.
pub const Registration = struct {
    /// The relay's registration endpoint, retained by the backend.
    url: []const u8,
};

/// Delay before replacing a registration leg that failed or was refused.
pub const registration_retry_ms: i64 = 100;
/// Promoted registration legs a listener may hold before it accepts them.
/// A full backlog pauses registration rather than growing.
pub const max_unaccepted_registrations = 64;
