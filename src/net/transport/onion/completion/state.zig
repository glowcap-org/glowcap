//! Owned state and operation vocabulary for the completion-backed onion leg.
//!
//! The backend drives SOCKS and Tor control transitions; this module owns the
//! data whose lifetimes those transitions coordinate. Keeping connection
//! footprint, retry links, retained receives, and configuration together makes
//! them one reviewable subject instead of reactor declarations.

const std = @import("std");

const model = @import("model");
const completion = @import("../../../completion/loop.zig");
const onion_control = @import("../control.zig");
const socks5 = @import("../socks5.zig");

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
        pub const ListenerAddress = [socks5.service_id_len]u8;

        pub const ConnId = u32;
        pub const InternalOp = enum(u3) { connect, recv, send, close, cancel };
        pub const State = enum {
            connecting,
            greeting_send,
            greeting_recv,
            request_send,
            reply_recv,
            open,
            closing,
        };

        pub const Pending = struct {
            connect: bool = false,
            recv: bool = false,
            send: bool = false,
            cancel: bool = false,

            pub fn get(self: *const Pending, op: InternalOp) bool {
                return switch (op) {
                    .connect => self.connect,
                    .recv => self.recv,
                    .send => self.send,
                    .cancel => self.cancel,
                    .close => false,
                };
            }

            pub fn arm(self: *Pending, op: InternalOp) void {
                std.debug.assert(!self.get(op));
                switch (op) {
                    .connect => self.connect = true,
                    .recv => self.recv = true,
                    .send => self.send = true,
                    .cancel => self.cancel = true,
                    .close => unreachable,
                }
            }

            pub fn retire(self: *Pending, op: InternalOp) void {
                std.debug.assert(self.get(op));
                switch (op) {
                    .connect => self.connect = false,
                    .recv => self.recv = false,
                    .send => self.send = false,
                    .cancel => self.cancel = false,
                    .close => unreachable,
                }
            }

            pub fn count(self: *const Pending) usize {
                return @intFromBool(self.connect) + @intFromBool(self.recv) +
                    @intFromBool(self.send) + @intFromBool(self.cancel);
            }
        };

        pub const Conn = struct {
            id: ConnId,
            inner_fd: Inner.Fd,
            state: State = .connecting,
            request: [socks5.connect_request_len]u8 = undefined,
            greeting_reply: [socks5.greeting_reply_len]u8 = undefined,
            greeting_reply_len: u8 = 0,
            handshake_send_offset: u8 = 0,
            external_connect: ?u64,
            external_recv: ?u64 = null,
            external_send: ?u64 = null,
            external_cancel: ?u64 = null,
            external_close: ?u64 = null,
            pending: Pending = .{},
            inner_close: enum { open, in_flight, failed, closed } = .open,
            abandon: bool = false,
            recv_retry: bool = false,
            send_retry: bool = false,
            close_retry: bool = false,
            retry_queued: bool = false,
            retry_next: ?ConnId = null,
            reply_prefix: [socks5.connect_reply_head_len + 1]u8 = undefined,
            reply_len: u16 = 0,
            reply_expected: u16 = socks5.connect_reply_head_len,
            held_recv: ?completion.Completion = null,
            held_offset: u16 = 0,
            borrowed: bool = false,

            pub fn deinit(self: *Conn, backend: anytype) void {
                std.debug.assert(!self.borrowed);
                if (self.held_recv) |held| backend.inner.recycleBorrowed(held);
                self.held_recv = null;
            }

            pub fn externalSeats(self: *const Conn) usize {
                return @intFromBool(self.external_connect != null) +
                    @intFromBool(self.external_recv != null) +
                    @intFromBool(self.external_send != null) +
                    @intFromBool(self.external_cancel != null) +
                    @intFromBool(self.external_close != null);
            }
        };

        pub const ConnMap = std.AutoHashMapUnmanaged(ConnId, *Conn);
        pub const setup_connect_ud: u64 = Namespace.userData(@intFromEnum(InternalOp.connect));
        pub const setup_send_ud: u64 = Namespace.userData(@intFromEnum(InternalOp.send));
        pub const setup_recv_ud: u64 = Namespace.userData(@intFromEnum(InternalOp.recv));
        pub const setup_close_ud: u64 = Namespace.userData(@intFromEnum(InternalOp.close));

        pub fn fdFromId(id: ConnId) error{AdapterHandleExhausted}!Inner.Fd {
            return Namespace.fdFromId(id);
        }

        pub fn idFromFd(fd: Inner.Fd) ?ConnId {
            if (!Namespace.ownsFd(fd)) return null;
            return @intCast(Namespace.fdId(fd));
        }

        pub fn internalUd(op: InternalOp, id: ConnId) u64 {
            return Namespace.userData((@as(u64, id) << 3) | @intFromEnum(op));
        }

        pub fn internalId(ud: u64) ConnId {
            return @intCast(Namespace.userDataPayload(ud) >> 3);
        }

        pub fn internalOp(ud: u64) InternalOp {
            return @enumFromInt(@as(u3, @truncate(Namespace.userDataPayload(ud))));
        }
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
