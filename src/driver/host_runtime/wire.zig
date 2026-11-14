//! Runtime-owned transport binding state: the owned storage and stable
//! identities that must move together through close and release. The
//! HostRuntime orchestrates these rows. They carry no I/O or lifecycle policy.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
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
    /// The transport reported closure (EOF or fault). The wire stays owned so
    /// a view holding it observes closed state rather than a dangling row.
    closed: bool = false,
    /// Physical carrier retirement is a separate barrier from logical CapTP
    /// closure. Its progress arrives through the resident's readiness row.
    carrier_closed: bool = false,
    carrier_close_deadline_ms: ?i64 = null,
    /// The logical primary plus the first carrier-cleanup consequence. Static
    /// names keep this bounded and allocation-free on the close path.
    close_failure: ?OperationFailure = null,
    /// A consumed session may transfer only its carrier into Runtime-owned
    /// retirement. Intrusive links make completion O(1) and allocation-free.
    /// `session` is never dereferenced while detached.
    detached: bool = false,
    retiring_prev: ?*Wire = null,
    retiring_next: ?*Wire = null,
    /// One owning session handle claimed release authority for this wire.
    session_handle_claimed: bool = false,
    /// Whether inbound application frames may dispatch. While unattended, the
    /// link parks the resident's pushed records in its bounded buffer.
    attended: bool = true,

    pub fn carrierClosed(self: *const Wire) bool {
        return self.carrier_closed;
    }

    /// The wire's connection on its resident, with the outbound frame the
    /// resident's window refused and the inbound records parked while the
    /// session is unattended.
    pub const Link = struct {
        index: usize,
        conn: usize,
        pending: ?PendingOut = null,
        /// Inbound held while the session is unattended. A byte-stream wire
        /// holds the bytes as they arrived. A message-framed wire holds each
        /// packet behind its length, so `parkedPackets` hands back the same
        /// packets in order.
        parked: std.ArrayList(u8) = .empty,
        /// The read loop stopped at the chunk that opened the session, so the
        /// embedder's post-open setup runs before later chunks dispatch.
        /// `resumeFeedTails` finishes the read once the open commits.
        read_deferred: bool = false,

        pub const PendingOut = struct {
            frame: foundation.Frame,
            prefix: [foundation.stream_framing.prefix_buffer_bytes]u8,
            prefix_len: usize,
            offset: usize,
        };

        const ParkedLength = u32;
        const parked_length_bytes = @sizeOf(ParkedLength);

        comptime {
            std.debug.assert(unattended_parked_cap_bytes <= std.math.maxInt(ParkedLength));
        }

        /// Hold `chunk` until the session is attended. A chunk that would
        /// take the buffer past `unattended_parked_cap_bytes` parks nothing
        /// and is refused as a lost connection. A packet's length counts
        /// against the cap, so the cap bounds the heap however small the
        /// packets are.
        pub fn park(
            link: *Link,
            allocator: std.mem.Allocator,
            framing: model.transport.WireFraming,
            chunk: []const u8,
        ) (std.mem.Allocator.Error || error{ConnectionLost})!void {
            const prefix: usize = switch (framing) {
                .byte_stream => 0,
                .message => parked_length_bytes,
            };
            if (link.parked.items.len + prefix + chunk.len > unattended_parked_cap_bytes) return error.ConnectionLost;
            try link.parked.ensureUnusedCapacity(allocator, prefix + chunk.len);
            if (prefix != 0) {
                var length: [parked_length_bytes]u8 = undefined;
                std.mem.writeInt(ParkedLength, &length, @intCast(chunk.len), .little);
                link.parked.appendSliceAssumeCapacity(&length);
            }
            link.parked.appendSliceAssumeCapacity(chunk);
        }

        /// The packets a message-framed wire parked, oldest first. Each
        /// borrows the parked buffer.
        pub fn parkedPackets(link: *const Link) ParkedPackets {
            return .{ .rest = link.parked.items };
        }

        pub const ParkedPackets = struct {
            rest: []const u8,

            pub fn next(self: *ParkedPackets) ?[]const u8 {
                if (self.rest.len == 0) return null;
                const length = std.mem.readInt(ParkedLength, self.rest[0..parked_length_bytes], .little);
                const packet = self.rest[parked_length_bytes..][0..length];
                self.rest = self.rest[parked_length_bytes + length ..];
                return packet;
            }
        };
    };
};

/// The most a wire may park before the embedder attends the session, counting
/// the length kept with each message packet. A peer that exceeds it is closed
/// instead of growing unclaimed heap.
pub const unattended_parked_cap_bytes: usize = 64 * 1024;
