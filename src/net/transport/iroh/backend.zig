//! The iroh completion backend: adapts the sidecar's endpoint and connection
//! verbs to `net.completion`'s backend contract, so the loop drives QUIC
//! streams the way it drives sockets and reads the authenticated node id as
//! the realizer proof.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const net = @import("net");
const sidecar = @import("sidecar.zig");
const locators = @import("locators.zig");
const policy = @import("policy.zig");
const resident_owner = @import("resident.zig");

const crypto = foundation.crypto;
const completion = net.completion;
const BufferPool = completion.BufferPool;
const CEndpoint = sidecar.CEndpoint;
const CConn = sidecar.CConn;
const ReadyEvent = sidecar.ReadyEvent;
const Resident = resident_owner.Resident;
const would_block = sidecar.would_block;
const ev_readable = sidecar.ev_readable;
const ev_writable = sidecar.ev_writable;
const ev_closed = sidecar.ev_closed;
const ev_accept = sidecar.ev_accept;
const ev_connect = sidecar.ev_connect;
const connRemoteKey = sidecar.connRemoteKey;

// ── Completion backend: many iroh connections on one `completion.Loop` (ADR-0019) ─

/// An iroh completion adapter over `Platform`. The sidecar's one readiness fd
/// and non-blocking try-I/O share the wrapped backend's wait primitive with
/// delegated transports, so one completion resident and Host action consumer
/// can drive all of them.
///
/// Construct with `initBound` over a `Resident`'s endpoint, then
/// `completion.Loop(Backend, DialResolver).initWithBackend`. `initBound` builds
/// the ordinary platform backend. `initBoundWithPlatform` accepts a configured
/// adapter such as keyed-relay. Iroh and stopper readiness are ordinary
/// nonblocking recv operations on borrowed descriptors owned by the resident
/// and wake channel respectively.
pub fn CompletionBackend(comptime Platform: type) type {
    return struct {
        const Self = @This();
        const Namespace = completion.AdapterNamespace(Platform);
        pub const Fd = Platform.Fd;
        pub const adapter_depth = Namespace.depth;
        pub const ListenerAddress = void;
        pub const ConnectTarget = union(enum) {
            iroh: locators.ConnectTarget,
            platform: Platform.ConnectTarget,
        };

        /// Sentinel listen handle: not an OS fd. `openListener` returns it after
        /// arming non-blocking accept on the endpoint.
        pub const listen_fd: Fd = Namespace.fdFromComptimeId(0);

        const Signal = enum(u1) { readiness, wake };

        const ConnEntry = struct {
            cconn: *CConn,
            pending: completion.HintedPending = .{},
        };

        /// One loop connection's adapter row: the sidecar handle beside the
        /// seats, hints, and terminal cause every multiplexed sidecar backend
        /// shares. Tests pin this exact cost so the scale path cannot grow
        /// unnoticed.
        pub const connection_state_bytes = @sizeOf(ConnEntry);

        /// How the shared try-I/O machine reaches this sidecar. An admitted
        /// read or write holds its ready-queue seat until it completes.
        const TryIoOps = struct {
            pub const Entry = ConnEntry;
            pub const holds_admission_seat = true;

            pub fn tryRead(entry: *ConnEntry, buf: []u8) completion.TryRead {
                const n = sidecar.glowcap_iroh_sidecar_conn_try_read(entry.cconn, buf.ptr, buf.len);
                if (n == would_block) return .would_block;
                // A count past the buffer is the sidecar breaking its
                // contract, never bytes to read.
                if (n > buf.len) return .{ .failed = error.IrohSidecarContract };
                if (n > 0) return .{ .transferred = @intCast(n) };
                // 0 = clean EOF, negative = fault.
                if (n == 0) return .closed;
                return .{ .failed = error.IrohReadFailed };
            }

            pub fn tryWrite(entry: *ConnEntry, bytes: []const u8) completion.TryWrite {
                const n = sidecar.glowcap_iroh_sidecar_conn_try_write(entry.cconn, bytes.ptr, bytes.len);
                if (n == would_block) return .would_block;
                if (n > bytes.len) return .{ .failed = error.IrohSidecarContract };
                if (n > 0) return .{ .transferred = @intCast(n) };
                return .{ .failed = error.IrohWriteFailed };
            }

            /// A faulted QUIC connection needs no separate close: the sidecar
            /// answers every later try verb with the fault, and `closeFd`
            /// frees the handle.
            pub fn closeOnFailure(_: *ConnEntry) void {}

            pub fn borrowToken(index: u32) u32 {
                return Namespace.borrowToken(index);
            }

            pub fn reserveSeats(backend: *Self, count: usize) !void {
                try backend.ready.reserve(backend.allocator, count);
            }

            pub fn publish(backend: *Self, item: completion.Completion) void {
                backend.ready.appendReserved(item);
            }
        };
        const TryIo = completion.HintedTryIo(Self, TryIoOps);

        const max_accept_stash = policy.accept_queue_bound;
        /// One pointer per admitted accept seat, reserved once per endpoint so
        /// readiness consumption remains allocation-free. On 64-bit targets
        /// this is a named 1 KiB heap cost, never a per-connection allocation.
        const accept_stash_bytes = max_accept_stash * @sizeOf(*CConn);

        allocator: std.mem.Allocator,
        platform: Platform,
        /// Borrowed. Must outlive the backend.
        resident: *Resident,
        endpoint: *CEndpoint,
        readiness_fd: Fd,
        accept_enabled: bool = false,
        readiness_armed: bool = false,
        /// Completions that need no further readiness (closes, immediate accepts
        /// from the stash, hint-satisfied recv/send, drained dials), drained before blocking.
        ready: completion.ReadyQueue = .{},
        /// Queue seats owned by admitted iroh operations that have not completed
        /// yet. Capacity is not a reservation: two pending operations both status-allow: pending state or quoted runtime label
        /// calling ensureUnusedCapacity(1) can claim the same last slot. This
        /// count makes admission cumulative and lets completion stay infallible
        /// after sidecar bytes or an event have been consumed.
        /// Accepted connections waiting for a `submitAccept` to claim them, edge-
        /// triggered accept can queue several before the loop re-arms.
        accept_stash: std.ArrayList(*CConn) = .empty,
        accept_ud: ?u64 = null,
        /// Synthetic fd to sidecar connection. Fd 0 is the listen sentinel.
        conns: std.AutoHashMap(Fd, ConnEntry),
        /// Sidecar stable connection identity to synthetic fd, for readiness records.
        by_id: std.AutoHashMap(usize, Fd),
        /// Reserved synthetic fd to connect completion user data. The fd is also the
        /// sidecar request id, making cancellation and retirement addressable.
        pending_dials: std.AutoHashMap(Fd, u64),
        /// Stopper wake polled beside the sidecar readiness fd. Iroh readiness is
        /// owned by the sidecar. Loop-owner cancellation is a separate userspace
        /// event and should not ride a timeout-polled side channel. The adapter
        /// drains this channel itself after the platform reports readability, so
        /// coalesced nudges cost one owner turn rather than one completion each.
        wake_channel: net.wake_channel.WakeChannel,
        wake_failure: net.wake_channel.FailureLatch = .{},
        wake_fd: Fd,
        wake_armed: bool = false,
        next_id: u32 = 1,
        buffer_pool: BufferPool,

        /// Bind a backend to `resident`'s endpoint. The resident must outlive the
        /// loop and be driven by no other consumer for accept/connection I/O.
        pub fn initBound(
            allocator: std.mem.Allocator,
            resident: *Resident,
            queue_entries: u16,
            read_buffers: u16,
            read_buffer_bytes: u32,
        ) !Self {
            const platform = try Platform.init(allocator, queue_entries, read_buffers, read_buffer_bytes);
            return initBoundWithPlatform(allocator, resident, platform, read_buffers, read_buffer_bytes);
        }

        /// Bind iroh over an already-configured platform adapter. Ownership of
        /// `platform` transfers on entry, including every error path.
        pub fn initBoundWithPlatform(
            allocator: std.mem.Allocator,
            resident: *Resident,
            platform: Platform,
            read_buffers: u16,
            read_buffer_bytes: u32,
        ) !Self {
            var owned_platform = platform;
            errdefer owned_platform.deinit();
            const wake_channel = try net.wake_channel.WakeChannel.open();
            errdefer wake_channel.deinit();
            var buffer_pool = try BufferPool.init(allocator, read_buffers, read_buffer_bytes);
            errdefer buffer_pool.deinit();
            var accept_stash: std.ArrayList(*CConn) = .empty;
            try accept_stash.ensureTotalCapacity(allocator, max_accept_stash);
            errdefer accept_stash.deinit(allocator);
            std.debug.assert(accept_stash.capacity * @sizeOf(*CConn) >= accept_stash_bytes);
            const readiness_source = sidecar.glowcap_iroh_sidecar_endpoint_readiness_fd(resident.endpoint);
            if (readiness_source < 0) return error.ListenFailed;

            return .{
                .allocator = allocator,
                .platform = owned_platform,
                .resident = resident,
                .endpoint = resident.endpoint,
                .readiness_fd = readiness_source,
                .accept_stash = accept_stash,
                .conns = std.AutoHashMap(Fd, ConnEntry).init(allocator),
                .by_id = std.AutoHashMap(usize, Fd).init(allocator),
                .pending_dials = std.AutoHashMap(Fd, u64).init(allocator),
                .wake_channel = wake_channel,
                .wake_fd = wake_channel.read,
                .buffer_pool = buffer_pool,
            };
        }

        pub fn deinit(self: *Self) void {
            var pending_it = self.pending_dials.keyIterator();
            while (pending_it.next()) |fd| self.cancelDial(Namespace.fdId(fd.*));
            self.pending_dials.deinit();

            var it = self.conns.iterator();
            while (it.next()) |entry| {
                sidecar.glowcap_iroh_sidecar_conn_free(entry.value_ptr.cconn);
            }
            self.conns.deinit();
            self.by_id.deinit();
            for (self.accept_stash.items) |cconn| sidecar.glowcap_iroh_sidecar_conn_free(cconn);
            self.accept_stash.deinit(self.allocator);
            self.platform.deinit();
            self.wake_channel.deinit();
            self.ready.deinit(self.allocator);
            self.buffer_pool.deinit();
        }

        /// Delegate the wrapped Linux TCP backend selection.
        pub fn tcpBackendStatus(self: *const Self) @TypeOf(self.platform.tcpBackendStatus()) {
            return self.platform.tcpBackendStatus();
        }

        /// Wake a parked `poll` so owner-thread stop or teardown state can be
        /// observed without timeout polling. Carries no authority and records no
        /// transport readiness. The next harvest drains the nudge and then observes
        /// the state the caller already changed.
        pub fn wake(self: *Self) net.wake_channel.Failure!void {
            try self.wake_failure.check();
            _ = self.wake_channel.nudge() catch |err| {
                self.wake_failure.record(err);
                return err;
            };
        }

        /// An endpoint accepts on its node id. There is nothing to choose.
        pub const ListenTarget = void;

        pub fn loopListenTarget(_: u16) ListenTarget {}

        pub fn openListener(self: *Self, _: ListenTarget) !Fd {
            if (sidecar.glowcap_iroh_sidecar_endpoint_set_nonblocking_accept(self.endpoint) != 0)
                return error.ListenFailed;
            self.accept_enabled = true;
            return listen_fd;
        }

        /// The accept endpoint is enabled when `openListener` returns;
        /// nothing pends.
        pub fn listenerPending(self: *const Self, _: Fd) bool {
            _ = self;
            return false;
        }

        /// Start an outbound dial in the layer that resolved it. Iroh reserves a
        /// synthetic handle immediately. Delegated targets retain the wrapped
        /// backend's handle and completion semantics unchanged.
        pub fn startDial(self: *Self, user_data: u64, target: Self.ConnectTarget) !Fd {
            return switch (target) {
                .platform => |platform_target| self.platform.startDial(user_data, platform_target),
                .iroh => |iroh_target| blk: {
                    try self.ready.reserve(self.allocator, 1);
                    errdefer self.ready.release(1);
                    const fd = try self.reserveFd();
                    try self.pending_dials.put(fd, user_data);
                    errdefer std.debug.assert(self.pending_dials.remove(fd));
                    try self.resident.loopStartConnectResolved(Namespace.fdId(fd), iroh_target.id, iroh_target.hints);
                    break :blk fd;
                },
            };
        }

        pub fn listenerAddress(_: *Self, fd: Fd) !ListenerAddress {
            if (fd != listen_fd) return error.InvalidListener;
        }

        pub fn listenerPort(_: ListenerAddress) ?u16 {
            return null;
        }

        pub fn applyKeepalive(self: *Self, fd: Fd, keepalive: completion.Keepalive) !void {
            if (Namespace.ownsFd(fd)) return error.OperationUnsupported;
            return self.platform.applyKeepalive(fd, keepalive);
        }

        pub fn wireFraming(self: *Self, fd: Fd) model.transport.WireFraming {
            if (Namespace.ownsFd(fd)) return .byte_stream;
            return self.platform.wireFraming(fd);
        }

        /// Release one owned descriptor. The loop calls this with nothing in
        /// flight and `submitClose` settles every pending seat first, so like
        /// its sibling adapters this asserts that rather than publishing.
        pub fn closeFd(self: *Self, fd: Fd) void {
            if (!Namespace.ownsFd(fd)) return self.platform.closeFd(fd);
            if (fd == listen_fd) return;
            std.debug.assert(!self.pending_dials.contains(fd));
            const entry = self.conns.getPtr(fd) orelse return;
            std.debug.assert(entry.pending.read_ud == null and entry.pending.write_ud == null);
            std.debug.assert(self.by_id.remove(self.resident.loopConnId(entry.cconn)));
            sidecar.glowcap_iroh_sidecar_conn_free(entry.cconn);
            std.debug.assert(self.conns.remove(fd));
        }

        pub fn shutdownFd(self: *Self, fd: Fd) void {
            if (!Namespace.ownsFd(fd)) self.platform.shutdownFd(fd);
        }

        pub fn recycleBorrowed(self: *Self, comp: completion.Completion) void {
            if (Namespace.ownsBorrowToken(comp.borrowed.token)) {
                self.buffer_pool.release(@intCast(Namespace.borrowTokenPayload(comp.borrowed.token)));
            } else {
                self.platform.recycleBorrowed(comp);
            }
        }

        /// Synthetic ids here never wrap, unlike the wrapped relay and onion
        /// legs: an id doubles as the sidecar request id a dial is
        /// canceled and finished under, so a reused id could let a stale
        /// sidecar record name a fresh dial.
        fn reserveFd(self: *Self) !Fd {
            if (self.next_id == 0 or self.next_id > Namespace.max_fd_id) return error.OutOfFds;
            const id = self.next_id;
            self.next_id += 1;
            return Namespace.fdFromId(id);
        }

        /// Cancellation publishes a terminal sidecar dial record. Consume it
        /// immediately: the adapter has already turned the cancellation into
        /// the Loop's user completion, so leaving the sidecar record around
        /// would retain one entry per canceled dial until endpoint teardown.
        fn cancelDial(self: *Self, request_id: usize) void {
            self.resident.loopCancelConnect(request_id);
        }

        fn bindFd(self: *Self, fd: Fd, cconn: *CConn) !void {
            // Fresh connections are writable; seed the hint so the first hello
            // send is not stranded if a writable edge fired before by_id
            // registration (edge-triggered readiness drops unknown conns).
            try self.conns.put(fd, .{ .cconn = cconn, .pending = .{ .writable_hint = true } });
            errdefer std.debug.assert(self.conns.remove(fd));
            const conn_id = self.resident.loopConnId(cconn);
            if (conn_id == 0) return error.InvalidConnId;
            try self.by_id.put(conn_id, fd);
        }

        fn allocFd(self: *Self, cconn: *CConn) !Fd {
            const fd = try self.reserveFd();
            try self.bindFd(fd, cconn);
            return fd;
        }

        fn takeAccept(self: *Self) void {
            if (!self.accept_enabled) return;
            const ud = self.accept_ud orelse return;
            if (self.accept_stash.items.len == 0) return;
            const cconn = self.accept_stash.orderedRemove(0);
            const fd = self.allocFd(cconn) catch |err| {
                sidecar.glowcap_iroh_sidecar_conn_free(cconn);
                self.ready.appendReserved(.{ .user_data = ud, .result = -1, .failure = err });
                self.accept_ud = null;
                return;
            };
            self.ready.appendReserved(.{ .user_data = ud, .result = 0, .accepted_fd = fd });
            self.accept_ud = null;
        }

        fn stashAccepts(self: *Self) void {
            while (sidecar.glowcap_iroh_sidecar_endpoint_try_accept(self.endpoint)) |cconn| {
                if (!self.accept_enabled) {
                    sidecar.glowcap_iroh_sidecar_conn_free(cconn);
                    continue;
                }
                if (self.accept_stash.items.len >= max_accept_stash) {
                    // Overload policy: the Zig-side stash is the admission boundary
                    // for accepted loop connections. Drop excess accepts and keep
                    // the backend live; sidecar producer queues are bounded too.
                    sidecar.glowcap_iroh_sidecar_conn_free(cconn);
                    continue;
                }
                if (sidecar.glowcap_iroh_sidecar_conn_set_nonblocking(self.endpoint, cconn) != 0) {
                    sidecar.glowcap_iroh_sidecar_conn_free(cconn);
                    continue;
                }
                self.accept_stash.appendAssumeCapacity(cconn);
            }
        }

        /// The QUIC-authenticated remote endpoint key for `fd`'s connection, or
        /// null when the connection is gone or the proof cannot be read. This is
        /// the evidence `completion.Loop.verifiedChannelKey` forwards to the bridge,
        /// which asserts it to the engine before the connection's first byte feeds
        /// (ADR-0028). Socket backends have no such decl and the loop answers null
        /// for them.
        pub fn verifiedChannelKey(self: *Self, fd: Fd) ?[crypto.peer_key_bytes]u8 {
            if (!Namespace.ownsFd(fd)) return self.platform.verifiedChannelKey(fd);
            const entry = self.conns.getPtr(fd) orelse return null;
            const key = connRemoteKey(entry.cconn) orelse return null;
            return key.bytes;
        }

        pub fn submitAccept(self: *Self, user_data: u64, listen: Fd) !void {
            if (!Namespace.ownsFd(listen)) return self.platform.submitAccept(user_data, listen);
            if (listen != listen_fd) return error.InvalidListenFd;
            if (!self.accept_enabled) return error.ListenerClosed;
            if (self.accept_ud != null) return error.AlreadyAccepting;
            try self.ready.reserve(self.allocator, 1);
            self.accept_ud = user_data;
            self.stashAccepts();
            self.takeAccept();
        }

        pub fn submitRecv(self: *Self, user_data: u64, fd: Fd) !void {
            if (!Namespace.ownsFd(fd)) return self.platform.submitRecv(user_data, fd);
            return TryIo.submitRecv(self, user_data, fd);
        }

        pub fn submitSend(self: *Self, user_data: u64, fd: Fd, bytes: []const u8) !void {
            if (!Namespace.ownsFd(fd)) return self.platform.submitSend(user_data, fd, bytes);
            return TryIo.submitSend(self, user_data, fd, bytes);
        }

        pub fn submitCancel(
            self: *Self,
            cancel_user_data: u64,
            target_user_data: u64,
            fd: Fd,
        ) !void {
            if (!Namespace.ownsFd(fd))
                return self.platform.submitCancel(cancel_user_data, target_user_data, fd);
            return TryIo.submitCancel(self, cancel_user_data, target_user_data, fd);
        }

        pub fn submitClose(self: *Self, user_data: u64, fd: Fd) !void {
            if (!Namespace.ownsFd(fd)) return self.platform.submitClose(user_data, fd);
            // Every pending accept, dial, read, or write already owns one seat
            // in the ready queue from its admission. Closing publishes those
            // cancellation records against their existing seats; reserve only
            // the one additional record introduced by this close operation.
            try self.ready.reserve(self.allocator, 1);
            if (fd == listen_fd) {
                // Cancel a pending accept so Loop.closeAndDrain cannot hang on an
                // idle acceptor; the listen sentinel is not a real conn entry.
                self.accept_enabled = false;
                if (self.accept_ud) |ud| {
                    self.ready.appendReserved(.{ .user_data = ud, .result = -1 });
                    self.accept_ud = null;
                }
                for (self.accept_stash.items) |cconn| sidecar.glowcap_iroh_sidecar_conn_free(cconn);
                self.accept_stash.clearRetainingCapacity();
                self.stashAccepts();
                self.ready.appendReserved(.{ .user_data = user_data, .result = 0 });
                return;
            }
            if (self.pending_dials.fetchRemove(fd)) |done| {
                self.cancelDial(Namespace.fdId(fd));
                self.ready.appendReserved(.{ .user_data = done.value, .result = -1 });
                self.ready.appendReserved(.{ .user_data = user_data, .result = 0 });
                return;
            }
            if (self.conns.getPtr(fd)) |entry| {
                if (entry.pending.read_ud) |ud| self.ready.appendReserved(.{ .user_data = ud, .result = -1 });
                if (entry.pending.write_ud) |ud| self.ready.appendReserved(.{ .user_data = ud, .result = -1 });
                entry.pending = .{};
            }
            self.closeFd(fd);
            self.ready.appendReserved(.{ .user_data = user_data, .result = 0 });
        }

        fn dispatchReady(self: *Self, ev: ReadyEvent) void {
            if (ev.events & ev_accept != 0) {
                self.stashAccepts();
                self.takeAccept();
                return;
            }
            if (ev.events & ev_connect != 0) {
                const request_id = std.math.cast(u32, ev.subject) orelse return;
                // tolerant: a subject that maps to no descriptor is a stale
                // event; drop it.
                const fd = Namespace.fdFromId(request_id) catch return;
                const done = self.pending_dials.fetchRemove(fd) orelse return;
                // Text declined: a chain's name bytes must outlive the loop's copy.
                const opaque_conn = self.resident.loopFinishConnect(ev.subject, null) catch |err| {
                    self.ready.appendReserved(.{ .user_data = done.value, .result = -1, .failure = err });
                    return;
                };
                const cconn: *CConn = @ptrCast(opaque_conn);
                self.bindFd(fd, cconn) catch |err| {
                    sidecar.glowcap_iroh_sidecar_conn_free(cconn);
                    self.ready.appendReserved(.{ .user_data = done.value, .result = -1, .failure = err });
                    return;
                };
                self.ready.appendReserved(.{ .user_data = done.value, .result = 0 });
                return;
            }
            const fd = self.by_id.get(ev.subject) orelse return;
            const entry = self.conns.getPtr(fd) orelse return;
            if (ev.events & (ev_readable | ev_closed) != 0) {
                entry.pending.readable_hint = true;
                if (entry.pending.read_ud != null) TryIo.completeRecv(self, entry);
            }
            if (ev.events & (ev_writable | ev_closed) != 0) {
                entry.pending.writable_hint = true;
                if (entry.pending.write_ud != null) TryIo.completeSend(self, entry);
            }
        }

        fn takeReady(self: *Self, out: []completion.Completion) usize {
            return self.ready.drain(out);
        }

        fn signalUserData(signal: Signal) u64 {
            return Namespace.userData(@backingInt(signal));
        }

        fn armSignals(self: *Self) !void {
            if (!self.readiness_armed) {
                try self.platform.submitRecv(signalUserData(.readiness), self.readiness_fd);
                self.readiness_armed = true;
            }
            if (!self.wake_armed) {
                try self.platform.submitRecv(signalUserData(.wake), self.wake_fd);
                self.wake_armed = true;
            }
        }

        /// Drain one bounded sidecar batch made observable by one readiness byte.
        /// The sidecar re-nudges its descriptor for remaining records. Limiting
        /// this projection to one batch gives delegated platform completions a
        /// turn even while the iroh queue stays continuously hot.
        fn harvestSidecar(self: *Self) !void {
            var events_buf: [256]ReadyEvent = undefined;
            const n = self.resident.drainReady(&events_buf);
            // A count past the buffer is the sidecar breaking its contract.
            if (n < 0 or n > events_buf.len) return error.SidecarDrainFailed;
            const count: usize = @intCast(n);
            for (events_buf[0..count]) |ev| self.dispatchReady(ev);
        }

        fn dispatchPlatform(self: *Self, comp: completion.Completion) !void {
            if (!Namespace.ownsUserData(comp.user_data)) {
                self.ready.appendAssumeCapacity(comp);
                return;
            }

            if (comp.borrowed.active()) self.platform.recycleBorrowed(comp);
            const signal: Signal = @fromBackingInt(@intCast(@as(u1, @truncate(Namespace.userDataPayload(comp.user_data)))));
            switch (signal) {
                .readiness => self.readiness_armed = false,
                .wake => self.wake_armed = false,
            }
            try self.wake_failure.check();
            // A pool-starved recv still proves descriptor readiness. Both
            // signal sources own stack-buffered drain APIs, so progress must not
            // depend on a general transport buffer becoming available.
            if (!comp.recv_no_buffer and comp.result <= 0)
                return error.SignalReadFailed;
            switch (signal) {
                .readiness => try self.harvestSidecar(),
                .wake => {
                    self.wake_channel.drain() catch |err| {
                        self.wake_failure.record(err);
                        return err;
                    };
                },
            }
        }

        pub fn poll(self: *Self, out: []completion.Completion, timeout_ms: i32) !usize {
            return collect(self, out, timeout_ms);
        }

        pub fn peek(self: *Self, out: []completion.Completion) !usize {
            return collect(self, out, null);
        }

        /// `wait_ms` null reaps what the platform already completed and
        /// submits nothing.
        fn collect(self: *Self, out: []completion.Completion, wait_ms: ?i32) !usize {
            try self.wake_failure.check();
            try self.armSignals();

            var platform_completions: [256]completion.Completion = undefined;
            // Wrapped-platform completions have no iroh admission reservation,
            // so make room for the whole batch without spending the seats each
            // pending iroh operation already owns.
            try self.ready.ensureUnreservedCapacity(self.allocator, platform_completions.len);
            const count = if (wait_ms) |timeout_ms|
                try self.platform.poll(&platform_completions, if (self.ready.len() > 0) 0 else timeout_ms)
            else
                try self.platform.peek(&platform_completions);
            for (platform_completions[0..count]) |comp| {
                try self.dispatchPlatform(comp);
            }

            const ready_count = self.takeReady(out);
            if (ready_count > 0) return ready_count;
            // A stopper wake carries no transport completion. Returning zero lets
            // `runUntil` observe the state the waking thread changed.
            return 0;
        }
    };
}
