//! Completion-backed keyed-relay dials.
//!
//! This adapter owns synthetic handles, wrapped platform operations, bounded
//! parser spill, and WebSocket send storage. Blocking std.Io ownership lives in
//! resident.zig; this file never constructs a reader or blocks a thread.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const completion = @import("../../completion/loop.zig");
const intrusive_queue = @import("../../completion/intrusive_queue.zig");
const tcp = @import("../tcp.zig");
const protocol = @import("protocol.zig");

const crypto = foundation.crypto;
const transport_name = model.transport.keyed_relay;
const rendezvous_query = protocol.rendezvous_query;
const RelayUrl = protocol.RelayUrl;
const OutgoingOpcode = protocol.OutgoingOpcode;
const acceptKey = protocol.acceptKey;
const writeFrameHeader = protocol.writeFrameHeader;
const upgrade_request_fmt = protocol.upgrade_request_fmt;
const max_upgrade_response_bytes = protocol.max_upgrade_response_bytes;
const max_header_len = protocol.max_header_len;
const parseFrameBytes = protocol.parseFrameBytes;
const validUpgradeResponse = protocol.validUpgradeResponse;

/// Header and control fragments are the ordinary retained receive state. A
/// coalesced platform read may temporarily leave a larger next-frame tail, but
/// draining it releases that burst capacity instead of turning the shared read
/// pool into a per-connection memory floor.
const steady_raw_in_bytes = max_header_len + protocol.max_control_payload;
/// Default per-connection storage for one masked WebSocket send. This includes
/// the frame header and payload; callers may trade a different explicit memory
/// commitment for larger or smaller application chunks.
pub const default_send_staging_bytes: usize = 4096;
const minimum_send_staging_bytes: usize = max_header_len + protocol.max_control_payload;

pub const RelayOptions = struct {
    url: []const u8,
    entropy_seed: [std.Random.DefaultCsprng.secret_seed_length]u8,
    /// Total retained storage for one masked WebSocket frame, including its
    /// header. This is transport staging, never an application or CapTP frame
    /// limit.
    send_staging_bytes: usize = default_send_staging_bytes,
};

/// A wrapped close submission can be refused under transient backend pressure.
/// Bound the next wait while one is owed so retry cannot sleep behind work that
/// only the retry itself can admit.
const close_retry_ms: i32 = 50;
/// Bound close-resubmission work per loop turn. A mass disconnect under a full
/// platform queue must not turn one poll into an O(all-connections) retry storm;
/// the intrusive FIFO rotates the remaining debt across later turns.
const close_retry_batch: usize = 256;

// --- Completion-loop dial backend -----------------------------------------

/// Dial target for a completion loop that can keep ordinary TCP and
/// keyed-relay outbound dials in one `driver.Bridge`. TCP remains a plain
/// platform socket; keyed-relay is a WebSocket client leg to the backend's
/// configured relay, using the locator designator as the rendezvous key.
pub const LoopConnectTarget = union(enum) {
    tcp: std.Io.net.IpAddress,
    keyed_relay: struct {
        designator: []const u8,
        relay: ?RelayUrl,
    },
};

/// Locator grammar for `completion.Loop(CompletionBackend(...), DialResolver)`.
/// It extends the TCP resolver with `keyed-relay`; the relay URL is
/// deployment configuration held by the backend, never locator bytes.
pub const DialResolver = struct {
    pub fn resolve(
        locator: model.PeerLocator,
    ) tcp.Error!LoopConnectTarget {
        if (std.mem.eql(u8, locator.transport, transport_name)) {
            if (crypto.PeerKey.fromDesignator(locator.designator) == null) return error.InvalidAddress;
            return .{ .keyed_relay = .{
                .designator = locator.designator,
                .relay = protocol.relayHint(locator.hints) catch return error.InvalidAddress,
            } };
        }
        return .{ .tcp = try tcp.DialResolver.resolve(locator) };
    }
};

/// A host-platform completion backend with native keyed-relay outbound dials.
/// Accepted sockets and ordinary TCP dials delegate straight to `Platform`.
/// `keyed-relay` dials use synthetic negative fds and drive TCP connect,
/// WebSocket upgrade, frame parse, control replies, masking, and close as
/// internal platform operations. No blocking socket or `std.Io` reader/writer
/// sits on this path.
pub fn CompletionBackend(comptime Platform: type) type {
    return struct {
        const Self = @This();
        const Namespace = completion.AdapterNamespace(Platform);
        pub const Fd = Platform.Fd;
        pub const adapter_depth = Namespace.depth;
        pub const ConnectTarget = LoopConnectTarget;
        pub const ListenerAddress = Platform.ListenerAddress;

        const ConnId = u32;
        const InternalOp = enum(u3) { connect, recv, send, close };

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

        const State = enum {
            connecting,
            sending_upgrade,
            reading_upgrade,
            open,
            closing,
        };

        const WsSendKind = enum(u2) {
            none,
            upgrade,
            application,
            control,
        };

        const ControlEffect = enum {
            consumed,
            reply_queued,
            closed,
        };

        const PlatformBufferDisposition = enum {
            recycle,
            lent_to_caller,
        };

        const PlatformCloseState = enum {
            open,
            in_flight,
            failed,
            closed,
        };

        const CloseHandshake = enum {
            open,
            received,
            sent,
            exchanged,

            pub fn hasReceived(state: CloseHandshake) bool {
                return state == .received or state == .exchanged;
            }

            pub fn hasSent(state: CloseHandshake) bool {
                return state == .sent or state == .exchanged;
            }

            fn markReceived(state: *CloseHandshake) void {
                state.* = if (state.hasSent()) .exchanged else .received;
            }

            fn markSent(state: *CloseHandshake) void {
                state.* = if (state.hasReceived()) .exchanged else .sent;
            }
        };

        const RetryLinks = intrusive_queue.Links(ConnId);

        /// Orthogonal progress toward retiring one relay leg. `wire` tracks the
        /// RFC 6455 handshake; `platform` tracks descriptor ownership. Keeping
        /// both here makes their joint teardown contract explicit without
        /// pretending they are one linear state machine.
        const CloseProgress = struct {
            wire: CloseHandshake = .open,
            platform: PlatformCloseState = .open,
            retry: RetryLinks = .{},
            graceful: bool = false,
            shutdown_requested: bool = false,
        };

        const RelayConn = struct {
            id: ConnId,
            os_fd: Platform.Fd,
            state: State = .connecting,
            ws_send_kind: WsSendKind = .none,
            external_connect_ud: ?u64,
            external_recv_ud: ?u64 = null,
            external_send_ud: ?u64 = null,
            external_send_len: i32 = 0,
            /// The caller-owned tail not yet copied and masked into `ws_out`.
            /// The completion contract keeps this borrow live until the one
            /// external send completion; subslicing advances without an offset
            /// field or a whole-write copy.
            external_send_remainder: []const u8 = &.{},
            external_close_ud: ?u64 = null,
            pending: InternalPending = .{},
            recv_retry: RetryLinks = .{},
            close: CloseProgress = .{},
            expected_accept: [28]u8,
            /// Needed only until the HTTP upgrade request has been rendered.
            designator: ?[]u8,
            upgrade_buf: std.ArrayList(u8) = .empty,
            raw_in: std.ArrayList(u8) = .empty,
            raw_in_head: usize = 0,
            ws_out: std.ArrayList(u8) = .empty,
            ws_out_off: usize = 0,
            data_remaining: u64 = 0,
            fragmented: bool = false,

            fn deinit(c: *RelayConn, allocator: std.mem.Allocator) void {
                if (c.designator) |designator| allocator.free(designator);
                c.upgrade_buf.deinit(allocator);
                c.raw_in.deinit(allocator);
                c.ws_out.deinit(allocator);
            }
        };

        /// Heap-resident adapter state added by one live keyed-relay leg,
        /// excluding temporary buffer capacity and hash-table bucket overhead.
        /// Tests pin this exact cost so the scale path cannot grow unnoticed.
        pub const connection_state_bytes = @sizeOf(RelayConn);

        fn recvRetryLinks(c: *RelayConn) *RetryLinks {
            return &c.recv_retry;
        }

        fn closeRetryLinks(c: *RelayConn) *RetryLinks {
            return &c.close.retry;
        }

        const ConnMap = std.AutoHashMapUnmanaged(ConnId, *RelayConn);

        /// Allocation-free retry ownership shared by receive starvation and
        /// refused close submission. Links live on RelayConn; both arbitrary
        /// teardown and FIFO retry remove in constant time.
        fn RetryQueue(
            comptime linksOf: fn (*RelayConn) *RetryLinks,
        ) type {
            return intrusive_queue.Queue(ConnId, RelayConn, linksOf);
        }

        const RecvRetryQueue = RetryQueue(recvRetryLinks);
        const CloseRetryQueue = RetryQueue(closeRetryLinks);

        /// Distinguish payload buffers owned by this WebSocket adapter from
        /// recv buffers the wrapped platform backend reports for ordinary TCP
        /// connections. `Completion.recv_token` is backend-opaque; without the
        /// tag, recycling a delegated TCP completion would return its index to
        /// the relay pool and permanently consume the platform buffer.
        const RelayConfig = struct {
            bytes: []u8,
            url: RelayUrl,

            fn deinit(config: *RelayConfig, allocator: std.mem.Allocator) void {
                allocator.free(config.bytes);
            }
        };

        allocator: std.mem.Allocator,
        platform: Platform,
        relay: ?RelayConfig,
        ready: completion.ReadyQueue,
        scratch_pool: completion.ScratchPool,
        /// Hard cap for bytes retained across wrapped recv completions: one
        /// whole platform buffer plus the largest header/control prefix it may
        /// complete. Ordinary payload is lent directly from the platform pool.
        raw_in_limit: usize,
        /// Total retained storage for one masked WebSocket send. Application
        /// writes are chunked behind this transport-owned memory commitment.
        send_staging_bytes: usize,
        conns: ConnMap = .{},
        /// Only connections owed a wrapped receive arm. RelayConn supplies the
        /// links, so starvation recovery has no allocation failure of its own.
        recv_retries: RecvRetryQueue = .{},
        /// A wrapped receive buffer returned since the previous retry pass.
        /// Starved receives retry only on this progress edge; polling alone
        /// cannot spin submissions while the platform pool remains empty.
        recv_recycle_progress: bool = false,
        /// Wrapped close submissions currently refused by the platform. RelayConn
        /// supplies the links, so retries visit only owed closes and cannot fail
        /// while trying to allocate their own recovery bookkeeping.
        close_retries: CloseRetryQueue = .{},
        next_id: ConnId = 1,
        rng: std.Random.DefaultCsprng,

        pub fn init(
            allocator: std.mem.Allocator,
            queue_entries: u16,
            read_buffers: u16,
            read_buffer_bytes: u32,
        ) !Self {
            return initConfigured(
                allocator,
                queue_entries,
                read_buffers,
                read_buffer_bytes,
                null,
            );
        }

        /// Build a TCP backend with keyed-relay dials enabled. `options.url` is
        /// retained deployment configuration; `options.entropy_seed` is the
        /// transport entropy boundary for WebSocket request keys and client
        /// masks and should come from the caller's existing `std.Io`
        /// `randomSecure` boundary. Plain `init` keeps keyed-relay disabled.
        pub fn initWithRelay(
            allocator: std.mem.Allocator,
            queue_entries: u16,
            read_buffers: u16,
            read_buffer_bytes: u32,
            options: RelayOptions,
        ) !Self {
            if (options.send_staging_bytes < minimum_send_staging_bytes or
                options.send_staging_bytes > std.math.maxInt(i32))
                return error.InvalidSendStagingBytes;
            return initConfigured(
                allocator,
                queue_entries,
                read_buffers,
                read_buffer_bytes,
                options,
            );
        }

        fn initConfigured(
            allocator: std.mem.Allocator,
            queue_entries: u16,
            read_buffers: u16,
            read_buffer_bytes: u32,
            relay_options: ?RelayOptions,
        ) !Self {
            var platform = try Platform.init(allocator, queue_entries, read_buffers, read_buffer_bytes);
            errdefer platform.deinit();
            var scratch_pool = try completion.ScratchPool.init(allocator, read_buffers, read_buffer_bytes);
            errdefer scratch_pool.deinit();
            const raw_in_limit = std.math.add(usize, read_buffer_bytes, steady_raw_in_bytes) catch
                return error.OutOfMemory;
            var relay: ?RelayConfig = null;
            if (relay_options) |options| {
                const url = options.url;
                const bytes = try allocator.dupe(u8, url);
                errdefer allocator.free(bytes);
                relay = .{ .bytes = bytes, .url = try RelayUrl.parse(bytes) };
            }
            return .{
                .allocator = allocator,
                .platform = platform,
                .relay = relay,
                .ready = .{},
                .scratch_pool = scratch_pool,
                .raw_in_limit = raw_in_limit,
                .send_staging_bytes = if (relay_options) |options|
                    options.send_staging_bytes
                else
                    default_send_staging_bytes,
                .rng = std.Random.DefaultCsprng.init(if (relay_options) |options|
                    options.entropy_seed
                else
                    [_]u8{0} ** std.Random.DefaultCsprng.secret_seed_length),
            };
        }

        /// Release an already-drained adapter. The owning completion Loop must
        /// close every synthetic handle and retire its wrapped operations first
        /// (`Loop.closeAndDrain`); a live send may still borrow `ws_out`, and
        /// io_uring teardown is not an operation-drain primitive.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.conns.count() == 0);
            std.debug.assert(self.recv_retries.count == 0);
            std.debug.assert(self.close_retries.count == 0);
            self.platform.deinit();
            self.conns.deinit(self.allocator);
            self.scratch_pool.deinit();
            self.ready.deinit(self.allocator);
            if (self.relay) |*relay| relay.deinit(self.allocator);
        }

        pub fn openListener(self: *Self, port: u16) !Fd {
            return self.platform.openListener(port);
        }

        pub fn listenerAddress(self: *Self, fd: Fd) !ListenerAddress {
            return self.platform.listenerAddress(fd);
        }

        pub fn listenerPort(address: ListenerAddress) ?u16 {
            return Platform.listenerPort(address);
        }

        pub fn verifiedChannelKey(self: *Self, fd: Fd) ?[crypto.PEER_KEY_BYTES]u8 {
            if (idFromFd(fd) != null) return null;
            return self.platform.verifiedChannelKey(fd);
        }

        pub fn closeFd(self: *Self, fd: Fd) void {
            if (idFromFd(fd)) |id| {
                const c = self.conns.get(id) orelse return;
                std.debug.assert(pendingExternalCount(c) == 0);
                if (c.close.platform != .closed) {
                    c.state = .closing;
                    c.close.graceful = false;
                    self.platform.shutdownFd(c.os_fd);
                    if (c.close.platform == .open and c.pending.count() == 0) {
                        self.close_retries.removeIfQueued(&self.conns, c);
                        self.platform.closeFd(c.os_fd);
                        c.close.platform = .closed;
                    } else if (c.close.platform == .open) {
                        self.beginPlatformClose(c);
                    }
                }
                if (c.close.platform == .failed and c.pending.count() == 0) {
                    self.platform.closeFd(c.os_fd);
                    c.close.platform = .closed;
                }
                if (c.pending.count() != 0 or self.close_retries.contains(c) or c.close.platform == .in_flight) {
                    return;
                }
                self.destroyRelay(id);
                return;
            }
            self.platform.closeFd(fd);
        }

        pub fn shutdownFd(self: *Self, fd: Fd) void {
            // The outer Loop calls shutdown immediately before submitClose.
            // A synthetic relay handle delays that shutdown so its WebSocket
            // close can drain first; submitClose performs the shutdown itself
            // if it must refuse admission, preserving the Loop's fallback.
            if (idFromFd(fd)) |id| {
                if (self.conns.get(id)) |c| c.close.shutdown_requested = true;
                return;
            }
            self.platform.shutdownFd(fd);
        }

        pub fn recycleRecv(self: *Self, comp: completion.Completion) void {
            if (Namespace.ownsRecvToken(comp.recv_token)) {
                self.scratch_pool.release(@intCast(Namespace.recvTokenPayload(comp.recv_token)));
            } else {
                self.platform.recycleRecv(comp);
                self.recv_recycle_progress = true;
            }
        }

        pub fn submitAccept(self: *Self, user_data: u64, listen_fd: Fd) !void {
            try self.platform.submitAccept(user_data, listen_fd);
        }

        pub fn startDial(self: *Self, user_data: u64, target: ConnectTarget) !Fd {
            return switch (target) {
                .tcp => |address| self.platform.startDial(user_data, address),
                .keyed_relay => |relay| self.startRelayDial(user_data, relay),
            };
        }

        pub fn submitRecv(self: *Self, user_data: u64, fd: Fd) !void {
            if (idFromFd(fd)) |id| {
                const c = self.conns.get(id) orelse return error.ConnectionLost;
                if (c.state != .open) return error.ConnectionLost;
                if (c.external_recv_ud != null) return error.AlreadyReading;
                // Buffered bytes may reveal a protocol fault synchronously.
                // Reserve every external failure completion before installing
                // the caller's seat so `failRelay` remains infallible.
                try self.ready.ensureUnusedCapacity(self.allocator, pendingExternalCount(c) + 1);
                errdefer c.external_recv_ud = null;
                c.external_recv_ud = user_data;
                try self.tryEmitRecv(c);
                return;
            }
            try self.platform.submitRecv(user_data, fd);
        }

        pub fn submitSend(self: *Self, user_data: u64, fd: Fd, bytes: []const u8) !void {
            if (idFromFd(fd)) |id| {
                const c = self.conns.get(id) orelse return error.ConnectionLost;
                if (c.state != .open) return error.ConnectionLost;
                if (c.close.wire != .open) return error.ConnectionLost;
                if (c.external_send_ud != null) return error.AlreadyWriting;
                const send_len = std.math.cast(i32, bytes.len) orelse return error.WriteTooLarge;
                if (bytes.len == 0) {
                    try self.ready.ensureUnusedCapacity(self.allocator, 1);
                    self.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
                    return;
                }
                c.external_send_ud = user_data;
                c.external_send_len = send_len;
                c.external_send_remainder = bytes;
                errdefer clearExternalSend(c);
                if (c.pending.send) {
                    // Only a control reply can own this seat: another
                    // application send would already hold external_send_ud.
                    // The completion contract keeps the caller's bytes borrowed
                    // until this write's single external completion.
                    std.debug.assert(c.ws_send_kind == .control);
                    return;
                }
                try self.stageExternalSendChunk(c);
                return;
            }
            try self.platform.submitSend(user_data, fd, bytes);
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
                    self.recv_retries.removeIfQueued(&self.conns, c);
                    self.ready.appendAssumeCapacity(.{ .user_data = target_user_data, .result = -1 });
                }
                // With no pending row, the synchronous receive path already
                // queued the target completion before cancellation was asked.
                self.ready.appendAssumeCapacity(.{ .user_data = cancel_user_data, .result = 0 });
                return;
            }
            try self.platform.submitCancel(cancel_user_data, target_user_data, fd);
        }

        pub fn submitClose(self: *Self, user_data: u64, fd: Fd) !void {
            if (idFromFd(fd)) |id| {
                const c = self.conns.get(id) orelse {
                    try self.ready.ensureUnusedCapacity(self.allocator, 1);
                    self.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
                    return;
                };
                if (c.external_close_ud != null) return error.AlreadyClosing;
                errdefer if (c.close.shutdown_requested) self.platform.shutdownFd(c.os_fd);
                const cancelled = pendingExternalCount(c);
                try self.ready.ensureUnusedCapacity(self.allocator, cancelled + 1);
                const send_close = c.state == .open and !c.close.wire.hasSent();
                if (send_close and !c.pending.send)
                    try c.ws_out.ensureTotalCapacityPrecise(
                        self.allocator,
                        try std.math.add(usize, c.ws_out.items.len, max_header_len),
                    );
                c.close.graceful = send_close;
                c.state = .closing;
                c.external_close_ud = user_data;
                if (c.external_connect_ud) |ud| {
                    self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                    c.external_connect_ud = null;
                }
                if (c.external_recv_ud) |ud| {
                    self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                    c.external_recv_ud = null;
                }
                self.refuseExternalSend(c);
                if (!c.pending.send) {
                    self.advanceRelayClose(c);
                    if (self.conns.get(id)) |still_live|
                        self.maybeFinishRelayClose(still_live);
                }
                return;
            }
            try self.platform.submitClose(user_data, fd);
        }

        pub fn poll(self: *Self, out: []completion.Completion, timeout_ms: i32) !usize {
            self.retryPendingCloses();
            // Pool starvation is an owed platform arm, but polling does not
            // create capacity. Retry only after a wrapped buffer is recycled;
            // this preserves fairness without a submission busy-spin.
            if (self.recv_recycle_progress) {
                self.recv_recycle_progress = false;
                try self.retryPlatformRecvStarvation();
            }
            const has_ready = self.ready.len() > 0;
            var tmp: [256]completion.Completion = undefined;
            // One consumed platform completion can fail a pending connect, recv,
            // and send together. Reserve the complete projection before asking
            // the platform to surrender any terminal record; after that point
            // every user completion is infallible even under allocator pressure.
            self.ready.ensureUnusedCapacity(self.allocator, tmp.len * 3) catch {
                // Already-earned completions remain deliverable under allocator
                // pressure. The wrapped platform stays untouched and is polled
                // on the next turn after the caller drains some queue state.
                if (has_ready) return self.ready.drain(out);
                return error.OutOfMemory;
            };
            const effective_timeout = if (has_ready)
                0
            else if (self.close_retries.count == 0)
                timeout_ms
            else if (timeout_ms < 0)
                close_retry_ms
            else
                @min(timeout_ms, close_retry_ms);
            const n = try self.platform.poll(&tmp, effective_timeout);
            for (tmp[0..n]) |comp| {
                if (isInternal(comp.user_data)) {
                    self.dispatchInternal(comp) catch {
                        const id = internalId(comp.user_data);
                        if (self.conns.get(id)) |c| self.failRelay(c);
                    };
                } else {
                    self.ready.appendAssumeCapacity(comp);
                }
            }
            return self.ready.drain(out);
        }

        fn startRelayDial(self: *Self, user_data: u64, target: @FieldType(ConnectTarget, "keyed_relay")) !Fd {
            const relay_url = target.relay orelse if (self.relay) |relay| relay.url else return error.NoRendezvousConfigured;
            if (crypto.PeerKey.fromDesignator(target.designator) == null) return error.InvalidAddress;
            const id = try self.reserveId();
            errdefer self.next_id = id;
            try self.conns.ensureUnusedCapacity(self.allocator, 1);
            const address = try tcp.parseHostPort(relay_url.host, relay_url.port);
            var designator_owned: ?[]u8 = try self.allocator.dupe(u8, target.designator);
            errdefer if (designator_owned) |bytes| self.allocator.free(bytes);
            const c = try self.allocator.create(RelayConn);
            errdefer self.allocator.destroy(c);
            c.* = .{
                .id = id,
                .os_fd = undefined,
                .external_connect_ud = user_data,
                .expected_accept = undefined,
                .designator = designator_owned.?,
            };
            // RelayConn is now the sole owner. Clearing the construction
            // carrier makes the two failure regions mechanically disjoint.
            designator_owned = null;
            errdefer c.deinit(self.allocator);
            try self.buildUpgrade(c, relay_url);
            c.os_fd = try self.platform.startDial(internalUd(.connect, id), address);
            errdefer self.platform.closeFd(c.os_fd);
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

        fn dispatchInternal(self: *Self, comp: completion.Completion) !void {
            const id = internalId(comp.user_data);
            const c = self.conns.get(id) orelse {
                if (comp.recv_bytes != null) self.platform.recycleRecv(comp);
                return;
            };
            // A completion for a live relay must retire one operation this
            // adapter admitted. Tolerating zero hides the exact accounting
            // drift that can release the synthetic connection while its
            // wrapped fd still has work in flight.
            const op = internalOp(comp.user_data);
            if (op == .close) {
                std.debug.assert(c.close.platform == .in_flight);
            } else {
                c.pending.retire(op);
            }
            switch (op) {
                .connect => try self.onRelayConnect(c, comp.result),
                .recv => {
                    if (comp.recv_no_buffer) {
                        // Closing never needs another read. Retiring this
                        // operation may be the last ownership edge after the
                        // wrapped close completed, so it must still reach the
                        // common close finalizer below.
                        if (c.state != .closing and c.external_recv_ud != null and !self.recv_retries.contains(c))
                            self.recv_retries.push(&self.conns, c);
                    } else {
                        var disposition: PlatformBufferDisposition = .recycle;
                        defer if (comp.recv_bytes != null and disposition == .recycle)
                            self.platform.recycleRecv(comp);
                        if (comp.result < 0) {
                            self.failRelay(c);
                        } else if (comp.result == 0) {
                            self.endRelay(c, if (c.state == .open) 0 else -1);
                        } else if (comp.recv_bytes) |bytes| {
                            if (c.state == .open and c.external_recv_ud != null and rawBytes(c).len == 0) {
                                disposition = try self.tryEmitPlatformRecv(c, comp, bytes);
                            } else if (c.state != .closing) {
                                // Cancellation retires the caller's receive
                                // seat, not a wrapped operation already owned
                                // by the platform. Preserve a late completion
                                // for the next seat instead of dropping stream
                                // bytes when the platform buffer is recycled.
                                try self.appendRaw(c, bytes);
                                try self.onRelayBytes(c);
                            }
                        } else {
                            self.failRelay(c);
                        }
                    }
                },
                .send => {
                    if (comp.result <= 0) {
                        if (c.state == .closing)
                            self.beginPlatformClose(c)
                        else
                            self.failRelay(c);
                    } else {
                        c.ws_out_off += @intCast(comp.result);
                        if (c.state == .closing) {
                            if (!c.close.wire.hasSent()) {
                                self.clearWsOut(c);
                                self.advanceRelayClose(c);
                            } else if (c.ws_out_off == c.ws_out.items.len) {
                                self.clearWsOut(c);
                                self.advanceRelayClose(c);
                            } else {
                                self.driveRelaySend(c) catch self.beginPlatformClose(c);
                            }
                        } else if (c.ws_out_off == c.ws_out.items.len) {
                            const completed_kind = c.ws_send_kind;
                            if (completed_kind == .upgrade) {
                                // The request target is deployment-sized and can
                                // exceed an ordinary frame. It is handshake
                                // scratch, not a per-connection memory floor.
                                c.ws_out.deinit(self.allocator);
                                c.ws_out = .empty;
                                c.ws_send_kind = .none;
                            } else {
                                self.clearWsOut(c);
                            }
                            c.ws_out_off = 0;
                            switch (completed_kind) {
                                .upgrade => {
                                    c.state = .reading_upgrade;
                                    try self.armPlatformRecv(c);
                                },
                                .application => {
                                    if (c.external_send_remainder.len == 0) {
                                        self.completeExternalSend(c);
                                    } else {
                                        // A complete binary message is one
                                        // byte-stream chunk, not the external
                                        // write boundary. Service any retained
                                        // Close/Ping before staging the next.
                                        try self.serviceBufferedInput(c);
                                        try self.stageExternalSendChunk(c);
                                    }
                                },
                                .control => {
                                    // A Pong may have an application write
                                    // waiting behind it. Consume a Close queued
                                    // behind the Ping before admitting data.
                                    try self.serviceBufferedInput(c);
                                    try self.stageExternalSendChunk(c);
                                },
                                .none => unreachable,
                            }
                        }
                        if (c.state != .closing) try self.driveRelaySend(c);
                        if (c.state == .open and c.ws_out.items.len == 0) try self.tryEmitRecv(c);
                    }
                },
                .close => {
                    // A failed wrapped close leaves descriptor ownership here,
                    // but another wrapped operation may still be kernel-owned.
                    // Record the owed release; the last retirement discharges
                    // it before the synthetic close completes.
                    c.close.platform = if (comp.result < 0) .failed else .closed;
                    self.maybeFinishRelayClose(c);
                },
            }
            if (self.conns.get(id)) |still_live| self.maybeFinishRelayClose(still_live);
        }

        fn onRelayConnect(self: *Self, c: *RelayConn, result: i32) !void {
            if (c.state == .closing) return;
            if (result < 0) {
                if (c.external_connect_ud) |ud| {
                    try self.ready.ensureUnusedCapacity(self.allocator, 1);
                    self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                    c.external_connect_ud = null;
                }
                return;
            }
            c.state = .sending_upgrade;
            try self.driveRelaySend(c);
        }

        fn buildUpgrade(self: *Self, c: *RelayConn, relay_url: RelayUrl) !void {
            var key_bytes: [16]u8 = undefined;
            self.rng.random().bytes(&key_bytes);
            var key_b64: [24]u8 = undefined;
            _ = std.base64.standard.Encoder.encode(&key_b64, &key_bytes);
            acceptKey(&c.expected_accept, &key_b64);
            const path = if (relay_url.path.len != 0) relay_url.path else "/";
            const designator = c.designator orelse return error.InvalidAddress;
            const args = .{
                path,
                relay_url.queryJoin(),
                rendezvous_query,
                designator,
                relay_url.authority_host,
                relay_url.port,
                &key_b64,
            };
            self.clearWsOut(c);
            c.ws_out_off = 0;
            try c.ws_out.ensureTotalCapacityPrecise(
                self.allocator,
                std.fmt.count(upgrade_request_fmt, args),
            );
            try c.ws_out.print(self.allocator, upgrade_request_fmt, args);
            c.ws_send_kind = .upgrade;
            self.allocator.free(designator);
            c.designator = null;
        }

        fn onRelayBytes(self: *Self, c: *RelayConn) !void {
            switch (c.state) {
                .reading_upgrade => try self.consumeUpgrade(c),
                .open => try self.tryEmitRecv(c),
                .closing, .connecting, .sending_upgrade => {},
            }
        }

        fn consumeUpgrade(self: *Self, c: *RelayConn) !void {
            const raw = rawBytes(c);
            const marker = "\r\n\r\n";
            const marker_end = upgradeMarkerEnd(c.upgrade_buf.items, raw, marker) orelse {
                if (raw.len > max_upgrade_response_bytes -| c.upgrade_buf.items.len)
                    return self.failRelay(c);
                try self.appendUpgrade(c, raw);
                self.clearRaw(c);
                try self.armPlatformRecv(c);
                return;
            };
            if (marker_end > max_upgrade_response_bytes -| c.upgrade_buf.items.len)
                return self.failRelay(c);
            try self.appendUpgrade(c, raw[0..marker_end]);
            self.dropRaw(c, marker_end);
            const header_end = c.upgrade_buf.items.len - marker.len;
            if (!validUpgradeResponse(c.upgrade_buf.items[0..header_end], &c.expected_accept))
                return self.failRelay(c);
            c.upgrade_buf.deinit(self.allocator);
            c.upgrade_buf = .empty;
            if (c.external_connect_ud != null) try self.ready.ensureUnusedCapacity(self.allocator, 1);
            c.state = .open;
            if (c.external_connect_ud) |ud| {
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = 0 });
                c.external_connect_ud = null;
            }
            try self.tryEmitRecv(c);
        }

        const ReceiveInput = union(enum) {
            retained,
            platform: struct {
                completion_record: completion.Completion,
                bytes: []const u8,
                at: usize = 0,
            },

            fn available(input: *ReceiveInput, c: *RelayConn) []const u8 {
                return switch (input.*) {
                    .retained => rawBytes(c),
                    .platform => |platform| platform.bytes[platform.at..],
                };
            }

            fn consume(input: *ReceiveInput, backend: *Self, c: *RelayConn, count: usize) void {
                switch (input.*) {
                    .retained => backend.dropRaw(c, count),
                    .platform => |*platform| platform.at += count,
                }
            }

            /// Preserve every unconsumed platform byte before its pool buffer is
            /// recycled. Retained input already lives in `raw_in`.
            fn retainRemainder(input: *ReceiveInput, backend: *Self, c: *RelayConn) !void {
                switch (input.*) {
                    .retained => {},
                    .platform => |*platform| {
                        const remaining = platform.bytes[platform.at..];
                        if (remaining.len > 0) try backend.appendRaw(c, remaining);
                        platform.at = platform.bytes.len;
                    },
                }
            }

            fn completionRecord(input: *ReceiveInput) ?completion.Completion {
                return switch (input.*) {
                    .retained => null,
                    .platform => |platform| platform.completion_record,
                };
            }
        };

        fn tryEmitRecv(self: *Self, c: *RelayConn) !void {
            var input: ReceiveInput = .retained;
            _ = try self.driveReceive(c, &input);
        }

        /// Project one wrapped platform buffer directly into the caller's recv
        /// seat when it contains application payload. The platform's recv token
        /// crosses unchanged, so `recycleRecv` returns the buffer to its actual
        /// owner after the outer Loop consumes it. Bytes that cannot share that
        /// lifetime (a split header/control frame or a coalesced next-frame
        /// tail) move into `raw_in`; only those exceptional bytes are copied.
        fn tryEmitPlatformRecv(
            self: *Self,
            c: *RelayConn,
            comp: completion.Completion,
            bytes: []const u8,
        ) !PlatformBufferDisposition {
            var input: ReceiveInput = .{ .platform = .{
                .completion_record = comp,
                .bytes = bytes,
            } };
            return self.driveReceive(c, &input);
        }

        /// The one WebSocket receive state machine. `ReceiveInput` owns the only
        /// source-dependent choices: retained bytes copy into the adapter pool,
        /// while a fresh platform payload is lent directly and preserves only
        /// its coalesced tail. Protocol progression and control handling are
        /// identical for both sources.
        fn driveReceive(
            self: *Self,
            c: *RelayConn,
            input: *ReceiveInput,
        ) !PlatformBufferDisposition {
            if (c.state != .open) return .recycle;
            // The Loop owns the receive seat for an open connection. A hidden
            // prefetch can outlive that seat under backpressure, leaving an
            // internal fault with no user_data to retire.
            const ud = c.external_recv_ud orelse return .recycle;
            if (c.close.wire.hasReceived()) {
                if (!c.pending.send and c.ws_out.items.len == 0) {
                    try self.ready.ensureUnusedCapacity(self.allocator, 1);
                    c.external_recv_ud = null;
                    self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = 0 });
                }
                return .recycle;
            }

            while (true) {
                const available = input.available(c);
                if (c.data_remaining > 0) {
                    if (available.len == 0) {
                        try self.armPlatformRecv(c);
                        return .recycle;
                    }
                    try self.ready.ensureUnusedCapacity(self.allocator, 1);
                    if (input.completionRecord()) |comp| {
                        const n: usize = @intCast(@min(
                            c.data_remaining,
                            @as(u64, @intCast(available.len)),
                        ));
                        input.consume(self, c, n);
                        try input.retainRemainder(self, c);
                        c.data_remaining -= n;
                        c.external_recv_ud = null;
                        self.ready.appendAssumeCapacity(.{
                            .user_data = ud,
                            .result = @intCast(n),
                            .recv_bytes = available[0..n],
                            .recv_token = comp.recv_token,
                        });
                        return .lent_to_caller;
                    }

                    const idx = self.scratch_pool.acquire() orelse {
                        self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1, .recv_no_buffer = true });
                        c.external_recv_ud = null;
                        return .recycle;
                    };
                    const out = self.scratch_pool.buffer(idx);
                    const remaining: usize = @intCast(@min(c.data_remaining, std.math.maxInt(usize)));
                    const n = @min(out.len, available.len, remaining);
                    @memcpy(out[0..n], available[0..n]);
                    input.consume(self, c, n);
                    c.data_remaining -= n;
                    c.external_recv_ud = null;
                    self.ready.appendAssumeCapacity(.{
                        .user_data = ud,
                        .result = @intCast(n),
                        .recv_bytes = out[0..n],
                        .recv_token = Namespace.recvToken(idx),
                    });
                    return .recycle;
                }

                const frame = (parseFrameBytes(&c.fragmented, available) catch {
                    self.failRelay(c);
                    return .recycle;
                }) orelse {
                    try input.retainRemainder(self, c);
                    try self.armPlatformRecv(c);
                    return .recycle;
                };
                const payload = frame.controlPayload(available);
                switch (frame.effect) {
                    .data => {
                        input.consume(self, c, frame.consumed_len);
                        c.data_remaining = frame.header.len;
                        if (frame.header.len == 0) continue;
                    },
                    .ping, .close => {
                        // A send borrows ws_out. Preserve this frame until that
                        // borrow retires; the send completion resumes the same
                        // receive seat through this function.
                        if (c.pending.send) {
                            try input.retainRemainder(self, c);
                            return .recycle;
                        }
                        const effect = try self.handleControlFrame(c, frame.effect, payload);
                        input.consume(self, c, frame.consumed_len);
                        if (effect == .reply_queued) try input.retainRemainder(self, c);
                        return .recycle;
                    },
                    .pong => {
                        _ = try self.handleControlFrame(c, frame.effect, payload);
                        input.consume(self, c, frame.consumed_len);
                    },
                }
            }
        }

        /// Control frames can arrive in a late wrapped receive after the Loop's
        /// receive seat was canceled. Between application chunks, inspect only
        /// complete retained controls: application headers and payload remain
        /// untouched until a caller owns their projection.
        fn drainRetainedControls(self: *Self, c: *RelayConn) !void {
            if (c.state != .open or c.pending.send or c.data_remaining != 0) return;
            while (rawBytes(c).len != 0) {
                var fragmented = c.fragmented;
                const frame = (parseFrameBytes(&fragmented, rawBytes(c)) catch {
                    self.failRelay(c);
                    return;
                }) orelse return;
                if (frame.effect == .data) return;

                c.fragmented = fragmented;
                const payload = frame.controlPayload(rawBytes(c));
                const effect = try self.handleControlFrame(c, frame.effect, payload);
                self.dropRaw(c, frame.consumed_len);
                if (effect == .reply_queued or effect == .closed) return;
            }
        }

        fn serviceBufferedInput(self: *Self, c: *RelayConn) !void {
            if (c.external_recv_ud != null) try self.tryEmitRecv(c);
            // A projected data payload can consume the caller's receive seat
            // and leave a complete control frame immediately behind it. Keep
            // the same control-before-next-chunk ordering in that case.
            if (c.external_recv_ud == null) try self.drainRetainedControls(c);
        }

        fn stageExternalSendChunk(self: *Self, c: *RelayConn) !void {
            if (c.external_send_ud == null or c.pending.send or c.state != .open or c.close.wire != .open)
                return;
            std.debug.assert(c.external_send_remainder.len != 0);
            const payload_limit = self.send_staging_bytes - max_header_len;
            const take = @min(c.external_send_remainder.len, payload_limit);
            try self.queueAndDriveWsFrame(
                c,
                .application,
                .binary,
                c.external_send_remainder[0..take],
            );
            c.external_send_remainder = c.external_send_remainder[take..];
        }

        fn completeExternalSend(self: *Self, c: *RelayConn) void {
            const user_data = c.external_send_ud orelse return;
            self.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = c.external_send_len });
            clearExternalSend(c);
        }

        fn clearExternalSend(c: *RelayConn) void {
            c.external_send_ud = null;
            c.external_send_len = 0;
            c.external_send_remainder = &.{};
        }

        fn queueWsFrame(
            self: *Self,
            c: *RelayConn,
            kind: WsSendKind,
            opcode: OutgoingOpcode,
            bytes: []const u8,
        ) !void {
            std.debug.assert(kind == .application or kind == .control);
            std.debug.assert(c.ws_send_kind == .none and c.ws_out.items.len == 0);
            var header: [max_header_len]u8 = undefined;
            const prefix = try writeFrameHeader(&header, opcode, bytes.len, .{0} ** 4);
            const frame_len = try std.math.add(usize, prefix.len, bytes.len);
            if (frame_len > self.send_staging_bytes) return error.SendStagingTooSmall;
            try c.ws_out.ensureTotalCapacityPrecise(self.allocator, frame_len);
            // Nothing below this point can fail. Consume mask entropy only
            // after every fallible size and capacity check, so rollback never
            // copies or rewinds the CSPRNG state on the wire path.
            var mask: [4]u8 = undefined;
            self.rng.random().bytes(&mask);
            @memcpy(header[prefix.len - mask.len .. prefix.len], &mask);
            c.ws_out.appendSliceAssumeCapacity(prefix);
            const start = c.ws_out.items.len;
            c.ws_out.appendSliceAssumeCapacity(bytes);
            for (c.ws_out.items[start..], 0..) |*b, i| b.* ^= mask[i % 4];
            c.ws_send_kind = kind;
            if (opcode == .close) c.close.wire.markSent();
        }

        fn queueAndDriveWsFrame(
            self: *Self,
            c: *RelayConn,
            kind: WsSendKind,
            opcode: OutgoingOpcode,
            bytes: []const u8,
        ) !void {
            const old_close_handshake = c.close.wire;
            errdefer {
                self.clearWsOut(c);
                c.close.wire = old_close_handshake;
            }
            try self.queueWsFrame(c, kind, opcode, bytes);
            try self.driveRelaySend(c);
        }

        fn driveRelaySend(self: *Self, c: *RelayConn) !void {
            // A wrapped close may already be queued ahead of this operation.
            // Submitting another send after that point can target a reused
            // integer fd on a completion backend, so closing admits no fresh
            // platform work; already-armed sends retire normally.
            if (c.pending.send or c.ws_out_off == c.ws_out.items.len) return;
            try self.platform.submitSend(internalUd(.send, c.id), c.os_fd, c.ws_out.items[c.ws_out_off..]);
            c.pending.arm(.send);
        }

        fn armPlatformRecv(self: *Self, c: *RelayConn) !void {
            if (c.pending.recv or c.state == .closing) return;
            try self.platform.submitRecv(internalUd(.recv, c.id), c.os_fd);
            c.pending.arm(.recv);
        }

        fn retryPlatformRecvStarvation(self: *Self) !void {
            while (self.recv_retries.head != 0) {
                const c = self.conns.get(self.recv_retries.head) orelse unreachable;
                if (c.state == .closing or c.external_recv_ud == null) {
                    self.recv_retries.removeQueued(&self.conns, c);
                    continue;
                }
                try self.armPlatformRecv(c);
                self.recv_retries.removeQueued(&self.conns, c);
            }
        }

        fn refuseExternalSend(self: *Self, c: *RelayConn) void {
            if (c.external_send_ud) |ud| {
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                clearExternalSend(c);
            }
        }

        /// Apply the adapter effect of one control frame already admitted by
        /// `protocol.admitFrame`. Buffer ownership remains with the caller;
        /// this owns only reply submission and connection lifecycle state.
        fn handleControlFrame(
            self: *Self,
            c: *RelayConn,
            effect: protocol.FrameEffect,
            payload: []const u8,
        ) !ControlEffect {
            return switch (effect) {
                .pong => .consumed,
                .ping => blk: {
                    try self.queueAndDriveWsFrame(c, .control, .pong, payload);
                    break :blk .reply_queued;
                },
                .close => blk: {
                    c.close.wire.markReceived();
                    if (!c.close.wire.hasSent())
                        try self.queueAndDriveWsFrame(c, .control, .close, payload);
                    self.refuseExternalSend(c);
                    break :blk .closed;
                },
                .data => unreachable,
            };
        }

        fn failRelay(self: *Self, c: *RelayConn) void {
            self.endRelay(c, -1);
        }

        /// Stop admitting work and publish every outstanding external result.
        /// `recv_result` preserves the completion contract's clean-EOF (`0`)
        /// versus failure (`-1`) distinction; connect and send never succeed as
        /// a side effect of terminal receive progress.
        fn endRelay(self: *Self, c: *RelayConn, recv_result: i32) void {
            std.debug.assert(recv_result == 0 or recv_result == -1);
            if (c.state == .closing) return;
            c.state = .closing;
            if (c.external_connect_ud) |ud| {
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                c.external_connect_ud = null;
            }
            if (c.external_recv_ud) |ud| {
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = recv_result });
                c.external_recv_ud = null;
            }
            self.refuseExternalSend(c);
            if (c.external_close_ud == null) {
                self.platform.shutdownFd(c.os_fd);
            }
        }

        /// Finish the WebSocket half-close before retiring the wrapped socket.
        /// Once submitClose is accepted, platform-close refusal is internal:
        /// closeFd gives the adapter an unconditional fallback and the caller
        /// still receives exactly one successful close completion.
        fn advanceRelayClose(self: *Self, c: *RelayConn) void {
            std.debug.assert(c.state == .closing and !c.pending.send);
            if (!c.close.graceful) {
                self.clearWsOut(c);
                c.ws_out_off = 0;
                return self.beginPlatformClose(c);
            }
            if (!c.close.wire.hasSent()) {
                self.clearWsOut(c);
                c.ws_out_off = 0;
                self.queueWsFrame(c, .control, .close, &.{}) catch return self.beginPlatformClose(c);
                self.driveRelaySend(c) catch return self.beginPlatformClose(c);
                return;
            }
            if (c.ws_out_off != c.ws_out.items.len) {
                self.driveRelaySend(c) catch return self.beginPlatformClose(c);
                return;
            }
            self.beginPlatformClose(c);
        }

        fn beginPlatformClose(self: *Self, c: *RelayConn) void {
            if (c.close.platform != .open or self.close_retries.contains(c)) return;
            self.platform.submitClose(internalUd(.close, c.id), c.os_fd) catch {
                self.platform.shutdownFd(c.os_fd);
                self.close_retries.push(&self.conns, c);
                return;
            };
            c.close.platform = .in_flight;
        }

        /// Retry only wrapped closes refused under transient queue or allocator
        /// pressure. The intrusive queue makes this O(owed closes), and keeping
        /// its link on RelayConn means recovery needs no fallible allocation.
        fn retryPendingCloses(self: *Self) void {
            const attempts = @min(self.close_retries.count, close_retry_batch);
            for (0..attempts) |_| {
                const c = self.close_retries.pop(&self.conns) orelse unreachable;
                self.platform.submitClose(internalUd(.close, c.id), c.os_fd) catch {
                    self.close_retries.push(&self.conns, c);
                    continue;
                };
                c.close.platform = .in_flight;
            }
        }

        fn maybeFinishRelayClose(self: *Self, c: *RelayConn) void {
            if (c.close.platform == .open or c.close.platform == .in_flight or c.pending.count() != 0) return;
            if (c.close.platform == .failed) {
                self.platform.closeFd(c.os_fd);
                c.close.platform = .closed;
            }
            self.finishRelayCloseAssumeCapacity(c);
        }

        fn finishRelayCloseAssumeCapacity(self: *Self, c: *RelayConn) void {
            if (c.external_close_ud) |ud| {
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = 0 });
                c.external_close_ud = null;
            }
            self.destroyRelay(c.id);
        }

        fn pendingExternalCount(c: *const RelayConn) usize {
            return @as(usize, @intFromBool(c.external_connect_ud != null)) +
                @as(usize, @intFromBool(c.external_recv_ud != null)) +
                @as(usize, @intFromBool(c.external_send_ud != null));
        }

        fn destroyRelay(self: *Self, id: ConnId) void {
            const c = self.conns.get(id) orelse unreachable;
            self.recv_retries.removeIfQueued(&self.conns, c);
            self.close_retries.removeIfQueued(&self.conns, c);
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

        fn rawBytes(c: *const RelayConn) []const u8 {
            return c.raw_in.items[c.raw_in_head..];
        }

        fn clearRaw(self: *Self, c: *RelayConn) void {
            c.raw_in.clearRetainingCapacity();
            c.raw_in_head = 0;
            if (c.raw_in.capacity > steady_raw_in_bytes) {
                c.raw_in.deinit(self.allocator);
                c.raw_in = .empty;
            }
        }

        fn clearWsOut(self: *Self, c: *RelayConn) void {
            if (c.ws_out.capacity > self.send_staging_bytes) {
                c.ws_out.deinit(self.allocator);
                c.ws_out = .empty;
            } else {
                c.ws_out.clearRetainingCapacity();
            }
            c.ws_out_off = 0;
            c.ws_send_kind = .none;
        }

        fn appendRaw(self: *Self, c: *RelayConn, bytes: []const u8) !void {
            if (bytes.len == 0) return;
            const live_len = rawBytes(c).len;
            if (bytes.len > self.raw_in_limit -| live_len) return error.RelayInputOverflow;
            if (c.raw_in_head != 0 and bytes.len > c.raw_in.capacity - c.raw_in.items.len)
                compactRaw(c);
            // Geometric ArrayList growth would make the byte limit a logical
            // bound while silently reserving more memory per connection. This
            // spill is itself the scale budget, so grow precisely and append
            // without a second capacity policy.
            try c.raw_in.ensureTotalCapacityPrecise(self.allocator, c.raw_in.items.len + bytes.len);
            c.raw_in.appendSliceAssumeCapacity(bytes);
        }

        fn appendUpgrade(self: *Self, c: *RelayConn, bytes: []const u8) !void {
            const needed = try std.math.add(usize, c.upgrade_buf.items.len, bytes.len);
            if (needed > max_upgrade_response_bytes) return error.UpgradeResponseTooLarge;
            try c.upgrade_buf.ensureTotalCapacityPrecise(self.allocator, needed);
            c.upgrade_buf.appendSliceAssumeCapacity(bytes);
        }

        fn dropRaw(self: *Self, c: *RelayConn, n: usize) void {
            if (n == 0) return;
            std.debug.assert(n <= rawBytes(c).len);
            c.raw_in_head += n;
            const live = rawBytes(c);
            if (live.len == 0) return self.clearRaw(c);
            if (live.len > steady_raw_in_bytes or c.raw_in.capacity <= steady_raw_in_bytes) return;

            // A coalesced platform read may leave a small partial frame behind
            // a large consumed prefix. Once that burst has drained, compact and
            // release its capacity instead of making it the connection's new
            // steady-state footprint.
            compactRaw(c);
            // Capacity reclamation is maintenance, not protocol progress.
            // ArrayList's best-effort shrink keeps the compact live bytes when
            // an allocator cannot provide the exact smaller block.
            c.raw_in.shrinkAndFree(self.allocator, live.len);
        }

        fn compactRaw(c: *RelayConn) void {
            if (c.raw_in_head == 0) return;
            const live = rawBytes(c);
            std.mem.copyForwards(u8, c.raw_in.items[0..live.len], live);
            c.raw_in.shrinkRetainingCapacity(live.len);
            c.raw_in_head = 0;
        }

        /// Number of bytes from `incoming` through the HTTP header terminator,
        /// including a marker split across the retained prefix and this read.
        /// Null means the complete concatenation still has no terminator.
        fn upgradeMarkerEnd(retained: []const u8, incoming: []const u8, marker: []const u8) ?usize {
            std.debug.assert(marker.len > 1);
            const retained_tail_len = @min(retained.len, marker.len - 1);
            const incoming_head_len = @min(incoming.len, marker.len - 1);
            var boundary: [6]u8 = undefined;
            std.debug.assert(marker.len * 2 - 2 <= boundary.len);
            @memcpy(boundary[0..retained_tail_len], retained[retained.len - retained_tail_len ..]);
            @memcpy(boundary[retained_tail_len..][0..incoming_head_len], incoming[0..incoming_head_len]);
            if (std.mem.indexOf(u8, boundary[0 .. retained_tail_len + incoming_head_len], marker)) |at| {
                const end_in_boundary = at + marker.len;
                if (end_in_boundary > retained_tail_len) return end_in_boundary - retained_tail_len;
            }
            if (std.mem.indexOf(u8, incoming, marker)) |at| return at + marker.len;
            return null;
        }
    };
}
