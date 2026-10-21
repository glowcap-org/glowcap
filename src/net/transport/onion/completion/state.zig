//! Owned state and operation vocabulary for the completion-backed onion leg.
//!
//! The backend drives SOCKS and Tor control transitions. This module owns the
//! data whose lifetimes those transitions coordinate. Keeping connection
//! footprint, retry links, retained receives, and configuration together makes
//! them one reviewable subject instead of reactor declarations.

const std = @import("std");

const model = @import("model");
const adapter = @import("../../../completion/adapter.zig");
const completion = @import("../../../completion/loop.zig");
const intrusive_queue = @import("../../../completion/intrusive_queue.zig");
const onion_control = @import("../control.zig");
const socks5 = @import("../socks5.zig");

/// What one chunk of a SOCKS5 CONNECT reply told the leg.
///
/// The reply arrives across any number of inner receives, and its whole
/// length is not known until its head names the bound address form, so the
/// leg accumulates until it can answer. Keeping the accumulation pure here
/// leaves the backend only the effects: recycle, refuse, read again, or open.
pub const ReplyVerdict = union(enum) {
    /// Not the whole reply yet. Read more. status-allow: pending state or quoted runtime label
    need_more,
    /// A well-formed success, having taken `consumed` bytes of this chunk.
    /// Anything past that is application data the leg retains.
    complete: usize,
    /// The reply cannot become a well-formed success.
    refused,
};

pub fn Types(comptime Inner: type, comptime Namespace: type) type {
    return struct {
        pub const ConfigType = struct {
            pub const default_setup_timeout_ms: u32 = 30_000;

            socks: Inner.ConnectTarget,
            control: ?Inner.ConnectTarget = null,
            auth: onion_control.Auth = .none,
            service_key: []const u8 = &.{},
            /// One deadline for connect, authentication, and service creation.
            setup_timeout_ms: u32 = default_setup_timeout_ms,
        };

        pub const Target = struct { service_id: [socks5.service_id_len]u8 };
        pub const ConnectTarget = union(enum) {
            plain: Inner.ConnectTarget,
            onion: Target,
        };

        pub const ConnId = u32;
        pub const InternalOp = enum(u3) { connect, recv, send, close };
        pub const PendingOps = adapter.PendingOps(InternalOp, &.{ .connect, .recv, .send });
        pub const Identity = Namespace.RowIdentity(InternalOp);
        pub const RetryLinks = intrusive_queue.Links(ConnId);
        pub const State = enum {
            connecting,
            greeting_send,
            greeting_recv,
            request_send,
            reply_recv,
            open,
            closing,
        };

        pub const Conn = struct {
            id: ConnId,
            inner_fd: Inner.Fd,
            state: State = .connecting,
            request: [socks5.connect_request_len]u8 = undefined,
            greeting_reply: [socks5.greeting_reply_len]u8 = undefined,
            greeting_reply_len: u8 = 0,
            handshake_send_offset: u8 = 0,
            external_connect_ud: ?u64,
            external_recv_ud: ?u64 = null,
            external_send_ud: ?u64 = null,
            external_close_ud: ?u64 = null,
            pending: PendingOps = .{},
            inner_close: adapter.InnerClose = .open,
            /// Intrusive memberships: recycle-gated starvation and owed
            /// submissions. A row occupies each queue at most once.
            recv_starvation: RetryLinks = .{},
            submission_retry: RetryLinks = .{},
            submission_retry_mask: u8 = 0,
            reply_prefix: [socks5.connect_reply_head_len + 1]u8 = undefined,
            reply_len: u16 = 0,
            reply_expected: u16 = socks5.connect_reply_head_len,
            /// A retained inner receive: the SOCKS reply's coalesced tail, or
            /// application bytes that arrived while no caller seat was open.
            /// The next receive seat lends it before another inner read is
            /// armed, so a canceled seat loses nothing.
            held_recv: ?completion.Completion = null,
            held_offset: u16 = 0,
            borrowed: bool = false,

            pub fn deinit(self: *Conn, inner: *Inner) void {
                std.debug.assert(!self.borrowed);
                if (self.held_recv) |held| inner.recycleBorrowed(held);
                self.held_recv = null;
            }
            /// Fold one received chunk into this leg's SOCKS5 CONNECT reply.
            /// The head names the bound address form, and that form gives the
            /// whole reply's length. A domain form carries its length in the
            /// byte after it, and a zero there can never complete.
            pub fn accumulateReply(c: *Conn, bytes: []const u8) ReplyVerdict {
                var offset: usize = 0;
                while (offset < bytes.len and c.reply_len < c.reply_expected) {
                    if (c.reply_len < c.reply_prefix.len)
                        c.reply_prefix[c.reply_len] = bytes[offset];
                    c.reply_len += 1;
                    offset += 1;
                    if (c.reply_len == socks5.connect_reply_head_len) {
                        const head: *const [socks5.connect_reply_head_len]u8 = c.reply_prefix[0..4];
                        const bound = socks5.boundAddress(head) catch return .refused;
                        c.reply_expected = @intCast(switch (bound) {
                            .fixed => |n| 4 + n,
                            .domain => 5,
                        });
                    } else if (c.reply_len == 5 and c.reply_prefix[3] == 0x03) {
                        if (c.reply_prefix[4] == 0) return .refused;
                        c.reply_expected = 4 + 1 + @as(u16, c.reply_prefix[4]) + 2;
                    }
                }
                if (c.reply_len < c.reply_expected) return .need_more;
                var head: [socks5.connect_reply_head_len]u8 = undefined;
                @memcpy(&head, c.reply_prefix[0..4]);
                socks5.checkConnectReply(&head) catch return .refused;
                return .{ .complete = offset };
            }
        };

        pub const ConnMap = std.AutoHashMapUnmanaged(ConnId, *Conn);
        pub const setup_connect_ud: u64 = Identity.userData(.connect, 0);
        pub const setup_send_ud: u64 = Identity.userData(.send, 0);
        pub const setup_recv_ud: u64 = Identity.userData(.recv, 0);
        pub const setup_close_ud: u64 = Identity.userData(.close, 0);
    };
}

/// Runtime configuration for a completion-loop onion backend. Both targets
/// are owned by the caller for the backend lifetime.
pub fn Config(comptime Inner: type) type {
    const Namespace = completion.AdapterNamespace(Inner);
    return Types(Inner, Namespace).ConfigType;
}

/// Resolve an onion locator into an owned service id while delegating every
/// other transport to the wrapped backend's resolver.
pub fn DialResolver(comptime InnerResolver: type, comptime Inner: type) type {
    const Namespace = completion.AdapterNamespace(Inner);
    const State = Types(Inner, Namespace);
    return struct {
        pub fn resolve(locator: model.PeerLocator) !State.ConnectTarget {
            if (std.mem.eql(u8, locator.transport, model.transport.onion)) {
                var id: [socks5.service_id_len]u8 = undefined;
                socks5.checkServiceId(locator.designator) catch return error.InvalidAddress;
                @memcpy(&id, locator.designator);
                return .{ .onion = .{ .service_id = id } };
            }
            return .{ .plain = try InnerResolver.resolve(locator) };
        }
    };
}
