//! Completion-backed keyed-relay dials.
//!
//! This adapter owns synthetic handles, wrapped platform operations, bounded
//! parser spill, and WebSocket send storage. Blocking std.Io ownership lives in
//! resident.zig; this file never constructs a reader or blocks a thread.

const std = @import("std");

const foundation = @import("foundation");
const carrier_failure = @import("../../carrier_failure.zig");
const completion = @import("../../completion/loop.zig");
const protocol = @import("../../websocket/client_protocol.zig");
const completion_buffers = @import("completion/buffers.zig");
const completion_dial_race = @import("completion/dial_race.zig");
const completion_dial_identity = @import("completion/dial_identity.zig");
const completion_machines = @import("completion/machines.zig");
const completion_resolver = @import("completion/resolver.zig");
const completion_state = @import("completion/state.zig");
const completion_options = @import("completion_options.zig");
const dial_resolver = @import("dial_resolver.zig");
const route = @import("route.zig");

const crypto = foundation.crypto;
const RelayUrl = route.RelayUrl;
const max_header_len = protocol.max_header_len;
pub const default_send_staging_bytes = completion_options.default_send_staging_bytes;
const minimum_send_staging_bytes = completion_options.minimum_send_staging_bytes;
pub const RelayOptions = completion_options.RelayOptions;
const operation_retry_ms = completion_options.operation_retry_ms;
const close_retry_batch = completion_options.close_retry_batch;

// --- Completion-loop dial backend -----------------------------------------

pub const LoopConnectTarget = dial_resolver.LoopConnectTarget;
pub const DialResolver = dial_resolver.DialResolver;

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
        const Types = completion_state.Types(Platform, Namespace);
        pub const Fd = Platform.Fd;
        pub const adapter_depth = Namespace.depth;
        pub const ConnectTarget = LoopConnectTarget;
        pub const ListenerAddress = Platform.ListenerAddress;

        const ConnId = Types.ConnId;
        const InternalOp = Types.InternalOp;
        const State = Types.State;
        const PlatformCloseState = Types.PlatformCloseState;
        const RelayConn = Types.RelayConn;
        const PendingDial = Types.PendingDial;
        const DialOp = enum(u1) { connect, close };
        const DialIdentity = completion_dial_identity.Identity(Namespace, ConnId, DialOp);
        const resolver_wake_ud = DialIdentity.resolver_wake_ud;
        const MachineOperations = struct {
            pub fn armPlatformRecv(backend: *Self, c: *RelayConn) !void {
                try backend.armPlatformRecv(c);
            }

            pub fn idFromFd(fd: Fd) ?ConnId {
                return Self.idFromFd(fd);
            }

            pub fn internalUd(op: InternalOp, id: ConnId) u64 {
                return Self.internalUd(op, id);
            }

            pub fn internalId(user_data: u64) ConnId {
                return Self.internalId(user_data);
            }

            pub fn internalOp(user_data: u64) InternalOp {
                return Self.internalOp(user_data);
            }
        };
        const MachineSet = completion_machines.Machines(
            Self,
            Types,
            Namespace,
            MachineOperations,
            max_header_len,
            close_retry_batch,
        );
        const Receive = MachineSet.Receive;
        const Send = MachineSet.Send;
        const Lifecycle = MachineSet.Lifecycle;
        const Dispatch = MachineSet.Dispatch;
        const Tls = MachineSet.Tls;
        const DialRaceAccess = struct {
            pub const dialUserData = DialIdentity.userData;
            pub const dialId = DialIdentity.id;
            pub const dialSlot = DialIdentity.slot;
            pub const dialOp = DialIdentity.op;

            pub fn failureToken(id: ConnId) u32 {
                return Namespace.borrowToken(id);
            }

            pub fn adoptWinner(backend: *Self, pending: *PendingDial, fd: Fd) void {
                backend.adoptDialWinner(pending, fd);
            }

            pub fn destroyPending(backend: *Self, pending: *PendingDial) void {
                backend.destroyPendingDial(pending);
            }

            pub fn retirePending(
                backend: *Self,
                pending: *PendingDial,
            ) ?carrier_failure.Failure {
                return Tls.retireDial(backend, pending.conn);
            }
        };
        const DialRace = completion_dial_race.Machine(Self, Types, DialRaceAccess);
        pub const white_box = completion_dial_race.WhiteBox(Self, Types, DialRace);

        /// Heap-resident adapter state added by one live keyed-relay leg,
        /// excluding temporary buffer capacity and hash-table bucket overhead.
        /// Tests pin this exact cost so the scale path cannot grow unnoticed.
        pub const connection_state_bytes = @sizeOf(RelayConn);
        /// One WSS-only state allocation, including both fixed TLS record
        /// windows. The sparse map's bucket overhead is accounted separately.
        pub const secure_connection_state_bytes = @sizeOf(Types.TlsState);
        /// Transient state while one logical dial resolves and races a bounded
        /// address wave. The resolver job is separate because IP-literal dials
        /// never allocate it and hostname dials retire it before admission.
        pub const pending_dial_state_bytes = @sizeOf(PendingDial);
        pub const resolver_job_state_bytes = @sizeOf(completion_resolver.Job);
        pub const parallel_address_attempts = Types.max_parallel_dials;

        const ConnMap = Types.ConnMap;
        const PendingDialMap = Types.PendingDialMap;
        const RecvRetryQueue = Types.RecvRetryQueue;
        const CloseRetryQueue = Types.CloseRetryQueue;
        const TlsMap = Types.TlsMap;
        const TlsSendRetryQueue = Types.TlsSendRetryQueue;

        /// Distinguish payload buffers owned by this WebSocket adapter from
        /// recv buffers the wrapped platform backend reports for ordinary TCP
        /// connections. `Completion.borrowed.token` is backend-opaque; without the
        /// tag, recycling a delegated TCP completion would return its index to
        /// the relay pool and permanently consume the platform buffer.
        const RelayConfig = Types.RelayConfig;

        allocator: std.mem.Allocator,
        platform: Platform,
        relay: ?RelayConfig,
        ready: completion.ReadyQueue,
        buffer_pool: completion.BufferPool,
        /// Hard cap for bytes retained across wrapped recv completions: one
        /// whole platform buffer plus the largest header/control prefix it may
        /// complete. Ordinary payload is lent directly from the platform pool.
        raw_in_limit: usize,
        /// Total retained storage for one masked WebSocket send. Application
        /// writes are chunked behind this transport-owned memory commitment.
        send_staging_bytes: usize,
        conns: ConnMap = .{},
        pending_dials: PendingDialMap = .{},
        resolver: ?*completion_resolver.Runtime = null,
        resolver_wake_armed: bool = false,
        dial_close_retry_head: ?*PendingDial = null,
        dial_close_retry_tail: ?*PendingDial = null,
        dial_close_retry_count: usize = 0,
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
        /// Sparse secure-only state. Clear connections retain the historical
        /// `RelayConn` footprint; this table allocates only after a WSS dial.
        secure: TlsMap = .{},
        /// Secure writes whose platform submission was refused before
        /// admission. TLS state supplies intrusive links; no ciphertext moves.
        tls_send_retries: TlsSendRetryQueue = .{},
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
            var buffer_pool = try completion.BufferPool.init(allocator, read_buffers, read_buffer_bytes);
            errdefer buffer_pool.deinit();
            const raw_in_limit = std.math.add(
                usize,
                read_buffer_bytes,
                completion_buffers.steady_raw_in_bytes,
            ) catch
                return error.OutOfMemory;
            var relay: ?RelayConfig = null;
            var resolver: ?*completion_resolver.Runtime = null;
            if (relay_options) |options| {
                const url = options.url;
                const bytes = try allocator.dupe(u8, url);
                errdefer allocator.free(bytes);
                var tls = if (options.tls_owner) |owner|
                    try owner.lease()
                else
                    null;
                errdefer if (tls) |*lease| lease.release();
                relay = .{
                    .bytes = bytes,
                    .url = try RelayUrl.parse(bytes),
                    .tls = tls,
                };
                tls = null;
                if (options.resolver_io) |resolver_io|
                    resolver = try completion_resolver.Runtime.init(allocator, resolver_io);
            }
            return .{
                .allocator = allocator,
                .platform = platform,
                .relay = relay,
                .resolver = resolver,
                .ready = .{},
                .buffer_pool = buffer_pool,
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
            std.debug.assert(self.pending_dials.count() == 0);
            std.debug.assert(!self.resolver_wake_armed);
            std.debug.assert(self.dial_close_retry_count == 0);
            std.debug.assert(self.dial_close_retry_head == null);
            std.debug.assert(self.dial_close_retry_tail == null);
            std.debug.assert(self.recv_retries.count == 0);
            std.debug.assert(self.close_retries.count == 0);
            std.debug.assert(self.secure.count() == 0);
            std.debug.assert(self.tls_send_retries.count == 0);
            self.platform.deinit();
            self.conns.deinit(self.allocator);
            self.pending_dials.deinit(self.allocator);
            self.secure.deinit(self.allocator);
            self.buffer_pool.deinit();
            self.ready.deinit(self.allocator);
            if (self.resolver) |resolver| resolver.deinit();
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

        pub fn applyKeepalive(self: *Self, fd: Fd, keepalive: completion.Keepalive) !void {
            if (idFromFd(fd)) |id| {
                if (self.pending_dials.contains(id)) return error.ConnectionLost;
                const c = self.conns.get(id) orelse return error.FileDescriptorNotASocket;
                return self.platform.applyKeepalive(c.os_fd, keepalive);
            }
            return self.platform.applyKeepalive(fd, keepalive);
        }

        pub fn closeFd(self: *Self, fd: Fd) void {
            if (idFromFd(fd)) |id| if (self.pending_dials.get(id)) |pending| {
                DialRace.requestClose(self, pending, null);
                return;
            };
            Lifecycle.closeFd(self, fd);
        }

        pub fn shutdownFd(self: *Self, fd: Fd) void {
            if (idFromFd(fd)) |id| if (self.pending_dials.get(id)) |pending| {
                DialRace.requestClose(self, pending, null);
                return;
            };
            Lifecycle.shutdownFd(self, fd);
        }

        pub fn recycleBorrowed(self: *Self, comp: completion.Completion) void {
            if (Namespace.ownsBorrowToken(comp.borrowed.token)) {
                switch (comp.borrowed.kind) {
                    .recv => self.buffer_pool.release(@intCast(Namespace.borrowTokenPayload(comp.borrowed.token))),
                    .failure, .carrier_failure => {
                        const id: ConnId = @intCast(Namespace.borrowTokenPayload(comp.borrowed.token));
                        if (self.pending_dials.get(id)) |pending|
                            DialRace.recycleFailure(self, pending)
                        else {
                            Tls.recycleFailure(self, id);
                            if (self.conns.get(id)) |c| Lifecycle.maybeFinish(self, c);
                        }
                    },
                    .none => unreachable,
                }
            } else {
                self.platform.recycleBorrowed(comp);
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
                if (self.pending_dials.contains(id)) return error.ConnectionLost;
                const c = self.conns.get(id) orelse return error.ConnectionLost;
                if (c.state != .open) return error.ConnectionLost;
                if (c.external_recv_ud != null) return error.AlreadyReading;
                // Buffered bytes may reveal a protocol fault synchronously.
                // Reserve every external failure completion before installing
                // the caller's seat so `failRelay` remains infallible.
                try self.ready.ensureUnusedCapacity(self.allocator, Lifecycle.pendingExternalCount(c) + 1);
                errdefer c.external_recv_ud = null;
                c.external_recv_ud = user_data;
                try Receive.tryEmit(self, c);
                return;
            }
            try self.platform.submitRecv(user_data, fd);
        }

        pub fn submitSend(self: *Self, user_data: u64, fd: Fd, bytes: []const u8) !void {
            try Send.submit(self, user_data, fd, bytes);
        }

        pub fn submitCancel(
            self: *Self,
            cancel_user_data: u64,
            target_user_data: u64,
            fd: Fd,
        ) !void {
            if (idFromFd(fd)) |id| {
                if (self.pending_dials.contains(id)) return error.InvalidCancelTarget;
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
            if (idFromFd(fd)) |id| if (self.pending_dials.get(id)) |pending| {
                if (pending.external_close_ud != null) return error.AlreadyClosing;
                try self.ready.ensureUnusedCapacity(self.allocator, 2);
                DialRace.requestClose(self, pending, user_data);
                return;
            };
            try Lifecycle.submitClose(self, user_data, fd);
        }

        pub fn poll(self: *Self, out: []completion.Completion, timeout_ms: i32) !usize {
            if (self.resolver) |resolver| {
                while (resolver.takeCompleted()) |job|
                    DialRace.resolverCompleted(self, job);
                if (resolver.hasLiveJobs() and !self.resolver_wake_armed)
                    resolver.maintainWake(self, resolver_wake_ud);
            }
            DialRace.retryPendingCloses(self);
            Tls.retryPendingSends(self);
            Lifecycle.retryPendingCloses(self);
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
            const resolver_unarmed = if (self.resolver) |resolver|
                resolver.hasLiveJobs() and !self.resolver_wake_armed
            else
                false;
            const effective_timeout = if (has_ready)
                0
            else if (self.close_retries.count == 0 and self.tls_send_retries.count == 0 and
                self.dial_close_retry_count == 0 and !resolver_unarmed)
                timeout_ms
            else if (timeout_ms < 0)
                operation_retry_ms
            else
                @min(timeout_ms, operation_retry_ms);
            const n = try self.platform.poll(&tmp, effective_timeout);
            for (tmp[0..n]) |comp| {
                if (comp.user_data == resolver_wake_ud) {
                    self.resolver_wake_armed = false;
                    if (comp.borrowed.active()) self.platform.recycleBorrowed(comp);
                    const resolver = self.resolver orelse unreachable;
                    try resolver.drainWake();
                    while (resolver.takeCompleted()) |job|
                        DialRace.resolverCompleted(self, job);
                    if (resolver.hasLiveJobs()) resolver.maintainWake(self, resolver_wake_ud);
                } else if (isDialInternal(comp.user_data)) {
                    DialRace.dispatch(self, comp);
                } else if (isInternal(comp.user_data)) {
                    Dispatch.dispatch(self, comp) catch |err| {
                        const id = internalId(comp.user_data);
                        if (self.conns.get(id)) |c| {
                            const phase = Dispatch.failurePhase(c, comp);
                            if (Tls.has(self, c)) Tls.platformFailed(self, c, phase, .{
                                .user_data = comp.user_data,
                                .result = -1,
                                .failure = err,
                            }, err);
                            Lifecycle.failWith(self, c, phase, err);
                        }
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
            const secure_lease = if (relay_url.scheme.secure())
                if (self.relay) |relay| relay.tls orelse
                    return error.SecureCarrierUnavailable else return error.SecureCarrierUnavailable
            else
                null;
            const id = try DialIdentity.reserve(self);
            errdefer self.next_id = id;
            const fd = try fdFromId(id);
            try self.conns.ensureUnusedCapacity(self.allocator, 1);
            try self.pending_dials.ensureUnusedCapacity(self.allocator, 1);
            try self.ready.ensureUnusedCapacity(self.allocator, 2);
            const c = try self.allocator.create(RelayConn);
            errdefer self.allocator.destroy(c);
            c.* = .{
                .id = id,
                .os_fd = undefined,
                .external_connect_ud = user_data,
                .expected_accept = undefined,
            };
            errdefer c.deinit(self.allocator);
            if (secure_lease != null) try Tls.prepare(self, c);
            errdefer Tls.destroy(self, c);
            // Rendering completes synchronously, so no target-designator copy
            // belongs in the admitted connection's scale footprint.
            try Dispatch.buildUpgrade(self, c, relay_url, target.designator);
            const pending = try self.allocator.create(PendingDial);
            pending.* = .{ .id = id, .conn = c };
            self.pending_dials.putAssumeCapacity(id, pending);
            var admitted = true;
            errdefer if (admitted) {
                std.debug.assert(self.pending_dials.remove(id));
                self.allocator.destroy(pending);
            };
            if (std.Io.net.IpAddress.parse(relay_url.host, relay_url.port)) |address| {
                try DialRace.startLiteral(self, pending, address);
            } else |_| {
                const resolver = self.resolver orelse return error.ResolverUnavailable;
                pending.resolver_job = try resolver.start(id, relay_url.host, relay_url.port);
                resolver.maintainWake(self, resolver_wake_ud);
            }
            if (secure_lease) |lease| switch (lease.open(relay_url.host)) {
                .client => |client| Tls.adoptClient(self, c, client),
                .failed => |failure| {
                    Tls.abandonPending(self, c);
                    DialRace.failAdmitted(
                        self,
                        pending,
                        Types.TlsState.fromTlsFailure(failure),
                    );
                    admitted = false;
                    return fd;
                },
            };
            admitted = false;
            return fd;
        }

        fn adoptDialWinner(self: *Self, pending: *PendingDial, winner_fd: Fd) void {
            const c = pending.conn;
            c.os_fd = winner_fd;
            self.conns.putAssumeCapacity(c.id, c);
            self.allocator.destroy(pending);
            Dispatch.connected(self, c) catch |err| {
                Lifecycle.failWith(self, c, .websocket_upgrade, err);
                Lifecycle.beginPlatformClose(self, c);
            };
        }

        fn destroyPendingDial(self: *Self, pending: *PendingDial) void {
            Tls.destroy(self, pending.conn);
            pending.conn.deinit(self.allocator);
            self.allocator.destroy(pending.conn);
            self.allocator.destroy(pending);
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

        fn fdFromId(id: ConnId) error{AdapterHandleExhausted}!Fd {
            return Types.fdFromId(id);
        }

        fn idFromFd(fd: Fd) ?ConnId {
            return Types.idFromFd(fd);
        }

        fn internalUd(op: InternalOp, id: ConnId) u64 {
            return Types.internalUd(op, id);
        }

        fn isInternal(ud: u64) bool {
            return Types.isInternal(ud);
        }

        fn isDialInternal(ud: u64) bool {
            return DialIdentity.owns(ud);
        }

        fn internalId(ud: u64) ConnId {
            return Types.internalId(ud);
        }

        fn internalOp(ud: u64) InternalOp {
            return Types.internalOp(ud);
        }
    };
}
