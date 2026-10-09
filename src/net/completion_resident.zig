//! A completion backend as a multiplexed resident (ADR-0193).
//!
//! `driver.HostRuntime` hosts multiplexed transports through
//! `MultiplexedResident`: one readiness descriptor, drained records over
//! stable connection ids, and nonblocking per-connection I/O. A completion
//! backend has the same shape, so this adapter lets stream transports join
//! the runtime through the machinery it already owns for iroh and WebRTC,
//! with no per-connection read buffer.
//!
//! The descriptor is the platform backend's own. Each verb ends with a
//! nonblocking `poll` that turns completions into records, because an adapter
//! may complete an operation synchronously into its ready queue where no
//! descriptor reports it. While records wait, a wake channel armed as a
//! backend readiness poll (`submitPoll`) keeps the descriptor readable, which
//! makes it level-shaped as the contract requires; the poll consumes no pool
//! buffer.
//!
//! Reads keep one completed receive per connection and lend it through the
//! contract's borrowed-read group, so the runtime feeds the core from the pool
//! buffer, which returns before the next receive is armed. `try_read` copies
//! the same receive out for a caller that needs its own buffer.
//!
//! Writes copy into a two-buffer staging queue bounded by
//! `Options.send_window_bytes`, because the contract hands the bytes over on
//! return while the backend borrows a send until it completes. A connection
//! holds staging only while bytes wait: a drained buffer goes to a
//! resident-wide spare list of at most `Options.spare_send_buffers`, each no
//! larger than `Options.spare_send_bytes`, and the next connection to write
//! takes it. An idle connection therefore holds no buffer, and a busy
//! resident allocates staging only when its spares run out. A message-framed
//! backend (WebRTC) sends each submit as one packet, so its connections stage
//! whole packets, one behind the send in flight, and never merge or split one.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const completion = @import("completion/loop.zig");
const netlayer = @import("netlayer.zig");
const resident_mod = @import("multiplexed_resident.zig");
const wake_channel = @import("wake_channel.zig");
const completions = @import("completion_resident/completions.zig");
const teardown = @import("completion_resident/teardown.zig");
const listening = @import("completion_resident/listening.zig");

const MultiplexedResident = resident_mod.MultiplexedResident;
const ReadyEvent = resident_mod.ReadyEvent;
const crypto = foundation.crypto;
const userData = completions.userData;

pub const Options = struct {
    /// Bytes one connection may hold between `try_write` and the backend.
    send_window_bytes: usize = 64 << 10,
    /// Drained staging buffers the resident keeps for reuse across all its
    /// connections.
    spare_send_buffers: usize = 64,
    /// The largest drained buffer kept as a spare; a larger one is freed.
    spare_send_bytes: usize = 16 << 10,
};

/// `Policy` binds the backend to transport symbols:
///
///   * `resolve(locator) !Backend.ConnectTarget`, the dial resolver;
///   * `listenTarget(backend, transport, config) !Backend.ListenTarget`,
///     refusing a designator the backend cannot serve exactly;
///   * `localLocator(backend, fd, transport, identity, allocator)
///     !model.PeerLocator`, the dialable locator of an open listener, owned
///     by `allocator`;
///   * `canonicalizeLocator(backend, fd, transport, identity, allocator,
///     candidate) !model.PeerLocator`, the validated form of a locator the
///     listener on `fd` may advertise instead, owned by `allocator`;
///   * optionally, `restorationState(backend, fd, out)
///     netlayer.ListenerRestorationOutcome`, the opaque state that restores
///     the listener on `fd`. A policy without it restores nothing.
///
/// `identity` is the listen config's: the durable key of the Host the
/// listener serves, which a key-designated profile publishes.
pub fn Resident(comptime Backend: type, comptime Policy: type) type {
    return struct {
        const Self = @This();
        pub const Fd = Backend.Fd;
        const Completions = completions.Machine(Self);
        const armRecv = Completions.armRecv;
        const startSend = Completions.startSend;
        pub const armAccept = Completions.armAccept;
        pub const pump = Completions.pump;
        const retireIfQuiet = Completions.retireIfQuiet;
        const recycle = Completions.recycle;
        const forgetStarved = Completions.forgetStarved;
        const signalRecords = Completions.signalRecords;
        const armWake = Completions.armWake;
        const latch = Completions.latch;

        pub const Recv = union(enum) {
            idle,
            armed,
            /// The pool buffer that waits for `try_read`, and how much of it
            /// has been read.
            holding: struct { comp: completion.Completion, offset: usize },
            starved,
            eof,
            failed: anyerror,
        };

        pub const Conn = struct {
            fd: Fd,
            recv: Recv = .idle,
            /// `front` is borrowed by the backend while `sending`; writes
            /// append to `back`.
            front: std.ArrayListUnmanaged(u8) = .empty,
            back: std.ArrayListUnmanaged(u8) = .empty,
            sent: usize = 0,
            sending: bool = false,
            /// A refused `try_write` owes an `ev_writable` record.
            owes_writable: bool = false,
            write_failure: ?anyerror = null,
            /// `take_failure` has claimed this row's failure.
            failure_claimed: bool = false,
            /// `closing` rows are already released to the runtime and live on
            /// only until the backend retires the operations borrowing them.
            close: enum { open, closing } = .open,
            /// Completions the backend still owes this row.
            inflight: u8 = 0,
        };

        /// Held per open connection, beside the map's key and metadata.
        pub const connection_state_bytes = @sizeOf(Conn);

        pub const Dial = struct {
            fd: Fd,
            state: union(enum) { connecting, connected, failed: anyerror, cancelling, cancelled },
            inflight: u8 = 1,
        };

        /// Completions name a listener by `token`, minted here and never
        /// reused, so a stopped listener's late accept cannot reach a later
        /// listener that the runtime gave the same route.
        pub const Listener = struct {
            token: usize,
            route: usize,
            fd: Fd,
            identity: ?crypto.PeerKey,
            accepted: std.ArrayListUnmanaged(Fd) = .empty,
            accept_armed: bool = false,
            /// A backend listener still finishing its setup reports here.
            setup: union(enum) { ready, pending, failed: anyerror } = .ready,
        };

        allocator: std.mem.Allocator,
        backend: Backend,
        options: Options,
        wake: wake_channel.WakeChannel,
        wake_armed: bool = false,
        wake_nudged: bool = false,
        wake_cancel_submitted: bool = false,
        records: std.ArrayListUnmanaged(ReadyEvent) = .empty,
        conns: std.AutoHashMapUnmanaged(usize, Conn) = .empty,
        dials: std.AutoHashMapUnmanaged(usize, Dial) = .empty,
        listeners: std.AutoHashMapUnmanaged(usize, *Listener) = .empty,
        starved: std.ArrayListUnmanaged(usize) = .empty,
        spare_sends: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8)) = .empty,
        next_conn: usize = 1,
        next_listener: usize = 1,
        /// Listener closes the backend still owes; a stopped listener's row
        /// is gone, but its descriptor is not released until this settles.
        closing_listeners: usize = 0,
        /// Listen-ready waits the backend still owes.
        listen_waits: usize = 0,
        failure: ?anyerror = null,
        /// Structured failures a backend lent with a failed completion, kept
        /// until the runtime claims them. Only failed rows have an entry.
        conn_failures: std.AutoHashMapUnmanaged(usize, foundation.FailureChain) = .empty,
        dial_failures: std.AutoHashMapUnmanaged(usize, foundation.FailureChain) = .empty,

        /// Ownership of `backend` transfers on entry, including every error
        /// path.
        pub fn init(allocator: std.mem.Allocator, backend: Backend, options: Options) !Self {
            var owned = backend;
            errdefer owned.deinit();
            var spare_sends: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8)) = .empty;
            try spare_sends.ensureTotalCapacityPrecise(allocator, options.spare_send_buffers);
            errdefer spare_sends.deinit(allocator);
            return .{
                .allocator = allocator,
                .backend = owned,
                .options = options,
                .wake = try wake_channel.WakeChannel.open(),
                .spare_sends = spare_sends,
            };
        }

        /// Close whatever is still open and retire every operation the
        /// backend still owes, waiting at most `timeout_ms`. Fallible and
        /// retryable, as `completion.Loop.closeAndDrain` is; `deinit` requires
        /// it to have succeeded, because an owed operation may still borrow a
        /// connection's staging.
        pub const closeAndDrain = teardown.Machine(Self).closeAndDrain;

        /// After a successful `closeAndDrain`.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.drained());
            self.records.deinit(self.allocator);
            self.conns.deinit(self.allocator);
            self.dials.deinit(self.allocator);
            self.conn_failures.deinit(self.allocator);
            self.dial_failures.deinit(self.allocator);
            self.listeners.deinit(self.allocator);
            self.starved.deinit(self.allocator);
            for (self.spare_sends.items) |*spare| spare.deinit(self.allocator);
            self.spare_sends.deinit(self.allocator);
            self.backend.deinit();
            self.wake.deinit();
        }

        pub fn drained(self: *const Self) bool {
            return self.conns.count() == 0 and self.dials.count() == 0 and
                self.listeners.count() == 0 and self.closing_listeners == 0 and self.listen_waits == 0 and !self.wake_armed;
        }

        /// The first resident-wide failure, which `drain_ready` reports to the
        /// runtime as `ProviderContract`.
        pub fn failureCause(self: *const Self) ?anyerror {
            return self.failure;
        }

        pub fn resident(self: *Self) MultiplexedResident {
            return .{ .ctx = self, .vtable = &vtable };
        }

        const vtable = MultiplexedResident.VTable{
            .readiness_fd = readinessFd,
            .wait_bound_ms = waitBoundMs,
            .drain_ready = drainReady,
            .try_read = tryRead,
            .borrowed_read = .{ .lend = lend, .release = release },
            .try_write = tryWrite,
            .flush_writes = flushWrites,
            .take_failure = takeFailure,
            .conn_close = connClose,
            .conn_remote_key = connRemoteKey,
            .dial = .{
                .start_connect = startConnect,
                .finish_connect = finishConnect,
                .cancel_connect = cancelConnect,
            },
            .listen = .{
                .listen = Listening.listen,
                .completion = if (Listening.can_pend) .{ .finish = Listening.finish, .cancel = Listening.cancel } else null,
                .local_locator = Listening.localLocator,
                .canonicalize_locator = Listening.canonicalizeLocator,
                .restoration_state = if (@hasDecl(Policy, "restorationState")) Listening.restorationState else null,
                .finish_accept = Listening.finishAccept,
                .stop_listen = Listening.stopListen,
            },
        };

        fn of(ctx: *anyopaque) *Self {
            return @ptrCast(@alignCast(ctx));
        }

        /// An adapter that retries on a timer bounds the runtime's wait.
        fn waitBoundMs(ctx: *anyopaque, requested_ms: i32) i32 {
            return of(ctx).backend.waitBoundMs(requested_ms);
        }

        fn readinessFd(ctx: *anyopaque) i32 {
            const self = of(ctx);
            self.armWake();
            return self.backend.readinessFd();
        }

        fn drainReady(ctx: *anyopaque, out: []ReadyEvent) resident_mod.ContractError!usize {
            const self = of(ctx);
            self.pump();
            if (self.failure != null) return error.ProviderContract;
            const count = @min(out.len, self.records.items.len);
            @memcpy(out[0..count], self.records.items[0..count]);
            std.mem.copyForwards(ReadyEvent, self.records.items[0 .. self.records.items.len - count], self.records.items[count..]);
            self.records.shrinkRetainingCapacity(self.records.items.len - count);
            self.wake_nudged = false;
            self.signalRecords();
            return count;
        }

        fn tryRead(ctx: *anyopaque, id: usize, buf: []u8) isize {
            const self = of(ctx);
            defer self.pump();
            const conn = self.conns.getPtr(id) orelse return -1;
            if (conn.close != .open) return -1;
            switch (conn.recv) {
                .holding => |*held| {
                    const bytes = held.comp.borrowed.recvBytes().?;
                    const n = @min(buf.len, bytes.len - held.offset);
                    @memcpy(buf[0..n], bytes[held.offset..][0..n]);
                    held.offset += n;
                    if (held.offset == bytes.len) {
                        const spent = held.comp;
                        conn.recv = .idle;
                        self.recycle(spent);
                        self.armRecv(id, conn);
                    }
                    return @intCast(n);
                },
                .eof => return 0,
                .failed => return -1,
                .idle => {
                    self.armRecv(id, conn);
                    return resident_mod.would_block;
                },
                .armed, .starved => return resident_mod.would_block,
            }
        }

        fn lend(ctx: *anyopaque, id: usize) resident_mod.borrowed_read.Lend {
            const self = of(ctx);
            const conn = self.conns.getPtr(id) orelse return .dead;
            if (conn.close != .open) return .dead;
            // Turn waiting completions into held bytes before answering.
            if (conn.recv != .holding) self.pump();
            switch (conn.recv) {
                .holding => |held| return .{ .bytes = held.comp.borrowed.recvBytes().?[held.offset..] },
                .eof => return .end_of_stream,
                .failed => return .dead,
                .idle => {
                    self.armRecv(id, conn);
                    self.pump();
                    return .would_block;
                },
                .armed, .starved => return .would_block,
            }
        }

        fn release(ctx: *anyopaque, id: usize) void {
            const self = of(ctx);
            const conn = self.conns.getPtr(id) orelse return;
            if (conn.close != .open or conn.recv != .holding) return;
            defer self.pump();
            const spent = conn.recv.holding.comp;
            conn.recv = .idle;
            self.recycle(spent);
            self.armRecv(id, conn);
        }

        fn tryWrite(ctx: *anyopaque, id: usize, bytes: []const u8) isize {
            const self = of(ctx);
            defer self.pump();
            const conn = self.conns.getPtr(id) orelse return -1;
            if (conn.write_failure != null or conn.close != .open) return -1;
            if (self.backend.wireFraming(conn.fd) == .message) return self.stagePacket(conn, bytes);
            const queued = conn.front.items.len - conn.sent + conn.back.items.len;
            const room = self.options.send_window_bytes -| queued;
            const take = @min(room, bytes.len);
            if (take == 0) {
                conn.owes_writable = true;
                return resident_mod.would_block;
            }
            if (conn.back.capacity == 0) conn.back = self.spare_sends.pop() orelse .empty;
            conn.back.appendSlice(self.allocator, bytes[0..take]) catch {
                conn.owes_writable = true;
                return resident_mod.would_block;
            };
            // The send starts at `flushWrites`, so one batch leaves together.
            return @intCast(take);
        }

        /// A message-framed backend sends each submit as one packet, so a
        /// packet is staged whole and at most one waits behind the send in
        /// flight: `startSend` then always submits exactly one packet. The
        /// window does not split a packet; the frame cap already bounds it.
        fn stagePacket(self: *Self, conn: *Conn, bytes: []const u8) isize {
            if (conn.back.items.len != 0) {
                conn.owes_writable = true;
                return resident_mod.would_block;
            }
            if (conn.back.capacity == 0) conn.back = self.spare_sends.pop() orelse .empty;
            conn.back.appendSlice(self.allocator, bytes) catch {
                conn.owes_writable = true;
                return resident_mod.would_block;
            };
            return @intCast(bytes.len);
        }

        fn flushWrites(ctx: *anyopaque, id: usize) void {
            const self = of(ctx);
            defer self.pump();
            const conn = self.conns.getPtr(id) orelse return;
            self.startSend(id, conn);
        }

        fn takeFailure(ctx: *anyopaque, id: usize) ?foundation.FailureChain {
            const self = of(ctx);
            const conn = self.conns.getPtr(id) orelse return null;
            if (conn.failure_claimed) return null;
            // A backend that keeps its own report (a foreign provider) is the
            // exact authority, even behind a clean end of stream.
            if (comptime @hasDecl(Backend, "takeConnFailure")) {
                if (self.backend.takeConnFailure(conn.fd)) |exact| {
                    conn.failure_claimed = true;
                    // idempotent: the borrowed copy, if any, is superseded.
                    _ = self.conn_failures.remove(id);
                    return exact;
                }
            }
            const cause = conn.write_failure orelse switch (conn.recv) {
                .failed => |err| err,
                else => return null,
            };
            conn.failure_claimed = true;
            if (self.conn_failures.fetchRemove(id)) |kept| return kept.value;
            return .init(cause);
        }

        /// The runtime's claim on the connection ends here. The row lives on,
        /// out of reach of every verb, until the backend retires the
        /// operations that borrow its staging.
        fn connClose(ctx: *anyopaque, id: usize) resident_mod.TeardownOutcome {
            const self = of(ctx);
            defer self.pump();
            const conn = self.conns.getPtr(id) orelse return .complete;
            if (conn.close == .closing) return .complete;
            if (conn.recv == .holding) {
                const held = conn.recv.holding.comp;
                conn.recv = .idle;
                self.forgetStarved(id);
                self.recycle(held);
            } else self.forgetStarved(id);
            conn.close = .closing;
            self.backend.shutdownFd(conn.fd);
            var outcome: resident_mod.TeardownOutcome = .complete;
            if (self.backend.submitClose(userData(.close, id), conn.fd)) {
                conn.inflight += 1;
            } else |err| {
                self.backend.closeFd(conn.fd);
                outcome = .{ .failed = .init(err) };
            }
            self.retireIfQuiet(id, conn);
            return outcome;
        }

        fn connRemoteKey(ctx: *anyopaque, id: usize) resident_mod.ContractError!?crypto.PeerKey {
            const self = of(ctx);
            const conn = self.conns.getPtr(id) orelse return null;
            const key = self.backend.verifiedChannelKey(conn.fd) orelse return null;
            return crypto.PeerKey.fromBytes(key);
        }

        fn startConnect(
            ctx: *anyopaque,
            request_id: usize,
            locator: model.PeerLocator,
            options: netlayer.OperationOptions,
        ) resident_mod.RawDialStartOutcome {
            const self = of(ctx);
            defer self.pump();
            options.requireInherited() catch |err| return .{ .failed = .init(err) };
            const target = Policy.resolve(locator) catch |err| return .{ .failed = dialFailure(err) };
            self.dials.ensureUnusedCapacity(self.allocator, 1) catch |err| return .{ .failed = .init(err) };
            const fd = self.backend.startDial(userData(.connect, request_id), target) catch |err|
                return .{ .failed = dialFailure(err) };
            self.dials.putAssumeCapacity(request_id, .{ .fd = fd, .state = .connecting });
            return .admitted;
        }

        /// Keeps the exact cause in the chain and classifies it on the
        /// closed retry axis; a cause outside that axis is a lost connection,
        /// except an unroutable locator, which no retry repairs.
        fn dialFailure(err: anyerror) netlayer.DialFailure {
            const classification: netlayer.DialError = switch (err) {
                error.InvalidAddress,
                error.InvalidOptions,
                error.WouldBlock,
                error.ConnectionRefused,
                error.NetworkUnreachable,
                error.TimedOut,
                error.ConnectionLost,
                error.SocketConfigurationFailed,
                error.WakeNudgeFailed,
                error.OutOfMemory,
                => |known| known,
                error.UnknownTransport, error.AddressNotAvailable => error.InvalidAddress,
                else => error.ConnectionLost,
            };
            return .fromChain(classification, .init(err));
        }

        fn finishConnect(ctx: *anyopaque, request_id: usize) resident_mod.RawDialFinishOutcome {
            const self = of(ctx);
            defer self.pump();
            const dial = self.dials.fetchRemove(request_id) orelse
                return .{ .failed = .init(error.InvalidOptions) };
            switch (dial.value.state) {
                .connected => {},
                .failed => |err| {
                    self.backend.closeFd(dial.value.fd);
                    var failure = dialFailure(err);
                    if (self.dial_failures.fetchRemove(request_id)) |kept| failure.chain = kept.value;
                    return .{ .failed = failure };
                },
                .connecting, .cancelling, .cancelled => {
                    self.latch(error.ProviderContract);
                    return .{ .failed = .fromChain(error.InvalidOptions, .init(error.ProviderContract)) };
                },
            }
            const id = self.adopt(dial.value.fd) catch |err| {
                self.backend.closeFd(dial.value.fd);
                return .{ .failed = .init(err) };
            };
            return .{ .connected = id };
        }

        fn cancelConnect(ctx: *anyopaque, request_id: usize) ?foundation.FailureChain {
            const self = of(ctx);
            defer self.pump();
            const dial = self.dials.getPtr(request_id) orelse return null;
            switch (dial.state) {
                .cancelled => {
                    std.debug.assert(self.dials.remove(request_id));
                    return null;
                },
                .cancelling => return null,
                .connected, .failed => {
                    self.backend.closeFd(dial.fd);
                    std.debug.assert(self.dials.remove(request_id));
                    // idempotent: only a failed dial kept a chain.
                    _ = self.dial_failures.remove(request_id);
                    return null;
                },
                .connecting => {
                    dial.state = .cancelling;
                    self.backend.submitClose(userData(.dial_close, request_id), dial.fd) catch |err| {
                        self.backend.closeFd(dial.fd);
                        return .init(err);
                    };
                    dial.inflight += 1;
                    return null;
                },
            }
        }

        const Listening = listening.Machine(Self, Policy);
        pub const stopListen = Listening.stopListen;

        pub fn adopt(self: *Self, fd: Fd) !usize {
            try self.conns.ensureUnusedCapacity(self.allocator, 1);
            const id = self.next_conn;
            self.next_conn += 1;
            self.conns.putAssumeCapacity(id, .{ .fd = fd });
            self.armRecv(id, self.conns.getPtr(id).?);
            return id;
        }
    };
}
