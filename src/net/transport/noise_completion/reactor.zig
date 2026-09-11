//! Sole mutable lifecycle owner for completion-backed Noise connections.
//!
//! The reactor is embedded in the completion adapter. It owns the connection
//! table, synthetic handle namespace, sealing identity, retry queues, ready
//! projection, and every sealed transition. `Inner` is borrowed per operation;
//! there is no reverse dependency on the public adapter and no second box.
//! Seat refusal, inner close progression, and final removal are the shared
//! leg lifecycle; this file supplies only what sealing adds to them.

const std = @import("std");

const foundation = @import("foundation");
const completion = @import("../../completion/loop.zig");
const contract = @import("../../completion/contract.zig");
const inner_leg = @import("../../completion/inner_leg.zig");
const submission_debt = @import("../../completion/submission_debt.zig");
const carrier_failure = @import("../../carrier_failure.zig");
const authority = @import("authority.zig");
const connection = @import("connection.zig");

const crypto = foundation.crypto;
const sealed = foundation.sealed;
/// Bound refused inner submissions attempted in one poll turn.
const submission_retry_batch: usize = 256;
const submission_retry_ms: i32 = 50;

pub fn Reactor(comptime Inner: type) type {
    return struct {
        const Self = @This();
        const Namespace = completion.AdapterNamespace(Inner);
        const Types = connection.Types(Inner, Namespace);
        const ConnId = Types.ConnId;
        const InternalOp = Types.InternalOp;
        const Identity = Types.Identity;
        const NoiseConn = Types.NoiseConn;
        const RetryState = submission_debt.State(Types);

        pub const Fd = Inner.Fd;
        pub const adapter_depth = Namespace.depth;
        pub const connection_state_bytes = @sizeOf(NoiseConn);
        pub const SealedTarget = struct {
            inner: Inner.ConnectTarget,
            remote: crypto.PeerKey,
            transport: []const u8,
        };

        pub const Sealing = authority.Authority;

        /// What sealing adds to the shared leg lifecycle: the channel is
        /// failed and the inner receive loan returned as the row enters
        /// `closing`, a refused send carries no borrowed failure, and every
        /// retry membership lives in the submission-debt state.
        const LegAccess = struct {
            pub fn closeUserData(id: ConnId) u64 {
                return Identity.userData(.close, id);
            }

            pub fn onClosing(self: *Self, inner: *Inner, c: *NoiseConn, how: inner_leg.Closing) void {
                self.retries.clearDataRetries(&self.conns, c);
                if (how == .ended) c.channel.fail();
                self.releaseInnerRecv(inner, c);
            }

            pub fn prepareClose(_: *Self, _: *Inner, _: *NoiseConn) !void {}

            pub fn closeRefused(_: *Self, _: *Inner, _: *NoiseConn) void {}

            pub fn refuseExternalSend(
                self: *Self,
                c: *NoiseConn,
                cause: ?anyerror,
                _: carrier_failure.Phase,
            ) void {
                const ud = c.external_send_ud orelse return;
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1, .failure = cause });
                c.external_send_ud = null;
                c.external_send_len = 0;
                c.external_send_bytes = &.{};
                c.external_send_off = 0;
            }

            pub fn startClose(self: *Self, inner: *Inner, c: *NoiseConn) void {
                Leg.beginInnerClose(self, inner, c);
            }

            pub fn owesClose(self: *Self, c: *NoiseConn) bool {
                return self.retries.owesSubmission(c, .close);
            }

            pub fn oweClose(self: *Self, c: *NoiseConn) void {
                self.retries.oweSubmission(&self.conns, c, .close);
            }

            pub fn clearOwedClose(self: *Self, c: *NoiseConn) void {
                self.retries.clearOwedRetries(&self.conns, c);
            }

            pub fn lendActive(c: *const NoiseConn) bool {
                return c.lend_active;
            }

            pub fn borrowFailure(_: *Self, _: *NoiseConn) contract.Borrowed {
                return .{};
            }

            pub fn prepareFinish(_: *Self, _: *NoiseConn, _: bool) bool {
                return false;
            }

            pub fn closeCause(_: *const NoiseConn) ?anyerror {
                return null;
            }

            pub fn hasBorrowedFailure(_: *const Self, _: *const NoiseConn) bool {
                return false;
            }

            pub fn retireRow(self: *Self, c: *NoiseConn) void {
                self.retries.clearOwedRetries(&self.conns, c);
            }

            pub fn deinitRow(self: *Self, _: *Inner, c: *NoiseConn) void {
                c.deinit(self.allocator);
            }
        };
        const Leg = inner_leg.Lifecycle(Self, Inner, Types, LegAccess);

        allocator: std.mem.Allocator,
        ready: completion.ReadyQueue = .{},
        conns: Types.ConnMap = .{},
        next_id: ConnId = 1,
        retries: RetryState = .{},
        sealing: ?Sealing,

        pub fn init(allocator: std.mem.Allocator, sealing: ?Sealing) Self {
            return .{ .allocator = allocator, .sealing = sealing };
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(self.conns.count() == 0);
            self.retries.assertEmpty();
            if (self.sealing) |*sealing| sealing.deinit();
            self.sealing = null;
            self.conns.deinit(self.allocator);
            self.ready.deinit(self.allocator);
        }

        pub fn verifiedChannelKey(self: *Self, id: ConnId) ?[crypto.PEER_KEY_BYTES]u8 {
            const c = self.conns.get(id) orelse return null;
            return c.proven;
        }

        pub fn applyKeepalive(
            self: *Self,
            inner: *Inner,
            id: ConnId,
            keepalive: completion.Keepalive,
        ) !void {
            const c = self.conns.get(id) orelse return error.FileDescriptorNotASocket;
            return inner.applyKeepalive(c.inner_fd, keepalive);
        }

        pub fn startDial(
            self: *Self,
            inner: *Inner,
            user_data: u64,
            target: SealedTarget,
        ) !Fd {
            const sealing = if (self.sealing) |*s| s else return error.NoSealingIdentity;
            const id = try Identity.reserveId(&self.next_id, self.conns);
            errdefer self.next_id = id;
            try self.conns.ensureUnusedCapacity(self.allocator, 1);
            var ephemeral_seed: [crypto.SEED_BYTES]u8 = undefined;
            defer std.crypto.secureZero(u8, &ephemeral_seed);
            sealing.rng.random().bytes(&ephemeral_seed);
            const c = try self.allocator.create(NoiseConn);
            errdefer self.allocator.destroy(c);
            c.* = .{
                .id = id,
                .inner_fd = undefined,
                .external_connect_ud = user_data,
                .channel = sealed.SealedChannel.initInitiator(
                    &sealing.identity,
                    target.remote,
                    ephemeral_seed,
                    target.transport,
                ) catch return error.InvalidAddress,
            };
            errdefer c.deinit(self.allocator);
            c.inner_fd = try inner.startDial(internalUd(.connect, id), target.inner);
            errdefer inner.closeFd(c.inner_fd);
            c.pending.arm(.connect);
            self.conns.putAssumeCapacity(id, c);
            return Identity.fdFromId(id);
        }

        pub fn submitRecv(self: *Self, inner: *Inner, id: ConnId, user_data: u64) !void {
            const c = self.conns.get(id) orelse return error.ConnectionLost;
            if (c.state != .open) return error.ConnectionLost;
            if (c.external_recv_ud != null or c.lend_active) return error.AlreadyReading;
            // A staged channel fault can complete every external seat. Reserve
            // their projection before installing the caller's seat.
            try self.ready.ensureUnusedCapacity(self.allocator, Leg.externalSeatCount(c) + 1);
            c.external_recv_ud = user_data;
            errdefer c.external_recv_ud = null;
            try self.emitOrArm(inner, c);
        }

        pub fn submitSend(
            self: *Self,
            inner: *Inner,
            id: ConnId,
            user_data: u64,
            bytes: []const u8,
        ) !void {
            const c = self.conns.get(id) orelse return error.ConnectionLost;
            if (c.state != .open) return error.ConnectionLost;
            if (c.external_send_ud != null) return error.AlreadyWriting;
            const send_len = std.math.cast(i32, bytes.len) orelse return error.WriteTooLarge;
            if (bytes.len == 0) {
                try self.ready.ensureUnusedCapacity(self.allocator, 1);
                self.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
                return;
            }
            // Seal one bounded record before claiming the borrowed caller
            // bytes. Later records are sealed only after the front drains.
            const first_len = @min(bytes.len, foundation.noise.MAX_RECORD_PLAINTEXT_BYTES);
            try c.channel.sealBytes(self.allocator, &c.ct_back, bytes[0..first_len]);
            c.external_send_ud = user_data;
            c.external_send_len = send_len;
            c.external_send_bytes = bytes;
            c.external_send_off = first_len;
            self.driveInnerSend(inner, c) catch self.retries.oweSubmission(&self.conns, c, .send);
        }

        pub fn submitCancel(
            self: *Self,
            id: ConnId,
            cancel_user_data: u64,
            target_user_data: u64,
        ) !void {
            const c = self.conns.get(id) orelse return error.ConnectionLost;
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
            self.ready.appendAssumeCapacity(.{ .user_data = cancel_user_data, .result = 0 });
        }

        pub fn shutdownFd(self: *Self, inner: *Inner, id: ConnId) void {
            const c = self.conns.get(id) orelse return;
            inner.shutdownFd(c.inner_fd);
        }

        pub fn submitClose(self: *Self, inner: *Inner, id: ConnId, user_data: u64) !void {
            const c = self.conns.get(id) orelse {
                try self.ready.ensureUnusedCapacity(self.allocator, 1);
                self.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
                return;
            };
            try Leg.submitCloseRow(self, inner, c, user_data);
        }

        pub fn closeFd(self: *Self, inner: *Inner, id: ConnId) void {
            const c = self.conns.get(id) orelse return;
            Leg.closeRow(self, inner, c);
        }

        pub fn recycleBorrowed(
            self: *Self,
            inner: *Inner,
            comp: completion.Completion,
        ) bool {
            if (!Namespace.ownsBorrowToken(comp.borrowed.token)) return false;
            const id: ConnId = @intCast(Namespace.borrowTokenPayload(comp.borrowed.token));
            if (self.conns.get(id)) |c| {
                std.debug.assert(c.lend_active);
                c.lend_active = false;
                c.channel.releasePlaintext();
                self.maybeFinishClose(inner, c);
            }
            return true;
        }

        pub fn noteInnerRecycle(self: *Self) void {
            self.retries.noteRecvRecycle();
        }

        pub fn poll(
            self: *Self,
            inner: *Inner,
            out: []completion.Completion,
            timeout_ms: i32,
        ) !usize {
            if (self.retries.takeRecvRecycleProgress()) {
                self.retryRecvStarvation(inner);
            }
            self.retrySubmissions(inner);
            const has_ready = self.ready.len() > 0;
            var tmp: [256]completion.Completion = undefined;
            // Reserve the maximum terminal fan-out before consuming an inner
            // completion. Already-earned work remains drainable on refusal.
            self.ready.ensureUnusedCapacity(self.allocator, tmp.len * 3) catch {
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
            const n = try inner.poll(&tmp, effective_timeout);
            for (tmp[0..n]) |comp| {
                if (Identity.owns(comp.user_data)) {
                    self.dispatchInternal(inner, comp) catch {
                        const id = Identity.id(comp.user_data);
                        if (self.conns.get(id)) |c| self.failNoise(inner, c);
                    };
                } else {
                    self.ready.appendAssumeCapacity(comp);
                }
            }
            return self.ready.drain(out);
        }

        fn dispatchInternal(self: *Self, inner: *Inner, comp: completion.Completion) !void {
            const id = Identity.id(comp.user_data);
            const c = self.conns.get(id) orelse {
                if (comp.borrowed.active()) inner.recycleBorrowed(comp);
                return;
            };
            const op = Identity.op(comp.user_data);
            if (op == .close)
                std.debug.assert(c.inner_close == .in_flight)
            else
                c.pending.retire(op);
            switch (op) {
                .connect => try self.onInnerConnect(inner, c, comp.result),
                .recv => {
                    if (comp.recv_no_buffer) {
                        if (c.state != .closing) self.retries.oweRecvStarvation(&self.conns, c);
                    } else if (comp.result < 0) {
                        if (comp.borrowed.active()) inner.recycleBorrowed(comp);
                        self.failNoise(inner, c);
                    } else if (comp.result == 0) {
                        if (comp.borrowed.active()) inner.recycleBorrowed(comp);
                        self.endNoise(inner, c, if (c.state == .open) 0 else -1);
                    } else if (comp.borrowed.recvBytes()) |recv_bytes| {
                        if (c.state == .closing) {
                            inner.recycleBorrowed(comp);
                        } else if (recv_bytes.len != @as(usize, @intCast(comp.result))) {
                            inner.recycleBorrowed(comp);
                            self.failNoise(inner, c);
                        } else {
                            std.debug.assert(c.inner_recv_bytes.len == 0);
                            c.inner_recv_bytes = recv_bytes;
                            c.inner_recv_off = 0;
                            c.inner_recv_token = comp.borrowed.token;
                            try self.driveInbound(inner, c);
                        }
                    } else {
                        self.failNoise(inner, c);
                    }
                },
                .send => {
                    if (comp.result <= 0) {
                        if (c.state == .closing)
                            self.beginInnerClose(inner, c)
                        else
                            self.failNoise(inner, c);
                    } else {
                        c.ct_front_off += @intCast(comp.result);
                        try self.onSendProgress(inner, c);
                    }
                },
                .close => c.inner_close = if (comp.result < 0) .failed else .closed,
            }
            if (self.conns.get(id)) |live| self.maybeFinishClose(inner, live);
        }

        fn onInnerConnect(self: *Self, inner: *Inner, c: *NoiseConn, result: i32) !void {
            if (c.state == .closing) return;
            if (result < 0) {
                if (c.external_connect_ud) |ud| {
                    self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                    c.external_connect_ud = null;
                }
                return;
            }
            c.state = .handshaking;
            try c.channel.takeWireInto(self.allocator, &c.ct_back);
            self.driveInnerSend(inner, c) catch self.retries.oweSubmission(&self.conns, c, .send);
            self.armInnerRecv(inner, c) catch self.retries.oweSubmission(&self.conns, c, .recv);
        }

        fn emitOrArm(self: *Self, inner: *Inner, c: *NoiseConn) !void {
            std.debug.assert(c.state == .open);
            if (c.external_recv_ud != null) try self.driveInbound(inner, c);
        }

        fn driveInbound(self: *Self, inner: *Inner, c: *NoiseConn) !void {
            while (true) {
                if (c.state == .open and c.external_recv_ud == null) return;
                const bytes = if (c.inner_recv_bytes.len != 0)
                    c.inner_recv_bytes[@as(usize, c.inner_recv_off)..]
                else
                    &.{};
                const step = c.channel.ingest(self.allocator, bytes) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    self.failNoise(inner, c);
                    return;
                };
                if (c.inner_recv_bytes.len != 0) {
                    c.inner_recv_off += @intCast(step.consumed);
                    if (@as(usize, c.inner_recv_off) == c.inner_recv_bytes.len)
                        self.releaseInnerRecv(inner, c);
                }
                switch (step.event) {
                    .need_input => {
                        std.debug.assert(c.inner_recv_bytes.len == 0);
                        self.armInnerRecv(inner, c) catch self.retries.oweSubmission(&self.conns, c, .recv);
                        return;
                    },
                    .handshake => continue,
                    .completed => |key| {
                        c.proven = key.bytes;
                        try c.channel.takeWireInto(self.allocator, &c.ct_back);
                        self.driveInnerSend(inner, c) catch self.retries.oweSubmission(&self.conns, c, .send);
                        c.state = .open;
                        if (c.external_connect_ud) |ud| {
                            self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = 0 });
                            c.external_connect_ud = null;
                        }
                    },
                    .plaintext => |plain| {
                        const ud = c.external_recv_ud orelse unreachable;
                        if (plain.len == 0) {
                            c.channel.releasePlaintext();
                            continue;
                        }
                        c.external_recv_ud = null;
                        c.lend_active = true;
                        self.ready.appendAssumeCapacity(.{
                            .user_data = ud,
                            .result = @intCast(plain.len),
                            .borrowed = .recv(plain, Namespace.borrowToken(c.id)),
                        });
                        return;
                    },
                }
            }
        }

        fn releaseInnerRecv(self: *Self, inner: *Inner, c: *NoiseConn) void {
            if (c.inner_recv_bytes.len == 0) return;
            const held = completion.Completion{
                .user_data = internalUd(.recv, c.id),
                .result = @intCast(c.inner_recv_bytes.len),
                .borrowed = .recv(c.inner_recv_bytes, c.inner_recv_token),
            };
            c.inner_recv_bytes = &.{};
            c.inner_recv_off = 0;
            c.inner_recv_token = 0;
            inner.recycleBorrowed(held);
            self.retries.noteRecvRecycle();
        }

        fn armInnerRecv(_: *Self, inner: *Inner, c: *NoiseConn) !void {
            std.debug.assert(c.inner_recv_bytes.len == 0);
            if (c.pending.get(.recv) or c.state == .closing) return;
            try inner.submitRecv(internalUd(.recv, c.id), c.inner_fd);
            c.pending.arm(.recv);
        }

        fn driveInnerSend(self: *Self, inner: *Inner, c: *NoiseConn) !void {
            if (c.state == .closing or c.pending.get(.send)) return;
            if (c.ct_front_off == c.ct_front.items.len) {
                c.clearCiphertextFront(self.allocator);
                if (c.ct_back.items.len == 0) return;
                std.mem.swap(std.ArrayList(u8), &c.ct_front, &c.ct_back);
            }
            try inner.submitSend(
                internalUd(.send, c.id),
                c.inner_fd,
                c.ct_front.items[c.ct_front_off..],
            );
            c.pending.arm(.send);
        }

        fn onSendProgress(self: *Self, inner: *Inner, c: *NoiseConn) !void {
            if (c.state == .closing) {
                self.beginInnerClose(inner, c);
                return;
            }
            self.driveInnerSend(inner, c) catch {
                self.retries.oweSubmission(&self.conns, c, .send);
                return;
            };
            if (c.pendingCiphertext() != 0 or c.pending.get(.send)) return;
            if (c.external_send_ud) |ud| {
                if (c.external_send_off < c.external_send_bytes.len) {
                    const remaining = c.external_send_bytes[c.external_send_off..];
                    const take = @min(remaining.len, foundation.noise.MAX_RECORD_PLAINTEXT_BYTES);
                    try c.channel.sealBytes(self.allocator, &c.ct_back, remaining[0..take]);
                    c.external_send_off += take;
                    self.driveInnerSend(inner, c) catch self.retries.oweSubmission(&self.conns, c, .send);
                    return;
                }
                try self.ready.ensureUnusedCapacity(self.allocator, 1);
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = c.external_send_len });
                c.external_send_ud = null;
                c.external_send_len = 0;
                c.external_send_bytes = &.{};
                c.external_send_off = 0;
            }
        }

        fn retryRecvStarvation(self: *Self, inner: *Inner) void {
            const attempts = self.retries.recvStarvationCount();
            for (0..attempts) |_| {
                const c = self.retries.popRecvStarvation(&self.conns) orelse unreachable;
                if (c.state == .closing) continue;
                const need_seat = c.state == .handshaking or c.external_recv_ud != null;
                if (need_seat) self.armInnerRecv(inner, c) catch self.retries.oweSubmission(&self.conns, c, .recv);
            }
        }

        fn retrySubmissions(self: *Self, inner: *Inner) void {
            const attempts = @min(self.retries.submissionRetryCount(), submission_retry_batch);
            for (0..attempts) |_| {
                const owed = self.retries.popSubmissionRetry(&self.conns) orelse unreachable;
                const c = owed.conn;
                if (owed.includes(.recv) and c.state != .closing) {
                    const need_seat = c.state == .handshaking or c.external_recv_ud != null;
                    if (need_seat) self.armInnerRecv(inner, c) catch self.retries.oweSubmission(&self.conns, c, .recv);
                }
                if (owed.includes(.send) and c.state != .closing)
                    self.driveInnerSend(inner, c) catch self.retries.oweSubmission(&self.conns, c, .send);
                if (owed.includes(.close)) self.beginInnerClose(inner, c);
                if (self.conns.get(c.id)) |live| self.maybeFinishClose(inner, live);
            }
        }

        fn beginInnerClose(self: *Self, inner: *Inner, c: *NoiseConn) void {
            Leg.beginInnerClose(self, inner, c);
        }

        fn failNoise(self: *Self, inner: *Inner, c: *NoiseConn) void {
            Leg.fail(self, inner, c);
        }

        fn endNoise(self: *Self, inner: *Inner, c: *NoiseConn, recv_result: i32) void {
            Leg.end(self, inner, c, recv_result);
        }

        fn maybeFinishClose(self: *Self, inner: *Inner, c: *NoiseConn) void {
            Leg.maybeFinish(self, inner, c);
        }

        pub fn idFromFd(_: *Self, fd: Fd) ?ConnId {
            return Identity.idFromFd(fd);
        }

        fn internalUd(op: InternalOp, id: ConnId) u64 {
            return Identity.userData(op, id);
        }
    };
}
