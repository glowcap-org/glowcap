//! A portable completion-driven connection loop, generic over its platform
//! backend.
//!
//! This is the cross-platform connection loop for high-fan-out OCapN I/O. The
//! connection orchestration lives here: feed complete frames to the peer, keep
//! partial frame tails, queue partial writes, park reads behind the outbound
//! high-water mark (ADR-0042), and close connections. That orchestration knows
//! nothing about the operating system. The platform-specific completion primitive
//! is supplied by a `Backend`, such as Linux's io_uring/epoll selector or
//! kqueue on macOS/BSD.
//! Adding a backend does not change this loop.
//!
//! The Zig TCP backends default their listener to `127.0.0.1`. Embedders that
//! accept from other hosts construct the platform backend with
//! `Backend.initWithListenerIp4` and move it into `initWithBackend`. Listener
//! exposure is transport state, not portable loop policy. The high-fan-out
//! numbers this loop is measured against remain loopback numbers.
//!
//! The loop is direction-neutral. OCapN is symmetric: a vat can accept
//! and dial. The type is therefore named for what it is, an event loop over
//! connections, rather than for one role. It accepts inbound connections and can
//! admit outbound connections into the same lifecycle.
//!
//! It owns no protocol the engine lacks. Every completion drives the same peer
//! APIs as the blocking pump. `frame_stream.drainWholeFrames` applies complete
//! envelopes and keeps the partial tail. `Peer.step` encodes queued sends.
//! `Peer.takeOutbound` pulls frames to write.
//! `test/engine/completion_seam_test.zig` pins the contract that arbitrary read
//! boundaries still apply each frame exactly once.
//!
//! ## Read memory: the shared buffer pool (ADR-0054)
//!
//! A connection holds no read buffer of its own. The backend owns one shared
//! pool of `BackendOptions.read_buffers` buffers, each exactly
//! `BackendOptions.read_buffer_bytes`, and a recv completion carries a borrowed
//! view of the pool buffer the backend selected for it. The loop consumes the bytes:
//! whole frames apply zero-copy straight from the completion view. A partial
//! frame tail absorbs into the connection's bounded spill (ADR-0041). It then
//! hands the buffer back with `recycleBorrowed`, exactly once per completion that
//! carried one. An idle connection therefore costs no read-buffer memory at
//! all, and a recv that finds the pool momentarily empty parks buffer-starved
//! until a buffer recycles. It is never a connection failure.

const std = @import("std");

const clock = @import("../clock.zig");
const contract = @import("contract.zig");
const tcp_keepalive = @import("tcp_keepalive.zig");

/// Re-export so loop callers configure keepalive without a second import path.
pub const Keepalive = tcp_keepalive.Keepalive;

/// Shared bounded byte-buffer pool for readiness backends and completion
/// adapters. Re-exported so out-of-graph transport modules reach the same
/// owner through `net.completion` rather than dual-homing the source file.
pub const BufferPool = @import("buffer_pool.zig").BufferPool;

pub const AdapterNamespace = contract.AdapterNamespace;

/// Vocabulary shared by the adapters that wrap another backend: which inner
/// operations a leg has in flight, where its inner descriptor stands in its
/// close, the try-I/O machine the multiplexed sidecar backends run, the
/// terminal leg lifecycle, and owed-submission bookkeeping. Re-exported so
/// out-of-graph transport modules reach one owner through `net.completion`.
const adapter = @import("adapter.zig");
const hinted_try_io = @import("hinted_try_io.zig");
pub const PendingOps = adapter.PendingOps;
pub const InnerClose = adapter.InnerClose;
pub const HintedPending = hinted_try_io.HintedPending;
pub const TryRead = hinted_try_io.TryRead;
pub const TryWrite = hinted_try_io.TryWrite;
pub const HintedTryIo = hinted_try_io.HintedTryIo;
pub const InnerLegLifecycle = @import("inner_leg.zig").Lifecycle;
pub const SubmissionDebt = @import("submission_debt.zig").State;
pub const CloseReason = contract.CloseReason;
pub const CloseReport = contract.CloseReport;
pub const Completion = contract.Completion;

/// The init drive's poll bound while a listener setup finishes. The setup's
/// own deadline lives in the backend; this bound only keeps each turn from
/// parking the init caller.
pub const listener_setup_poll_ms: i32 = 100;
pub const Interest = contract.Interest;
pub const ReadyQueue = contract.ReadyQueue;
pub const keepForeign = contract.keepForeign;
pub const passThrough = contract.passThrough;
pub const failureFromErrno = contract.failureFromErrno;
const loop_configuration = @import("loop/configuration.zig");
const loop_state = @import("loop/state.zig");
const loop_deadlines = @import("loop/connections/deadlines.zig");
const loop_lifecycle = @import("loop/connections/lifecycle.zig");
const loop_flow = @import("loop/connections/flow.zig");
const loop_admission = @import("loop/connections/admission.zig");
const loop_wake = @import("loop/wake.zig");
const loop_affinity = @import("loop/affinity.zig");
const loop_driver = @import("loop/driver.zig");

pub const MakePeer = loop_configuration.MakePeer;
pub const MakeConnCtx = loop_configuration.MakeConnCtx;
pub const Serve = loop_configuration.Serve;
pub const FreeConnCtx = loop_configuration.FreeConnCtx;
pub const OnClose = loop_configuration.OnClose;
pub const OnDriverExit = loop_configuration.OnDriverExit;
pub const OnLoopTurn = loop_configuration.OnLoopTurn;
pub const ParkReason = loop_configuration.ParkReason;
pub const OnPark = loop_configuration.OnPark;
pub const listen_backlog = loop_configuration.listen_backlog;
pub const DialAdmission = loop_configuration.DialAdmission;
pub const default_read_buffer_bytes = loop_configuration.default_read_buffer_bytes;
pub const default_outbound_high_water_bytes = loop_configuration.default_outbound_high_water_bytes;
pub const BackendOptions = loop_configuration.BackendOptions;
pub const Options = loop_configuration.Options;
pub const Stop = loop_configuration.Stop;

/// The portable completion-driven connection loop over a platform \`Backend\`
/// and a netlayer \`DialResolver\` (OCapN locator parts to \`Backend.ConnectTarget\`).
pub fn Loop(comptime Backend: type, comptime DialResolver: type) type {
    comptime contract.validateBackend(Backend);
    comptime contract.validateDialResolver(DialResolver, Backend.ConnectTarget);
    return struct {
        const Self = @This();
        const Types = loop_state.Types(Backend);
        const Conn = Types.Conn;
        const Fd = Types.Fd;
        const Deadlines = loop_deadlines.Machine(Self, contract.CloseReason, loop_state, clock);
        const Lifecycle = loop_lifecycle.Machine(Self, Backend, Types, Deadlines);
        const Flow = loop_flow.Machine(Self, Types, Deadlines, Lifecycle);
        const Admission = loop_admission.Machine(Self, Backend, DialResolver, Types, Lifecycle, Flow);
        const Wake = loop_wake.Machine(Self, Types);
        const Driver = loop_driver.Machine(Self, Deadlines, Lifecycle, Flow, Admission, Wake);

        allocator: std.mem.Allocator,
        backend: Backend,
        /// The bound listening socket, or null when `Options.listen` was null:
        /// a pure dialer loop never listens and never arms an accept.
        listen_fd: ?Fd,
        /// The backend-specific listener address, owned by this Loop value.
        listener_address: ?Backend.ListenerAddress,
        conns: []Conn,
        ordinary_capacity: usize,
        outbound_high_water_bytes: usize,
        make_peer: MakePeer,
        make_ctx: ?*anyopaque,
        serve: ?Serve,
        make_conn_ctx: ?MakeConnCtx,
        free_conn_ctx: ?FreeConnCtx,
        on_close: ?OnClose,
        /// Quiescent adapter ownership transfer. See `Options.on_driver_exit`.
        on_driver_exit: ?OnDriverExit,
        /// Deferred adapter scheduling. See `Options.on_loop_turn`.
        on_loop_turn: ?OnLoopTurn,
        /// Optional park notification (ADR-0082). See `Options.on_park`.
        on_park: ?OnPark,
        /// Opt-in TCP keepalive applied at connect/accept finish (see `Options`).
        keepalive: ?tcp_keepalive.Keepalive,
        /// Fan-in source throttle (ADR-0082). See `Options.fan_in_throttle`.
        fan_in_throttle: bool,
        /// Park-duration kill (ADR-0082). See `Options.park_kill_ms`.
        park_kill_ms: ?u64,
        /// Terminal-flush bound. See `Options.drain_kill_ms`.
        drain_kill_ms: ?u64,
        /// Whether an accept is outstanding. `run` and `runUntil` both begin by
        /// arming one, and both are callable more than once, a driver that
        /// waits on one vow per `runUntil` calls it repeatedly. Without this
        /// each call mints another accept, and since every accept completion
        /// re-arms exactly once, the extras never go away.
        accept_armed: bool = false,
        /// A submitted listener close is an outstanding backend operation, but
        /// it has no connection slot to keep `live_count` high. The descriptor
        /// remains in `listener_close_fd` across transient submit refusal. Only
        /// the close completion clears it.
        listener_close_pending: bool = false,
        listener_close_fd: ?Fd = null,
        closed_count: usize = 0,
        /// How many slots are not `.free`. `adoptSlot` and `teardown` are the
        /// only two sites that move a slot across that line, so this has the
        /// same one-writer-per-event shape as the counters below it.
        ///
        /// A count rather than a walk because `closeAndDrain` asks once per
        /// poll. At the 500k destination a walk there touches every slot's
        /// cache line on every one of the thousands of polls a full drain
        /// takes, which is a shutdown that reads as a hang.
        live_count: usize = 0,
        /// True while `deinit` tears the loop down: cross-connection entries
        /// (`armOutbound`, `closeSlot`) no-op then, because a submit during
        /// teardown would mint an op whose completion never arrives and trip
        /// the in-flight accounting `deinit` asserts on.
        tearing_down: bool = false,
        /// True while `closeAndDrain` (or `runUntil`'s shutdown phase) is
        /// retiring live connections: accept completions must not re-arm or
        /// adopt, and the listen handle is closed so poll cannot hang on an
        /// idle accept.
        shutting_down: bool = false,
        /// The nearest deadline the loop knows of, or null when it must look.
        ///
        /// Only ever early, never late: a cleared stamp leaves its entry
        /// behind, so the loop may wake with nothing to do, and
        /// `reapDeadlines` recomputes after a wake that closes nothing. A
        /// late entry would miss a reap, which is why nothing may raise it.
        earliest_due_ms: ?i64 = null,
        /// How many connections sit over the outbound high-water mark. The
        /// fan-in throttle asks this once per armed read, so it is a count
        /// rather than a table walk. Maintained solely by `refreshOverMark`.
        over_mark_count: usize = 0,
        /// Closes whose `submitClose` failed and must be retried. Zero on
        /// every healthy loop, so the retry sweep never runs.
        pending_close_submits: usize = 0,
        /// The out-of-band wake (ADR-0102): a recv armed on a socketpair half
        /// whose completion runs `handler` on this thread and re-arms. The
        /// sanctioned cross-thread entry, a worker nudges the other half
        /// (`driver.SettleMailbox.post`), replacing the connect-and-drop
        /// wake `runUntil` documents.
        wake: ?struct {
            fd: Fd,
            ctx: ?*anyopaque,
            handler: *const fn (?*anyopaque) void,
        } = null,
        /// True from successful wake-recv submission until its one completion
        /// is dispatched. The wake descriptor is caller-owned, so shutdown
        /// retires this operation with `submitCancel` rather than closing it.
        wake_armed: bool = false,
        /// A wake re-arm whose submit failed (transient ring pressure) and
        /// must be retried. Bounds the next wait like an owed close, so the
        /// wake channel cannot silently go deaf.
        wake_rearm_pending: bool = false,
        /// A cancellation the backend has not admitted yet. Kept separate from
        /// `wake_cancel_pending`: a refused submit mints no completion, while an
        /// admitted cancel must be drained even if the target recv wins first.
        wake_cancel_submit_pending: bool = false,
        wake_cancel_pending: bool = false,
        /// The slot whose `make_conn_ctx` is running, if any. Teardown of that
        /// slot is deferred until the hook returns: the context being built
        /// borrows the slot's peer, and reclaiming it underneath would free
        /// the peer before the context that owns a session over it is even
        /// handed back.
        adopting_slot: ?usize = null,
        /// Whether a teardown arrived for `adopting_slot` while its hook ran.
        /// One slot adopts at a time on this single-threaded loop, so this
        /// belongs here rather than costing every connection a byte.
        adopting_teardown_deferred: bool = false,
        /// How many connections currently carry a deadline stamp. Zero on a
        /// healthy loop. Both deadline sweeps are `O(max_conns)`, so running
        /// them per poll batch would put the per-connection cost this loop
        /// refuses onto its quietest path. Maintained solely by `setWaiting`.
        waiting_count: usize = 0,
        /// Set when a connection left while fan-in throttling was on, so the
        /// sources it may have been throttling get one re-evaluation at the
        /// end of the poll batch. A flag rather than a call at the departure
        /// point: the resume arms reads, so performing it inside a teardown
        /// re-enters the loop, and doing it per departure makes a mass close
        /// quadratic.
        fan_in_dirty: bool = false,
        /// Debug-only owning thread: latched when `run` begins, asserted on
        /// every `armOutbound`/`closeSlot` (and other public entries). Zero-
        /// sized in release. The loop is single-threaded by contract.
        owner_tid: loop_affinity.OwnerThreadId = loop_affinity.initial_owner_thread_id,
        /// Heads of the two intrusive free-slot lists threaded through
        /// `Conn.next_link`. Ordinary slots occupy the prefix ending at
        /// `ordinary_capacity`. Reserved slots occupy the suffix. The index is
        /// therefore the admission class, with no per-connection field or
        /// counter to pay for or drift.
        ordinary_free_head: usize,
        reserved_free_head: usize,
        /// Head of the intrusive buffer-starved list threaded through the same
        /// `Conn.next_link` while a slot is starved. `conns.len` when no
        /// connection is starved.
        starved_head: usize,
        /// Head of the intrusive backpressure-parked list (see `Conn.next_link`).
        /// `conns.len` when nothing is parked. It makes the fan-in release
        /// proportional to the connections parked rather than to
        /// `max_conns`, which at the 500k target is half a million cold slot
        /// reads per departure to re-arm, usually, nothing.
        parked_head: usize,

        /// Build a loop over a backend the caller already constructed. Use this
        /// for backend state that portable loop options do not own, such as a
        /// Zig listener interface or an iroh resident's endpoint. `init`
        /// builds the platform backend with its ordinary defaults.
        pub fn initWithBackend(
            allocator: std.mem.Allocator,
            backend: Backend,
            make_peer: MakePeer,
            make_ctx: ?*anyopaque,
            options: Options,
        ) !Self {
            var backend_mut = backend;
            errdefer backend_mut.deinit();

            // A loop only listens when asked to: a dialer-only loop must not
            // expose a socket that accepts strangers under its identity.
            const listen_fd: ?Fd = if (options.listen) |listen_port| blk: {
                const fd = try backend_mut.openListener(Backend.loopListenTarget(listen_port));
                // A backend whose listener setup finishes later reports it
                // pending. The loop's contract is a live listener at init, so
                // the init caller drives the backend's own poll until the
                // setup ends; the setup's deadline lives in the backend and
                // bounds this drive.
                var turn: [4]Completion = undefined;
                while (backend_mut.listenerPending(fd)) {
                    _ = try backend_mut.poll(&turn, listener_setup_poll_ms);
                }
                break :blk fd;
            } else null;
            errdefer if (listen_fd) |fd| backend_mut.closeFd(fd);
            const listener_address: ?Backend.ListenerAddress = if (listen_fd) |fd|
                try backend_mut.listenerAddress(fd)
            else
                null;

            // A fan-in throttle with no park deadline is a wedge, not a
            // policy: a sink the partner never drains parks every other
            // connection's read, and with no deadline anywhere the poll has
            // nothing left to wake for. Refused here rather than described,
            // because the one caller that pairs them correctly had to carry
            // five lines of comment explaining why.
            if (options.fan_in_throttle and
                (options.park_kill_ms == null or options.drain_kill_ms == null))
            {
                return error.FanInThrottleNeedsParkDeadline;
            }
            // The intrusive links are `u32`; see `Conn.next_link`.
            std.debug.assert(options.max_conns < std.math.maxInt(u32));
            if (options.reserved_dial_conns > options.max_conns)
                return error.ReservedDialCapacityExceedsConnections;
            const conns = try allocator.alloc(Conn, options.max_conns);
            errdefer allocator.free(conns);
            for (conns, 0..) |*c, i| {
                c.* = .{};
                c.next_link = @intCast(i + 1);
            }
            const ordinary_capacity = options.max_conns - options.reserved_dial_conns;
            if (ordinary_capacity > 0)
                conns[ordinary_capacity - 1].next_link = @intCast(conns.len);

            return .{
                .allocator = allocator,
                .backend = backend_mut,
                .listen_fd = listen_fd,
                .listener_address = listener_address,
                .conns = conns,
                .ordinary_capacity = ordinary_capacity,
                .outbound_high_water_bytes = options.outbound_high_water_bytes,
                .make_peer = make_peer,
                .make_ctx = make_ctx,
                .serve = options.serve,
                .make_conn_ctx = options.make_conn_ctx,
                .free_conn_ctx = options.free_conn_ctx,
                .on_close = options.on_close,
                .on_driver_exit = options.on_driver_exit,
                .on_loop_turn = options.on_loop_turn,
                .on_park = options.on_park,
                .keepalive = options.keepalive,
                .fan_in_throttle = options.fan_in_throttle,
                .park_kill_ms = options.park_kill_ms,
                .drain_kill_ms = options.drain_kill_ms,
                .ordinary_free_head = if (ordinary_capacity > 0) 0 else conns.len,
                .reserved_free_head = if (ordinary_capacity < conns.len) ordinary_capacity else conns.len,
                .starved_head = conns.len,
                .parked_head = conns.len,
            };
        }

        pub fn init(
            allocator: std.mem.Allocator,
            make_peer: MakePeer,
            make_ctx: ?*anyopaque,
            options: Options,
        ) !Self {
            return initWithBackendOptions(allocator, .{}, make_peer, make_ctx, options);
        }

        /// Build a loop and its backend with explicit queue and shared-pool
        /// resources. Runtime policy remains in `Options`. A caller that has
        /// already built a backend uses `initWithBackend` instead.
        pub fn initWithBackendOptions(
            allocator: std.mem.Allocator,
            backend_options: BackendOptions,
            make_peer: MakePeer,
            make_ctx: ?*anyopaque,
            options: Options,
        ) !Self {
            if (backend_options.read_buffer_bytes == 0)
                return error.InvalidReadBufferBytes;
            const backend = try Backend.init(
                allocator,
                backend_options.queue_entries,
                backend_options.read_buffers,
                backend_options.read_buffer_bytes,
            );
            return initWithBackend(allocator, backend, make_peer, make_ctx, options);
        }

        /// Return the owned backend-specific address for this listener.
        pub fn listenerAddress(self: *const Self) ?Backend.ListenerAddress {
            return self.listener_address;
        }

        /// TCP convenience derived totally from the sole listener address.
        pub fn port(self: *const Self) ?u16 {
            return if (self.listener_address) |address| Backend.listenerPort(address) else null;
        }

        /// Tear down the loop. Requires every connection's in-flight ops to
        /// have retired, call `closeAndDrain` (or stop with
        /// `.{ .after_closed = n }` once those closes complete) before this.
        /// A submitted send borrows the connection's `front` buffer until the
        /// backend reports it complete, so freeing a connection with an op
        /// still in flight would hand the kernel freed storage. That is a
        /// use-after-free, not a leak. Draining without closing first is not
        /// an option: `poll` blocks until *something* completes, and an armed
        /// recv on an idle partner never does. So `deinit` asserts that every
        /// remaining connection has no op in flight rather than draining.
        pub fn deinit(self: *Self) void {
            if (comptime loop_affinity.tracks_thread_affinity)
                std.debug.assert(self.owner_tid == loop_affinity.initial_owner_thread_id);
            self.tearing_down = true;
            std.debug.assert(self.listener_close_fd == null);
            std.debug.assert(!self.listener_close_pending);
            std.debug.assert(self.wake == null);
            std.debug.assert(!self.wake_armed);
            std.debug.assert(!self.wake_rearm_pending);
            std.debug.assert(!self.wake_cancel_submit_pending);
            std.debug.assert(!self.wake_cancel_pending);
            for (self.conns, 0..) |*c, slot| if (c.state != .free) {
                std.debug.assert(c.ops_in_flight == 0);
                // A closing connection's fd rides its already-queued close op;
                // open/draining ones have no close queued anywhere, so they
                // must be closed here or they leak (teardown never closes fds).
                if (c.state == .open or c.state == .draining) self.backend.closeFd(c.fd);
                // Every other route into `teardown` unlinks first, and the
                // slot reset below clears `next_link`, so skipping it here
                // would leave a predecessor pointing into the free list.
                Lifecycle.unlinkStarved(self, slot);
                Lifecycle.unlinkParked(self, slot);
                // Not counted: `deinit` is the loop ending, not connections
                // being served to completion.
                _ = Lifecycle.teardown(self, slot);
            };
            // Both counts are edge-triggered against slots that no longer
            // exist, so a missed release here is a silent drift that only
            // shows up as a table walk that never stops finding work.
            std.debug.assert(self.waiting_count == 0);
            std.debug.assert(self.over_mark_count == 0);
            std.debug.assert(self.live_count == 0);
            self.allocator.free(self.conns);
            if (self.listen_fd) |fd| self.backend.closeFd(fd);
            self.backend.deinit();
        }

        // Drive, admission, connection I/O, and wake transactions live in
        // internal owners. Direct aliases preserve the supported Loop API
        // without forwarding bodies or exporting those modules through net.
        pub const run = Driver.run;
        pub const runUntil = Driver.runUntil;
        pub const closeAndDrain = Driver.closeAndDrain;
        pub const dialLocator = Admission.dialLocator;
        pub const dialLocatorReserved = Admission.dialLocatorReserved;
        pub const armOutbound = Flow.armOutbound;
        pub const verifiedChannelKey = Admission.verifiedChannelKey;
        pub const closeSlot = Flow.closeSlot;
        pub const armWake = Wake.armWake;
    };
}
