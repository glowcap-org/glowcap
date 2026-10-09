//! Completion-backed keyed-relay dials.
//!
//! This adapter owns synthetic handles, wrapped platform operations, bounded
//! parser spill, and WebSocket send storage. Blocking std.Io ownership lives in
//! resident.zig; this file never constructs a reader or blocks a thread.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const carrier_failure = @import("../../carrier_failure.zig");
const completion = @import("../../completion/loop.zig");
const protocol = @import("../../websocket.zig").client_protocol;
const completion_buffers = @import("completion/buffers.zig");
const completion_dial_race = @import("completion/dial_race.zig");
const completion_dial_identity = @import("completion/dial_identity.zig");
const completion_leg_start = @import("completion/leg_start.zig");
const completion_machines = @import("completion/machines.zig");
const completion_poll = @import("completion/poll.zig");
const completion_registration = @import("completion/registration.zig");
const completion_resolver = @import("completion/resolver.zig");
const completion_state = @import("completion/state.zig");
const completion_options = @import("completion/options.zig");
const dial_resolver = @import("completion/target.zig");
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
pub const ResidentPolicy = @import("completion/resident_policy.zig").ResidentPolicy;

/// A host-platform completion backend with native keyed-relay dials and, when
/// configured with a registration, a listener that accepts dialers through
/// the relay. Ordinary TCP dials and listeners delegate straight to `Platform`.
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
        pub const ListenerAddress = union(enum) {
            platform: Platform.ListenerAddress,
            /// Dialers reach this listener through the relay registration.
            relay,
        };

        const ConnId = Types.ConnId;
        const InternalOp = Types.InternalOp;
        const Identity = Types.Identity;
        const State = Types.State;
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

            pub fn promoteParked(backend: *Self, c: *RelayConn) void {
                Registration.promote(backend, c);
            }

            pub fn isRegistrationLeg(backend: *const Self, id: ConnId) bool {
                return backend.registration.isLeg(id);
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
                LegStart.adoptWinner(backend, pending, fd);
            }

            pub fn destroyPending(backend: *Self, pending: *PendingDial) void {
                LegStart.destroyPending(backend, pending);
            }

            pub fn retirePending(
                backend: *Self,
                pending: *PendingDial,
            ) ?carrier_failure.Failure {
                return Tls.retireDial(backend, pending.conn);
            }
        };
        const DialRace = completion_dial_race.Machine(Self, Types, DialRaceAccess);
        const LegStart = completion_leg_start.Machine(Self, Types, MachineSet, DialRace, resolver_wake_ud);
        const Registration = completion_registration.Machine(
            Self,
            Types,
            Namespace,
            LegStart,
            operation_retry_ms,
        );
        pub const white_box = completion_dial_race.WhiteBox(Self, Types, DialRace);
        const PollAccess = struct {
            pub fn armPlatformRecv(backend: *Self, c: *RelayConn) !void {
                try backend.armPlatformRecv(c);
            }

            pub fn retryPendingDialCloses(backend: *Self) void {
                DialRace.retryPendingCloses(backend);
            }

            pub fn retryPendingSecureSends(backend: *Self) void {
                Tls.retryPendingSends(backend);
            }

            pub fn retryPendingCloses(backend: *Self) void {
                Lifecycle.retryPendingCloses(backend);
            }

            pub fn serviceRegistration(backend: *Self) void {
                Registration.service(backend);
            }

            pub fn registrationWaitMs(backend: *const Self) ?i32 {
                return Registration.waitMs(backend);
            }

            pub fn resolverCompleted(backend: *Self, job: *completion_resolver.Job) void {
                DialRace.resolverCompleted(backend, job);
            }

            pub fn isDialInternal(user_data: u64) bool {
                return DialIdentity.owns(user_data);
            }

            pub fn isInternal(user_data: u64) bool {
                return Identity.owns(user_data);
            }

            pub fn dispatchDial(backend: *Self, comp: completion.Completion) void {
                DialRace.dispatch(backend, comp);
            }

            pub fn dispatchInternal(backend: *Self, comp: completion.Completion) void {
                Dispatch.dispatch(backend, comp) catch |err| {
                    const id = internalId(comp.user_data);
                    if (backend.conns.get(id)) |c| {
                        const phase = Dispatch.failurePhase(c, comp);
                        if (Tls.has(backend, c)) Tls.platformFailed(backend, c, phase, .{
                            .user_data = comp.user_data,
                            .result = -1,
                            .failure = err,
                        }, err);
                        Lifecycle.failWith(backend, c, phase, err);
                    }
                };
            }
        };
        const Poll = completion_poll.Machine(
            Self,
            PollAccess,
            operation_retry_ms,
            resolver_wake_ud,
        );

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
        registration: completion_registration.State,
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
            var registration: completion_registration.State = .{};
            errdefer registration.deinit(allocator);
            if (relay_options) |options| {
                registration = try .init(allocator, options.registration);
                // A registration that could never start is refused here, so
                // the listener's retry only ever waits out the relay.
                if (registration.config) |config| {
                    if (config.url.scheme.secure() and options.tls_owner == null)
                        return error.SecureCarrierUnavailable;
                    const literal = if (std.Io.net.IpAddress.parse(config.url.host, config.url.port)) |_| true else |_| false;
                    if (!literal and options.resolver_io == null) return error.ResolverUnavailable;
                }
                if (options.resolver_io) |resolver_io|
                    resolver = try completion_resolver.Runtime.init(allocator, resolver_io);
                errdefer if (resolver) |runtime| runtime.deinit();
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
            }
            return .{
                .allocator = allocator,
                .platform = platform,
                .relay = relay,
                .resolver = resolver,
                .registration = registration,
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
                    @as([std.Random.DefaultCsprng.secret_seed_length]u8, @splat(0))),
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
            self.registration.deinit(self.allocator);
        }

        /// Delegate the wrapped Linux TCP backend selection.
        pub fn tcpBackendStatus(self: *const Self) @TypeOf(self.platform.tcpBackendStatus()) {
            return self.platform.tcpBackendStatus();
        }

        /// Listen through the relay registration when one is configured, or
        /// on the platform port otherwise.
        /// Adapter work that completes off the caller's thread reaches this
        /// backend through a platform operation, so the platform's descriptor
        /// reports it; work that completes synchronously waits in the ready
        /// queue for the caller's next `poll`.
        pub fn readinessFd(self: *const Self) Fd {
            return self.platform.readinessFd();
        }

        pub fn flush(self: *Self) !void {
            return self.platform.flush();
        }

        pub fn submitPoll(self: *Self, user_data: u64, fd: Fd, interest: completion.Interest) !void {
            return self.platform.submitPoll(user_data, fd, interest);
        }

        pub fn waitBoundMs(self: *const Self, requested_ms: i32) i32 {
            return Poll.waitBound(self, self.platform.waitBoundMs(requested_ms));
        }

        pub fn listenerIp4(self: *const Self) [4]u8 {
            return self.platform.listenerIp4();
        }

        /// The relay arm registers the listening Host's key, so a backend
        /// holds at most one relay listener; it needs `Options.registration`.
        pub const ListenTarget = union(enum) {
            platform: Platform.ListenTarget,
            relay: crypto.PeerKey,
        };

        pub fn loopListenTarget(port: u16) ListenTarget {
            return .{ .platform = Platform.loopListenTarget(port) };
        }

        pub fn openListener(self: *Self, target: ListenTarget) !Fd {
            switch (target) {
                .platform => |platform_target| return self.platform.openListener(platform_target),
                .relay => |identity| {
                    if (self.registration.config == null) return error.RelayRegistrationNotConfigured;
                    return Registration.open(self, identity);
                },
            }
        }

        pub fn listenerAddress(self: *Self, fd: Fd) !ListenerAddress {
            if (fd == Registration.listen_fd) return .relay;
            return .{ .platform = try self.platform.listenerAddress(fd) };
        }

        pub fn listenerPort(address: ListenerAddress) ?u16 {
            return switch (address) {
                .platform => |platform| Platform.listenerPort(platform),
                .relay => null,
            };
        }

        pub fn verifiedChannelKey(self: *Self, fd: Fd) ?[crypto.PEER_KEY_BYTES]u8 {
            if (idFromFd(fd) != null) return null;
            return self.platform.verifiedChannelKey(fd);
        }

        pub fn applyKeepalive(self: *Self, fd: Fd, keepalive: completion.Keepalive) !void {
            if (idFromFd(fd)) |id| {
                if (self.pending_dials.contains(id)) return error.ConnectionLost;
                const c = self.conns.get(id) orelse return error.FileDescriptorNotASocket;
                return self.platform.applyKeepalive(c.inner_fd, keepalive);
            }
            return self.platform.applyKeepalive(fd, keepalive);
        }

        pub fn wireFraming(self: *Self, fd: Fd) model.transport.WireFraming {
            if (idFromFd(fd) != null) return .byte_stream;
            return self.platform.wireFraming(fd);
        }

        pub fn closeFd(self: *Self, fd: Fd) void {
            if (fd == Registration.listen_fd) return Registration.release(self);
            if (idFromFd(fd)) |id| if (self.pending_dials.get(id)) |pending| {
                DialRace.requestClose(self, pending, null);
                return;
            };
            Lifecycle.closeFd(self, fd);
        }

        pub fn shutdownFd(self: *Self, fd: Fd) void {
            // The registration's close retires its legs; there is no socket.
            if (fd == Registration.listen_fd) return;
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
            if (listen_fd == Registration.listen_fd) return Registration.submitAccept(self, user_data);
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
            if (fd == Registration.listen_fd) return Registration.submitClose(self, user_data);
            if (idFromFd(fd)) |id| if (self.pending_dials.get(id)) |pending| {
                if (pending.external_close_ud != null) return error.AlreadyClosing;
                try self.ready.ensureUnusedCapacity(self.allocator, 2);
                DialRace.requestClose(self, pending, user_data);
                return;
            };
            try Lifecycle.submitClose(self, user_data, fd);
        }

        pub fn poll(self: *Self, out: []completion.Completion, timeout_ms: i32) !usize {
            return Poll.poll(self, out, timeout_ms);
        }

        fn startRelayDial(self: *Self, user_data: u64, target: @FieldType(ConnectTarget, "keyed_relay")) !Fd {
            const relay_url = target.relay orelse if (self.relay) |relay| relay.url else return error.NoRendezvousConfigured;
            if (crypto.PeerKey.fromDesignator(target.designator) == null) return error.InvalidAddress;
            return LegStart.start(self, .{
                .url = relay_url,
                .leg = .rendezvous,
                .query_value = target.designator,
                .connect_ud = user_data,
            });
        }

        fn armPlatformRecv(self: *Self, c: *RelayConn) !void {
            if (c.pending.get(.recv) or c.state == .closing) return;
            try self.platform.submitRecv(internalUd(.recv, c.id), c.inner_fd);
            c.pending.arm(.recv);
        }

        fn idFromFd(fd: Fd) ?ConnId {
            return Identity.idFromFd(fd);
        }

        fn internalUd(op: InternalOp, id: ConnId) u64 {
            return Identity.userData(op, id);
        }

        fn internalId(ud: u64) ConnId {
            return Identity.id(ud);
        }

        fn internalOp(ud: u64) InternalOp {
            return Identity.op(ud);
        }
    };
}
