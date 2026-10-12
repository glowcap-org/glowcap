//! Completion-loop onion adapter (ADR-0108).
//!
//! The adapter has two separate jobs. A dial is an ordinary inner
//! connection to Tor's SOCKS endpoint followed by a byte-level SOCKS5 machine.
//! The outer connect completion is not emitted until the complete reply,
//! including its bound-address tail, has been consumed. Once that point is
//! reached, application sends and receives delegate to the inner backend and
//! retain no onion buffer. A listener first lets the inner backend bind its
//! platform listener, then publishes that exact bound endpoint through one Tor
//! control connection. The control connection stays open for the listener's
//! lifetime, which is Tor's undetached-service lifetime rule.
//!
//! Only setup uses a synchronous wait: it is one bounded control conversation,
//! not a connection worker. Every connection thereafter is driven by the same
//! completion queue as the wrapped backend. Seat refusal, inner close
//! progression, and final removal are the shared leg lifecycle. Owed inner
//! submissions are the shared submission debt.

const std = @import("std");

const completion = @import("../../completion/loop.zig");
const contract = @import("../../completion/contract.zig");
const inner_leg = @import("../../completion/inner_leg.zig");
const submission_debt = @import("../../completion/submission_debt.zig");
const carrier_failure = @import("../../carrier_failure.zig");
const model = @import("model");
const completion_listener = @import("completion/listener.zig");
const leg_access = @import("completion/leg_access.zig");
const completion_state = @import("completion/state.zig");
const socks5 = @import("socks5.zig");

pub const Config = completion_state.Config;
pub const DialResolver = completion_state.DialResolver;

/// Bound refused inner submissions attempted in one poll turn.
const submission_retry_batch: usize = 256;
const submission_retry_ms: i32 = 50;

/// The poll cadence a pending listener setup asks of the loop: its deadline
/// and owed retries are enforced on those turns.
const setup_turn_ms: i32 = 100;

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

        const ConnId = Types.ConnId;
        const InternalOp = Types.InternalOp;
        const Identity = Types.Identity;
        const Conn = Types.Conn;
        const RetryState = submission_debt.State(Types);
        const Listener = completion_listener.Machine(Self, Inner, Types);
        pub const ListenTarget = Listener.Target;
        pub const ListenerAddress = Listener.Address;

        pub const connection_state_bytes = @sizeOf(Conn);

        pub const Leg = inner_leg.Lifecycle(Self, Inner, Types, leg_access.Access(Self, Inner, Types));

        const ConnMap = Types.ConnMap;
        allocator: std.mem.Allocator,
        inner: Inner,
        ready: completion.ReadyQueue,
        conns: ConnMap = .{},
        next_id: ConnId = 1,
        config: ?ConfigType,
        listener: Listener.State = .{},
        control_fd: ?Inner.Fd = null,
        retries: RetryState = .{},

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

        /// A null `config` refuses onion dials and listens.
        pub fn initOnion(allocator: std.mem.Allocator, inner: Inner, config: ?ConfigType) Self {
            return .{ .allocator = allocator, .inner = inner, .ready = .{}, .config = config };
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(self.conns.count() == 0);
            std.debug.assert(self.control_fd == null);
            self.retries.assertEmpty();
            self.inner.deinit();
            self.conns.deinit(self.allocator);
            self.ready.deinit(self.allocator);
        }

        /// Delegate the wrapped Linux TCP backend selection.
        pub fn tcpBackendStatus(self: *const Self) @TypeOf(self.inner.tcpBackendStatus()) {
            return self.inner.tcpBackendStatus();
        }

        pub fn readinessFd(self: *const Self) Fd {
            return self.inner.readinessFd();
        }

        pub fn flush(self: *Self) !void {
            return self.inner.flush();
        }

        pub fn submitPoll(self: *Self, user_data: u64, fd: Fd, interest: completion.Interest) !void {
            return self.inner.submitPoll(user_data, fd, interest);
        }

        /// An owed inner submission retries on `submission_retry_ms`.
        pub fn waitBoundMs(self: *const Self, requested_ms: i32) i32 {
            // A pending listener setup asks for its own turn cadence: the
            // deadline and owed retries are enforced on those turns.
            var bound = self.inner.waitBoundMs(requested_ms);
            // A running setup turns for its deadline and owed retries; a
            // settled row that still owes a seat turns for the delivery.
            if (self.listener.setup != null or self.listener.ready_ud != null) {
                bound = if (bound < 0) setup_turn_ms else @min(bound, setup_turn_ms);
            }
            if (self.retries.submissionRetryCount() == 0) return bound;
            return if (bound < 0) submission_retry_ms else @min(bound, submission_retry_ms);
        }

        /// The loop's one listener is its published service.
        pub fn loopListenTarget(port: u16) ListenTarget {
            return .{ .onion = Inner.loopListenTarget(port) };
        }

        pub fn openListener(self: *Self, target: ListenTarget) !Fd {
            return Listener.open(self, target);
        }

        /// Whether the listener on `fd` is still publishing its service.
        pub fn listenerPending(self: *const Self, fd: Fd) bool {
            return Listener.pending(self, fd);
        }

        /// Complete `user_data` when the listener's service exists or its
        /// setup has failed.
        pub fn submitListenReady(self: *Self, user_data: u64, fd: Fd) !void {
            return Listener.submitReady(self, user_data, fd);
        }

        pub fn listenerAddress(self: *Self, fd: Fd) !ListenerAddress {
            return Listener.address(self, fd);
        }

        pub fn listenerPort(address: ListenerAddress) ?u16 {
            return Listener.port(address);
        }

        pub fn listenerServiceKey(self: *const Self, fd: Fd) ?[]const u8 {
            return Listener.serviceKey(self, fd);
        }

        pub fn submitAccept(self: *Self, user_data: u64, fd: Fd) !void {
            try self.inner.submitAccept(user_data, fd);
        }

        pub fn verifiedChannelKey(self: *Self, fd: Fd) ?[32]u8 {
            if (Identity.idFromFd(fd)) |id| {
                _ = self.conns.get(id) orelse return null;
                return null;
            }
            return self.inner.verifiedChannelKey(fd);
        }

        pub fn applyKeepalive(self: *Self, fd: Fd, keepalive: completion.Keepalive) !void {
            if (self.connection(fd)) |c| return self.inner.applyKeepalive(c.inner_fd, keepalive);
            return self.inner.applyKeepalive(fd, keepalive);
        }

        pub fn wireFraming(self: *Self, fd: Fd) model.transport.WireFraming {
            if (self.connection(fd) != null) return .byte_stream;
            return self.inner.wireFraming(fd);
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
            const id = try Identity.reserveId(&self.next_id, self.conns);
            try self.conns.ensureUnusedCapacity(self.allocator, 1);
            const c = try self.allocator.create(Conn);
            errdefer self.allocator.destroy(c);
            c.* = .{ .id = id, .inner_fd = undefined, .external_connect_ud = user_data };
            errdefer c.deinit(&self.inner);
            _ = socks5.writeConnectRequest(&c.request, &target.service_id) catch return error.InvalidAddress;
            c.inner_fd = try self.inner.startDial(Identity.userData(.connect, id), config.socks);
            c.pending.arm(.connect);
            self.conns.putAssumeCapacity(id, c);
            return Identity.fdFromId(id);
        }

        pub fn submitRecv(self: *Self, user_data: u64, fd: Fd) !void {
            const c = self.connection(fd) orelse return self.inner.submitRecv(user_data, fd);
            if (c.state != .open) return error.ConnectionLost;
            if (c.external_recv_ud != null or c.borrowed) return error.AlreadyReading;
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
            c.external_recv_ud = user_data;
            self.armRecv(c);
        }

        pub fn submitSend(self: *Self, user_data: u64, fd: Fd, bytes: []const u8) !void {
            const c = self.connection(fd) orelse return self.inner.submitSend(user_data, fd, bytes);
            if (c.state != .open) return error.ConnectionLost;
            if (c.external_send_ud != null) return error.AlreadyWriting;
            c.external_send_ud = user_data;
            errdefer c.external_send_ud = null;
            try self.inner.submitSend(Identity.userData(.send, c.id), c.inner_fd, bytes);
            c.pending.arm(.send);
        }

        /// Cancellation is answered here, as the relay leg answers it: the caller's seat is released and the inner receive stays
        /// armed. Bytes it later delivers are retained in `held_recv` for the
        /// next seat, so nothing is asked of the inner backend and nothing is
        /// lost.
        pub fn submitCancel(self: *Self, cancel_user_data: u64, target_user_data: u64, fd: Fd) !void {
            const c = self.connection(fd) orelse return self.inner.submitCancel(cancel_user_data, target_user_data, fd);
            const target_pending = if (c.external_recv_ud) |ud| blk: {
                if (ud != target_user_data) return error.InvalidCancelTarget;
                break :blk true;
            } else false;
            try self.ready.ensureUnusedCapacity(
                self.allocator,
                1 + @as(usize, @intFromBool(target_pending)),
            );
            if (target_pending) {
                c.external_recv_ud = null;
                self.retries.clearRecvRetry(&self.conns, c);
                self.ready.appendAssumeCapacity(.{ .user_data = target_user_data, .result = -1 });
            }
            // With no pending seat, the synchronous receive path already
            // queued the target completion before cancellation was asked.
            self.ready.appendAssumeCapacity(.{ .user_data = cancel_user_data, .result = 0 });
        }

        pub fn shutdownFd(self: *Self, fd: Fd) void {
            if (self.connection(fd)) |c| self.inner.shutdownFd(c.inner_fd) else self.inner.shutdownFd(fd);
        }

        pub fn submitClose(self: *Self, user_data: u64, fd: Fd) !void {
            if (Listener.owns(self, fd)) return Listener.submitClose(self, user_data, fd);
            if (Identity.idFromFd(fd)) |id| {
                const c = self.conns.get(id) orelse {
                    try self.ready.ensureUnusedCapacity(self.allocator, 1);
                    self.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
                    return;
                };
                return Leg.submitCloseRow(self, &self.inner, c, user_data);
            }
            try self.inner.submitClose(user_data, fd);
        }

        pub fn closeFd(self: *Self, fd: Fd) void {
            if (Listener.owns(self, fd)) return Listener.close(self, fd);
            if (Identity.idFromFd(fd)) |id| {
                // A synthetic handle whose row already retired names nothing
                // the inner backend owns; forwarding it would hand the inner
                // backend a negative descriptor.
                const c = self.conns.get(id) orelse return;
                Leg.closeRow(self, &self.inner, c);
                return;
            }
            self.inner.closeFd(fd);
        }

        pub fn recycleBorrowed(self: *Self, comp: completion.Completion) void {
            if (Namespace.ownsBorrowToken(comp.borrowed.token)) {
                const id: ConnId = @intCast(Namespace.borrowTokenPayload(comp.borrowed.token));
                const c = self.conns.get(id) orelse return;
                std.debug.assert(c.borrowed);
                c.borrowed = false;
                self.releaseHeld(c);
                Leg.maybeFinish(self, &self.inner, c);
                return;
            }
            self.inner.recycleBorrowed(comp);
            self.retries.noteRecvRecycle();
        }

        pub fn poll(self: *Self, out: []completion.Completion, timeout_ms: i32) !usize {
            // The listener setup turns on every poll: its deadline and owed
            // submissions are enforced here, never by blocking a caller.
            Listener.pump(self);
            // Pool starvation is an owed inner arm, but polling creates no
            // capacity. Retry only after a wrapped buffer is recycled.
            if (self.retries.takeRecvRecycleProgress()) self.retryRecvStarvation();
            self.retrySubmissions();
            const has_ready = self.ready.len() != 0;
            var tmp: [256]completion.Completion = undefined;
            // One consumed inner completion can fail a pending connect, recv,
            // and send together and publish the close beside them. Reserve
            // that fan-out before asking the inner backend for any record.
            self.ready.ensureUnusedCapacity(self.allocator, tmp.len * 4) catch {
                if (has_ready) return self.ready.drain(out);
                return error.OutOfMemory;
            };
            const effective_timeout: i32 = if (has_ready)
                0
            else if (self.retries.submissionRetryCount() == 0)
                timeout_ms
            else if (timeout_ms < 0)
                submission_retry_ms
            else
                @min(timeout_ms, submission_retry_ms);
            const n = try self.inner.poll(&tmp, effective_timeout);
            for (tmp[0..n]) |comp| {
                if (Identity.owns(comp.user_data)) {
                    self.dispatchInternal(comp) catch |err| {
                        const id = Identity.id(comp.user_data);
                        if (id == 0) return err;
                        if (self.conns.get(id)) |c| self.fail(c);
                    };
                } else self.ready.appendAssumeCapacity(comp);
            }
            return self.ready.drain(out);
        }

        fn dispatchInternal(self: *Self, comp: completion.Completion) !void {
            const id = Identity.id(comp.user_data);
            if (id == 0) {
                // Id-zero records belong to the listener's pending publish
                // conversation, which consumes or drops them itself.
                return Listener.advance(self, comp);
            }
            const c = self.conns.get(id) orelse {
                if (comp.borrowed.active()) self.inner.recycleBorrowed(comp);
                return;
            };
            const op = Identity.op(comp.user_data);
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
                .close => c.inner_close = if (comp.result < 0) .failed else .closed,
            }
            if (self.conns.get(id)) |live| Leg.maybeFinish(self, &self.inner, live);
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
                    if (c.external_send_ud) |ud| {
                        self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = result });
                        c.external_send_ud = null;
                    }
                },
                else => self.fail(c),
            }
        }

        fn onRecv(self: *Self, c: *Conn, comp: completion.Completion) void {
            if (comp.recv_no_buffer) {
                if (c.state != .closing) self.retries.oweRecvStarvation(&self.conns, c);
                return;
            }
            if (comp.result < 0 or comp.borrowed.recvBytes() == null) {
                if (comp.borrowed.active()) self.inner.recycleBorrowed(comp);
                self.fail(c);
                return;
            }
            if (comp.result == 0) {
                if (comp.borrowed.active()) self.inner.recycleBorrowed(comp);
                self.end(c, if (c.state == .open) 0 else -1);
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
                    if (c.external_recv_ud) |ud| {
                        c.external_recv_ud = null;
                        std.debug.assert(c.held_recv == null);
                        c.held_recv = comp;
                        c.held_offset = 0;
                        c.borrowed = true;
                        self.ready.appendAssumeCapacity(.{
                            .user_data = ud,
                            .result = comp.result,
                            .borrowed = .recv(bytes, Namespace.borrowToken(c.id)),
                        });
                    } else {
                        // A canceled caller seat does not cancel the inner
                        // receive. Retain its bytes for the next seat.
                        std.debug.assert(c.held_recv == null);
                        c.held_recv = comp;
                        c.held_offset = 0;
                    }
                },
                .closing => self.inner.recycleBorrowed(comp),
                else => {
                    self.inner.recycleBorrowed(comp);
                    self.fail(c);
                },
            }
        }

        /// Apply one received chunk to the SOCKS reply this leg is waiting
        /// on. The accumulation is the state module's. This owns only what
        /// each verdict costs: the borrowed chunk, the leg's fate, and the
        /// caller's connect seat.
        fn consumeReply(self: *Self, c: *Conn, comp: completion.Completion) void {
            const bytes = comp.borrowed.recvBytes().?;
            switch (c.accumulateReply(bytes)) {
                .refused => {
                    self.inner.recycleBorrowed(comp);
                    self.fail(c);
                },
                .need_more => {
                    self.inner.recycleBorrowed(comp);
                    self.armRecv(c);
                },
                .complete => |consumed| {
                    // Anything past the reply is application data that arrived
                    // coalesced behind it; retain the chunk so the first
                    // receive seat lends it before another read is armed.
                    if (consumed < bytes.len) {
                        c.held_recv = comp;
                        c.held_offset = @intCast(consumed);
                    } else self.inner.recycleBorrowed(comp);
                    c.state = .open;
                    if (c.external_connect_ud) |ud| {
                        self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = 0 });
                        c.external_connect_ud = null;
                    }
                },
            }
        }

        fn submitHandshake(self: *Self, c: *Conn) void {
            const whole: []const u8 = if (c.state == .greeting_send) &socks5.greeting else &c.request;
            const bytes = whole[c.handshake_send_offset..];
            self.inner.submitSend(Identity.userData(.send, c.id), c.inner_fd, bytes) catch {
                self.retries.oweSubmission(&self.conns, c, .send);
                return;
            };
            c.pending.arm(.send);
        }

        fn armRecv(self: *Self, c: *Conn) void {
            if (c.state == .closing or c.pending.get(.recv)) return;
            self.inner.submitRecv(Identity.userData(.recv, c.id), c.inner_fd) catch {
                self.retries.oweSubmission(&self.conns, c, .recv);
                return;
            };
            c.pending.arm(.recv);
        }

        /// Whether an inner receive should be armed for `c` now: the SOCKS
        /// reply states always read, and an open leg reads only into a seat
        /// no retained receive can already satisfy.
        fn needsRecv(c: *const Conn) bool {
            return switch (c.state) {
                .greeting_recv, .reply_recv => true,
                .open => c.external_recv_ud != null and c.held_recv == null,
                .connecting, .greeting_send, .request_send, .closing => false,
            };
        }

        fn fail(self: *Self, c: *Conn) void {
            Leg.fail(self, &self.inner, c);
        }

        fn end(self: *Self, c: *Conn, recv_result: i32) void {
            Leg.end(self, &self.inner, c, recv_result);
        }

        pub fn releaseHeld(self: *Self, c: *Conn) void {
            const held = c.held_recv orelse return;
            std.debug.assert(!c.borrowed);
            c.held_recv = null;
            c.held_offset = 0;
            self.inner.recycleBorrowed(held);
            self.retries.noteRecvRecycle();
        }

        fn retryRecvStarvation(self: *Self) void {
            const attempts = self.retries.recvStarvationCount();
            for (0..attempts) |_| {
                const c = self.retries.popRecvStarvation(&self.conns) orelse unreachable;
                if (needsRecv(c)) self.armRecv(c);
            }
        }

        fn retrySubmissions(self: *Self) void {
            const attempts = @min(self.retries.submissionRetryCount(), submission_retry_batch);
            for (0..attempts) |_| {
                const owed = self.retries.popSubmissionRetry(&self.conns) orelse unreachable;
                const c = owed.conn;
                if (owed.includes(.recv) and needsRecv(c)) self.armRecv(c);
                if (owed.includes(.send) and (c.state == .greeting_send or c.state == .request_send))
                    self.submitHandshake(c);
                if (owed.includes(.close)) Leg.beginInnerClose(self, &self.inner, c);
                if (self.conns.get(c.id)) |live| Leg.maybeFinish(self, &self.inner, live);
            }
        }

        fn connection(self: *Self, fd: Fd) ?*Conn {
            return self.conns.get(Identity.idFromFd(fd) orelse return null);
        }
    };
}

pub const CompletionBackend = InnerBackend;

/// The resident policy that adds `onion` to an inner one.
pub const ResidentPolicy = @import("completion/resident_policy.zig").ResidentPolicy;
