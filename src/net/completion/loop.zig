//! A portable completion-driven connection loop, generic over its platform
//! backend.
//!
//! This is the cross-platform connection loop for high-fan-out OCapN I/O. The
//! connection orchestration lives here: feed complete frames to the peer, keep
//! partial frame tails, queue partial writes, park reads behind the outbound
//! high-water mark (ADR-0042), and close connections. That orchestration knows
//! nothing about the operating system. The platform-specific completion primitive
//! is supplied by a `Backend`, such as io_uring on Linux or kqueue on macOS/BSD.
//! Adding a backend does not change this loop.
//!
//! The loop is direction-neutral by design. OCapN is symmetric: a vat can accept
//! and dial. The type is therefore named for what it is, an event loop over
//! connections, rather than for one role. It accepts inbound connections and can
//! admit outbound connections into the same lifecycle.
//!
//! It owns no protocol the engine lacks. Every completion drives the same peer
//! APIs as the blocking pump. `Peer.recvStreamPrefix` applies complete frames and
//! keeps the partial tail. `Peer.step` encodes queued sends. `Peer.takeOutbound`
//! pulls frames to write. `test/engine/completion_seam_test.zig` pins the
//! contract that arbitrary read boundaries still apply each frame exactly once.
//!
//! ## Read memory: the shared buffer pool (ADR-0054)
//!
//! A connection holds no read buffer of its own. The backend owns one shared
//! pool of `Options.read_buffers` buffers (each `loop_read_buf_bytes`, capped by
//! `frame_cap`), and a recv completion carries a borrowed view of the pool
//! buffer the backend selected for it. The loop consumes the bytes — whole
//! frames apply zero-copy straight from the completion view; a partial frame
//! tail absorbs into the connection's bounded spill (ADR-0041) — and then hands
//! the buffer back with `recycleRecv`, exactly once per completion that carried
//! one. An idle connection therefore costs no read-buffer memory at all, and a
//! recv that finds the pool momentarily empty parks buffer-starved until a
//! buffer recycles; it is never a connection failure.
//!
//! ## Backend interface
//!
//! A backend is a struct providing the platform completion primitive. The server
//! calls only these; nothing here issues a syscall directly:
//!
//!   * `pub const Fd = <platform socket handle type>;`
//!   * `pub fn init(allocator, queue_entries: u16, read_buffers: u16, read_buffer_bytes: u32) !Backend;`
//!     — `read_buffers` buffers of `read_buffer_bytes` each form the shared
//!     recv pool the backend owns.
//!   * `pub fn deinit(self: *Backend) void;`
//!   * `pub fn openListener(self: *Backend, port: u16) !Fd;` — bind+listen
//!     (TCP) or arm the transport's acceptor (a userspace backend). Instance
//!     method so a backend that already carries endpoint state (iroh) can use
//!     it; socket backends ignore `self`.
//!   * `pub const ConnectTarget;` — Backend-owned dial target type. TCP's is an
//!     `IpAddress`; iroh's is `{ id, hints }`. There is no shared union: a
//!     Backend cannot be handed a target shape it refuses.
//!   * `pub fn startDial(self: *Backend, user_data: u64, target: ConnectTarget) !Fd;`
//!     — start one outbound dial and return the connection handle for the Loop
//!     slot. The Backend owns the whole start (mint a socket or a pending
//!     sentinel, submit the connect, clean up on failure). Connect completions
//!     for a userspace dial may return a synthetic fd as `result` (>0) rather
//!     than TCP's 0-on-success.
//!   * `pub fn boundPort(fd: Fd) !u16;` — the kernel-chosen port for `port = 0`.
//!   * `pub fn closeFd(self: *Backend, fd: Fd) void;` — release a handle.
//!     Instance method so a userspace backend can free transport state keyed by
//!     `Fd`; socket backends ignore `self`.
//!   * `pub fn submitAccept(self: *Backend, user_data: u64, listen_fd: Fd) !void;`
//!   * `pub fn submitRecv(self: *Backend, user_data: u64, fd: Fd) !void;` — no
//!     caller buffer: the backend selects one from its shared pool when data
//!     arrives and surfaces it on the completion (`Completion.recv_bytes`). A
//!     recv that finds the pool empty completes with
//!     `Completion.recv_no_buffer` instead of failing the connection.
//!   * `pub fn submitSend(self: *Backend, user_data: u64, fd: Fd, bytes: []const u8) !void;`
//!   * `pub fn submitClose(self: *Backend, user_data: u64, fd: Fd) !void;` —
//!     including the listen handle: cancel a pending accept (yield one accept
//!     completion with `result < 0` when one was armed) and close the fd so
//!     `Loop.closeAndDrain` cannot hang on an idle acceptor.
//!   * `pub fn shutdownFd(self: *Backend, fd: Fd) void;` — unblock an armed
//!     recv (TCP: `SHUT_RDWR`) so `closeAndDrain` does not wait on a quiet
//!     peer. Required on every Backend; a userspace backend's body may be a
//!     no-op.
//!   * `pub fn recycleRecv(self: *Backend, completion: Completion) void;` — hand
//!     the pool buffer behind a recv completion back. The loop calls it exactly
//!     once per completion whose `recv_bytes` is non-null, after consuming the
//!     bytes; the borrowed view is invalid afterward.
//!   * `pub fn poll(self: *Backend, out: []Completion, timeout_ms: i32) !usize;` —
//!     flush submitted operations and wait for completions. A negative
//!     `timeout_ms` blocks until at least one completes (or the backend's
//!     idle-wake policy applies). A non-negative `timeout_ms` waits at most that
//!     many milliseconds; zero completions in that window returns 0, not an
//!     error. Fills `out` with up to `out.len` completions and returns the count.
//!
//! The Loop is also parameterized by a `Locator`: OCapN
//! `(transport, designator, hint)` → `Backend.ConnectTarget`. That grammar
//! belongs on the netlayer (`tcp.DialResolver`, `iroh.DialResolver`), never on a
//! platform Backend. `Loop.dialLocator` is the only public dial verb.
//!
//! A readiness-based platform (kqueue) makes its backend look completion-shaped
//! internally: `submitRecv` records the request and `poll` performs the read once
//! the fd is ready — into a buffer from its own scratch pool — synthesizing the
//! completion. The loop sees the same interface either way.
//!
//! Every submitted op must eventually yield exactly one completion — including a
//! recv or send still pending when `submitClose` runs on its fd. The loop counts
//! a connection's in-flight ops and defers teardown until each retires, so a
//! backend that silently dropped a pending op on close would strand the slot.
//! io_uring posts a cancellation completion for these; a readiness backend
//! synthesizes them in `submitClose`.

const std = @import("std");

const foundation = @import("foundation");
const engine = @import("engine");
const frame_stream = @import("../frame_stream.zig");
const tcp_keepalive = @import("tcp_keepalive.zig");

/// Re-export so loop callers configure keepalive without a second import path.
pub const Keepalive = tcp_keepalive.Keepalive;

/// Shared recv scratch pool for readiness backends (kqueue, iroh). Re-exported
/// so the out-of-graph iroh resident reaches it through `net.completion` rather
/// than dual-homing the source file.
pub const ScratchPool = @import("scratch_pool.zig").ScratchPool;

/// Compile-time check that `Backend` declares the total dial/I/O contract the
/// Loop calls. Soft optionality (`@hasDecl` at call sites) is forbidden: a
/// missing member fails here, not as a latent special case on one path.
fn validateBackend(comptime Backend: type) void {
    const required = .{
        "Fd",
        "ConnectTarget",
        "deinit",
        "openListener",
        "boundPort",
        "closeFd",
        "startDial",
        "shutdownFd",
        "submitAccept",
        "submitRecv",
        "submitSend",
        "submitClose",
        "recycleRecv",
        "poll",
    };
    inline for (required) |name| {
        if (!@hasDecl(Backend, name)) {
            @compileError("completion Backend missing `" ++ name ++ "` — total contract, no optional dial/shutdown members");
        }
    }
}

/// Compile-time check that `Locator` turns OCapN locator parts into
/// `ConnectTarget`. Netlayer-owned; never a platform Backend concern.
fn validateLocator(comptime Locator: type, comptime ConnectTarget: type) void {
    if (!@hasDecl(Locator, "resolve")) {
        @compileError("completion Locator missing `resolve` — OCapN locator → ConnectTarget");
    }
    _ = ConnectTarget;
}

/// One finished operation reported by a backend: the `user_data` the submit
/// carried, and the platform result (bytes transferred, a new fd, or negative on
/// error, the same sign convention as the underlying syscall).
pub const Completion = struct {
    user_data: u64,
    result: i32,
    /// For a recv completion that selected a shared pool buffer: a borrowed
    /// view of backend-owned storage holding the received bytes. Valid until
    /// the loop hands the buffer back via `recycleRecv`; the loop consumes the
    /// bytes first and retains no reference after the recycle.
    recv_bytes: ?[]const u8 = null,
    /// Backend-opaque token identifying the pool buffer behind `recv_bytes`,
    /// passed back verbatim through `recycleRecv`. Meaningless when
    /// `recv_bytes` is null.
    recv_token: u32 = 0,
    /// True when a recv completed without data only because the shared pool
    /// was momentarily empty. The loop parks the connection buffer-starved and
    /// re-arms it when a buffer recycles; it never closes the connection for
    /// this.
    recv_no_buffer: bool = false,
};

/// Drain up to `out.len` ready completions from `ready` into `out`, sliding any
/// remainder to the front for the next call, and return the count moved. The one
/// remainder-slide both readiness backends' poll paths share (the kqueue backend
/// and the iroh completion `Backend`), so the copy-forward and shrink bookkeeping
/// lives in one place instead of a hand-copied block in each.
pub fn drainReady(ready: *std.ArrayList(Completion), out: []Completion) usize {
    const n = @min(ready.items.len, out.len);
    if (n == 0) return 0;
    @memcpy(out[0..n], ready.items[0..n]);
    const rest = ready.items.len - n;
    std.mem.copyForwards(Completion, ready.items[0..rest], ready.items[n..]);
    ready.shrinkRetainingCapacity(rest);
    return n;
}

/// Builds and configures the `Peer` for one accepted connection. The callback
/// chooses the handshake policy, publishes the shared application's bootstrap
/// capabilities, and queues the opening `op:start-session`. The server owns the
/// returned peer and deinits it when the connection closes. This is where many
/// connections bind to one shared application world.
pub const MakePeer = *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!engine.Peer;

/// Build the per-connection application context on accept. Called once the
/// connection's peer is in its final home, with `&conn.peer` stable for the
/// connection's life. A returned context may bind to that peer, for example an
/// `actors.Vat` that hosts the connection's objects. `null` means the connection
/// has no per-connection state. `net` stays actor-agnostic; the vat lives
/// one layer up and rides through this opaque pointer. `slot` is the
/// connection's loop slot — the handle `armOutbound` and `closeSlot` take from
/// a hook that works across connections. It is recycled once the connection
/// closes, so retain it only alongside the context this call builds.
pub const MakeConnCtx = *const fn (ctx: ?*anyopaque, peer: *engine.Peer, slot: usize) anyerror!?*anyopaque;

/// Per-event application hook. This is where objects run on the scalable path.
/// The loop invokes it for each surfaced event on a connection, after the engine
/// has already auto-answered a bootstrap fetch. The hook receives the
/// per-connection context from `MakeConnCtx`, the caller-owned peer, and the
/// borrowed event. If the hook enqueues a reply on `peer`, the same loop step
/// flushes it after the event is drained, matching `driver.BlockingSession.step`.
/// An error closes that one connection; it never tears down the loop.
pub const Serve = *const fn (conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void;

/// Tear down a per-connection context built by `MakeConnCtx`, on connection
/// close. Receives the shared `ctx` and the per-connection context to free.
pub const FreeConnCtx = *const fn (ctx: ?*anyopaque, conn_ctx: ?*anyopaque) void;

/// Close notification, fired once per connection at teardown, before
/// `free_conn_ctx` releases the per-connection context. Receives the shared
/// `ctx`, the per-connection context (null when the connection failed before
/// `make_conn_ctx` ran), and `opened`: true when the connection completed its
/// connect or accept, false when it failed before opening (e.g. a refused
/// dial). This is the loop's only failure surface for a dialed connection,
/// `dial` returns before the connect completes, so a refused dial is
/// observable nowhere else.
/// Why a connection is tearing down (ADR-0082). Surfaced on `OnClose` so an
/// embedder can tell ordinary peer loss from park-duration reclaim.
pub const CloseReason = enum {
    /// Partner EOF, read error, keepalive, `closeSlot`, refused dial, …
    ordinary,
    /// Stayed `.parked` past `Options.park_kill_ms`.
    park_kill,
};

/// `slot` is the connection's loop index: refused dials tear down before
/// `make_conn_ctx` runs (`conn_ctx` is null), so an embedder correlating an
/// in-flight dial to a ticket needs the slot — `conn_ctx` alone cannot name
/// it (ADR-0076 loop-side dial executor).
/// `reason` is `.park_kill` only when `park_kill_ms` reclaimed the seat.
pub const OnClose = *const fn (ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, opened: bool, reason: CloseReason) void;

/// Optional park notification (ADR-0082): fired when a connection's read seat
/// first enters `.parked`. `slot` and `conn_ctx` match `OnClose` so an embedder
/// can correlate lag to an open connection without scraping private Loop state.
pub const OnPark = *const fn (ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque) void;

/// The listen backlog both platform backends pass to `listen(2)`: pending,
/// not-yet-accepted connections the kernel queues before refusing new ones.
/// The loop re-arms its accept immediately after every completion, so the
/// backlog only has to absorb a connect burst between two loop wakes.
pub const listen_backlog: u31 = 128;

pub const Options = struct {
    /// Sizes the shared read-buffer pool (each buffer is `min(frame_cap,
    /// 16 KiB)`) and defaults the outbound high-water mark. It is not the
    /// frame-admission cap: the authority for how large an inbound frame may be
    /// is each peer's own `max_frame_bytes` (what the codec scans against and
    /// the loop's incomplete-at-cap mirror honors), so a peer configured with a
    /// larger `max_frame_bytes` than this is served correctly, not aborted. A
    /// frame larger than one pool buffer accumulates in the connection's bounded
    /// spill while in flight, so per-connection memory does not scale with it.
    frame_cap: usize = 1 << 16,
    max_conns: usize = 1024,
    /// Backend completion-queue depth hint.
    queue_entries: u16 = 256,
    /// Listen on this loopback port and accept inbound connections; 0 lets the
    /// kernel choose (read it back from `Loop.port`). `null` — the default —
    /// never binds, listens, or arms an accept, so a pure dialer loop exposes
    /// no socket a stranger could connect to.
    listen: ?u16 = null,
    /// Outbound backpressure high-water mark (ADR-0042): when a connection's
    /// pending outbound bytes cross this, the loop stops arming reads on it. No
    /// new inbound frames means no new replies. Reading resumes when
    /// the partner has drained the queue. `null` defaults to `frame_cap`, so a
    /// connection buffers about one largest-admissible frame of unread replies
    /// before its partner is made to catch up.
    outbound_high_water: ?usize = null,
    /// Size of the backend's shared read-buffer pool (ADR-0054). The pool is
    /// shared across every connection, so this sizes the *concurrent inbound
    /// burst*, not the connection count: an idle connection holds no read
    /// buffer, and a recv that finds the pool momentarily empty parks
    /// buffer-starved until any in-flight buffer recycles.
    read_buffers: u16 = 256,
    /// Optional per-event application hook (see `Serve`). Null leaves the loop
    /// blind to application traffic beyond the engine's auto-answered fetch.
    serve: ?Serve = null,
    /// Optional per-connection context builder (see `MakeConnCtx`). The thing it
    /// returns is handed to `serve` for every event on that connection and freed
    /// by `free_conn_ctx` at close. This is how a per-connection vat lives on the
    /// loop without `net` knowing what a vat is.
    make_conn_ctx: ?MakeConnCtx = null,
    /// Frees a per-connection context (see `FreeConnCtx`). Required when
    /// `make_conn_ctx` allocates.
    free_conn_ctx: ?FreeConnCtx = null,
    /// Optional close notification (see `OnClose`), fired once per connection
    /// at teardown. Null leaves closes (including failed dials) unobserved. This
    /// fires under `run`, not only at `closeAndDrain`: the moment any completion
    /// ends a connection — a partner's clean FIN, a read error from an RST, or a
    /// keepalive probe giving up on a dead remote host — the loop reclaims that
    /// one slot and fires `on_close(…, opened)` for it, leaving the rest of the
    /// loop running (ADR-0081).
    on_close: ?OnClose = null,
    /// Optional park notification (ADR-0082): fired when a connection's read
    /// seat enters `.parked` (outbound high-water or fan-in throttle). Embedders
    /// scrape lag without an in-core HTTP monitor.
    on_park: ?OnPark = null,
    /// Opt-in TCP keepalive. When set, all of idle/interval/count are applied
    /// on every accepted and dialed TCP fd (best-effort). Null — the default —
    /// leaves sockets without keepalive (NODELAY only). Do not "just enable"
    /// SO_KEEPALIVE: the OS idle default is hours. Rationale is NAT hold-open /
    /// dead-remote-host reclaim — not reaping a live orphaned process.
    ///
    /// This is also the loop's only automatic detector of a *silently* vanished
    /// peer (ADR-0081): a remote that disappears with no FIN and no RST — a
    /// crash, a cable pull, a partition — sends nothing, so its armed recv never
    /// completes and its slot is held until a completion surfaces. Keepalive is
    /// what makes one surface: its probes eventually fail, the recv completes
    /// with a read error, and `on_close` fires under `run`. Without it, and
    /// without application-level heartbeats, such a slot is reclaimed only at
    /// `closeAndDrain`. The detection deadline is deliberately the caller's — a
    /// liveness policy lives above pancake — which is why this stays opt-in
    /// rather than a silent default. See `tcp_keepalive.Keepalive`.
    keepalive: ?tcp_keepalive.Keepalive = null,
    /// Fan-in source throttle (ADR-0082): when any live connection is parked
    /// under ADR-0042 outbound high-water, also refuse to arm reads on every
    /// *other* connection until no connection remains parked. Off by default
    /// so existing scale harnesses keep per-connection-only backpressure;
    /// enable to prove many-A→one-B sources slow when the sink parks.
    fan_in_throttle: bool = false,
    /// Park-duration kill (ADR-0082 / NATS write_deadline analogue): if a
    /// connection stays `.parked` longer than this many milliseconds, the loop
    /// closes it. `null` (default) never kills on park age alone.
    park_kill_ms: ?u64 = null,
};

/// When `Loop.run` returns. Production servers and dialers run `.forever`;
/// tests stop after a known number of connections have fully closed.
pub const Stop = union(enum) {
    forever,
    after_closed: usize,
};

/// Which kind of submitted operation a completion belongs to. Packed into the low
/// bits of `user_data`; the rest is the connection slot index.
const Op = enum(u3) { accept, connect, recv, send, close };

fn userData(op: Op, slot: usize) u64 {
    return (@as(u64, slot) << 3) | @intFromEnum(op);
}
fn opOf(ud: u64) Op {
    return @enumFromInt(@as(u3, @truncate(ud)));
}
fn slotOf(ud: u64) usize {
    return @intCast(ud >> 3);
}

/// Wall-clock milliseconds since the Unix epoch for `runUntil` deadlines.
fn milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    switch (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.REALTIME, &ts))) {
        .SUCCESS => {},
        else => return 0,
    }
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divFloor(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// Size of one shared pool buffer (the spill carries the rare larger frame).
/// Large enough that ordinary CapTP traffic never spills; small enough that the
/// pool's memory is not set by `frame_cap`.
const loop_read_buf_bytes: usize = 16 * 1024;

/// Outbound queue capacity a drained `front` retains (ADR-0042). Shared with the
/// iroh loop in one home so the ladder's per-connection footprint budget cannot
/// split between them.
const steady_outbound_bytes: usize = frame_stream.steady_outbound_bytes;

/// Per-connection slot bookkeeping ceiling (ADR-0045): the most a `Conn` may
/// cost *beyond* the `engine.Peer` it embeds — the slot state, the outbound
/// queue's two `ArrayList` headers, the spill header, the intrusive link, and
/// the in-flight/context words. `Peer` is gated by its own `@sizeOf(Peer)`
/// ceiling; this guards the wrapper the loop allocates `max_conns` of, which
/// nothing capped before. Isolating the overhead keeps a `Peer` change within
/// its own ceiling from tripping this, while a new `Conn` field always does.
/// The number lives here and in docs/ladder.md rung 2 together; raise it only
/// by weighing the bytes, never to route around the gate. The measured overhead
/// is 112 bytes on every backend (`Backend.Fd` is `i32` for tcp, kqueue, uring,
/// and iroh alike, so `Conn` carries no backend-dependent width); the ceiling
/// keeps one word of headroom over that for cross-target padding stability.
const conn_slot_overhead_bytes: usize = 128;

/// How recv-completion consumption ended, decided by `onRecvConsume` while
/// the completion's pool buffer is still borrowed and acted on by
/// `onRecvFinish` after the buffer has been recycled, so every exit path
/// recycles exactly once.
const RecvVerdict = enum {
    /// Bytes consumed; run events, outbound drive, and the next read arm.
    proceed,
    /// Close this connection after flushing what the engine projected
    /// (typically an `op:abort`).
    fail,
    /// Close this connection without an engine projection (EOF, read error,
    /// or out of memory).
    close,
    /// Nothing further: the connection was already closing, or it parked
    /// buffer-starved.
    done,
};

/// The portable completion-driven connection loop over a platform `Backend`
/// and a netlayer `DialResolver` (OCapN locator parts → `Backend.ConnectTarget`).
pub fn Loop(comptime Backend: type, comptime Locator: type) type {
    comptime validateBackend(Backend);
    comptime validateLocator(Locator, Backend.ConnectTarget);
    return struct {
        const Self = @This();
        const Fd = Backend.Fd;
        const ConnectTarget = Backend.ConnectTarget;

        const Conn = struct {
            /// The slot lifecycle: `.free` slots sit on the free list, `.open`
            /// slots carry a live (or still-connecting) connection, `.closing`
            /// slots have their close queued and wait for in-flight ops to
            /// retire before `teardown` reclaims them.
            state: enum { free, open, closing } = .free,
            /// The read seat — exactly one recv is armed per open connection,
            /// or the seat is explicitly idle/parked: `.idle` between a recv
            /// completion and its verdict, `.armed` while a recv is submitted,
            /// `.parked` under ADR-0042 backpressure (outbound past the
            /// high-water mark; `onSend`'s drain resumes it), `.starved` when
            /// the shared pool was empty (ADR-0054; a recycle resumes it).
            read: enum { idle, armed, parked, starved } = .idle,
            /// Wall-clock ms when this connection entered `.parked`, or 0 when
            /// not parked. Used by `Options.park_kill_ms` (ADR-0082).
            parked_at_ms: i64 = 0,
            /// True once the connection completed its connect or accept; false
            /// for a dialed connection that failed before opening. Reported to
            /// `Options.on_close` at teardown.
            opened: bool = false,
            /// Why this connection is closing; set before `closeConn` for
            /// park-kill so `on_close` can name the reclaim (ADR-0082).
            close_reason: CloseReason = .ordinary,
            fd: Fd = undefined,
            peer: engine.Peer = undefined,
            /// Bounded overflow for a frame that does not complete within one
            /// recv completion's borrowed pool buffer; inactive (and
            /// allocation-free) while whole frames arrive per completion.
            spill: frame_stream.Spill = .{},
            /// The frozen half of the outbound queue. A submitted write borrows
            /// `front.items[front_off..]` until the backend reports it complete,
            /// so nothing may append to (or otherwise resize) `front` while
            /// `write_in_flight` — a realloc would free the storage the kernel
            /// is still reading. Bytes queued meanwhile land in `back`.
            front: std.ArrayList(u8) = .empty,
            front_off: usize = 0,
            /// The open half of the outbound queue: where `flushOutbound`
            /// appends while a write is in flight. When the in-flight write
            /// drains, the emptied front and this swap, and the queued bytes
            /// submit as the next write.
            back: std.ArrayList(u8) = .empty,
            write_in_flight: bool = false,
            /// Per-connection recv/send/close operations the backend has not yet
            /// reported complete. Teardown waits for this to reach zero, so the
            /// slot is never reused and `front` is never freed while a
            /// completion-based backend could still write into it. That prevents
            /// stale completions from landing on a reused slot and prevents the
            /// kernel from writing a pending send's bytes after they are freed.
            ops_in_flight: usize = 0,
            /// Per-connection application context (from `make_conn_ctx`), passed
            /// to the serve hook for every event and freed at teardown. Opaque to
            /// this layer. Typically this is the connection's `actors.Vat`.
            app_ctx: ?*anyopaque = null,
            /// Intrusive link for the one list this slot is on: the free list
            /// while `state == .free`, or the buffer-starved list while
            /// `read == .starved`. The two are disjoint — a free slot is never
            /// open, so never starved — so one link serves both, holding the
            /// next slot index or `conns.len` as the end sentinel. `unlinkStarved`
            /// clears the starved link before `closeConn`, and `teardown` resets
            /// the slot before `pushFreeSlot` relinks it, so a starved successor
            /// never rides into the free list.
            next_link: usize = 0,
        };

        comptime {
            // The 500k-connection budget is gated at the unit the loop
            // multiplies (ADR-0045). A field added to `Conn` is a withdrawal;
            // trip this and weigh the bytes, then raise the number here and in
            // docs/ladder.md rung 2 together — never route around the gate.
            std.debug.assert(@sizeOf(Conn) - @sizeOf(engine.Peer) <= conn_slot_overhead_bytes);
        }

        allocator: std.mem.Allocator,
        backend: Backend,
        /// The bound listening socket, or null when `Options.listen` was null:
        /// a pure dialer loop never listens and never arms an accept.
        listen_fd: ?Fd,
        /// The kernel-chosen bound port when listening; null when not.
        port: ?u16,
        conns: []Conn,
        frame_cap: usize,
        outbound_high_water: usize,
        make_peer: MakePeer,
        make_ctx: ?*anyopaque,
        serve: ?Serve,
        make_conn_ctx: ?MakeConnCtx,
        free_conn_ctx: ?FreeConnCtx,
        on_close: ?OnClose,
        /// Optional park notification (ADR-0082); see `Options.on_park`.
        on_park: ?OnPark,
        /// Opt-in TCP keepalive applied at connect/accept finish (see `Options`).
        keepalive: ?tcp_keepalive.Keepalive,
        /// Fan-in source throttle (ADR-0082); see `Options.fan_in_throttle`.
        fan_in_throttle: bool,
        /// Park-duration kill (ADR-0082); see `Options.park_kill_ms`.
        park_kill_ms: ?u64,
        closed_count: usize = 0,
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
        /// Debug-only owning thread: latched when `run` begins, asserted on
        /// every `armOutbound`/`closeSlot` (and other public entries). Zero-
        /// sized in release. The loop is single-threaded by contract.
        owner_tid: if (std.debug.runtime_safety) ?std.Thread.Id else void =
            if (std.debug.runtime_safety) null else {},
        /// Head of the intrusive free-slot list threaded through `Conn.next_link`
        /// while a slot is free; `conns.len` when every slot is in use. Keeps slot
        /// allocate and release O(1) at any `max_conns`.
        free_head: usize,
        /// Head of the intrusive buffer-starved list threaded through the same
        /// `Conn.next_link` while a slot is starved; `conns.len` when no
        /// connection is starved.
        starved_head: usize,

        /// Build a loop over a backend the caller already constructed. Use this
        /// when the backend needs state `Backend.init` cannot take (an iroh
        /// resident's endpoint). Socket backends prefer `init`, which builds
        /// the platform backend itself.
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
            const listen_fd: ?Fd = if (options.listen) |listen_port| try backend_mut.openListener(listen_port) else null;
            errdefer if (listen_fd) |fd| backend_mut.closeFd(fd);
            const bound_port: ?u16 = if (listen_fd) |fd| try Backend.boundPort(fd) else null;

            const conns = try allocator.alloc(Conn, options.max_conns);
            errdefer allocator.free(conns);
            for (conns, 0..) |*c, i| {
                c.* = .{};
                c.next_link = i + 1;
            }

            return .{
                .allocator = allocator,
                .backend = backend_mut,
                .listen_fd = listen_fd,
                .port = bound_port,
                .conns = conns,
                .frame_cap = options.frame_cap,
                .outbound_high_water = options.outbound_high_water orelse options.frame_cap,
                .make_peer = make_peer,
                .make_ctx = make_ctx,
                .serve = options.serve,
                .make_conn_ctx = options.make_conn_ctx,
                .free_conn_ctx = options.free_conn_ctx,
                .on_close = options.on_close,
                .on_park = options.on_park,
                .keepalive = options.keepalive,
                .fan_in_throttle = options.fan_in_throttle,
                .park_kill_ms = options.park_kill_ms,
                .free_head = 0,
                .starved_head = conns.len,
            };
        }

        pub fn init(
            allocator: std.mem.Allocator,
            make_peer: MakePeer,
            make_ctx: ?*anyopaque,
            options: Options,
        ) !Self {
            const read_buffer_bytes: u32 = @intCast(@min(options.frame_cap, loop_read_buf_bytes));
            const backend = try Backend.init(allocator, options.queue_entries, options.read_buffers, read_buffer_bytes);
            return initWithBackend(allocator, backend, make_peer, make_ctx, options);
        }

        /// Tear down the loop. Requires every connection's in-flight ops to
        /// have retired — call `closeAndDrain` (or stop with
        /// `.{ .after_closed = n }` once those closes complete) before this.
        /// A submitted send borrows the connection's `front` buffer until the
        /// backend reports it complete, so freeing a connection with an op
        /// still in flight would hand the kernel freed storage; that is a
        /// use-after-free, not a leak. Draining without closing first is not
        /// an option: `poll` blocks until *something* completes, and an armed
        /// recv on an idle partner never does. So `deinit` asserts that every
        /// remaining connection has no op in flight rather than draining.
        pub fn deinit(self: *Self) void {
            self.tearing_down = true;
            for (self.conns, 0..) |*c, slot| if (c.state != .free) {
                std.debug.assert(c.ops_in_flight == 0);
                // A closing connection's fd rides its already-queued close op;
                // an open one has no close queued anywhere, so it must be
                // closed here or it leaks (teardown never closes fds).
                if (c.state == .open) self.backend.closeFd(c.fd);
                self.teardown(slot);
            };
            self.allocator.free(self.conns);
            if (self.listen_fd) |fd| self.backend.closeFd(fd);
            self.backend.deinit();
        }

        /// Run the loop until `stop` says to return: `.forever` for a
        /// production server or dialer, `.{ .after_closed = n }` to return once
        /// `n` connections have been fully served and closed (the test-shaped
        /// stop condition). Per-connection failures close only their
        /// connection; the errors that escape here are loop-global, namely a
        /// backend poll failure or a listener accept re-arm failure.
        pub fn run(self: *Self, stop: Stop) !void {
            self.latchOwner();
            if (self.listen_fd) |fd| try self.backend.submitAccept(userData(.accept, 0), fd);
            // Per-poll batch cap, deliberately independent of
            // `Options.queue_entries`: a deeper completion queue drains across
            // more polls, while the fixed stack batch keeps `run` allocation-free.
            const poll_batch = 256;
            var completions: [poll_batch]Completion = undefined;
            while (switch (stop) {
                .forever => true,
                .after_closed => |n| self.closed_count < n,
            }) {
                const n = try self.backend.poll(&completions, -1);
                for (completions[0..n]) |c| try self.dispatch(c);
                // Every pool buffer this batch carried has been recycled, so
                // re-arm whatever parked buffer-starved during the batch. A
                // starved completion can be dispatched after the recycle that
                // should have resumed it; this sweep closes that ordering gap.
                self.resumeStarved(.all);
                self.reapParkKills();
            }
        }

        /// Drive the loop until `done` is true. Same poll/dispatch body as
        /// `run` until the flag a Host vow callback (or peer teardown) sets.
        /// Call from the loop-owner thread — the same affinity as `dial`.
        ///
        /// `deadline_ms` bounds wall-clock wait time from the first poll:
        /// `0` is unbounded (prior behavior); a positive value polls with the
        /// remaining milliseconds and returns `error.Timeout` if the deadline
        /// elapses while `done` is still false — the same contract as
        /// `Connection.runUntil`.
        ///
        /// If `done` is set from another thread, that thread must also wake
        /// this loop's `poll` (for a listening loop, a connect-and-drop against
        /// the bound port is enough). A flag set from a serve/vow callback on
        /// this thread needs no wake — the next loop iteration sees it.
        ///
        /// After return, slots may still hold armed recvs; call `closeAndDrain`
        /// before `deinit`.
        pub fn runUntil(self: *Self, done: *const std.atomic.Value(bool), deadline_ms: i32) !void {
            self.latchOwner();
            if (self.listen_fd) |fd| try self.backend.submitAccept(userData(.accept, 0), fd);
            const poll_batch = 256;
            var completions: [poll_batch]Completion = undefined;
            const deadline_start: ?i64 = if (deadline_ms > 0) milliTimestamp() else null;
            while (!done.load(.acquire)) {
                const poll_timeout: i32 = if (deadline_ms > 0) blk: {
                    const elapsed = milliTimestamp() - deadline_start.?;
                    const remaining = deadline_ms - @as(i32, @intCast(elapsed));
                    if (remaining <= 0) return error.Timeout;
                    break :blk remaining;
                } else -1;
                const n = try self.backend.poll(&completions, poll_timeout);
                for (completions[0..n]) |c| try self.dispatch(c);
                self.resumeStarved(.all);
                self.reapParkKills();
            }
            // closeAndDrain is separate: callers that need honest deinit invoke
            // it after runUntil (same thread), once CapTP work is done.
        }

        /// Close every open connection and the listen handle, then poll until
        /// every slot is free. After this returns, `deinit` is safe: no armed
        /// recv can hang the drain because each close retires pending ops
        /// (Backend contract). Call from the loop-owner thread — typically
        /// after `runUntil` returns, or after an early `run` return that left
        /// slots live.
        pub fn closeAndDrain(self: *Self) !void {
            self.latchOwner();
            if (self.shutting_down) return;
            self.shutting_down = true;
            // Do not set tearing_down yet: closeConn must still submitClose.
            // freeConnCtx skips drainActions while shutting_down.

            // Cancel a pending accept and close the listen handle first so the
            // drain poll cannot block forever on an idle acceptor. Null the
            // field before submit so `deinit` does not double-close; Backends
            // must yield an accept completion (result < 0) when one was armed.
            if (self.listen_fd) |fd| {
                self.listen_fd = null;
                self.backend.submitClose(userData(.close, self.conns.len), fd) catch self.backend.closeFd(fd);
            }

            for (self.conns, 0..) |*c, slot| {
                // Hard close: skip the abort flush. Shutdown first so an armed
                // recv on a quiet peer completes immediately; otherwise the
                // drain can wait until the peer drops.
                if (c.state == .open) {
                    self.backend.shutdownFd(c.fd);
                    self.closeConn(slot, c);
                }
            }

            const poll_batch = 256;
            var completions: [poll_batch]Completion = undefined;
            while (self.anyBusy()) {
                const n = try self.backend.poll(&completions, -1);
                for (completions[0..n]) |c| try self.dispatch(c);
                self.resumeStarved(.all);
            }
        }

        fn anyBusy(self: *const Self) bool {
            for (self.conns) |c| if (c.state != .free) return true;
            return false;
        }

        /// Resolve OCapN locator parts through the Locator, then admit the dial.
        /// This is the only public dial verb: above the net boundary callers speak
        /// only `transport` + `designator` + hint, never a Backend `ConnectTarget`.
        pub fn dialLocator(
            self: *Self,
            transport: []const u8,
            designator: []const u8,
            direct_addresses_hint: []const u8,
        ) !usize {
            const target = try Locator.resolve(transport, designator, direct_addresses_hint);
            return self.dial(target);
        }

        /// Admit an outbound dial into the same slot lifecycle as an accepted
        /// connection once the backend reports connect completion. Returns the
        /// connection's slot index. Slots are recycled: the value is only valid
        /// until the connection closes, after which it may name a different
        /// connection. `Options.on_close` is where a dialed connection's end
        /// (including a refused connect) is observed.
        ///
        /// Private: resolve happens in `dialLocator`. The Backend owns dial
        /// *start* (`startDial`); the Loop only allocates the slot and peer,
        /// then accounts the in-flight connect op.
        fn dial(self: *Self, target: ConnectTarget) !usize {
            if (self.shutting_down or self.tearing_down) return error.ShuttingDown;

            const slot = self.freeSlot() orelse return error.TooManyConnections;
            errdefer self.pushFreeSlot(slot);
            var peer = try self.make_peer(self.make_ctx, self.allocator);
            errdefer peer.deinit();

            const fd = try self.backend.startDial(userData(.connect, slot), target);
            // startDial submitted the connect: the slot must own the fd and the
            // in-flight op before any further failure can run, or a completion
            // would land with nowhere to go.
            const c = &self.conns[slot];
            c.* = .{ .state = .open, .fd = fd, .peer = peer };
            c.ops_in_flight += 1;
            return slot;
        }

        fn dispatch(self: *Self, comp: Completion) !void {
            const slot = slotOf(comp.user_data);
            switch (opOf(comp.user_data)) {
                // The only handler that may fail the loop: a dead accept re-arm
                // is loop-global. Every per-connection handler resolves its own
                // failures by closing that one connection.
                .accept => try self.onAccept(comp.result),
                .connect => {
                    self.onConnect(slot, comp.result);
                    self.retireConnOp(slot);
                },
                // Each per-connection op decrements its in-flight count after the
                // handler runs; the last one on a closing connection reclaims it.
                .recv => {
                    // Consume the borrowed pool bytes, recycle the buffer —
                    // exactly once per completion that carried one, on every
                    // verdict — then act on the verdict.
                    const verdict = self.onRecvConsume(slot, comp);
                    if (comp.recv_bytes != null) self.recycleRecvBuffer(comp);
                    self.onRecvFinish(slot, verdict);
                    self.retireConnOp(slot);
                },
                .send => {
                    self.onSend(slot, comp.result);
                    self.retireConnOp(slot);
                },
                .close => self.retireConnOp(slot),
            }
        }

        fn armAccept(self: *Self) !void {
            // Only reachable from an accept completion, which only a listening
            // loop ever receives.
            try self.backend.submitAccept(userData(.accept, 0), self.listen_fd.?);
        }

        fn onAccept(self: *Self, res: i32) !void {
            // Shutdown closed the listener (or cancelled its accept): drop any
            // racing accept and never re-arm.
            if (self.shutting_down or self.listen_fd == null) {
                if (res >= 0) self.backend.closeFd(@intCast(res));
                return;
            }
            // Keep one accept armed so the next connection is not missed. The
            // re-arm runs first deliberately; if it fails (loop-global, kills
            // `run`), the accepted fd must still be closed, not leaked.
            errdefer if (res >= 0) self.backend.closeFd(@intCast(res));
            try self.armAccept();
            if (res < 0) return; // transient accept failure: the re-arm recovers

            const fd: Fd = @intCast(res);
            const slot = self.freeSlot() orelse {
                self.backend.submitClose(userData(.close, self.conns.len), fd) catch self.backend.closeFd(fd);
                return;
            };
            const c = &self.conns[slot];

            const peer = self.make_peer(self.make_ctx, self.allocator) catch {
                self.pushFreeSlot(slot);
                self.backend.submitClose(userData(.close, self.conns.len), fd) catch self.backend.closeFd(fd);
                return;
            };
            c.* = .{ .state = .open, .opened = true, .fd = fd, .peer = peer };
            self.finishConnected(slot, c);
        }

        fn onConnect(self: *Self, slot: usize, res: i32) void {
            const c = self.liveConn(slot) orelse {
                // Iroh success returns the synthetic fd as `result`; if the
                // slot was torn down before this completion, free that fd.
                if (res > 0) self.backend.closeFd(res);
                return;
            };
            if (res < 0) {
                self.closeConn(slot, c);
                return;
            }
            // TCP connect succeeds with result 0 and `c.fd` already set.
            // Iroh connect succeeds with result = synthetic fd (>= 1).
            if (res > 0) c.fd = res;
            c.opened = true;
            self.finishConnected(slot, c);
        }

        fn finishConnected(self: *Self, slot: usize, c: *Conn) void {
            // No per-connection read buffer is allocated: reads borrow from the
            // backend's shared pool, completion by completion (ADR-0054).

            // Opt-in TCP keepalive: both accept and dial land here. Best-effort
            // on non-TCP backends (iroh synthetic fds): apply fails quietly.
            if (self.keepalive) |ka| {
                tcp_keepalive.apply(@intCast(c.fd), ka);
            }

            // Bind the per-connection application context to this connection's
            // peer now that it sits at its final, stable address. A failure here
            // closes the connection cleanly rather than serving it context-less.
            if (self.make_conn_ctx) |make| {
                c.app_ctx = make(self.make_ctx, &c.peer, slot) catch {
                    self.closeConn(slot, c);
                    return;
                };
            }

            self.driveOut(slot, c) catch {
                self.failConn(slot, c);
                return;
            };
            self.armOrPark(slot, c) catch self.closeConn(slot, c);
        }

        /// The cross-connection outbound arm: encode and submit whatever is
        /// queued on `slot`'s peer. This is how work enqueued on a connection
        /// the loop is *not* currently serving reaches the wire — a hook
        /// serving connection A that enqueued sends on connection B's peer
        /// calls this with B's slot, and B's frames go out without waiting
        /// for B's own traffic. Safe mid-dispatch: the loop is
        /// single-threaded, the drive touches only `slot`'s connection,
        /// `write_in_flight` prevents a double submit, and ADR-0042 parking
        /// still engages at that connection's next `armOrPark`. Idempotent
        /// for the slot currently being served (its own post-event drive
        /// finds nothing left), and a no-op on a free, closing, or
        /// tearing-down slot. A drive failure resolves like any
        /// per-connection failure: that one connection fails and closes.
        pub fn armOutbound(self: *Self, slot: usize) void {
            self.assertOwner();
            if (self.tearing_down) return;
            const c = self.liveConn(slot) orelse return;
            self.driveOut(slot, c) catch self.failConn(slot, c);
        }

        /// Close the connection at `slot` after a best-effort flush of
        /// whatever the engine projected onto its outbound (typically an
        /// `op:abort`) — the "arm, then close" entry a bridge's `close`
        /// action needs. No-op on a free, closing, or tearing-down slot; the
        /// teardown itself rides the ordinary close path, so in-flight ops
        /// retire before the slot is reclaimed.
        pub fn closeSlot(self: *Self, slot: usize) void {
            self.assertOwner();
            if (self.tearing_down) return;
            const c = self.liveConn(slot) orelse return;
            self.failConn(slot, c);
        }

        /// Latch the owning thread at `run` entry. Setup (`init`, `dial`,
        /// `attach`) may run on a different thread before the loop starts;
        /// only the run thread may call `armOutbound`/`closeSlot`.
        fn latchOwner(self: *Self) void {
            if (comptime !std.debug.runtime_safety) return;
            const tid = std.Thread.getCurrentId();
            if (self.owner_tid) |owned| {
                std.debug.assert(owned == tid);
            } else {
                self.owner_tid = tid;
            }
        }

        fn assertOwner(self: *const Self) void {
            if (comptime !std.debug.runtime_safety) return;
            std.debug.assert(self.owner_tid != null);
            std.debug.assert(self.owner_tid.? == std.Thread.getCurrentId());
        }

        /// The connection at `slot`, when a completion landing there is still
        /// addressed to a live connection. Null drops the stale cases: a slot
        /// index from a torn-down (possibly already reused) connection, and a
        /// closing connection whose remaining completions only retire ops.
        fn liveConn(self: *Self, slot: usize) ?*Conn {
            if (slot >= self.conns.len) return null;
            const c = &self.conns[slot];
            if (c.state != .open) return null;
            return c;
        }

        fn armRecv(self: *Self, slot: usize, c: *Conn) !void {
            // One recv per connection: arming over an armed/parked/starved
            // read seat would double-arm and corrupt the seat's accounting.
            std.debug.assert(c.read == .idle);
            try self.backend.submitRecv(userData(.recv, slot), c.fd);
            c.read = .armed;
            c.ops_in_flight += 1;
        }

        /// Outbound bytes queued but not yet written to the wire: the unwritten
        /// tail of the frozen front plus everything queued behind it on the
        /// back. This is the quantity the ADR-0042 high-water mark bounds.
        fn pendingOut(c: *const Conn) usize {
            return pendingFront(c) + c.back.items.len;
        }

        /// The unwritten tail of the frozen submit buffer.
        fn pendingFront(c: *const Conn) usize {
            return c.front.items.len - c.front_off;
        }

        /// Arm the next read, unless the partner is not draining our writes.
        /// Pending outbound past the high-water mark means every newly applied
        /// inbound frame would pile more replies onto an unread socket, so the
        /// read parks instead and `onSend` resumes it when the queue drains
        /// (ADR-0042). With `fan_in_throttle`, a parked sink also parks every
        /// other connection's reads so many-A→one-B sources slow (ADR-0082).
        /// Protocol frames are never dropped; the queue is bounded at the mark
        /// plus the replies of frames already buffered.
        fn armOrPark(self: *Self, slot: usize, c: *Conn) !void {
            if (pendingOut(c) > self.outbound_high_water) {
                self.markParked(slot, c);
                return;
            }
            if (self.fan_in_throttle and self.anySinkParked()) {
                self.markParked(slot, c);
                return;
            }
            try self.armRecv(slot, c);
        }

        fn markParked(self: *Self, slot: usize, c: *Conn) void {
            if (c.read != .parked) {
                c.parked_at_ms = if (self.park_kill_ms != null) milliTimestamp() else 0;
                if (self.on_park) |hook| hook(self.make_ctx, slot, c.app_ctx);
            }
            c.read = .parked;
        }

        /// True when any open connection is over its outbound high-water mark
        /// (a true ADR-0042 sink park, not a fan-in source park).
        fn anySinkParked(self: *Self) bool {
            for (self.conns) |*c| {
                if (c.state == .open and pendingOut(c) > self.outbound_high_water) return true;
            }
            return false;
        }

        /// Close connections that have stayed `.parked` past `park_kill_ms`.
        fn reapParkKills(self: *Self) void {
            const limit = self.park_kill_ms orelse return;
            const now = milliTimestamp();
            for (self.conns, 0..) |*c, slot| {
                if (c.state != .open or c.read != .parked) continue;
                if (c.parked_at_ms == 0) continue;
                if (now - c.parked_at_ms < @as(i64, @intCast(limit))) continue;
                c.close_reason = .park_kill;
                self.closeConn(slot, c);
            }
        }

        /// Consume one recv completion's bytes while its pool buffer is still
        /// borrowed. Whole frames apply zero-copy straight from the completion
        /// view, advancing by offset; a partial tail absorbs into the bounded
        /// spill (ADR-0041) because the buffer goes back to the pool the moment
        /// this returns. The follow-up work that does not need the buffer —
        /// events, outbound drive, the next read arm — runs in
        /// `onRecvFinish`, after the recycle.
        fn onRecvConsume(self: *Self, slot: usize, comp: Completion) RecvVerdict {
            const c = self.liveConn(slot) orelse return .done;
            // This completion retires the one armed recv: the read seat is
            // idle until the verdict re-arms or parks it.
            std.debug.assert(c.read == .armed);
            c.read = .idle;
            if (comp.recv_no_buffer) {
                // The shared pool was momentarily empty when data arrived. Not
                // a connection failure: park buffer-starved; a recycle (or the
                // end-of-batch sweep) re-arms the read.
                self.parkStarved(slot, c);
                return .done;
            }
            if (comp.result <= 0) {
                // result == 0 is a clean EOF; negative is a read error. Either
                // ends the connection.
                return .close;
            }

            const incoming = comp.recv_bytes orelse &.{};

            // Apply every whole frame in this completion's bytes, carrying a
            // partial tail into the connection's spill. recvStreamPrefix projects
            // an op:abort for a malformed or oversize frame before erroring; the
            // .fail verdict flushes it, then closes. The drain, its cap mirror,
            // and the tail-to-spill copy are shared with the iroh loop in
            // `frame_stream.drainWholeFrames`, so the two cannot drift.
            return switch (frame_stream.drainWholeFrames(&c.peer, &c.spill, incoming, self.allocator)) {
                .ok => .proceed,
                .fail => .fail,
                .close => .close,
            };
        }

        /// Act on `onRecvConsume`'s verdict, after the completion's pool
        /// buffer has been recycled.
        fn onRecvFinish(self: *Self, slot: usize, verdict: RecvVerdict) void {
            // The .close and .fail arms skip the `liveConn` guard on purpose:
            // a non-.done verdict was minted under it in `onRecvConsume`, and
            // the recycle between consume and finish cannot close this slot
            // (this connection completed a recv, so it is not on the starved
            // list the recycle resumes).
            switch (verdict) {
                .done => return,
                .close => {
                    const c = &self.conns[slot];
                    self.closeConn(slot, c);
                    return;
                },
                .fail => {
                    const c = &self.conns[slot];
                    self.failConn(slot, c);
                    return;
                },
                .proceed => {},
            }
            const c = self.liveConn(slot) orelse return;

            // Surfaced events belong to the application. The engine auto-answers
            // a bootstrap fetch; every other event (an application deliver or
            // resolve) is offered to the optional serve hook, then released. With
            // no hook, the loop is blind to application traffic. The hook is where
            // an application runs objects on the scalable path. A hook error
            // closes only that connection; one bad partner never tears down the
            // loop. A reply the hook enqueues on the peer flushes in the
            // `driveOut` below, matching the drain-then-flush order
            // `driver.BlockingSession.step` uses.
            while (c.peer.pollEvent()) |ev_in| {
                var ev = ev_in;
                defer ev.deinit();
                if (self.serve) |serve_fn| {
                    serve_fn(c.app_ctx, &c.peer, &ev) catch {
                        self.failConn(slot, c);
                        return;
                    };
                }
            }

            self.driveOut(slot, c) catch {
                self.failConn(slot, c);
                return;
            };
            if (c.state == .closing) return;

            self.armOrPark(slot, c) catch self.closeConn(slot, c);
        }

        /// Park a connection whose recv found the shared pool empty. Distinct
        /// from `.parked` (ADR-0042), which is deliberate backpressure;
        /// starvation is transient pool contention and resolves as soon as a
        /// buffer recycles.
        fn parkStarved(self: *Self, slot: usize, c: *Conn) void {
            // Only an idle read seat parks starved: the caller's recv
            // completion just vacated it, and linking an already-listed slot
            // would build a cycle.
            std.debug.assert(c.read == .idle);
            c.read = .starved;
            c.next_link = self.starved_head;
            self.starved_head = slot;
        }

        /// Remove a connection from the starved list (on close) so teardown's
        /// slot reset cannot break the chain. O(starved count), on the close
        /// path only.
        fn unlinkStarved(self: *Self, slot: usize) void {
            const c = &self.conns[slot];
            if (c.read != .starved) return;
            c.read = .idle;
            if (self.starved_head == slot) {
                self.starved_head = c.next_link;
                return;
            }
            var i = self.starved_head;
            while (i < self.conns.len) {
                const node = &self.conns[i];
                if (node.next_link == slot) {
                    node.next_link = c.next_link;
                    return;
                }
                i = node.next_link;
            }
            // The read seat was `.starved`, so the slot must be in the list,
            // `parkStarved` links and marks together. Falling off the end means
            // the chain is corrupt; keep that loud instead of letting a later
            // `parkStarved` build a cycle on the broken link.
            unreachable;
        }

        /// Hand a recv completion's pool buffer back to the backend — the loop
        /// calls this exactly once per completion that carried one — then re-arm
        /// one buffer-starved connection, since exactly one buffer just became
        /// available.
        fn recycleRecvBuffer(self: *Self, comp: Completion) void {
            self.backend.recycleRecv(comp);
            self.resumeStarved(.one);
        }

        /// Re-arm starved connections. `.one` re-arms the first that can read —
        /// the per-recycle cadence, since exactly one buffer just freed. `.all`
        /// drains the list — the end-of-poll-batch cadence, when every pool
        /// buffer the batch carried has been recycled: a connection parked by a
        /// starved completion dispatched *after* the batch's recycles would
        /// otherwise wait for a recycle that already happened. Either way, one
        /// whose outbound crossed the high-water mark re-parks under ADR-0042
        /// (its drain re-arms it) without consuming a freed buffer, and a
        /// re-armed read that loses the race for a buffer simply completes
        /// starved again; it is never dropped.
        fn resumeStarved(self: *Self, comptime scope: enum { one, all }) void {
            while (self.starved_head < self.conns.len) {
                const slot = self.starved_head;
                const c = &self.conns[slot];
                self.starved_head = c.next_link;
                c.read = .idle;
                if (c.state != .open) continue;
                if (pendingOut(c) > self.outbound_high_water) {
                    self.markParked(slot, c);
                    continue;
                }
                if (self.fan_in_throttle and self.anySinkParked()) {
                    self.markParked(slot, c);
                    continue;
                }
                self.armRecv(slot, c) catch {
                    self.closeConn(slot, c);
                    continue;
                };
                if (scope == .one) return;
            }
        }

        /// Encode queued sends, append their frame bytes to the outbound queue,
        /// and submit a write if one is not already in flight.
        fn driveOut(self: *Self, slot: usize, c: *Conn) !void {
            while ((try c.peer.step()) != .idle) {}
            try self.flushOutbound(slot, c);
        }

        /// Append already-encoded outbound frames to the connection's queue and
        /// submit a write. Split from `driveOut` so a failed `step` can still
        /// flush the `op:abort` the engine projected for it. Frames always
        /// append to `back`: while a write is in flight, the backend borrows
        /// `front`'s storage, and an append there could realloc it out from
        /// under the kernel. With no write in flight, a drained front swaps
        /// with the back and the queued bytes become the next frozen submit.
        fn flushOutbound(self: *Self, slot: usize, c: *Conn) !void {
            try frame_stream.queueOutboundBytes(&c.peer, self.allocator, &c.back);
            if (c.write_in_flight) return;
            if (pendingFront(c) == 0 and c.back.items.len > 0) {
                c.front.clearRetainingCapacity();
                c.front_off = 0;
                std.mem.swap(std.ArrayList(u8), &c.front, &c.back);
            }
            if (pendingFront(c) > 0) try self.submitSend(slot, c);
        }

        /// Resolve a per-connection failure the way the blocking pump does
        /// (`connection.pumpOver`): best-effort encode and flush whatever the
        /// engine projected — typically an `op:abort` — then close this one
        /// connection. Every error is swallowed; one bad partner never tears
        /// down the loop.
        fn failConn(self: *Self, slot: usize, c: *Conn) void {
            while ((c.peer.step() catch .idle) != .idle) {}
            self.flushOutbound(slot, c) catch {};
            self.closeConn(slot, c);
        }

        fn submitSend(self: *Self, slot: usize, c: *Conn) !void {
            // The backend borrows this slice until the send completes; `front`
            // is frozen from here until `onSend` sees it drained.
            try self.backend.submitSend(userData(.send, slot), c.fd, c.front.items[c.front_off..]);
            c.write_in_flight = true;
            c.ops_in_flight += 1;
        }

        fn onSend(self: *Self, slot: usize, res: i32) void {
            const c = self.liveConn(slot) orelse return;
            if (res <= 0) {
                self.closeConn(slot, c);
                return;
            }
            c.front_off += @intCast(res);
            if (c.front_off < c.front.items.len) {
                // Partial write: send the remainder. `front` is untouched
                // since the original submit (appends went to `back`), so the
                // resubmitted slice is still backed by live storage.
                self.submitSend(slot, c) catch self.closeConn(slot, c);
                return;
            }
            // Drained. Burst capacity frees on drain (the spill's posture,
            // ADR-0041/0042): one slow-reader episode must not pin its
            // high-water bytes for the connection's lifetime. Steady-sized
            // capacity is retained so ordinary reply traffic never reallocates.
            frame_stream.reclaimBurst(&c.front, self.allocator, steady_outbound_bytes);
            // A drained connection never pins burst capacity: this is the
            // 500k-footprint invariant a slow-drain episode must not break. The
            // live-socket measurement is rung 5 work (docs/ladder.md); this pins
            // the bound loudly in every safe build, on every drain.
            std.debug.assert(c.front.capacity <= steady_outbound_bytes);
            c.front_off = 0;
            c.write_in_flight = false;
            // Bytes queued on `back` while this write was in flight — and any
            // reply this drive encodes — swap into the emptied front and go
            // out now (`flushOutbound`).
            self.driveOut(slot, c) catch {
                self.failConn(slot, c);
                return;
            };
            // The partner caught up: a read parked at the high-water mark
            // resumes, unless this drive refilled the queue past it — or
            // fan-in still has another sink parked (ADR-0082).
            if (c.read == .parked and pendingOut(c) <= self.outbound_high_water) {
                if (!(self.fan_in_throttle and self.anySinkParked())) {
                    c.read = .idle;
                    c.parked_at_ms = 0;
                    self.armRecv(slot, c) catch self.closeConn(slot, c);
                }
            }
            // Fan-in sources parked only because a sink was over high-water must
            // resume when the last true sink drains — onSend only sees the
            // draining slot, so walk the rest (ADR-0082).
            if (self.fan_in_throttle and !self.anySinkParked()) {
                self.resumeFanInSources();
            }
        }

        /// Re-arm connections parked solely by `fan_in_throttle` once no true
        /// ADR-0042 sink remains over the high-water mark. Skip seats that are
        /// still sink-parked (`pendingOut` over the mark) or not `.parked`.
        fn resumeFanInSources(self: *Self) void {
            for (self.conns, 0..) |*other, other_slot| {
                if (other.state != .open or other.read != .parked) continue;
                if (pendingOut(other) > self.outbound_high_water) continue;
                other.read = .idle;
                other.parked_at_ms = 0;
                self.armOrPark(other_slot, other) catch self.closeConn(other_slot, other);
            }
        }

        fn closeConn(self: *Self, slot: usize, c: *Conn) void {
            if (c.state == .closing) return;
            self.unlinkStarved(slot);
            c.state = .closing;
            self.backend.submitClose(userData(.close, slot), c.fd) catch {
                // Could not even queue the close. Close the fd directly so it is
                // not leaked: the normal path closes it via the queued op, so
                // `teardown` never closes, this failure branch is the only place
                // the fd would otherwise outlive the connection, and the two are
                // mutually exclusive, so there is no double close. If no other op
                // is outstanding, reclaim now; otherwise the last in-flight op's
                // completion reclaims it (teardown must still wait for the kernel
                // to be done with the buffers).
                self.backend.closeFd(c.fd);
                if (c.ops_in_flight == 0) {
                    self.teardown(slot);
                    self.closed_count += 1;
                }
                return;
            };
            c.ops_in_flight += 1;
        }

        /// Account one completed per-connection op. On a closing connection the
        /// op that drains the last in-flight one reclaims the slot, deferring
        /// teardown until here is what keeps `front` alive for as long as any
        /// submitted send could still touch it, and keeps the slot from being
        /// reused while a stale completion could still arrive for it. A close
        /// for a refused accept carries the out-of-range sentinel slot
        /// `conns.len` and is ignored rather than indexed.
        fn retireConnOp(self: *Self, slot: usize) void {
            if (slot >= self.conns.len) return;
            const c = &self.conns[slot];
            if (c.state == .free) return;
            if (c.ops_in_flight > 0) c.ops_in_flight -= 1;
            if (c.state == .closing and c.ops_in_flight == 0) {
                self.teardown(slot);
                self.closed_count += 1;
            }
        }

        fn teardown(self: *Self, slot: usize) void {
            const c = &self.conns[slot];
            // Notify the application first, while the per-connection context
            // is still alive: this fires once per connection, and `opened`
            // tells a dialer whether the connection ever completed its
            // connect (a refused dial reports `opened == false`).
            if (self.on_close) |on_close| on_close(self.make_ctx, slot, c.app_ctx, c.opened, c.close_reason);
            // Free the per-connection app context next: it may hold a vat that
            // borrows this peer, so it must release before the peer deinits.
            if (c.app_ctx) |app_ctx| {
                if (self.free_conn_ctx) |free| free(self.make_ctx, app_ctx);
            }
            c.peer.deinit();
            c.spill.deinit(self.allocator);
            c.front.deinit(self.allocator);
            c.back.deinit(self.allocator);
            c.* = .{};
            self.pushFreeSlot(slot);
        }

        fn freeSlot(self: *Self) ?usize {
            if (self.free_head >= self.conns.len) return null;
            const slot = self.free_head;
            self.free_head = self.conns[slot].next_link;
            return slot;
        }

        fn pushFreeSlot(self: *Self, slot: usize) void {
            self.conns[slot].next_link = self.free_head;
            self.free_head = slot;
        }
    };
}
