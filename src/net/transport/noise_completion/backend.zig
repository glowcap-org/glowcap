//! Completion contract adapter for sealed and plain targets.
//!
//! This owner keeps the wrapped backend and routes each public operation once.
//! The embedded reactor owns all sealed mutable state and terminal projection;
//! plain operations go directly to `Inner`.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const completion = @import("../../completion/loop.zig");
const reactor_module = @import("reactor.zig");

const crypto = foundation.crypto;

pub fn Backend(comptime Inner: type) type {
    return struct {
        const Self = @This();
        const Reactor = reactor_module.Reactor(Inner);

        pub const Fd = Inner.Fd;
        pub const adapter_depth = Reactor.adapter_depth;
        pub const ListenerAddress = Inner.ListenerAddress;
        pub const SealedTarget = Reactor.SealedTarget;
        pub const ConnectTarget = union(enum) {
            plain: Inner.ConnectTarget,
            sealed: SealedTarget,
        };

        /// Heap-resident state paid by one sealed leg, excluding buffer
        /// capacity and hash-table bucket overhead.
        pub const connection_state_bytes = Reactor.connection_state_bytes;

        inner: Inner,
        reactor: Reactor,

        /// Construct a pass-through adapter. Sealed dials fail before opening
        /// an inner transport because this instance has no sealing identity.
        pub fn init(
            allocator: std.mem.Allocator,
            queue_entries: u16,
            read_buffers: u16,
            read_buffer_bytes: u32,
        ) !Self {
            const inner = try Inner.init(allocator, queue_entries, read_buffers, read_buffer_bytes);
            return .{
                .inner = inner,
                .reactor = Reactor.init(allocator, null),
            };
        }

        /// Wrap `inner` with the durable identity and entropy source used by
        /// initiator Noise_XK handshakes.
        pub fn initSealing(
            allocator: std.mem.Allocator,
            inner: Inner,
            identity: *const crypto.SecretKey,
            seed: [std.Random.DefaultCsprng.secret_seed_length]u8,
        ) Self {
            return .{
                .inner = inner,
                .reactor = Reactor.init(allocator, .{
                    .identity = identity.*,
                    .rng = std.Random.DefaultCsprng.init(seed),
                }),
            };
        }

        /// Release an already-drained adapter. The owning Loop must have
        /// closed every synthetic handle first.
        pub fn deinit(self: *Self) void {
            self.reactor.deinit();
            self.inner.deinit();
        }

        pub fn openListener(self: *Self, port: u16) !Fd {
            return self.inner.openListener(port);
        }

        pub fn listenerAddress(self: *Self, fd: Fd) !ListenerAddress {
            return self.inner.listenerAddress(fd);
        }

        pub fn listenerPort(address: ListenerAddress) ?u16 {
            return Inner.listenerPort(address);
        }

        pub fn submitAccept(self: *Self, user_data: u64, listen_fd: Fd) !void {
            try self.inner.submitAccept(user_data, listen_fd);
        }

        pub fn verifiedChannelKey(self: *Self, fd: Fd) ?[crypto.PEER_KEY_BYTES]u8 {
            if (self.reactor.idFromFd(fd)) |id|
                return self.reactor.verifiedChannelKey(id);
            return self.inner.verifiedChannelKey(fd);
        }

        pub fn applyKeepalive(self: *Self, fd: Fd, keepalive: completion.Keepalive) !void {
            if (self.reactor.idFromFd(fd)) |id|
                return self.reactor.applyKeepalive(&self.inner, id, keepalive);
            return self.inner.applyKeepalive(fd, keepalive);
        }

        pub fn wireFraming(self: *Self, fd: Fd) model.transport.WireFraming {
            if (self.reactor.idFromFd(fd) != null) return .byte_stream;
            return self.inner.wireFraming(fd);
        }

        pub fn startDial(self: *Self, user_data: u64, target: ConnectTarget) !Fd {
            return switch (target) {
                .plain => |inner_target| self.inner.startDial(user_data, inner_target),
                .sealed => |sealed_target| self.reactor.startDial(
                    &self.inner,
                    user_data,
                    sealed_target,
                ),
            };
        }

        pub fn submitRecv(self: *Self, user_data: u64, fd: Fd) !void {
            if (self.reactor.idFromFd(fd)) |id|
                return self.reactor.submitRecv(&self.inner, id, user_data);
            return self.inner.submitRecv(user_data, fd);
        }

        pub fn submitSend(self: *Self, user_data: u64, fd: Fd, bytes: []const u8) !void {
            if (self.reactor.idFromFd(fd)) |id|
                return self.reactor.submitSend(&self.inner, id, user_data, bytes);
            return self.inner.submitSend(user_data, fd, bytes);
        }

        pub fn submitCancel(
            self: *Self,
            cancel_user_data: u64,
            target_user_data: u64,
            fd: Fd,
        ) !void {
            if (self.reactor.idFromFd(fd)) |id|
                return self.reactor.submitCancel(id, cancel_user_data, target_user_data);
            return self.inner.submitCancel(cancel_user_data, target_user_data, fd);
        }

        pub fn shutdownFd(self: *Self, fd: Fd) void {
            if (self.reactor.idFromFd(fd)) |id| {
                self.reactor.shutdownFd(&self.inner, id);
                return;
            }
            self.inner.shutdownFd(fd);
        }

        pub fn submitClose(self: *Self, user_data: u64, fd: Fd) !void {
            if (self.reactor.idFromFd(fd)) |id|
                return self.reactor.submitClose(&self.inner, id, user_data);
            return self.inner.submitClose(user_data, fd);
        }

        pub fn closeFd(self: *Self, fd: Fd) void {
            if (self.reactor.idFromFd(fd)) |id| {
                self.reactor.closeFd(&self.inner, id);
                return;
            }
            self.inner.closeFd(fd);
        }

        pub fn recycleBorrowed(self: *Self, comp: completion.Completion) void {
            if (self.reactor.recycleBorrowed(&self.inner, comp)) return;
            self.inner.recycleBorrowed(comp);
            self.reactor.noteInnerRecycle();
        }

        pub fn poll(self: *Self, out: []completion.Completion, timeout_ms: i32) !usize {
            return self.reactor.poll(&self.inner, out, timeout_ms);
        }
    };
}
