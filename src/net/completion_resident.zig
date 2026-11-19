//! A completion backend as a multiplexed resident (ADR-0018).
//!
//! `driver.HostRuntime` hosts multiplexed transports through
//! `MultiplexedResident`: one readiness descriptor, drained records over
//! stable connection ids, and nonblocking per-connection I/O. A completion
//! backend has the same shape, so this adapter lets stream transports join
//! the runtime through the machinery it already owns for iroh and WebRTC,
//! with no per-connection read buffer.
//!
//! The descriptor is the platform backend's own, and it reports what the
//! kernel holds. Each verb ends with a nonblocking `poll` that turns
//! completions into records, because an adapter may complete an operation
//! synchronously into its ready queue where no descriptor reports it. A
//! record reaped that way waits in the resident, which answers the contract's
//! `ready_pending` query, and the runtime services it before it parks
//! (ADR-0019).
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
const carrier_failure = @import("carrier_failure.zig");
const resident_mod = @import("multiplexed_resident.zig");
const completions = @import("completion_resident/completions.zig");
const teardown = @import("completion_resident/teardown.zig");
const listening = @import("completion_resident/listening.zig");
const dialing = @import("completion_resident/dialing.zig");

const MultiplexedResident = resident_mod.MultiplexedResident;
const ReadyEvent = resident_mod.ReadyEvent;
const crypto = foundation.crypto;
pub const userData = completions.userData;
pub const acceptRefusalPersists = completions.acceptRefusalPersists;

pub const Options = struct {
    /// Bytes one connection may hold between `try_write` and the backend.
    send_window_bytes: usize = 64 << 10,
    /// Drained staging buffers the resident keeps for reuse across all its
    /// connections.
    spare_send_buffers: usize = 64,
    /// The largest drained buffer kept as a spare. A larger one is freed.
    spare_send_bytes: usize = 16 << 10,
};

/// `Backend` is a completion backend with `readyPending(*const Backend)
/// bool`, which `ready_pending` calls. It reports, with no peek, sleep, I/O,
/// allocation, lock, or callback, whether the backend holds work no
/// descriptor reports: a completion held in user space, or a fault deferred
/// for the next `peek`. The next nonblocking drain can advance or surface that
/// work, though an adapter may consume a held completion internally instead
/// of yielding it. An adapter answers for its own queue, then asks the backend
/// it wraps. A backend holding nothing returns false. Only this generic
/// resident needs the method, and a `completion.Loop` backend does not.
///
/// `Policy` binds the backend to transport symbols:
///
///   * `resolve(locator) !Backend.ConnectTarget`, the dial resolver.
///   * `listenTarget(backend, transport, config) !Backend.ListenTarget`,
///     refusing a designator the backend cannot serve exactly.
///   * `localLocator(backend, fd, transport, identity, allocator)
///     !model.PeerLocator`, the dialable locator of an open listener, owned
///     by `allocator`.
///   * `canonicalizeLocator(backend, fd, transport, identity, allocator,
///     candidate) !model.PeerLocator`, the validated form of a locator the
///     listener on `fd` may advertise instead, owned by `allocator`.
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
        /// The completion machine, public for white-box tests that hand the
        /// resident a kernel verdict no loopback socket can be made to
        /// produce (an accept refused for descriptor quota).
        pub const Completions = completions.Machine(Self);
        const armRecv = Completions.armRecv;
        const startSend = Completions.startSend;
        pub const armAccept = Completions.armAccept;
        pub const pump = Completions.pump;
        const retireIfQuiet = Completions.retireIfQuiet;
        const recycle = Completions.recycle;
        const forgetStarved = Completions.forgetStarved;
        const beforeWait = Completions.beforeWait;
        const queueSend = Completions.queueSend;
        const submitQueued = Completions.submitQueued;
        pub const latch = Completions.latch;

        pub const Recv = union(enum) {
            idle,
            /// The re-arm waits in `recv_queue` for the `beforeWait` that
            /// precedes a park.
            queued,
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
            /// `front` is borrowed by the backend while `sending`. Writes
            /// append to `back`.
            front: std.ArrayList(u8) = .empty,
            back: std.ArrayList(u8) = .empty,
            sent: usize = 0,
            sending: bool = false,
            /// Staged bytes wait in `send_queue` for the next `beforeWait`.
            send_queued: bool = false,
            /// A refused `try_write` owes an `ev_writable` record.
            owes_writable: bool = false,
            write_failure: ?anyerror = null,
            /// `take_failure` has claimed this row's failure.
            failure_claimed: bool = false,
            /// A `draining` row belongs to no runtime wire: no read is armed
            /// or lent, and only the bytes `conn_close` admitted keep the
            /// socket open. `closing` rows are released and live on only
            /// until the backend retires the operations borrowing them.
            close: enum { open, draining, closing } = .open,
            /// Completions the backend still owes this row.
            inflight: u8 = 0,
            /// Holds one `records` seat (`close_seats`) for the `ev_closed`
            /// that says the provider's close can be claimed. Set at
            /// adoption on a connection whose backend `awaitsClose`, and
            /// given back exactly once: by that record, or with the row.
            close_seat: bool = false,
            /// An awaiting caller's close: `awaited` while the backend still
            /// holds borrows or the provider handle, `claimable` once the
            /// backend reported the handle quiet and the next `awaited`
            /// `conn_close` returns its result.
            close_wait: enum { none, awaited, claimable } = .none,
        };

        /// Held per open connection, beside the map's key and metadata.
        pub const connection_state_bytes = @sizeOf(Conn);

        pub const Dial = struct {
            fd: Fd,
            state: union(enum) { connecting, connected, failed: anyerror, cancelling, cancelled },
            inflight: u8 = 1,
        };

        /// Accepted sockets a listener holds for the runtime to claim before
        /// it stops accepting. The kernel's listen backlog holds arrivals past
        /// this, so a flood of connections costs this many descriptors per
        /// listener and no more until the runtime claims one.
        pub const max_unclaimed_accepts: usize = 64;

        /// Completions name a listener by `token`, minted here and never
        /// reused, so a stopped listener's late accept cannot reach a later
        /// listener that the runtime gave the same route.
        pub const Listener = struct {
            token: usize,
            route: usize,
            fd: Fd,
            identity: ?crypto.PeerKey,
            accepted: std.ArrayList(Fd) = .empty,
            accept_armed: bool = false,
            /// A failed accept follows earlier queued connections. Claiming
            /// an arrival failure re-arms the listener. A listener failure
            /// stops it so it cannot spin on the same outstanding arrival.
            accept_failure: ?union(enum) { arrival: foundation.FailureChain, listener: foundation.FailureChain } = null,
            /// The allocator refused the re-arm of an admitted listener. The
            /// runtime's paced retry (`memory_retry`) owns the next attempt,
            /// and an ordinary claim or completion skips this listener.
            rearm_owed: bool = false,
            /// A backend listener still finishing its setup reports here.
            setup: union(enum) { ready, pending, failed: anyerror } = .ready,
        };

        allocator: std.mem.Allocator,
        backend: Backend,
        options: Options,
        /// Records reaped from the kernel and not yet handed to the runtime.
        /// `ready_pending` reports them, because no descriptor does. It also
        /// reports work the backend still holds, which the next pump advances
        /// or surfaces.
        records: std.ArrayList(ReadyEvent) = .empty,
        /// Connections whose flushed batch starts at the next `beforeWait`.
        /// Bounded by the connections with staged bytes. Capacity is kept.
        send_queue: std.ArrayList(usize) = .empty,
        /// Connections whose receive re-arms at the `beforeWait` that
        /// precedes a park. Bounded by the open connections. Capacity is kept.
        recv_queue: std.ArrayList(usize) = .empty,
        /// Descriptors whose readiness wakes the park, armed as it begins.
        watches: std.ArrayList(completions.Watch) = .empty,
        conns: foundation.identity_hash.Map(usize, Conn) = .empty,
        dials: foundation.identity_hash.Map(usize, Dial) = .empty,
        listeners: foundation.identity_hash.Map(usize, *Listener) = .empty,
        starved: std.ArrayList(usize) = .empty,
        spare_sends: std.ArrayList(std.ArrayList(u8)) = .empty,
        next_conn: usize = 1,
        next_listener: usize = 1,
        /// Listener closes the backend still owes. A stopped listener's row
        /// is gone, but its descriptor is not released until this settles.
        closing_listeners: usize = 0,
        /// Listen-ready waits the backend still owes.
        listen_waits: usize = 0,
        failure: ?anyerror = null,
        /// Armed accepts. Each holds one `records` seat and one `accepted`
        /// slot reserved before the submit, so its completion cannot fail to
        /// record. `accept_seats` and `close_seats` together are the seats
        /// `records.capacity` keeps free beyond `records.items.len`.
        accept_seats: usize = 0,
        /// Open connections that hold a `close_seat`. Each one's `ev_closed`
        /// record has its room reserved the same way an armed accept's does.
        close_seats: usize = 0,
        /// Listeners with `rearm_owed` set.
        rearm_owed_count: usize = 0,
        /// Structured failures a backend lent with a failed completion, kept
        /// until the runtime claims them. Only failed rows have an entry.
        conn_failures: foundation.identity_hash.Map(usize, foundation.FailureChain) = .empty,
        dial_failures: foundation.identity_hash.Map(usize, foundation.FailureChain) = .empty,

        /// Ownership of `backend` transfers on entry, including every error
        /// path.
        pub fn init(allocator: std.mem.Allocator, backend: Backend, options: Options) !Self {
            var owned = backend;
            errdefer owned.deinit();
            var spare_sends: std.ArrayList(std.ArrayList(u8)) = .empty;
            try spare_sends.ensureTotalCapacityPrecise(allocator, options.spare_send_buffers);
            errdefer spare_sends.deinit(allocator);
            return .{
                .allocator = allocator,
                .backend = owned,
                .options = options,
                .spare_sends = spare_sends,
            };
        }

        /// Close whatever is still open and retire every operation the
        /// backend still owes, waiting at most `timeout_ms`. Fallible and
        /// retryable, as `completion.Loop.closeAndDrain` is. `deinit` requires
        /// it to have succeeded, because an owed operation may still borrow a
        /// connection's staging.
        const Teardown = teardown.Machine(Self);
        pub const closeAndDrain = Teardown.closeAndDrain;

        /// After a successful `closeAndDrain`.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.drained());
            self.records.deinit(self.allocator);
            self.send_queue.deinit(self.allocator);
            self.recv_queue.deinit(self.allocator);
            self.watches.deinit(self.allocator);
            self.conns.deinit(self.allocator);
            self.dials.deinit(self.allocator);
            self.conn_failures.deinit(self.allocator);
            self.dial_failures.deinit(self.allocator);
            self.listeners.deinit(self.allocator);
            self.starved.deinit(self.allocator);
            for (self.spare_sends.items) |*spare| spare.deinit(self.allocator);
            self.spare_sends.deinit(self.allocator);
            self.backend.deinit();
        }

        pub fn drained(self: *const Self) bool {
            return self.conns.count() == 0 and self.dials.count() == 0 and
                self.listeners.count() == 0 and self.closing_listeners == 0 and self.listen_waits == 0;
        }

        pub fn resident(self: *Self) MultiplexedResident {
            return .{ .ctx = self, .vtable = &vtable };
        }

        const vtable = MultiplexedResident.VTable{
            .readiness_fd = readinessFd,
            .ready_pending = readyPending,
            .before_wait = beforeWaitVerb,
            .reap = reapVerb,
            .wait_bound_ms = waitBoundMs,
            .park = parkVerb,
            .watch = watchVerb,
            .memory_retry = .{ .owes = Completions.owesRearm, .retry = Completions.retryRearms },
            .drain_ready = drainReady,
            .try_read = tryRead,
            .borrowed_read = .{ .lend = lend, .release = release },
            .try_write = tryWrite,
            .flush_writes = flushWrites,
            .take_failure = takeFailure,
            .conn_close = connClose,
            .conn_abort = connAbort,
            .conn_remote_key = connRemoteKey,
            .dial = .{
                .start_connect = Dialing.startConnect,
                .finish_connect = Dialing.finishConnect,
                .cancel_connect = Dialing.cancelConnect,
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
            return of(ctx).backend.readinessFd();
        }

        /// Records wait, a failure the runtime must take at `drain_ready`, or
        /// the backend holds work the next drain can advance or surface. That
        /// work may end in no record. Records and the failure answer first.
        fn readyPending(ctx: *anyopaque) bool {
            const self = of(ctx);
            return self.records.items.len != 0 or self.failure != null or self.backend.readyPending();
        }

        fn beforeWaitVerb(ctx: *anyopaque, after: resident_mod.AfterTurn) void {
            // Writes made during a turn are only queued. They go to the kernel
            // in one submit when the runtime is about to wait (ADR-0060). A
            // receive re-arm waits for the same moment (ADR-0060).
            of(ctx).beforeWait(after);
        }

        fn reapVerb(ctx: *anyopaque) void {
            of(ctx).pump();
        }

        fn parkVerb(ctx: *anyopaque, timeout_ms: i32) MultiplexedResident.Park {
            return Completions.park(of(ctx), timeout_ms);
        }

        fn watchVerb(ctx: *anyopaque, fd: i32) error{OutOfMemory}!void {
            return Completions.watch(of(ctx), fd);
        }

        fn drainReady(ctx: *anyopaque, out: []ReadyEvent) resident_mod.ContractError!usize {
            const self = of(ctx);
            self.pump();
            if (self.failure != null) return error.ProviderContract;
            const count = @min(out.len, self.records.items.len);
            @memcpy(out[0..count], self.records.items[0..count]);
            @memmove(self.records.items[0 .. self.records.items.len - count], self.records.items[count..]);
            self.records.shrinkRetainingCapacity(self.records.items.len - count);
            return count;
        }

        fn tryRead(ctx: *anyopaque, id: usize, buf: []u8) isize {
            const self = of(ctx);
            const conn = self.conns.getPtr(id) orelse return -1;
            if (conn.close != .open) return -1;
            // Turn waiting completions into held bytes before answering, as
            // `lend` does, so a receive that landed since the last pump is
            // copied now instead of costing one would-block turn.
            if (conn.recv != .holding) self.pump();
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
                .queued, .armed, .starved => return resident_mod.would_block,
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
                    return .would_block;
                },
                .queued, .armed, .starved => return .would_block,
            }
        }

        fn release(ctx: *anyopaque, id: usize) void {
            const self = of(ctx);
            const conn = self.conns.getPtr(id) orelse return;
            if (conn.close != .open or conn.recv != .holding) return;
            const spent = conn.recv.holding.comp;
            conn.recv = .idle;
            self.recycle(spent);
            self.armRecv(id, conn);
        }

        fn tryWrite(ctx: *anyopaque, id: usize, bytes: []const u8) isize {
            const self = of(ctx);
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
            // Staging that cannot grow fails the connection with its cause:
            // a would-block here owes an `ev_writable` that only a send
            // completion records, so an idle connection would stall.
            conn.back.appendSlice(self.allocator, bytes[0..take]) catch |err| {
                conn.write_failure = err;
                return -1;
            };
            // The batch starts at `flushWrites` and leaves at `beforeWait`.
            return @intCast(take);
        }

        /// A message-framed backend sends each submit as one packet, so a
        /// packet is staged whole and at most one waits behind the send in
        /// flight: `startSend` then always submits exactly one packet. The
        /// window does not split a packet. The frame cap already bounds it.
        fn stagePacket(self: *Self, conn: *Conn, bytes: []const u8) isize {
            if (conn.back.items.len != 0) {
                conn.owes_writable = true;
                return resident_mod.would_block;
            }
            if (conn.back.capacity == 0) conn.back = self.spare_sends.pop() orelse .empty;
            conn.back.appendSlice(self.allocator, bytes) catch |err| {
                conn.write_failure = err;
                return -1;
            };
            return @intCast(bytes.len);
        }

        fn flushWrites(ctx: *anyopaque, id: usize) void {
            const self = of(ctx);
            // This only queues the send for this connection. The kernel gets
            // it in the next submit, the one `beforeWait` makes before the
            // runtime parks, so a turn's writes leave together.
            const conn = self.conns.getPtr(id) orelse return;
            self.queueSend(id, conn);
        }

        fn takeFailure(ctx: *anyopaque, id: usize) ?carrier_failure.Report {
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
                    return .{ .chain = exact };
                }
            }
            const cause = conn.write_failure orelse switch (conn.recv) {
                .failed => |err| err,
                else => return null,
            };
            conn.failure_claimed = true;
            if (self.conn_failures.fetchRemove(id)) |kept| return .{ .chain = kept.value };
            return .init(cause);
        }

        /// The runtime's claim on the connection ends here. The row lives on,
        /// out of reach of every verb, until the backend retires the
        /// operations that borrow its staging.
        fn connClose(ctx: *anyopaque, id: usize, mode: resident_mod.CloseMode) resident_mod.TeardownOutcome {
            return Teardown.connClose(of(ctx), id, mode);
        }

        /// Drop the connection now, whatever `connClose` was still sending.
        fn connAbort(ctx: *anyopaque, id: usize, mode: resident_mod.CloseMode) resident_mod.TeardownOutcome {
            return Teardown.connAbort(of(ctx), id, mode);
        }

        fn connRemoteKey(ctx: *anyopaque, id: usize) resident_mod.ContractError!?crypto.PeerKey {
            const self = of(ctx);
            const conn = self.conns.getPtr(id) orelse return null;
            const key = self.backend.verifiedChannelKey(conn.fd) orelse return null;
            return crypto.PeerKey.fromBytes(key);
        }

        const Dialing = dialing.Machine(Self, Policy);

        const Listening = listening.Machine(Self, Policy);
        pub const stopListen = Listening.stopListen;

        /// Whether a connection of this backend can have its provider's close
        /// result claimed after the close is submitted. Only a backend that
        /// declares `awaitsClose` answers yes, and only for the connections it
        /// names: a platform descriptor behind the same backend does not.
        fn awaitsClose(self: *const Self, fd: Fd) bool {
            if (comptime !@hasDecl(Backend, "awaitsClose")) return false;
            return self.backend.awaitsClose(fd);
        }

        /// Admit connection `fd`. An awaitable connection also reserves its
        /// `ev_closed` seat here, before the caller's close can need it, so
        /// no later step allocates. A refusal reserves nothing.
        pub fn adopt(self: *Self, fd: Fd) !usize {
            try self.conns.ensureUnusedCapacity(self.allocator, 1);
            const seat = self.awaitsClose(fd);
            if (seat) try self.records.ensureTotalCapacity(
                self.allocator,
                self.records.items.len + self.accept_seats + self.close_seats + 1,
            );
            const id = self.next_conn;
            self.next_conn += 1;
            if (seat) self.close_seats += 1;
            self.conns.putAssumeCapacity(id, .{ .fd = fd, .close_seat = seat });
            self.armRecv(id, self.conns.getPtr(id).?);
            return id;
        }
    };
}
