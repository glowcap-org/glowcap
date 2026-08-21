//! Runtime-owned transport binding state.
//!
//! The HostRuntime orchestrates these rows, but this leaf defines the owned
//! storage and stable identities that must move together through close and
//! release. No I/O or lifecycle policy lives here.

const std = @import("std");

const foundation = @import("foundation");
const net = @import("net");
const driver_core = @import("driver_core");
const OperationFailure = @import("../operation_failure.zig").OperationFailure;

/// A session wrapper dropped from inside a behavior callback transfers its
/// release request through this intrusive node. The wrapper owns the node, so
/// deferral adds no allocation and keeps the runtime lease alive.
pub const DeferredSessionRelease = struct {
    session: *driver_core.HostSession,
    ctx: *anyopaque,
    complete: *const fn (ctx: *anyopaque) bool,
    next: ?*DeferredSessionRelease = null,
    queued: bool = false,
};

/// One session's transport binding, retained after transport close until the
/// application releases its session handle.
pub const Wire = struct {
    link: Link,
    session: *driver_core.HostSession,
    /// The transport reported closure (EOF or fault); the wire stays owned so
    /// a view holding it observes closed state rather than a dangling row.
    closed: bool = false,
    /// Physical carrier retirement is a separate barrier from logical CapTP
    /// closure. Waiting states name the descriptor interest needed to advance
    /// a stream; resident progress arrives through its runtime readiness row.
    carrier_close: CarrierClose = .open,
    carrier_close_deadline_ms: ?i64 = null,
    /// The logical primary plus the first carrier-cleanup consequence. Static
    /// names keep this bounded and allocation-free on the close path.
    close_failure: ?OperationFailure = null,
    /// A consumed session may transfer only its carrier into Runtime-owned
    /// retirement. Intrusive links make completion O(1) and allocation-free;
    /// `session` is never dereferenced while detached.
    detached: bool = false,
    retiring_prev: ?*Wire = null,
    retiring_next: ?*Wire = null,
    /// The installed close observer reserved publication before this session
    /// became visible. Close consumes it; release-before-close gives it back.
    close_event_reserved: bool = false,
    /// One owning session handle claimed release authority for this wire.
    session_handle_claimed: bool = false,
    /// Whether inbound application frames may dispatch. A stream can leave
    /// bytes in the kernel while unattended; a resident must park its pushed
    /// records in the bounded buffer below.
    attended: bool = true,

    pub const CarrierClose = enum {
        open,
        wait_read,
        wait_write,
        wait_resident,
        complete,
    };

    pub fn carrierClosed(self: *const Wire) bool {
        return self.carrier_close == .complete;
    }

    pub const Link = union(enum) {
        stream: StreamLink,
        resident: ResidentLink,
    };

    pub const StreamLink = struct {
        conn: net.Connection,
        read_buf: []u8,
        write_buf: []u8,
        transport_released: bool = false,
    };

    pub const ResidentLink = struct {
        index: usize,
        conn: usize,
        read_buf: []u8,
        pending: ?PendingOut = null,
        parked: std.ArrayListUnmanaged(u8) = .empty,
        parked_packets: std.ArrayListUnmanaged([]u8) = .empty,
        parked_packet_bytes: usize = 0,

        pub const PendingOut = struct {
            frame: foundation.Frame,
            prefix: [foundation.stream_framing.prefix_buffer_bytes]u8,
            prefix_len: usize,
            offset: usize,
        };
    };
};

/// The most inbound data a resident may park before the embedder attends the
/// session. A peer that exceeds it is closed instead of growing unclaimed heap.
pub const unattended_parked_cap_bytes: usize = 64 * 1024;
