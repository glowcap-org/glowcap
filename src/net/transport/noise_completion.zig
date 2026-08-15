//! The sealing completion-backend adapter (ADR-0107): `noise-relay` for the
//! completion-loop tier.
//!
//! On the byte-fed tier the core Host owns the sealed channel, because every
//! wire byte already passes through `Host.feedBytes` and
//! `HostSession.takeOutbound`. The completion loop has no such chokepoint —
//! it drives `engine.Peer` directly and holds no `HostSession` — but it does
//! have exactly one byte-transform seam: the completion `Backend`, where the
//! keyed-relay adapter already frames WebSocket bytes and the iroh backend
//! already proves its QUIC channel. This adapter is the sealed channel at
//! that seam. It wraps any inner completion backend, completes the Noise_XK
//! handshake *before* reporting the dial's connect completion — exactly as
//! the keyed-relay adapter completes the WebSocket upgrade first — and from
//! then on seals every submitted send into records and opens every received
//! record into the plaintext the loop's recv seat is lent. By adoption time
//! `verifiedChannelKey` answers the responder's durable Ed25519 key, so
//! `driver.Bridge` binds the proof through the same ADR-0105 realizer seam it
//! already uses for iroh, with no loop or bridge change.
//!
//! This adapter owns the completion tier's initiator half. Registered accepts
//! use the relay resident with its `noise-relay` profile and the byte-fed Host,
//! whose HostSession owns the responder channel. Everything else — TCP accepts,
//! plain dials, listener verbs — delegates to the wrapped backend untouched.
//!
//! Cost, per sealed connection (the memory rule's ledger points here): one
//! heap `NoiseConn` (`connection_state_bytes`, pinned by
//! `test/net/noise_relay_test.zig`) holding the embedded
//! `foundation.sealed.SealedChannel` and the two-buffer ciphertext staging.
//! Outbound pays the one AEAD pass per record ADR-0107 names, into `ct_back`
//! (`ct_front` is frozen while the inner backend borrows it — the loop's own
//! ADR-0042 shape, one tier down); a drained burst retains at most
//! `steady_ct_bytes`. Inbound opens one record at a time into the channel's
//! own scratch and lends that plaintext to the caller's recv seat zero-copy —
//! safe because the loop holds one recv seat per connection and recycles it
//! before arming the next, so no second `advance` can run under the borrow.
//! Unsealed connections pay nothing.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const intrusive_queue = @import("../completion/intrusive_queue.zig");
const completion = @import("../completion/loop.zig");

const crypto = foundation.crypto;
const sealed = foundation.sealed;

/// Steady retained capacity of each ciphertext staging buffer after a drain.
const steady_ct_bytes: usize = 4096;
/// Bound refused inner submissions attempted in one poll turn. Requeueing at
/// the tail gives every owed connection progress without letting persistent
/// backend pressure turn one turn into O(all debt) work.
const submission_retry_batch: usize = 256;
const submission_retry_ms: i32 = 50;

/// The locator designator scheme `noise-relay` shares with every sealed
/// symbol: the responder's durable Ed25519 key (ADR-0107).
pub const designator_scheme: model.transport.DesignatorScheme =
    model.transport.Known.noise_relay.metadata().designator_scheme;

/// The locator grammar for a sealing loop: `noise-relay` resolves to a sealed
/// dial over the inner resolver's `keyed-relay` target (same designator, same
/// rendezvous), and every other transport passes through unsealed. The
/// responder key comes from the designator, which is what lets `Noise_XK`
/// start from a locator that exists today.
pub fn DialResolver(comptime Backend: type, comptime InnerResolver: type) type {
    return struct {
        pub fn resolve(
            locator: model.PeerLocator,
        ) !Backend.ConnectTarget {
            if (std.mem.eql(u8, locator.transport, model.transport.noise_relay)) {
                const remote = crypto.PeerKey.fromDesignator(locator.designator) orelse return error.InvalidAddress;
                return .{ .sealed = .{
                    .inner = try InnerResolver.resolve(.{
                        .transport = model.transport.keyed_relay,
                        .designator = locator.designator,
                        .hints = locator.hints,
                    }),
                    .remote = remote,
                    .transport = model.transport.noise_relay,
                } };
            }
            return .{ .plain = try InnerResolver.resolve(locator) };
        }
    };
}

/// A completion backend that seals `.sealed` dial targets with ADR-0107's
/// byte channel and delegates everything else to `Inner`. Construct with
/// `initSealing`, then hand to `completion.Loop`'s `initWithBackend`.
pub fn CompletionBackend(comptime Inner: type) type {
    return struct {
        const Self = @This();
        const Namespace = completion.AdapterNamespace(Inner);
        pub const Fd = Inner.Fd;
        pub const adapter_depth = Namespace.depth;
        pub const ListenerAddress = Inner.ListenerAddress;

        /// The identity and rendezvous of one sealed dial: the inner
        /// backend's own target for the byte pipe, the responder key the
        /// designator named, and the transport symbol (a `model.transport`
        /// constant, so no owned bytes) both prologues must agree on.
        pub const SealedTarget = struct {
            inner: Inner.ConnectTarget,
            remote: crypto.PeerKey,
            transport: []const u8,
        };

        pub const ConnectTarget = union(enum) {
            plain: Inner.ConnectTarget,
            sealed: SealedTarget,
        };

        const ConnId = u32;
        const InternalOp = enum(u3) { connect, recv, send, close };
        const RetryLinks = intrusive_queue.Links(ConnId);

        const InternalPending = struct {
            connect: bool = false,
            recv: bool = false,
            send: bool = false,

            fn get(p: InternalPending, op: InternalOp) bool {
                return switch (op) {
                    .connect => p.connect,
                    .recv => p.recv,
                    .send => p.send,
                    .close => unreachable,
                };
            }

            fn arm(p: *InternalPending, op: InternalOp) void {
                std.debug.assert(!p.get(op));
                switch (op) {
                    .connect => p.connect = true,
                    .recv => p.recv = true,
                    .send => p.send = true,
                    .close => unreachable,
                }
            }

            fn retire(p: *InternalPending, op: InternalOp) void {
                std.debug.assert(p.get(op));
                switch (op) {
                    .connect => p.connect = false,
                    .recv => p.recv = false,
                    .send => p.send = false,
                    .close => unreachable,
                }
            }

            fn count(p: InternalPending) usize {
                return @intFromBool(p.connect) + @intFromBool(p.recv) + @intFromBool(p.send);
            }
        };

        const NoiseConn = struct {
            id: ConnId,
            inner_fd: Inner.Fd,
            state: enum { connecting, handshaking, open, closing } = .connecting,
            channel: sealed.SealedChannel,
            /// The responder key the handshake proved, published through
            /// `verifiedChannelKey` once the channel opens and never before.
            proven: ?[crypto.PEER_KEY_BYTES]u8 = null,
            external_connect_ud: ?u64,
            external_recv_ud: ?u64 = null,
            external_send_ud: ?u64 = null,
            external_send_len: i32 = 0,
            /// The caller-owned plaintext remains borrowed until its external
            /// send completion. Only one record is sealed and staged at a
            /// time, so a large frame cannot become a frame-sized ciphertext
            /// allocation inside the adapter.
            external_send_bytes: []const u8 = &.{},
            external_send_off: usize = 0,
            external_close_ud: ?u64 = null,
            /// An inner completion whose receive-buffer borrow still carries
            /// unread ciphertext. Keeping the transport borrow avoids a second
            /// ciphertext buffer for coalesced records and handshake data.
            inner_recv_bytes: []const u8 = &.{},
            inner_recv_off: u32 = 0,
            inner_recv_token: u32 = 0,
            pending: InternalPending = .{},
            inner_close: enum { open, in_flight, failed, closed } = .open,
            /// Receive-buffer starvation cannot progress until some wrapped
            /// buffer is recycled. Submission refusal is independently
            /// actionable on the next poll; its bitset can carry simultaneous
            /// handshake send and receive debt in one FIFO membership.
            recv_starvation: RetryLinks = .{},
            submission_retry: RetryLinks = .{},
            submission_retry_mask: u8 = 0,
            /// The frozen half of the ciphertext staging: the inner backend
            /// borrows `ct_front.items[ct_front_off..]` until its send
            /// completes, so nothing may resize it meanwhile.
            ct_front: std.ArrayList(u8) = .empty,
            ct_front_off: usize = 0,
            /// The open half: handshake messages and freshly sealed records
            /// append here and swap in when the frozen half drains.
            ct_back: std.ArrayList(u8) = .empty,
            /// Whether the channel's record-plaintext scratch is currently
            /// lent to the caller's recv seat (until `recycleRecv`).
            lend_active: bool = false,

            fn deinit(c: *NoiseConn, allocator: std.mem.Allocator) void {
                std.debug.assert(c.inner_recv_bytes.len == 0);
                c.channel.deinit(allocator);
                c.ct_front.deinit(allocator);
                c.ct_back.deinit(allocator);
            }

            fn pendingCiphertext(c: *const NoiseConn) usize {
                return (c.ct_front.items.len - c.ct_front_off) + c.ct_back.items.len;
            }

            fn externalSeatCount(c: *const NoiseConn) usize {
                return @as(usize, @intFromBool(c.external_connect_ud != null)) +
                    @as(usize, @intFromBool(c.external_recv_ud != null)) +
                    @as(usize, @intFromBool(c.external_send_ud != null));
            }
        };

        /// Heap-resident adapter state added by one sealed leg, excluding
        /// buffer capacity and hash-table bucket overhead. Pinned by
        /// `test/net/noise_relay_test.zig` so the scale path cannot grow
        /// unnoticed.
        pub const connection_state_bytes = @sizeOf(NoiseConn);

        const ConnMap = std.AutoHashMapUnmanaged(ConnId, *NoiseConn);

        fn recvStarvationLinks(c: *NoiseConn) *RetryLinks {
            return &c.recv_starvation;
        }

        fn submissionRetryLinks(c: *NoiseConn) *RetryLinks {
            return &c.submission_retry;
        }

        const RecvStarvationQueue = intrusive_queue.Queue(ConnId, NoiseConn, recvStarvationLinks);
        const SubmissionRetryQueue = intrusive_queue.Queue(ConnId, NoiseConn, submissionRetryLinks);

        /// The dialing identity and entropy a sealed dial needs. Absent on a
        /// backend built with plain `init`, whose sealed dials fail closed —
        /// the keyed-relay adapter's no-relay-configured posture.
        const Sealing = struct {
            identity: crypto.SecretKey,
            rng: std.Random.DefaultCsprng,

            fn deinit(self: *Sealing) void {
                std.crypto.secureZero(u8, std.mem.asBytes(&self.identity));
                std.crypto.secureZero(u8, std.mem.asBytes(&self.rng));
            }
        };

        allocator: std.mem.Allocator,
        inner: Inner,
        ready: completion.ReadyQueue,
        conns: ConnMap = .{},
        next_id: ConnId = 1,
        /// Only connections with work in these queues are visited. Receive
        /// starvation waits for a recycle edge; refused submissions retry in
        /// bounded FIFO batches on ordinary poll turns.
        recv_starvation: RecvStarvationQueue = .{},
        submission_retries: SubmissionRetryQueue = .{},
        /// A wrapped receive buffer was recycled since the last retry pass;
        /// starved inner recvs retry only on this progress edge.
        recv_recycle_progress: bool = false,
        sealing: ?Sealing,

        /// A pass-through backend with no sealing identity: every `.plain`
        /// verb delegates and a `.sealed` dial is refused before any socket
        /// opens. `Loop.init` reaches this; production loops construct the
        /// inner backend and use `initSealing` with `Loop.initWithBackend`.
        pub fn init(
            allocator: std.mem.Allocator,
            queue_entries: u16,
            read_buffers: u16,
            read_buffer_bytes: u32,
        ) !Self {
            const inner = try Inner.init(allocator, queue_entries, read_buffers, read_buffer_bytes);
            return .{
                .allocator = allocator,
                .inner = inner,
                .ready = .{},
                .sealing = null,
            };
        }

        /// Wrap `inner` with sealing dials for `identity`, the durable key
        /// whose X25519 image is this end's Noise static. `seed` is the
        /// channel-entropy boundary the driver tier owns: per-dial ephemeral
        /// seeds are drawn from a CSPRNG seeded once here, so draw it from
        /// the embedder's secure random source, exactly as the keyed-relay
        /// adapter's mask seed is.
        pub fn initSealing(
            allocator: std.mem.Allocator,
            inner: Inner,
            identity: *const crypto.SecretKey,
            seed: [std.Random.DefaultCsprng.secret_seed_length]u8,
        ) Self {
            return .{
                .allocator = allocator,
                .inner = inner,
                .ready = .{},
                .sealing = .{
                    .identity = identity.*,
                    .rng = std.Random.DefaultCsprng.init(seed),
                },
            };
        }

        /// Release an already-drained adapter; the owning Loop must have
        /// closed every synthetic handle first (`Loop.closeAndDrain`).
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.conns.count() == 0);
            std.debug.assert(self.recv_starvation.count == 0);
            std.debug.assert(self.submission_retries.count == 0);
            if (self.sealing) |*sealing| sealing.deinit();
            self.sealing = null;
            self.inner.deinit();
            self.conns.deinit(self.allocator);
            self.ready.deinit(self.allocator);
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
            if (idFromFd(fd)) |id| {
                const c = self.conns.get(id) orelse return null;
                return c.proven;
            }
            return self.inner.verifiedChannelKey(fd);
        }

        pub fn applyKeepalive(self: *Self, fd: Fd, keepalive: completion.Keepalive) !void {
            if (idFromFd(fd)) |id| {
                const c = self.conns.get(id) orelse return error.FileDescriptorNotASocket;
                return self.inner.applyKeepalive(c.inner_fd, keepalive);
            }
            return self.inner.applyKeepalive(fd, keepalive);
        }

        pub fn startDial(self: *Self, user_data: u64, target: ConnectTarget) !Fd {
            return switch (target) {
                .plain => |inner_target| self.inner.startDial(user_data, inner_target),
                .sealed => |sealed_target| self.startSealedDial(user_data, sealed_target),
            };
        }

        fn startSealedDial(self: *Self, user_data: u64, target: SealedTarget) !Fd {
            const sealing = if (self.sealing) |*s| s else return error.NoSealingIdentity;
            const id = try self.reserveId();
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
            c.inner_fd = try self.inner.startDial(internalUd(.connect, id), target.inner);
            errdefer self.inner.closeFd(c.inner_fd);
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
            if (idFromFd(fd)) |id| {
                const c = self.conns.get(id) orelse return error.ConnectionLost;
                if (c.state != .open) return error.ConnectionLost;
                if (c.external_recv_ud != null or c.lend_active) return error.AlreadyReading;
                // Staged bytes may reveal a channel fault synchronously, and
                // the failure projection completes every external seat, so
                // reserve them all before installing the caller's.
                try self.ready.ensureUnusedCapacity(self.allocator, c.externalSeatCount() + 1);
                c.external_recv_ud = user_data;
                errdefer c.external_recv_ud = null;
                try self.emitOrArm(c);
                return;
            }
            try self.inner.submitRecv(user_data, fd);
        }

        pub fn submitSend(self: *Self, user_data: u64, fd: Fd, bytes: []const u8) !void {
            if (idFromFd(fd)) |id| {
                const c = self.conns.get(id) orelse return error.ConnectionLost;
                if (c.state != .open) return error.ConnectionLost;
                if (c.external_send_ud != null) return error.AlreadyWriting;
                const send_len = std.math.cast(i32, bytes.len) orelse return error.WriteTooLarge;
                if (bytes.len == 0) {
                    try self.ready.ensureUnusedCapacity(self.allocator, 1);
                    self.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
                    return;
                }
                // Stage one bounded record before claiming the external seat:
                // a refusal appends nothing, advances no cipher state, and
                // leaves submit retryable. The completion contract keeps the
                // caller's plaintext borrowed while later records are sealed
                // on demand; an inner submit refusal is transient pressure,
                // absorbed by the owed retry because the cipher cannot rewind.
                const first_len = @min(bytes.len, foundation.noise.MAX_RECORD_PLAINTEXT_BYTES);
                try c.channel.sealBytes(self.allocator, &c.ct_back, bytes[0..first_len]);
                c.external_send_ud = user_data;
                c.external_send_len = send_len;
                c.external_send_bytes = bytes;
                c.external_send_off = first_len;
                self.driveInnerSend(c) catch self.oweSubmission(c, .send);
                return;
            }
            try self.inner.submitSend(user_data, fd, bytes);
        }

        pub fn submitCancel(
            self: *Self,
            cancel_user_data: u64,
            target_user_data: u64,
            fd: Fd,
        ) !void {
            if (idFromFd(fd)) |id| {
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
                    self.clearRecvRetry(c);
                    self.ready.appendAssumeCapacity(.{ .user_data = target_user_data, .result = -1 });
                }
                self.ready.appendAssumeCapacity(.{ .user_data = cancel_user_data, .result = 0 });
                return;
            }
            try self.inner.submitCancel(cancel_user_data, target_user_data, fd);
        }

        pub fn shutdownFd(self: *Self, fd: Fd) void {
            if (idFromFd(fd)) |id| {
                const c = self.conns.get(id) orelse return;
                self.inner.shutdownFd(c.inner_fd);
                return;
            }
            self.inner.shutdownFd(fd);
        }

        pub fn submitClose(self: *Self, user_data: u64, fd: Fd) !void {
            if (idFromFd(fd)) |id| {
                const c = self.conns.get(id) orelse {
                    try self.ready.ensureUnusedCapacity(self.allocator, 1);
                    self.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
                    return;
                };
                if (c.external_close_ud != null) return error.AlreadyClosing;
                // Reserve every completion this close mints before touching
                // any state, so a refusal below leaves the connection exactly
                // as it was and mints nothing.
                try self.ready.ensureUnusedCapacity(self.allocator, c.externalSeatCount());
                c.state = .closing;
                c.external_close_ud = user_data;
                self.clearDataRetries(c);
                self.releaseInnerRecv(c);
                if (c.external_connect_ud) |ud| {
                    self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                    c.external_connect_ud = null;
                }
                if (c.external_recv_ud) |ud| {
                    self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                    c.external_recv_ud = null;
                }
                if (c.external_send_ud) |ud| {
                    self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                    c.external_send_ud = null;
                    c.external_send_len = 0;
                    c.external_send_bytes = &.{};
                    c.external_send_off = 0;
                }
                self.beginInnerClose(c);
                if (self.conns.get(id)) |still_live| self.maybeFinishClose(still_live);
                return;
            }
            try self.inner.submitClose(user_data, fd);
        }

        pub fn closeFd(self: *Self, fd: Fd) void {
            if (idFromFd(fd)) |id| {
                const c = self.conns.get(id) orelse return;
                std.debug.assert(c.externalSeatCount() == 0);
                c.state = .closing;
                self.clearDataRetries(c);
                self.releaseInnerRecv(c);
                if (c.inner_close != .closed) {
                    self.inner.shutdownFd(c.inner_fd);
                    if (c.inner_close == .open and c.pending.count() == 0) {
                        self.clearOwedRetries(c);
                        self.inner.closeFd(c.inner_fd);
                        c.inner_close = .closed;
                    } else if (c.inner_close == .open) {
                        self.beginInnerClose(c);
                    }
                }
                if (c.inner_close == .failed and c.pending.count() == 0) {
                    self.inner.closeFd(c.inner_fd);
                    c.inner_close = .closed;
                }
                self.maybeFinishClose(c);
                return;
            }
            self.inner.closeFd(fd);
        }

        pub fn recycleRecv(self: *Self, comp: completion.Completion) void {
            if (Namespace.ownsRecvToken(comp.recv_token)) {
                const id: ConnId = @intCast(Namespace.recvTokenPayload(comp.recv_token));
                if (self.conns.get(id)) |c| {
                    std.debug.assert(c.lend_active);
                    c.lend_active = false;
                    c.channel.releasePlaintext();
                    self.maybeFinishClose(c);
                }
                return;
            }
            self.inner.recycleRecv(comp);
            self.recv_recycle_progress = true;
        }

        pub fn poll(self: *Self, out: []completion.Completion, timeout_ms: i32) !usize {
            if (self.recv_recycle_progress) {
                self.recv_recycle_progress = false;
                self.retryRecvStarvation();
            }
            self.retrySubmissions();
            const has_ready = self.ready.len() > 0;
            var tmp: [256]completion.Completion = undefined;
            // One consumed inner completion can fail a pending connect, recv,
            // and send together. Reserve the whole projection before asking
            // the inner backend to surrender any terminal record, so every
            // user completion below is infallible.
            self.ready.ensureUnusedCapacity(self.allocator, tmp.len * 3) catch {
                if (has_ready) return self.ready.drain(out);
                return error.OutOfMemory;
            };
            const effective_timeout: i32 = if (has_ready)
                0
            else if (self.submission_retries.count == 0)
                timeout_ms
            else if (timeout_ms < 0)
                submission_retry_ms
            else
                @min(timeout_ms, submission_retry_ms);
            const n = try self.inner.poll(&tmp, effective_timeout);
            for (tmp[0..n]) |comp| {
                if (isInternal(comp.user_data)) {
                    self.dispatchInternal(comp) catch {
                        const id = internalId(comp.user_data);
                        if (self.conns.get(id)) |c| self.failNoise(c);
                    };
                } else {
                    self.ready.appendAssumeCapacity(comp);
                }
            }
            return self.ready.drain(out);
        }

        fn dispatchInternal(self: *Self, comp: completion.Completion) !void {
            const id = internalId(comp.user_data);
            const c = self.conns.get(id) orelse {
                if (comp.recv_bytes != null) self.inner.recycleRecv(comp);
                return;
            };
            const op = internalOp(comp.user_data);
            if (op == .close) {
                std.debug.assert(c.inner_close == .in_flight);
            } else {
                c.pending.retire(op);
            }
            switch (op) {
                .connect => try self.onInnerConnect(c, comp.result),
                .recv => {
                    if (comp.recv_no_buffer) {
                        if (c.state != .closing) self.oweRecvStarvation(c);
                    } else {
                        if (comp.result < 0) {
                            if (comp.recv_bytes != null) self.inner.recycleRecv(comp);
                            self.failNoise(c);
                        } else if (comp.result == 0) {
                            if (comp.recv_bytes != null) self.inner.recycleRecv(comp);
                            self.endNoise(c, if (c.state == .open) 0 else -1);
                        } else if (comp.recv_bytes != null) {
                            if (c.state == .closing) {
                                self.inner.recycleRecv(comp);
                            } else {
                                const recv_bytes = comp.recv_bytes.?;
                                const result_len: u32 = @intCast(comp.result);
                                if (recv_bytes.len != result_len) {
                                    self.inner.recycleRecv(comp);
                                    self.failNoise(c);
                                    return;
                                }
                                std.debug.assert(c.inner_recv_bytes.len == 0);
                                c.inner_recv_bytes = recv_bytes;
                                c.inner_recv_off = 0;
                                c.inner_recv_token = comp.recv_token;
                                try self.driveInbound(c);
                            }
                        } else {
                            self.failNoise(c);
                        }
                    }
                },
                .send => {
                    if (comp.result <= 0) {
                        if (c.state == .closing)
                            self.beginInnerClose(c)
                        else
                            self.failNoise(c);
                    } else {
                        c.ct_front_off += @intCast(comp.result);
                        try self.onSendProgress(c);
                    }
                },
                .close => {
                    c.inner_close = if (comp.result < 0) .failed else .closed;
                },
            }
            if (self.conns.get(id)) |still_live| self.maybeFinishClose(still_live);
        }

        fn onInnerConnect(self: *Self, c: *NoiseConn, result: i32) !void {
            if (c.state == .closing) return;
            if (result < 0) {
                if (c.external_connect_ud) |ud| {
                    self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                    c.external_connect_ud = null;
                }
                return;
            }
            // The byte pipe is up; run the handshake before the loop ever
            // hears the connect completed. Message one is already pending in
            // the channel.
            c.state = .handshaking;
            try c.channel.takeWireInto(self.allocator, &c.ct_back);
            self.driveInnerSend(c) catch self.oweSubmission(c, .send);
            self.armInnerRecv(c) catch self.oweSubmission(c, .recv);
        }

        /// With a recv seat installed: open the next staged record and lend
        /// its plaintext, consume a retained inner receive borrow, or arm the
        /// next inner read.
        fn emitOrArm(self: *Self, c: *NoiseConn) !void {
            std.debug.assert(c.state == .open);
            if (c.external_recv_ud == null) return;
            try self.driveInbound(c);
        }

        /// Advance a handshake without an external seat, or open one record for
        /// an installed seat. Prefixes are consumed directly from the retained
        /// inner receive borrow, whose coalesced suffix remains borrowed until
        /// a later seat asks for it.
        fn driveInbound(self: *Self, c: *NoiseConn) !void {
            while (true) {
                if (c.state == .open and c.external_recv_ud == null) return;
                const bytes = if (c.inner_recv_bytes.len != 0)
                    c.inner_recv_bytes[@as(usize, c.inner_recv_off)..]
                else
                    &.{};
                const step = c.channel.ingest(self.allocator, bytes) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    self.failNoise(c);
                    return;
                };
                if (c.inner_recv_bytes.len != 0) {
                    c.inner_recv_off += @intCast(step.consumed);
                    if (@as(usize, c.inner_recv_off) == c.inner_recv_bytes.len)
                        self.releaseInnerRecv(c);
                }
                switch (step.event) {
                    .need_input => {
                        std.debug.assert(c.inner_recv_bytes.len == 0);
                        self.armInnerRecv(c) catch self.oweSubmission(c, .recv);
                        return;
                    },
                    .handshake => continue,
                    .completed => |key| {
                        // Message three is queued before connect publication.
                        // Bytes coalesced after message two remain in the inner
                        // receive borrow until the loop installs a recv seat.
                        c.proven = key.bytes;
                        try c.channel.takeWireInto(self.allocator, &c.ct_back);
                        self.driveInnerSend(c) catch self.oweSubmission(c, .send);
                        c.state = .open;
                        if (c.external_connect_ud) |ud| {
                            self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = 0 });
                            c.external_connect_ud = null;
                        }
                        continue;
                    },
                    .plaintext => |plain| {
                        const ud = c.external_recv_ud orelse unreachable;
                        // An empty Noise record is not EOF and occupies no
                        // external seat.
                        if (plain.len == 0) {
                            c.channel.releasePlaintext();
                            continue;
                        }
                        c.external_recv_ud = null;
                        c.lend_active = true;
                        self.ready.appendAssumeCapacity(.{
                            .user_data = ud,
                            .result = @intCast(plain.len),
                            .recv_bytes = plain,
                            .recv_token = Namespace.recvToken(c.id),
                        });
                        return;
                    },
                }
            }
        }

        fn releaseInnerRecv(self: *Self, c: *NoiseConn) void {
            if (c.inner_recv_bytes.len == 0) return;
            const held = completion.Completion{
                .user_data = internalUd(.recv, c.id),
                .result = @intCast(c.inner_recv_bytes.len),
                .recv_bytes = c.inner_recv_bytes,
                .recv_token = c.inner_recv_token,
            };
            c.inner_recv_bytes = &.{};
            c.inner_recv_off = 0;
            c.inner_recv_token = 0;
            self.inner.recycleRecv(held);
            self.recv_recycle_progress = true;
        }

        fn armInnerRecv(self: *Self, c: *NoiseConn) !void {
            std.debug.assert(c.inner_recv_bytes.len == 0);
            if (c.pending.recv or c.state == .closing) return;
            try self.inner.submitRecv(internalUd(.recv, c.id), c.inner_fd);
            c.pending.arm(.recv);
        }

        fn driveInnerSend(self: *Self, c: *NoiseConn) !void {
            if (c.state == .closing) return;
            if (c.pending.send) return;
            if (c.ct_front_off == c.ct_front.items.len) {
                self.clearCtFront(c);
                if (c.ct_back.items.len == 0) return;
                std.mem.swap(std.ArrayList(u8), &c.ct_front, &c.ct_back);
            }
            try self.inner.submitSend(internalUd(.send, c.id), c.inner_fd, c.ct_front.items[c.ct_front_off..]);
            c.pending.arm(.send);
        }

        fn onSendProgress(self: *Self, c: *NoiseConn) !void {
            if (c.state == .closing) {
                self.beginInnerClose(c);
                return;
            }
            self.driveInnerSend(c) catch {
                self.oweSubmission(c, .send);
                return;
            };
            if (c.pendingCiphertext() == 0 and !c.pending.send) {
                if (c.external_send_ud) |ud| {
                    if (c.external_send_off < c.external_send_bytes.len) {
                        const remaining = c.external_send_bytes[c.external_send_off..];
                        const take = @min(remaining.len, foundation.noise.MAX_RECORD_PLAINTEXT_BYTES);
                        try c.channel.sealBytes(self.allocator, &c.ct_back, remaining[0..take]);
                        c.external_send_off += take;
                        self.driveInnerSend(c) catch self.oweSubmission(c, .send);
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
        }

        fn clearCtFront(self: *Self, c: *NoiseConn) void {
            if (c.ct_front.capacity > steady_ct_bytes) {
                c.ct_front.deinit(self.allocator);
                c.ct_front = .empty;
            } else {
                c.ct_front.clearRetainingCapacity();
            }
            c.ct_front_off = 0;
        }

        fn submissionBit(op: InternalOp) u8 {
            std.debug.assert(op != .connect);
            return @as(u8, 1) << @intFromEnum(op);
        }

        fn owesSubmission(c: *const NoiseConn, op: InternalOp) bool {
            return c.submission_retry_mask & submissionBit(op) != 0;
        }

        fn oweRecvStarvation(self: *Self, c: *NoiseConn) void {
            if (!self.recv_starvation.contains(c))
                self.recv_starvation.push(&self.conns, c);
        }

        fn oweSubmission(self: *Self, c: *NoiseConn, op: InternalOp) void {
            const bit = submissionBit(op);
            if (c.submission_retry_mask & bit != 0) return;
            c.submission_retry_mask |= bit;
            if (!self.submission_retries.contains(c))
                self.submission_retries.push(&self.conns, c);
        }

        fn clearOwedRetries(self: *Self, c: *NoiseConn) void {
            self.recv_starvation.removeIfQueued(&self.conns, c);
            self.submission_retries.removeIfQueued(&self.conns, c);
            c.submission_retry_mask = 0;
        }

        fn clearRecvRetry(self: *Self, c: *NoiseConn) void {
            self.recv_starvation.removeIfQueued(&self.conns, c);
            c.submission_retry_mask &= ~submissionBit(.recv);
            if (c.submission_retry_mask == 0)
                self.submission_retries.removeIfQueued(&self.conns, c);
        }

        fn clearDataRetries(self: *Self, c: *NoiseConn) void {
            self.recv_starvation.removeIfQueued(&self.conns, c);
            c.submission_retry_mask &= submissionBit(.close);
            if (c.submission_retry_mask == 0)
                self.submission_retries.removeIfQueued(&self.conns, c);
        }

        fn retryRecvStarvation(self: *Self) void {
            const attempts = self.recv_starvation.count;
            for (0..attempts) |_| {
                const c = self.recv_starvation.pop(&self.conns) orelse unreachable;
                if (c.state == .closing) continue;
                const need_seat = c.state == .handshaking or c.external_recv_ud != null;
                if (!need_seat) continue;
                self.armInnerRecv(c) catch self.oweSubmission(c, .recv);
            }
        }

        fn retrySubmissions(self: *Self) void {
            const attempts = @min(self.submission_retries.count, submission_retry_batch);
            for (0..attempts) |_| {
                const c = self.submission_retries.pop(&self.conns) orelse unreachable;
                const owed = c.submission_retry_mask;
                c.submission_retry_mask = 0;
                if (owed & submissionBit(.recv) != 0 and c.state != .closing) {
                    const need_seat = c.state == .handshaking or c.external_recv_ud != null;
                    if (need_seat) self.armInnerRecv(c) catch self.oweSubmission(c, .recv);
                }
                if (owed & submissionBit(.send) != 0 and c.state != .closing)
                    self.driveInnerSend(c) catch self.oweSubmission(c, .send);
                if (owed & submissionBit(.close) != 0)
                    self.beginInnerClose(c);
                if (self.conns.get(c.id)) |still_live| {
                    self.maybeFinishClose(still_live);
                }
            }
        }

        fn beginInnerClose(self: *Self, c: *NoiseConn) void {
            if (c.inner_close != .open or owesSubmission(c, .close)) return;
            self.inner.submitClose(internalUd(.close, c.id), c.inner_fd) catch {
                self.inner.shutdownFd(c.inner_fd);
                self.oweSubmission(c, .close);
                return;
            };
            c.inner_close = .in_flight;
        }

        fn failNoise(self: *Self, c: *NoiseConn) void {
            self.endNoise(c, -1);
        }

        /// Stop admitting work, wipe the channel's keys, and publish every
        /// outstanding external result. `recv_result` keeps the completion
        /// contract's clean-EOF (`0`) versus failure (`-1`) distinction.
        fn endNoise(self: *Self, c: *NoiseConn, recv_result: i32) void {
            std.debug.assert(recv_result == 0 or recv_result == -1);
            if (c.state == .closing) return;
            c.state = .closing;
            self.clearDataRetries(c);
            c.channel.fail();
            self.releaseInnerRecv(c);
            if (c.external_connect_ud) |ud| {
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                c.external_connect_ud = null;
            }
            if (c.external_recv_ud) |ud| {
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = recv_result });
                c.external_recv_ud = null;
            }
            if (c.external_send_ud) |ud| {
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                c.external_send_ud = null;
                c.external_send_len = 0;
                c.external_send_bytes = &.{};
                c.external_send_off = 0;
            }
            if (c.external_close_ud == null) {
                self.inner.shutdownFd(c.inner_fd);
            }
        }

        fn maybeFinishClose(self: *Self, c: *NoiseConn) void {
            if (c.state != .closing) return;
            if (c.inner_close == .open or c.inner_close == .in_flight or owesSubmission(c, .close)) return;
            if (c.pending.count() != 0 or c.lend_active) return;
            if (c.inner_close == .failed) {
                self.inner.closeFd(c.inner_fd);
                c.inner_close = .closed;
            }
            if (c.external_close_ud) |ud| {
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = 0 });
                c.external_close_ud = null;
            }
            self.destroyConn(c.id);
        }

        fn destroyConn(self: *Self, id: ConnId) void {
            const c = self.conns.get(id) orelse unreachable;
            self.clearOwedRetries(c);
            const kv = self.conns.fetchRemove(id) orelse unreachable;
            std.debug.assert(kv.value == c);
            c.deinit(self.allocator);
            self.allocator.destroy(c);
        }

        fn fdFromId(id: ConnId) Fd {
            return Namespace.fdFromId(id) catch unreachable;
        }

        fn idFromFd(fd: Fd) ?ConnId {
            if (!Namespace.ownsFd(fd)) return null;
            return @intCast(Namespace.fdId(fd));
        }

        fn internalUd(op: InternalOp, id: ConnId) u64 {
            return Namespace.userData((@as(u64, id) << 3) | @intFromEnum(op));
        }

        fn isInternal(ud: u64) bool {
            return Namespace.ownsUserData(ud);
        }

        fn internalId(ud: u64) ConnId {
            return @intCast(Namespace.userDataPayload(ud) >> 3);
        }

        fn internalOp(ud: u64) InternalOp {
            return @enumFromInt(@as(u3, @truncate(ud)));
        }
    };
}
