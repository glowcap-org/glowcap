//! Completion-loop onion adapter (ADR-0108).
//!
//! The adapter has two deliberately separate jobs. A dial is an ordinary inner
//! connection to Tor's SOCKS endpoint followed by a byte-level SOCKS5 machine;
//! the outer connect completion is not emitted until the complete reply,
//! including its bound-address tail, has been consumed. Once that point is
//! reached, application sends and receives delegate to the inner backend and
//! retain no onion buffer. A listener first lets the inner backend bind its
//! platform listener, then publishes that exact bound endpoint through one Tor
//! control connection. The control connection stays open for the listener's
//! lifetime, which is Tor's undetached-service lifetime rule.
//!
//! Only setup uses a synchronous wait: it is one bounded control conversation,
//! not a connection worker. Every connection thereafter is driven by the same
//! completion queue as the wrapped backend.

const std = @import("std");

const clock = @import("../../clock.zig");
const completion = @import("../../completion/loop.zig");
const onion_control = @import("control.zig");
const completion_state = @import("completion/state.zig");
const socks5 = @import("socks5.zig");

pub const Config = completion_state.Config;
pub const DialResolver = completion_state.DialResolver;

/// A completion backend that adds Tor SOCKS and onion-service publication to an
/// existing platform backend.
pub fn InnerBackend(comptime Inner: type) type {
    return struct {
        const Self = @This();
        const Namespace = completion.AdapterNamespace(Inner);
        const Types = completion_state.Types(Inner, Namespace);

        pub const Fd = Inner.Fd;
        pub const adapter_depth = Namespace.depth;
        pub const ConfigType = Types.ConfigType;
        pub const Target = Types.Target;
        pub const ConnectTarget = Types.ConnectTarget;
        pub const ListenerAddress = Types.ListenerAddress;

        const ConnId = Types.ConnId;
        const InternalOp = Types.InternalOp;
        const State = Types.State;
        const Conn = Types.Conn;

        pub const connection_state_bytes = @sizeOf(Conn);

        const ConnMap = Types.ConnMap;
        const setup_connect_ud = Types.setup_connect_ud;
        const setup_send_ud = Types.setup_send_ud;
        const setup_recv_ud = Types.setup_recv_ud;
        const setup_close_ud = Types.setup_close_ud;

        allocator: std.mem.Allocator,
        inner: Inner,
        ready: completion.ReadyQueue,
        conns: ConnMap = .{},
        next_id: ConnId = 1,
        config: ?ConfigType,
        listener_fd: ?Fd = null,
        listener_service_id: [socks5.service_id_len]u8 = undefined,
        listener_published: bool = false,
        control_fd: ?Inner.Fd = null,
        retry_head: ?ConnId = null,
        retry_tail: ?ConnId = null,

        pub fn init(
            allocator: std.mem.Allocator,
            queue_entries: u16,
            read_buffers: u16,
            read_buffer_bytes: u32,
        ) !Self {
            return .{
                .allocator = allocator,
                .inner = try Inner.init(allocator, queue_entries, read_buffers, read_buffer_bytes),
                .ready = .{},
                .config = null,
            };
        }

        pub fn initOnion(allocator: std.mem.Allocator, inner: Inner, config: ConfigType) Self {
            return .{ .allocator = allocator, .inner = inner, .ready = .{}, .config = config };
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(self.conns.count() == 0);
            std.debug.assert(self.control_fd == null);
            self.inner.deinit();
            self.conns.deinit(self.allocator);
            self.ready.deinit(self.allocator);
        }

        pub fn openListener(self: *Self, port: u16) !Fd {
            if (self.listener_fd != null) return error.ListenerAlreadyOpen;
            const fd = try self.inner.openListener(port);
            errdefer self.inner.closeFd(fd);
            const inner_address = try self.inner.listenerAddress(fd);
            const bound = Inner.listenerPort(inner_address) orelse return error.ListenerNotForwardable;
            const config = self.config orelse return error.OnionControlNotConfigured;
            const control_target = config.control orelse return error.OnionControlNotConfigured;
            const service = self.publishService(control_target, bound, config) catch |err| return err;
            self.listener_fd = fd;
            self.listener_service_id = service;
            self.listener_published = true;
            return fd;
        }

        pub fn listenerAddress(self: *Self, fd: Fd) !ListenerAddress {
            if (self.listener_fd != fd or !self.listener_published) return error.InvalidListener;
            return self.listener_service_id;
        }

        pub fn listenerPort(_: ListenerAddress) ?u16 {
            return null;
        }

        pub fn submitAccept(self: *Self, user_data: u64, fd: Fd) !void {
            try self.inner.submitAccept(user_data, fd);
        }

        pub fn verifiedChannelKey(self: *Self, fd: Fd) ?[32]u8 {
            if (idFromFd(fd)) |id| {
                _ = self.conns.get(id) orelse return null;
                return null;
            }
            return self.inner.verifiedChannelKey(fd);
        }

        pub fn applyKeepalive(self: *Self, fd: Fd, keepalive: completion.Keepalive) !void {
            if (self.connection(fd)) |c| return self.inner.applyKeepalive(c.inner_fd, keepalive);
            return self.inner.applyKeepalive(fd, keepalive);
        }

        pub fn startDial(self: *Self, user_data: u64, target: ConnectTarget) !Fd {
            return switch (target) {
                .plain => |inner_target| self.inner.startDial(user_data, inner_target),
                .onion => |onion| self.startOnionDial(user_data, onion),
            };
        }

        fn startOnionDial(self: *Self, user_data: u64, target: Target) !Fd {
            const config = self.config orelse return error.OnionNotConfigured;
            try socks5.checkServiceId(&target.service_id);
            const id = try self.reserveId();
            try self.conns.ensureUnusedCapacity(self.allocator, 1);
            const c = try self.allocator.create(Conn);
            errdefer self.allocator.destroy(c);
            c.* = .{ .id = id, .inner_fd = undefined, .external_connect = user_data };
            errdefer c.deinit(self);
            _ = socks5.writeConnectRequest(&c.request, &target.service_id) catch return error.InvalidAddress;
            c.inner_fd = try self.inner.startDial(internalUd(.connect, id), config.socks);
            c.pending.arm(.connect);
            self.conns.putAssumeCapacity(id, c);
            return fdFromId(id);
        }

        fn reserveId(self: *Self) !ConnId {
            var remaining: u64 = Namespace.max_fd_id;
            while (remaining != 0) : (remaining -= 1) {
                const id = self.next_id;
                self.next_id = if (id == Namespace.max_fd_id) 1 else id + 1;
                if (!self.conns.contains(id)) return id;
            }
            return error.TooManyConnections;
        }

        pub fn submitRecv(self: *Self, user_data: u64, fd: Fd) !void {
            const c = self.connection(fd) orelse return self.inner.submitRecv(user_data, fd);
            if (c.state != .open or c.external_recv != null or c.borrowed)
                return error.AlreadyReading;
            if (c.held_recv) |held| {
                try self.ready.ensureUnusedCapacity(self.allocator, 1);
                const bytes = held.borrowed.recvBytes().?[@as(usize, c.held_offset)..];
                c.borrowed = true;
                self.ready.appendAssumeCapacity(.{
                    .user_data = user_data,
                    .result = @intCast(bytes.len),
                    .borrowed = .recv(bytes, Namespace.borrowToken(c.id)),
                });
                return;
            }
            c.external_recv = user_data;
            errdefer c.external_recv = null;
            self.armRecv(c);
        }

        pub fn submitSend(self: *Self, user_data: u64, fd: Fd, bytes: []const u8) !void {
            const c = self.connection(fd) orelse return self.inner.submitSend(user_data, fd, bytes);
            if (c.state != .open or c.external_send != null) return error.AlreadyWriting;
            c.external_send = user_data;
            errdefer c.external_send = null;
            try self.inner.submitSend(internalUd(.send, c.id), c.inner_fd, bytes);
            c.pending.arm(.send);
        }

        pub fn submitCancel(self: *Self, cancel_user_data: u64, target_user_data: u64, fd: Fd) !void {
            const c = self.connection(fd) orelse return self.inner.submitCancel(cancel_user_data, target_user_data, fd);
            if (c.external_recv != target_user_data or c.external_cancel != null)
                return error.InvalidCancelTarget;
            c.external_cancel = cancel_user_data;
            errdefer c.external_cancel = null;
            try self.inner.submitCancel(internalUd(.cancel, c.id), internalUd(.recv, c.id), c.inner_fd);
            c.pending.arm(.cancel);
        }

        pub fn shutdownFd(self: *Self, fd: Fd) void {
            if (self.connection(fd)) |c| self.inner.shutdownFd(c.inner_fd) else self.inner.shutdownFd(fd);
        }

        pub fn submitClose(self: *Self, user_data: u64, fd: Fd) !void {
            if (self.listener_fd == fd) {
                try self.inner.submitClose(user_data, fd);
                if (self.control_fd) |control_fd| {
                    self.inner.closeFd(control_fd);
                    self.control_fd = null;
                }
                self.listener_fd = null;
                return;
            }
            const c = self.connection(fd) orelse return self.inner.submitClose(user_data, fd);
            if (c.external_close != null) return error.AlreadyClosing;
            try self.ready.ensureUnusedCapacity(self.allocator, c.externalSeats() + 1);
            c.external_close = user_data;
            c.state = .closing;
            self.clearDataRetries(c);
            if (c.external_connect) |ud| {
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                c.external_connect = null;
            }
            if (c.external_recv) |ud| {
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                c.external_recv = null;
            }
            if (c.external_send) |ud| {
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                c.external_send = null;
            }
            if (!c.borrowed) self.releaseHeld(c);
            self.beginClose(c);
            if (self.conns.get(c.id)) |live| self.maybeFinishClose(live);
        }

        pub fn closeFd(self: *Self, fd: Fd) void {
            if (self.listener_fd == fd) {
                if (self.control_fd) |control_fd| self.inner.closeFd(control_fd);
                self.control_fd = null;
                self.listener_fd = null;
                self.inner.closeFd(fd);
                return;
            }
            const c = self.connection(fd) orelse {
                self.inner.closeFd(fd);
                return;
            };
            std.debug.assert(c.externalSeats() == 0);
            c.state = .closing;
            c.abandon = true;
            self.clearDataRetries(c);
            if (!c.borrowed) self.releaseHeld(c);
            self.inner.shutdownFd(c.inner_fd);
            if (c.inner_close == .open and c.pending.count() == 0) {
                self.inner.closeFd(c.inner_fd);
                c.inner_close = .closed;
            } else if (c.inner_close == .open) {
                self.beginClose(c);
            }
            self.maybeFinishClose(c);
        }

        pub fn recycleBorrowed(self: *Self, comp: completion.Completion) void {
            if (Namespace.ownsBorrowToken(comp.borrowed.token)) {
                const id: ConnId = @intCast(Namespace.borrowTokenPayload(comp.borrowed.token));
                const c = self.conns.get(id) orelse return;
                std.debug.assert(c.borrowed);
                c.borrowed = false;
                self.releaseHeld(c);
                self.maybeFinishClose(c);
                return;
            }
            self.inner.recycleBorrowed(comp);
        }

        pub fn poll(self: *Self, out: []completion.Completion, timeout_ms: i32) !usize {
            self.retryOwed();
            const ready = self.ready.len() != 0;
            const retries_pending = self.retry_head != null;
            var tmp: [256]completion.Completion = undefined;
            self.ready.ensureUnusedCapacity(self.allocator, tmp.len * 4) catch {
                if (ready) return self.ready.drain(out);
                return error.OutOfMemory;
            };
            const n = try self.inner.poll(&tmp, if (ready or retries_pending) 0 else timeout_ms);
            for (tmp[0..n]) |comp| {
                if (Namespace.ownsUserData(comp.user_data)) {
                    self.dispatchInternal(comp) catch |err| {
                        if (internalId(comp.user_data) != 0) {
                            if (self.conns.get(internalId(comp.user_data))) |c| self.fail(c);
                        } else return err;
                    };
                } else try self.ready.append(self.allocator, comp);
            }
            return self.ready.drain(out);
        }

        fn dispatchInternal(self: *Self, comp: completion.Completion) !void {
            const id = internalId(comp.user_data);
            if (id == 0) {
                if (comp.borrowed.active()) self.inner.recycleBorrowed(comp);
                return error.UnexpectedControlCompletion;
            }
            const c = self.conns.get(id) orelse {
                if (comp.borrowed.active()) self.inner.recycleBorrowed(comp);
                return;
            };
            const op = internalOp(comp.user_data);
            if (op == .close) {
                std.debug.assert(c.inner_close == .in_flight);
            } else c.pending.retire(op);
            switch (op) {
                .connect => {
                    if (c.state == .closing) {} else if (comp.result < 0) self.fail(c) else {
                        c.state = .greeting_send;
                        self.submitHandshake(c);
                    }
                },
                .send => self.onSend(c, comp.result),
                .recv => self.onRecv(c, comp),
                .cancel => {
                    if (c.external_cancel) |ud| {
                        self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = comp.result });
                        c.external_cancel = null;
                    }
                },
                .close => {
                    c.inner_close = if (comp.result < 0) .failed else .closed;
                },
            }
            if (self.conns.get(id)) |live| self.maybeFinishClose(live);
        }

        fn onSend(self: *Self, c: *Conn, result: i32) void {
            if (c.state == .closing) return;
            if (result <= 0) {
                self.fail(c);
                return;
            }
            switch (c.state) {
                .greeting_send => {
                    const remaining = socks5.greeting.len - c.handshake_send_offset;
                    if (result > remaining) return self.fail(c);
                    c.handshake_send_offset += @intCast(result);
                    if (c.handshake_send_offset != socks5.greeting.len) return self.submitHandshake(c);
                    c.handshake_send_offset = 0;
                    c.state = .greeting_recv;
                    self.armRecv(c);
                },
                .request_send => {
                    const remaining = c.request.len - c.handshake_send_offset;
                    if (result > remaining) return self.fail(c);
                    c.handshake_send_offset += @intCast(result);
                    if (c.handshake_send_offset != c.request.len) return self.submitHandshake(c);
                    c.handshake_send_offset = 0;
                    c.state = .reply_recv;
                    c.reply_len = 0;
                    c.reply_expected = socks5.connect_reply_head_len;
                    self.armRecv(c);
                },
                .open => {
                    if (c.external_send) |ud| {
                        self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = result });
                        c.external_send = null;
                    }
                },
                else => self.fail(c),
            }
        }

        fn onRecv(self: *Self, c: *Conn, comp: completion.Completion) void {
            if (comp.recv_no_buffer) {
                if (c.state != .closing) self.owe(c, .recv);
                return;
            }
            if (comp.result <= 0 or comp.borrowed.recvBytes() == null) {
                if (comp.borrowed.active()) self.inner.recycleBorrowed(comp);
                if (comp.result < 0 and c.state == .open and c.external_cancel != null) {
                    if (c.external_recv) |ud| {
                        self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = comp.result });
                        c.external_recv = null;
                    }
                    return;
                }
                if (c.state == .open) {
                    if (c.external_recv) |ud| {
                        self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = comp.result });
                        c.external_recv = null;
                    }
                }
                self.fail(c);
                return;
            }
            const bytes = comp.borrowed.recvBytes().?;
            if (@as(usize, @intCast(comp.result)) != bytes.len) {
                self.inner.recycleBorrowed(comp);
                self.fail(c);
                return;
            }
            switch (c.state) {
                .greeting_recv => {
                    const need = socks5.greeting_reply_len - c.greeting_reply_len;
                    const take = @min(need, bytes.len);
                    @memcpy(c.greeting_reply[c.greeting_reply_len..][0..take], bytes[0..take]);
                    c.greeting_reply_len += @intCast(take);
                    if (take != bytes.len) {
                        self.inner.recycleBorrowed(comp);
                        self.fail(c);
                        return;
                    }
                    self.inner.recycleBorrowed(comp);
                    if (c.greeting_reply_len != socks5.greeting_reply_len) {
                        self.armRecv(c);
                        return;
                    }
                    socks5.checkGreetingReply(&c.greeting_reply) catch {
                        self.fail(c);
                        return;
                    };
                    c.state = .request_send;
                    self.submitHandshake(c);
                },
                .reply_recv => self.consumeReply(c, comp),
                .open => {
                    if (c.external_recv) |ud| {
                        c.external_recv = null;
                        std.debug.assert(c.held_recv == null);
                        c.held_recv = comp;
                        c.held_offset = 0;
                        c.borrowed = true;
                        self.ready.appendAssumeCapacity(.{
                            .user_data = ud,
                            .result = comp.result,
                            .borrowed = .recv(bytes, Namespace.borrowToken(c.id)),
                        });
                    } else self.inner.recycleBorrowed(comp);
                },
                .closing => self.inner.recycleBorrowed(comp),
                else => {
                    self.inner.recycleBorrowed(comp);
                    self.fail(c);
                },
            }
        }

        fn consumeReply(self: *Self, c: *Conn, comp: completion.Completion) void {
            const bytes = comp.borrowed.recvBytes().?;
            var offset: usize = 0;
            while (offset < bytes.len and c.reply_len < c.reply_expected) {
                if (c.reply_len < c.reply_prefix.len)
                    c.reply_prefix[c.reply_len] = bytes[offset];
                c.reply_len += 1;
                offset += 1;
                if (c.reply_len == socks5.connect_reply_head_len) {
                    const head: *const [socks5.connect_reply_head_len]u8 = c.reply_prefix[0..4];
                    const bound = socks5.boundAddress(head) catch {
                        self.inner.recycleBorrowed(comp);
                        self.fail(c);
                        return;
                    };
                    c.reply_expected = @intCast(switch (bound) {
                        .fixed => |n| 4 + n,
                        .domain => 5,
                    });
                } else if (c.reply_len == 5 and c.reply_prefix[3] == 0x03) {
                    if (c.reply_prefix[4] == 0) {
                        self.inner.recycleBorrowed(comp);
                        self.fail(c);
                        return;
                    }
                    c.reply_expected = 4 + 1 + @as(u16, c.reply_prefix[4]) + 2;
                }
            }
            if (c.reply_len < c.reply_expected) {
                self.inner.recycleBorrowed(comp);
                self.armRecv(c);
                return;
            }
            var head: [socks5.connect_reply_head_len]u8 = undefined;
            @memcpy(&head, c.reply_prefix[0..4]);
            socks5.checkConnectReply(&head) catch {
                self.inner.recycleBorrowed(comp);
                self.fail(c);
                return;
            };
            if (offset < bytes.len) {
                c.held_recv = comp;
                c.held_offset = @intCast(offset);
            } else self.inner.recycleBorrowed(comp);
            c.state = .open;
            if (c.external_connect) |ud| {
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = 0 });
                c.external_connect = null;
            }
        }

        fn submitHandshake(self: *Self, c: *Conn) void {
            const whole: []const u8 = if (c.state == .greeting_send) &socks5.greeting else &c.request;
            const bytes = whole[c.handshake_send_offset..];
            self.inner.submitSend(internalUd(.send, c.id), c.inner_fd, bytes) catch {
                self.owe(c, .send);
                return;
            };
            c.pending.arm(.send);
        }

        fn armRecv(self: *Self, c: *Conn) void {
            if (c.state == .closing or c.pending.recv) return;
            self.inner.submitRecv(internalUd(.recv, c.id), c.inner_fd) catch {
                self.owe(c, .recv);
                return;
            };
            c.pending.arm(.recv);
        }

        fn beginClose(self: *Self, c: *Conn) void {
            if (c.inner_close != .open or c.close_retry) return;
            self.inner.submitClose(internalUd(.close, c.id), c.inner_fd) catch {
                self.inner.shutdownFd(c.inner_fd);
                self.owe(c, .close);
                return;
            };
            c.inner_close = .in_flight;
        }

        fn fail(self: *Self, c: *Conn) void {
            if (c.state == .closing) return;
            c.state = .closing;
            self.clearDataRetries(c);
            if (!c.borrowed) self.releaseHeld(c);
            if (c.external_connect) |ud| {
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                c.external_connect = null;
            }
            if (c.external_recv) |ud| {
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                c.external_recv = null;
            }
            if (c.external_send) |ud| {
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                c.external_send = null;
            }
            self.inner.shutdownFd(c.inner_fd);
        }

        fn releaseHeld(self: *Self, c: *Conn) void {
            const held = c.held_recv orelse return;
            std.debug.assert(!c.borrowed);
            c.held_recv = null;
            c.held_offset = 0;
            self.inner.recycleBorrowed(held);
        }

        fn clearDataRetries(self: *Self, c: *Conn) void {
            _ = self;
            c.recv_retry = false;
            c.send_retry = false;
        }

        fn owe(self: *Self, c: *Conn, op: InternalOp) void {
            if (op == .close and c.close_retry) return;
            if (op == .recv and c.recv_retry) return;
            if (op == .send and c.send_retry) return;
            if (op == .close) c.close_retry = true else if (op == .recv) c.recv_retry = true else if (op == .send) c.send_retry = true;
            if (c.retry_queued) return;
            c.retry_queued = true;
            if (self.retry_tail) |tail_id| {
                const tail = self.conns.get(tail_id) orelse unreachable;
                std.debug.assert(tail.retry_next == null);
                tail.retry_next = c.id;
            } else {
                self.retry_head = c.id;
            }
            self.retry_tail = c.id;
        }

        fn retryOwed(self: *Self) void {
            var id = self.retry_head;
            self.retry_head = null;
            self.retry_tail = null;
            while (id) |current_id| {
                const c = self.conns.get(current_id) orelse unreachable;
                id = c.retry_next;
                c.retry_next = null;
                c.retry_queued = false;
                if (c.recv_retry and c.state != .closing) {
                    c.recv_retry = false;
                    self.armRecv(c);
                }
                if (c.send_retry and c.state != .closing) {
                    c.send_retry = false;
                    if (c.state == .greeting_send or c.state == .request_send) self.submitHandshake(c);
                }
                if (c.close_retry) {
                    c.close_retry = false;
                    self.beginClose(c);
                }
                if (self.conns.get(current_id)) |live| self.maybeFinishClose(live);
            }
        }

        fn maybeFinishClose(self: *Self, c: *Conn) void {
            if (c.state != .closing) return;
            if (c.retry_queued) return;
            if (c.inner_close == .open or c.inner_close == .in_flight or c.close_retry) return;
            if (c.pending.count() != 0 or c.borrowed) return;
            if (c.inner_close == .failed) {
                self.inner.closeFd(c.inner_fd);
                c.inner_close = .closed;
            }
            if (c.external_close) |ud| {
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = 0 });
                c.external_close = null;
                self.destroyConn(c.id);
            } else if (c.abandon) {
                self.destroyConn(c.id);
            }
        }

        fn destroyConn(self: *Self, id: ConnId) void {
            const kv = self.conns.fetchRemove(id) orelse unreachable;
            const c = kv.value;
            std.debug.assert(!c.retry_queued);
            self.clearDataRetries(c);
            c.close_retry = false;
            c.deinit(self);
            self.allocator.destroy(c);
        }

        fn connection(self: *Self, fd: Fd) ?*Conn {
            return self.conns.get(idFromFd(fd) orelse return null);
        }

        const fdFromId = Types.fdFromId;
        const idFromFd = Types.idFromFd;
        const internalUd = Types.internalUd;
        const internalId = Types.internalId;
        const internalOp = Types.internalOp;

        // The publication conversation is deliberately synchronous and bounded:
        // it runs before the listener is returned, so Loop cannot arm accept on
        // an unpublished service. The control fd itself remains open afterward.
        fn publishService(
            self: *Self,
            target: Inner.ConnectTarget,
            port: u16,
            config: ConfigType,
        ) ![socks5.service_id_len]u8 {
            const fd = try self.inner.startDial(setup_connect_ud, target);
            self.control_fd = fd;
            errdefer {
                if (self.control_fd != null) {
                    self.inner.closeFd(fd);
                    self.control_fd = null;
                }
            }
            const deadline_ms = clock.nowMonotonicMs() + config.setup_timeout_ms;
            const comp = try self.waitSetup(fd, setup_connect_ud, deadline_ms);
            if (comp.result < 0) return error.ControlConnectionLost;

            var reader: SetupReader = .{ .backend = self, .fd = fd, .deadline_ms = deadline_ms };
            defer reader.deinit();
            var request: [onion_control.max_line_bytes]u8 = undefined;
            const auth = try onion_control.writeAuthenticate(&request, config.auth);
            try self.setupSend(fd, auth, deadline_ms);
            try self.setupOk(&reader);

            var forward_buf: [32]u8 = undefined;
            const forward = try std.fmt.bufPrint(&forward_buf, "127.0.0.1:{d}", .{port});
            const add = if (config.service_key.len == 0)
                try onion_control.writeAddOnionNew(&request, .{ .address = forward })
            else
                try onion_control.writeAddOnionRestore(&request, config.service_key, .{ .address = forward });
            try self.setupSend(fd, add, deadline_ms);

            var service_id: [socks5.service_id_len]u8 = undefined;
            var have_id = false;
            var lines: usize = 0;
            while (true) {
                lines += 1;
                if (lines > 64) return error.ControlReplyTooLong;
                const line = try reader.nextLine();
                const reply = onion_control.parseLine(line) catch return error.ControlProtocolViolation;
                if (!reply.isOk()) return error.ControlRefused;
                if (reply.field()) |field| if (std.mem.eql(u8, field.key, "ServiceID")) {
                    if (field.value.len != socks5.service_id_len) return error.ControlProtocolViolation;
                    socks5.checkServiceId(field.value) catch return error.ControlProtocolViolation;
                    @memcpy(&service_id, field.value);
                    have_id = true;
                };
                if (reply.continuation == .end) break;
            }
            if (!have_id) return error.ControlProtocolViolation;
            return service_id;
        }

        fn waitSetup(self: *Self, fd: Inner.Fd, wanted: u64, deadline_ms: i64) !completion.Completion {
            var out: [8]completion.Completion = undefined;
            while (true) {
                const remaining = deadline_ms - clock.nowMonotonicMs();
                if (remaining <= 0) {
                    try self.abortSetup(fd, wanted);
                    return error.ControlSetupTimedOut;
                }
                const timeout_ms: i32 = @intCast(@min(remaining, std.math.maxInt(i32)));
                const n = try self.inner.poll(&out, timeout_ms);
                try self.ready.ensureUnusedCapacity(self.allocator, n * 4);
                var found: ?completion.Completion = null;
                for (out[0..n]) |comp| {
                    if (comp.user_data == wanted and found == null) {
                        found = comp;
                    } else if (Namespace.ownsUserData(comp.user_data) and internalId(comp.user_data) != 0) {
                        try self.dispatchInternal(comp);
                    } else if (!Namespace.ownsUserData(comp.user_data)) {
                        self.ready.appendAssumeCapacity(comp);
                    } else {
                        if (comp.borrowed.active()) self.inner.recycleBorrowed(comp);
                        return error.UnexpectedControlCompletion;
                    }
                }
                if (found) |comp| return comp;
            }
        }

        /// A timed-out setup operation still owns an inner completion seat.
        /// Close the control handle and drain both records before returning to
        /// normal polling, where an id-zero setup completion would be invalid.
        fn abortSetup(self: *Self, fd: Inner.Fd, wanted: u64) !void {
            self.inner.shutdownFd(fd);
            var close_submitted = false;
            var wanted_done = false;
            var close_done = false;
            var close_failed = false;
            var out: [8]completion.Completion = undefined;

            while (!wanted_done or (close_submitted and !close_done)) {
                if (!close_submitted) {
                    self.inner.submitClose(setup_close_ud, fd) catch {
                        const n = try self.inner.poll(&out, 1);
                        try self.harvestSetupAbort(out[0..n], wanted, &wanted_done, &close_done, &close_failed);
                        if (wanted_done) break;
                        continue;
                    };
                    close_submitted = true;
                }
                const n = try self.inner.poll(&out, -1);
                try self.harvestSetupAbort(out[0..n], wanted, &wanted_done, &close_done, &close_failed);
            }

            if (!close_submitted or close_failed) self.inner.closeFd(fd);
            self.control_fd = null;
        }

        fn harvestSetupAbort(
            self: *Self,
            completions: []const completion.Completion,
            wanted: u64,
            wanted_done: *bool,
            close_done: *bool,
            close_failed: *bool,
        ) !void {
            try self.ready.ensureUnusedCapacity(self.allocator, completions.len * 4);
            for (completions) |comp| {
                if (comp.user_data == wanted and !wanted_done.*) {
                    wanted_done.* = true;
                    if (comp.borrowed.active()) self.inner.recycleBorrowed(comp);
                } else if (comp.user_data == setup_close_ud and !close_done.*) {
                    close_done.* = true;
                    close_failed.* = comp.result < 0;
                    if (comp.borrowed.active()) self.inner.recycleBorrowed(comp);
                } else if (Namespace.ownsUserData(comp.user_data) and internalId(comp.user_data) != 0) {
                    try self.dispatchInternal(comp);
                } else if (!Namespace.ownsUserData(comp.user_data)) {
                    self.ready.appendAssumeCapacity(comp);
                } else {
                    if (comp.borrowed.active()) self.inner.recycleBorrowed(comp);
                    return error.UnexpectedControlCompletion;
                }
            }
        }

        fn setupSend(self: *Self, fd: Inner.Fd, bytes: []const u8, deadline_ms: i64) !void {
            var offset: usize = 0;
            while (offset < bytes.len) {
                try self.inner.submitSend(setup_send_ud, fd, bytes[offset..]);
                const comp = try self.waitSetup(fd, setup_send_ud, deadline_ms);
                if (comp.result <= 0) return error.ControlConnectionLost;
                const sent: usize = @intCast(comp.result);
                if (sent > bytes.len - offset) return error.ControlProtocolViolation;
                offset += sent;
            }
        }

        fn setupOk(_: *Self, reader: *SetupReader) !void {
            var lines: usize = 0;
            while (true) {
                lines += 1;
                if (lines > 64) return error.ControlReplyTooLong;
                const line = try reader.nextLine();
                const reply = onion_control.parseLine(line) catch return error.ControlProtocolViolation;
                if (!reply.isOk()) return error.ControlRefused;
                if (reply.continuation == .end) return;
            }
        }

        const SetupReader = struct {
            backend: *Self,
            fd: Inner.Fd,
            deadline_ms: i64,
            held: ?completion.Completion = null,
            offset: usize = 0,
            line: [onion_control.max_line_bytes]u8 = undefined,
            line_len: usize = 0,

            fn deinit(self: *@This()) void {
                self.releaseHeld();
            }

            fn nextLine(self: *@This()) ![]const u8 {
                while (true) {
                    if (self.held) |held| {
                        const bytes = held.borrowed.recvBytes().?;
                        const available = bytes[self.offset..];
                        if (std.mem.indexOfScalar(u8, available, '\n')) |newline| {
                            const fragment = available[0..newline];
                            self.offset += newline + 1;
                            if (self.line_len == 0) {
                                return onion_control.trimLineEnding(fragment);
                            }
                            try self.append(fragment);
                            const line_len = self.line_len;
                            self.line_len = 0;
                            if (self.offset == bytes.len) self.releaseHeld();
                            return onion_control.trimLineEnding(self.line[0..line_len]);
                        }
                        try self.append(available);
                        self.releaseHeld();
                        continue;
                    }

                    try self.backend.inner.submitRecv(setup_recv_ud, self.fd);
                    const comp = try self.backend.waitSetup(self.fd, setup_recv_ud, self.deadline_ms);
                    if (comp.result <= 0 or comp.borrowed.recvBytes() == null) {
                        if (comp.borrowed.active()) self.backend.inner.recycleBorrowed(comp);
                        return error.ControlConnectionLost;
                    }
                    const bytes = comp.borrowed.recvBytes().?;
                    if (@as(usize, @intCast(comp.result)) != bytes.len) {
                        self.backend.inner.recycleBorrowed(comp);
                        return error.ControlProtocolViolation;
                    }
                    self.held = comp;
                    self.offset = 0;
                }
            }

            fn append(self: *@This(), bytes: []const u8) !void {
                if (bytes.len > self.line.len - self.line_len) return error.ControlReplyTooLong;
                @memcpy(self.line[self.line_len..][0..bytes.len], bytes);
                self.line_len += bytes.len;
            }

            fn releaseHeld(self: *@This()) void {
                const held = self.held orelse return;
                self.held = null;
                self.offset = 0;
                self.backend.inner.recycleBorrowed(held);
            }
        };
    };
}

pub const CompletionBackend = InnerBackend;
