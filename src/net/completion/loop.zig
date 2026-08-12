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
//! The TCP backends bind `127.0.0.1` only, and nothing here takes a bind
//! address. A loop that accepts from off-host is not implemented; the
//! high-fan-out numbers this loop is measured against are loopback numbers.
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
//! pool of `BackendOptions.read_buffers` buffers, each exactly
//! `BackendOptions.read_buffer_bytes`, and a recv completion carries a borrowed
//! view of the pool buffer the backend selected for it. The loop consumes the bytes:
//! whole frames apply zero-copy straight from the completion view; a partial
//! frame tail absorbs into the connection's bounded spill (ADR-0041). It then
//! hands the buffer back with `recycleRecv`, exactly once per completion that
//! carried one. An idle connection therefore costs no read-buffer memory at
//! all, and a recv that finds the pool momentarily empty parks buffer-starved
//! until a buffer recycles; it is never a connection failure.
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
//!     synthetic handle, submit the connect, clean up on failure). Every backend
//!     reports terminal connect success as result 0; the returned `Fd` already
//!     belongs to the slot before that completion arrives.
//!   * `pub const ListenerAddress;`
//!   * `pub fn listenerAddress(self: *Backend, fd: Fd) !ListenerAddress;`
//!     — the backend-owned address published for the listener, returned by
//!     value so moving the backend cannot invalidate it.
//!   * `pub fn listenerPort(address: ListenerAddress) ?u16;` — total projection
//!     for TCP convenience; transports without a TCP address return null.
//!   * `pub fn closeFd(self: *Backend, fd: Fd) void;` — release a handle.
//!     Instance method so a userspace backend can free transport state keyed by
//!     `Fd`; socket backends ignore `self`.
//!   * `pub fn submitAccept(self: *Backend, user_data: u64, listen_fd: Fd) !void;`
//!     — success reports the accepted handle in `Completion.accepted_fd` (or,
//!     for an ordinary non-negative OS fd, in `result`); failure reports a
//!     negative `result` and no handle.
//!   * `pub fn submitRecv(self: *Backend, user_data: u64, fd: Fd) !void;` — no
//!     caller buffer: the backend selects one from its shared pool when data
//!     arrives and surfaces it on the completion (`Completion.recv_bytes`). A
//!     recv that finds the pool empty completes with
//!     `Completion.recv_no_buffer` instead of failing the connection.
//!   * `pub fn submitSend(self: *Backend, user_data: u64, fd: Fd, bytes: []const u8) !void;`
//!   * `pub fn submitCancel(self: *Backend, cancel_user_data: u64,
//!     target_user_data: u64, fd: Fd) !void;` — cancel the exact submitted recv
//!     named by `target_user_data` without closing the caller-owned `fd`. A
//!     successful submit eventually yields both the target recv completion and
//!     one completion carrying `cancel_user_data`; either may arrive first.
//!   * `pub fn submitClose(self: *Backend, user_data: u64, fd: Fd) !void;` —
//!     including the listen handle: cancel a pending accept (yield one accept
//!     completion with `result < 0` when one was armed) and close the fd so
//!     `Loop.closeAndDrain` cannot hang on an idle acceptor.
//!     For connection handles, `Loop` calls `shutdownFd` first. A userspace
//!     backend whose shutdown is a no-op must synthesize one completion for
//!     every pending recv/send when it accepts the close.
//!     The close completion reports the close result; a negative result means
//!     the backend did not release the handle and the Loop must call `closeFd`.
//!   * A `submit*` that returns an error must have minted **no** completion for
//!     that `user_data`. The loop counts an op only after a successful submit,
//!     so a completion for a refused submit lands on a seat the loop believes is
//!     idle and drives the in-flight count below the truth. That frees a
//!     connection's outbound buffer while the backend is still reading from it.
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
//!     `timeout_ms` blocks until at least one completion or explicit backend
//!     wake is observed. A non-negative `timeout_ms` waits at most that many
//!     milliseconds; zero completions after a timeout or explicit stopper wake
//!     returns 0, not an error. Fills `out` with up to `out.len` completions and
//!     returns the count.
//!
//! The Loop is also parameterized by a `DialResolver`: OCapN
//! `(transport, designator, hint)` maps to `Backend.ConnectTarget`. That grammar
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
//! The loop calls `shutdownFd` before every connection close so kernel socket
//! operations are forced to complete; a userspace backend whose shutdown is a
//! no-op synthesizes pending-operation completions in `submitClose`.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const frame_stream = @import("../frame_stream.zig");
const clock = @import("../clock.zig");
const tcp_keepalive = @import("tcp_keepalive.zig");

/// Re-export so loop callers configure keepalive without a second import path.
pub const Keepalive = tcp_keepalive.Keepalive;

/// Shared recv scratch pool for readiness backends (kqueue, iroh). Re-exported
/// so the out-of-graph iroh resident reaches it through `net.completion` rather
/// than dual-homing the source file.
pub const ScratchPool = @import("scratch_pool.zig").ScratchPool;

/// One collision-free namespace layer for a completion-backend adapter.
///
/// Adapters share connection handles, completion `user_data`, and receive
/// buffer tokens with the backend they wrap. Ad-hoc sentinel ranges do not
/// compose: two wrappers can claim the same high bit and consume each other's
/// events. A wrapped backend therefore publishes `adapter_depth`; this type
/// derives the next disjoint layer for all three channels from that one fact.
///
/// Platform backends start at depth zero. Synthetic fds use successively
/// longer negative prefixes (`10`, `110`, ...), while user data and recv tokens
/// claim one high bit per layer. OS fds stay non-negative and Loop user data
/// stays below bit 35 (`max_conns < maxInt(u32)`), so neither can collide.
pub fn AdapterNamespace(comptime Platform: type) type {
    if (!@hasDecl(Platform, "adapter_depth"))
        @compileError(@typeName(Platform) ++ " must declare `pub const adapter_depth = 0` before it can be wrapped by a completion adapter");
    if (Platform.Fd != i32)
        @compileError("completion adapter namespaces currently require a signed 32-bit Fd");

    const child_depth: u6 = Platform.adapter_depth;
    if (child_depth >= 30)
        @compileError("completion adapter namespace depth exhausted");

    return struct {
        pub const depth: u6 = child_depth + 1;

        const fd_prefix_bits: u6 = child_depth + 2;
        const fd_id_bits: u6 = 32 - fd_prefix_bits;
        const fd_id_mask: u32 = (@as(u32, 1) << @intCast(fd_id_bits)) - 1;
        const fd_prefix: u32 = (~@as(u32, 0)) << @intCast(32 - (child_depth + 1));
        const fd_prefix_mask: u32 = (~@as(u32, 0)) << @intCast(32 - fd_prefix_bits);
        const user_data_bit: u64 = @as(u64, 1) << @intCast(63 - child_depth);
        const recv_token_bit: u32 = @as(u32, 1) << @intCast(31 - child_depth);
        pub const max_fd_id: u32 = fd_id_mask;

        pub fn fdFromId(id: u32) error{AdapterHandleExhausted}!i32 {
            if (id > fd_id_mask) return error.AdapterHandleExhausted;
            return @bitCast(fd_prefix | id);
        }

        pub fn ownsFd(fd: i32) bool {
            const bits: u32 = @bitCast(fd);
            return bits & fd_prefix_mask == fd_prefix;
        }

        pub fn fdId(fd: i32) u32 {
            std.debug.assert(ownsFd(fd));
            return @as(u32, @bitCast(fd)) & fd_id_mask;
        }

        pub fn userData(payload: u64) u64 {
            std.debug.assert(payload & user_data_bit == 0);
            return payload | user_data_bit;
        }

        pub fn ownsUserData(value: u64) bool {
            return value & user_data_bit != 0;
        }

        pub fn userDataPayload(value: u64) u64 {
            std.debug.assert(ownsUserData(value));
            return value & ~user_data_bit;
        }

        pub fn recvToken(token: u32) u32 {
            std.debug.assert(token & recv_token_bit == 0);
            return token | recv_token_bit;
        }

        pub fn ownsRecvToken(token: u32) bool {
            return token & recv_token_bit != 0;
        }

        pub fn recvTokenPayload(token: u32) u32 {
            std.debug.assert(ownsRecvToken(token));
            return token & ~recv_token_bit;
        }
    };
}

/// Compile-time check that `Backend` declares the total dial/I/O contract the
/// Loop calls. Soft optionality (`@hasDecl` at call sites) is forbidden: a
/// missing member fails here, not as a latent special case on one path.
fn validateBackend(comptime Backend: type) void {
    const required = .{
        "Fd",
        "ConnectTarget",
        "ListenerAddress",
        "deinit",
        "openListener",
        "listenerAddress",
        "listenerPort",
        "closeFd",
        "startDial",
        "shutdownFd",
        "submitAccept",
        "submitRecv",
        "submitSend",
        "submitCancel",
        "submitClose",
        "recycleRecv",
        "poll",
        "verifiedChannelKey",
    };
    inline for (required) |name| {
        if (!@hasDecl(Backend, name)) {
            @compileError("completion Backend missing `" ++ name ++ "` — total contract, no optional dial/shutdown members");
        }
    }
}

/// Compile-time check that `DialResolver` turns OCapN locator parts into
/// `ConnectTarget`. Netlayer-owned; never a platform Backend concern.
fn validateDialResolver(comptime DialResolver: type, comptime ConnectTarget: type) void {
    if (!@hasDecl(DialResolver, "resolve")) {
        @compileError("completion DialResolver missing `resolve` — OCapN locator → ConnectTarget");
    }
    // And that it resolves to *this* backend's target. Taking the type and
    // discarding it checked the half that never goes wrong: a `resolve` that
    // returns some other backend's target is the mismatch worth catching, and
    // it is exactly what a comptime parameter can see.
    const info = @typeInfo(@TypeOf(DialResolver.resolve));
    if (info != .@"fn") @compileError("completion DialResolver.resolve must be a function");
    const returns = info.@"fn".return_type orelse
        @compileError("completion DialResolver.resolve must have a concrete return type");
    const payload = switch (@typeInfo(returns)) {
        .error_union => |eu| eu.payload,
        else => returns,
    };
    if (payload != ConnectTarget) {
        @compileError("completion DialResolver.resolve must return " ++ @typeName(ConnectTarget) ++
            ", found " ++ @typeName(payload));
    }
}

/// One finished operation reported by a backend: the `user_data` the submit
/// carried, and the platform result (bytes transferred, status, or negative on
/// error, the same sign convention as the underlying syscall).
pub const Completion = struct {
    user_data: u64,
    result: i32,
    /// The connection handle produced by a successful accept. Kept separate
    /// from `result` because composable userspace backends use collision-free
    /// negative synthetic handles, while `result < 0` remains the uniform
    /// operation-failure convention. Platform backends that report an ordinary
    /// non-negative OS fd in `result` remain valid.
    accepted_fd: ?i32 = null,
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

/// The queue of ready completions a readiness backend fills and the loop drains,
/// shared by the kqueue backend and the iroh completion `Backend`.
///
/// A read cursor, not a slide. The loop drains a fixed batch per poll, so a
/// burst of `M` completions is handed over in `M / batch` calls, and sliding the
/// remainder forward each time moves `M²/batch` entries in total. A mass close
/// at the 500k destination queues on the order of a million completions in one
/// sweep, which is where that arithmetic stops being academic. Advancing a
/// cursor instead is `O(M)` over the whole burst, and the storage is reused
/// because the cursor and the list reset together the moment the queue empties.
pub const ReadyQueue = struct {
    items: std.ArrayList(Completion) = .empty,
    /// How far into `items` the drains have read. The prefix behind it is dead
    /// storage, reclaimed when the queue empties or when the dead prefix
    /// outgrows the live remainder, so neither the cursor nor the list grows
    /// with uptime.
    head: usize = 0,

    pub fn deinit(self: *ReadyQueue, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        self.head = 0;
    }

    /// How many completions are still waiting to be drained.
    pub fn len(self: *const ReadyQueue) usize {
        return self.items.items.len - self.head;
    }

    pub fn append(self: *ReadyQueue, allocator: std.mem.Allocator, c: Completion) !void {
        try self.items.append(allocator, c);
    }

    pub fn ensureUnusedCapacity(self: *ReadyQueue, allocator: std.mem.Allocator, n: usize) !void {
        try self.items.ensureUnusedCapacity(allocator, n);
    }

    pub fn appendAssumeCapacity(self: *ReadyQueue, c: Completion) void {
        self.items.appendAssumeCapacity(c);
    }

    /// Move up to `out.len` completions out, and return how many moved.
    pub fn drain(self: *ReadyQueue, out: []Completion) usize {
        const n = @min(self.len(), out.len);
        if (n == 0) return 0;
        @memcpy(out[0..n], self.items.items[self.head..][0..n]);
        self.head += n;
        const rest = self.items.items.len - self.head;
        if (rest == 0) {
            self.items.clearRetainingCapacity();
            self.head = 0;
        } else if (self.head >= rest) {
            // The cursor bounds the copying, not the storage. A queue that
            // never empties in a single drain never reclaims the prefix behind
            // the cursor, and a backend whose reads complete synchronously
            // keeps one permanently — so the list would grow for as long as the
            // loop runs. Compacting once the dead prefix outgrows the live
            // remainder halves it each time, which keeps the whole burst at
            // `O(M)` moved entries while bounding the storage by the backlog
            // instead of by uptime.
            std.mem.copyForwards(Completion, self.items.items[0..rest], self.items.items[self.head..]);
            self.items.shrinkRetainingCapacity(rest);
            self.head = 0;
        }
        return n;
    }
};

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

/// Why a connection is tearing down (ADR-0082). Surfaced on `OnClose` so an
/// embedder can separate ordinary peer loss from the two reclaims the loop
/// performs on its own initiative.
pub const CloseReason = enum {
    /// Partner EOF, read error, keepalive, `closeSlot`, refused dial, …
    ordinary,
    /// Stayed `.parked` past `Options.park_kill_ms`.
    park_kill,
    /// The partner did not read this connection's terminal bytes within
    /// `Options.drain_kill_ms`. Distinct from `park_kill` because it says
    /// nothing about how fast a *healthy* partner reads, because the close
    /// had already been requested when the wait began.
    drain_kill,
};

/// Close notification, fired once per connection at teardown, before
/// `free_conn_ctx` releases the per-connection context. Receives the shared
/// `ctx`, the per-connection context (null when the connection failed before
/// `make_conn_ctx` ran), and `opened`: true when the connection completed its
/// connect or accept, false when it failed before opening (e.g. a refused
/// dial). This is the loop's only failure surface for a dialed connection,
/// `dial` returns before the connect completes, so a refused dial is
/// observable nowhere else.
///
/// `slot` is the connection's loop index: refused dials tear down before
/// `make_conn_ctx` runs (`conn_ctx` is null), so an embedder correlating an
/// in-flight dial to a ticket needs the slot — `conn_ctx` alone cannot name
/// it (ADR-0076 loop-side dial executor). `reason` names which of the loop's
/// reclaims fired, or `.ordinary` for everything else.
pub const OnClose = *const fn (ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, opened: bool, reason: CloseReason) void;

/// Called on the loop owner thread whenever a public drive method returns,
/// after dispatch has stopped and before the loop releases its own thread
/// claim. An adapter uses this to transfer ownership of unsynchronized state
/// it drives alongside the loop. It must not submit new loop work.
pub const OnDriverExit = *const fn (ctx: ?*anyopaque) void;

/// Run one deferred adapter-owned work turn immediately before the backend
/// poll. Return true when work ran, so this poll is non-blocking and the
/// driver's stop condition or another deferred turn is observed first. This
/// is a scheduler seam, not protocol authority: `net` neither knows nor stores
/// the adapter's work.
pub const OnLoopTurn = *const fn (ctx: ?*anyopaque) anyerror!bool;

/// When a waiting connection is due to be reaped, and what the wait was for.
/// Named rather than anonymous: two instantiations of `Loop` would otherwise
/// each mint their own incompatible struct for the same two fields, which the
/// tests that compare across instantiations cannot work with. Module-private,
/// like the function that returns it; `Loop.white_box` is how a test reaches
/// both.
const Deadline = struct { due: i64, reason: CloseReason };

/// Why a read seat parked (ADR-0082). The two are operationally different and
/// an embedder watching lag needs to tell them apart: `.sink` is this
/// connection's own partner failing to drain, `.fan_in` is this connection
/// being throttled for somebody else's.
pub const ParkReason = enum { sink, fan_in };

/// Optional park notification (ADR-0082): fired when a connection's read seat
/// first enters `.parked`. `slot` and `conn_ctx` match `OnClose` so an embedder
/// can correlate lag to an open connection without scraping private Loop state,
/// and `reason` says which of the two parks it is — the branch that decides is
/// the branch that reports, so the two cannot disagree.
pub const OnPark = *const fn (ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, reason: ParkReason) void;

/// The listen backlog both platform backends pass to `listen(2)`: pending,
/// not-yet-accepted connections the kernel queues before refusing new ones.
/// The loop re-arms its accept immediately after every completion, so the
/// backlog only has to absorb a connect burst between two loop wakes.
pub const listen_backlog: u31 = 128;

/// Admission class for outbound dials. Ordinary dials share capacity with
/// accepted connections. Reserved dials consume only the fixed reservation in
/// `Options.reserved_dial_conns`, so a control-plane reconnect cannot be
/// starved by data-plane accepts or speculative outbound work.
pub const DialAdmission = enum { ordinary, reserved };

/// Shared-pool buffer size used unless the caller names another one. The spill
/// carries the rare larger frame, so this sizes concurrent ordinary traffic,
/// not protocol admission or per-connection memory.
pub const default_read_buffer_bytes: u32 = 16 * 1024;
/// Loop-wide pending-output slack, deliberately independent of frame admission
/// and transport framing.
pub const default_outbound_high_water_bytes: usize = 64 * 1024;

/// Resources used only when the loop constructs its backend. A prebuilt
/// backend owns these decisions already, so `initWithBackend` cannot accept a
/// second, ignored representation of them.
pub const BackendOptions = struct {
    /// Backend completion-queue depth hint.
    queue_entries: u16 = 256,
    /// Number of buffers in the backend's shared read pool (ADR-0054).
    read_buffers: u16 = 256,
    /// Exact size of each shared read-pool buffer. This is not a frame limit;
    /// larger admissible frames accumulate in the bounded connection spill.
    read_buffer_bytes: u32 = default_read_buffer_bytes,
};

pub const Options = struct {
    /// How many connections this loop can hold at once. Slots are allocated
    /// once at `init` and recycled, never per connection, so this is a
    /// commitment rather than a ceiling: the loop reserves
    /// `max_conns * (@sizeOf(engine.Peer) + conn_slot_overhead_bytes)` bytes up
    /// front, and a dial or accept past it is refused rather than queued. At the
    /// 500k destination that reservation is the loop's own footprint, separate
    /// from the outbound queues each live connection grows (`docs/ladder.md`
    /// step 2).
    max_conns: usize = 1024,
    /// Slots held exclusively for dials explicitly admitted as `.reserved`.
    /// Ordinary dials and accepts cannot consume them; reserved dials cannot
    /// spill into ordinary capacity. This is a hard partition, so both classes
    /// remain bounded and a reconnect path does not depend on timing.
    reserved_dial_conns: usize = 0,
    /// Listen on this loopback port and accept inbound connections; 0 lets the
    /// kernel choose (read it back from `Loop.port`). `null` — the default —
    /// never binds, listens, or arms an accept, so a pure dialer loop exposes
    /// no socket a stranger could connect to.
    listen: ?u16 = null,
    /// Outbound backpressure high-water mark (ADR-0042): when a connection's
    /// pending outbound bytes cross this, the loop stops arming reads on it.
    /// This is independent resource policy, not a local or remote frame limit.
    /// Reading resumes when the partner drains below the mark.
    outbound_high_water_bytes: usize = default_outbound_high_water_bytes,
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
    /// Optional quiescent ownership-transfer hook (see `OnDriverExit`).
    on_driver_exit: ?OnDriverExit = null,
    /// Optional deferred adapter turn (see `OnLoopTurn`).
    on_loop_turn: ?OnLoopTurn = null,
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
    /// liveness policy lives above pancake, which is why this stays opt-in
    /// rather than a silent default. See `tcp_keepalive.Keepalive`.
    keepalive: ?tcp_keepalive.Keepalive = null,
    /// Fan-in source throttle (ADR-0082): when any live connection is parked
    /// under ADR-0042 outbound high-water, also refuse to arm reads on every
    /// *other* connection until no connection remains parked. Off by default
    /// so existing scale harnesses keep per-connection-only backpressure;
    /// enable to prove many-A-to-one-B sources slow when the sink parks.
    fan_in_throttle: bool = false,
    /// Park-duration kill (ADR-0082 / NATS write_deadline analogue): if a
    /// connection stays `.parked` longer than this many milliseconds, the loop
    /// closes it. `null` (default) never kills on park age alone.
    ///
    /// With `fan_in_throttle` on, `null` is more than a missing reclaim: a
    /// sink the partner never drains parks every other connection's read, and
    /// with no deadline anywhere the poll has nothing to wake for. Pair the
    /// two, or leave the throttle off.
    park_kill_ms: ?u64 = null,
    /// How long a connection whose close has been requested (`closeSlot`,
    /// state `.draining`) may wait for the partner to read its terminal bytes
    /// before the loop stops waiting and closes it.
    ///
    /// This is teardown, not policy, so unlike `park_kill_ms` it has a finite
    /// default. That option decides how patient the loop is with a *healthy*
    /// slow reader. Even an embedder that wants no such policy must not leak a
    /// slot to a partner that never reads an abort. `null` waits forever,
    /// pinning the slot, its fd, its peer, and its queues until the loop ends.
    /// With `fan_in_throttle` it pins more than that: a stuck connection's
    /// unread queue keeps counting toward the fan-in mark, so every other
    /// connection's read stays parked too.
    drain_kill_ms: ?u64 = 5_000,
};

/// When `Loop.run` returns. Production servers and dialers run `.forever`;
/// tests stop after a known number of connections have fully closed.
pub const Stop = union(enum) {
    forever,
    after_closed: usize,
};

/// Which kind of submitted operation a completion belongs to. Packed into the low
/// bits of `user_data`; the rest is the connection slot index. `wake` and
/// `wake_cancel` have no connection: the out-of-band wake recv (ADR-0102) and
/// its shutdown cancellation always carry slot 0 and are dispatched before
/// any slot lookup.
const Op = enum(u3) { accept, connect, recv, send, close, wake, wake_cancel };

fn userData(op: Op, slot: usize) u64 {
    return (@as(u64, slot) << 3) | @intFromEnum(op);
}
fn opOf(ud: u64) Op {
    return @enumFromInt(@as(u3, @truncate(ud)));
}
fn slotOf(ud: u64) usize {
    return @intCast(ud >> 3);
}

/// How long the loop may sleep while it still owes the backend a close it
/// could not admit. Short, because those closes are what retire the ops some
/// connections are waiting on, and the failure that caused them is transient.
const close_retry_ms: i32 = 50;

/// Outbound queue capacity a drained `front` retains (ADR-0042). The iroh
/// sidecar keeps the same bound for its own per-connection buffer, in Rust
/// (`NB_STEADY_BYTES`), so the ladder's footprint budget cannot split between
/// them; `meta-check` holds the two numbers together.
const steady_outbound_bytes: usize = frame_stream.steady_outbound_bytes;

/// Per-connection slot bookkeeping ceiling (ADR-0045): the most a `Conn` may
/// cost *beyond* the `engine.Peer` it embeds — the slot state, the outbound
/// queue's two `ArrayList` headers, the spill header, the intrusive link, and
/// the in-flight/context words. `Peer` is gated by its own `@sizeOf(Peer)`
/// ceiling; this guards the wrapper the loop allocates `max_conns` of, which
/// nothing capped before. Isolating the overhead keeps a `Peer` change within
/// its own ceiling from tripping this, while a new `Conn` field always does.
/// The number lives here and in docs/ladder.md step 2 together; move it only by
/// weighing the bytes, never to route around the gate.
///
/// The assertion below is an equality, not a ceiling, and that is deliberate.
/// As a ceiling it said only "128 or less", so the overhead grew to exactly 128
/// while both this comment and the ladder went on claiming a measured 112 with
/// a word of headroom — a stale figure no build could catch, in the two places
/// an agent goes to find out whether a new field is affordable. An equality
/// makes the constant the measurement: any change to `Conn` fails the build and
/// is answered by moving the number here and in the ladder together, which is
/// the process this comment already described and nothing enforced. It holds
/// across backends because `Backend.Fd` is `i32` for tcp, kqueue, uring, and
/// iroh alike, so `Conn` carries no backend-dependent width.
///
/// It exists to stop a field being *added* unnoticed, not to invite shaving
/// bytes off it. For scale: 128 bytes is 64 MB at 500k connections, against the
/// roughly 16 GiB of steady outbound queue the same connections carry
/// (`docs/ladder.md` step 2). Three unavoidable slice headers make up 72 of the
/// 128, so the whole available saving is noise against the queues.
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
/// and a netlayer `DialResolver` (OCapN locator parts to `Backend.ConnectTarget`).
pub fn Loop(comptime Backend: type, comptime DialResolver: type) type {
    comptime validateBackend(Backend);
    comptime validateDialResolver(DialResolver, Backend.ConnectTarget);
    return struct {
        const Self = @This();
        const Fd = Backend.Fd;
        const ConnectTarget = Backend.ConnectTarget;

        const Conn = struct {
            /// The slot lifecycle: `.free` slots sit on the free list, `.open`
            /// slots carry a live (or still-connecting) connection,
            /// `.draining` slots accept only send completions until their
            /// already-projected terminal bytes flush, and `.closing` slots
            /// have their close queued and wait for in-flight ops to retire
            /// before `teardown` reclaims them.
            state: enum { free, open, draining, closing } = .free,
            /// The read seat — exactly one recv is armed per open connection,
            /// or the seat is explicitly idle/parked: `.idle` between a recv
            /// completion and its verdict, `.armed` while a recv is submitted,
            /// `.parked` under ADR-0042 backpressure (outbound past the
            /// high-water mark; `onSend`'s drain resumes it), `.starved` when
            /// the shared pool was empty (ADR-0054; a recycle resumes it).
            read: enum { idle, armed, parked, starved } = .idle,
            /// Monotonic ms (since boot, not wall-clock) when this connection
            /// started waiting on the partner, or 0 when it is not waiting
            /// (or is a fan-in victim, which the reaper deliberately exempts).
            /// Only differences are meaningful.
            ///
            /// Which wait this is, and therefore which deadline bounds it,
            /// comes from the connection's state, not from a second meaning
            /// packed into this number. `waiting_is_drain` records which one
            /// the stamp was taken for, so a connection that was already
            /// waiting when its state changed starts the new clock instead of
            /// inheriting the old one's elapsed time. `.open` with a parked read
            /// is a slow reader, bounded by `Options.park_kill_ms`; a
            /// `.draining` connection is waiting for its terminal bytes to be
            /// read, bounded by `Options.drain_kill_ms`. Condemnation
            /// restamps it, which is correct: the slow-reader question is moot
            /// once the session is already being torn down, and the drain
            /// bound is the shorter of the two.
            waiting_since_ms: i64 = 0,
            /// Whether `waiting_since_ms` was taken for the terminal-flush wait
            /// rather than the slow-reader park. Meaningless when unstamped.
            waiting_is_drain: bool = false,
            /// Set when `closeConn` could not queue a close and shut the fd
            /// down instead: the last retiring op releases the handle, because
            /// no close completion is coming to do it.
            owns_fd_close: bool = false,
            /// Whether this connection's queue is over the high-water mark.
            /// Edge-triggered so `over_mark_count` stays exact.
            over_mark: bool = false,
            /// Bumped every time this slot is reclaimed, so slot reuse is
            /// observable — the state alone cannot show it, because a
            /// replacement occupant is `.open` too. No production path compares
            /// it today; it is what `test/net/fuzz_test.zig` checks slot
            /// identity against, and it costs nothing, because the four bytes
            /// land in alignment padding `Conn` already carries.
            generation: u32 = 0,
            /// True once the connection completed its connect or accept; false
            /// for a dialed connection that failed before opening. Reported to
            /// `Options.on_close` at teardown.
            opened: bool = false,
            /// Why this connection is closing; set before `closeConn` for a
            /// loop-initiated reclaim so `on_close` can name it (ADR-0082).
            close_reason: CloseReason = .ordinary,
            fd: Fd = undefined,
            peer: engine.Peer = undefined,
            /// Bounded overflow for a frame that does not complete within one
            /// recv completion's borrowed pool buffer; inactive (and
            /// allocation-free) while whole frames arrive per completion. The
            /// scan that walks its frame rides on the `peer` above
            /// (`engine.Peer.stream_scan`), which documents why.
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
            /// Intrusive links for the one list this slot is on, holding slot
            /// indices, or `conns.len` as the end sentinel.
            ///
            /// Four lists share this pair: the ordinary and reserved free lists
            /// while `state == .free`, buffer-starved while `read == .starved`,
            /// and backpressure-parked while `read == .parked`. A slot belongs
            /// to exactly one. A free slot's seat is `.idle`, because the slot
            /// reset leaves it there, and `.starved` and `.parked` are two
            /// values of one enum. Every departure unlinks before the state
            /// changes, so no successor rides from one list into another. This
            /// is the invariant the whole scheme rests on; the heads below and
            /// the link helpers point back here rather than restating it.
            ///
            /// Two `u32`s rather than one `usize`, which costs the same eight
            /// bytes and buys `O(1)` removal. Removing by value from a singly
            /// linked list walks it, and the list this matters for is the parked
            /// one: it is longest in exactly the regime it exists for, a fan-in
            /// throttle holding every connection behind one slow reader. Every
            /// `closeConn` walking it makes `closeAndDrain` quadratic — the
            /// shape `teardown` deliberately refuses two hundred lines below.
            /// `max_conns` is checked against `maxInt(u32)` at construction.
            next_link: u32 = 0,
            prev_link: u32 = 0,
        };

        comptime {
            // The 500k-connection budget is gated at the unit the loop
            // multiplies (ADR-0045). A field added to `Conn` is a withdrawal;
            // trip this and weigh the bytes, then raise the number here and in
            // docs/ladder.md step 2 together — never route around the gate.
            std.debug.assert(@sizeOf(Conn) - @sizeOf(engine.Peer) == conn_slot_overhead_bytes);
        }

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
        /// Quiescent adapter ownership transfer; see `Options.on_driver_exit`.
        on_driver_exit: ?OnDriverExit,
        /// Deferred adapter scheduling; see `Options.on_loop_turn`.
        on_loop_turn: ?OnLoopTurn,
        /// Optional park notification (ADR-0082); see `Options.on_park`.
        on_park: ?OnPark,
        /// Opt-in TCP keepalive applied at connect/accept finish (see `Options`).
        keepalive: ?tcp_keepalive.Keepalive,
        /// Fan-in source throttle (ADR-0082); see `Options.fan_in_throttle`.
        fan_in_throttle: bool,
        /// Park-duration kill (ADR-0082); see `Options.park_kill_ms`.
        park_kill_ms: ?u64,
        /// Terminal-flush bound; see `Options.drain_kill_ms`.
        drain_kill_ms: ?u64,
        /// Whether an accept is outstanding. `run` and `runUntil` both begin by
        /// arming one, and both are callable more than once — a driver that
        /// waits on one vow per `runUntil` calls it repeatedly. Without this
        /// each call mints another accept, and since every accept completion
        /// re-arms exactly once, the extras never go away.
        accept_armed: bool = false,
        /// A submitted listener close is an outstanding backend operation, but
        /// it has no connection slot to keep `live_count` high. The descriptor
        /// remains in `listener_close_fd` across transient submit refusal; only
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
        /// sanctioned cross-thread entry — a worker nudges the other half
        /// (`driver.SettleMailbox.post`) — replacing the connect-and-drop
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
        /// must be retried; bounds the next wait like an owed close, so the
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
        owner_tid: if (std.debug.runtime_safety) ?std.Thread.Id else void =
            if (std.debug.runtime_safety) null else {},
        /// Heads of the two intrusive free-slot lists threaded through
        /// `Conn.next_link`. Ordinary slots occupy the prefix ending at
        /// `ordinary_capacity`; reserved slots occupy the suffix. The index is
        /// therefore the admission class, with no per-connection field or
        /// counter to pay for or drift.
        ordinary_free_head: usize,
        reserved_free_head: usize,
        /// Head of the intrusive buffer-starved list threaded through the same
        /// `Conn.next_link` while a slot is starved; `conns.len` when no
        /// connection is starved.
        starved_head: usize,
        /// Head of the intrusive backpressure-parked list (see `Conn.next_link`);
        /// `conns.len` when nothing is parked. It makes the fan-in release
        /// proportional to the connections actually parked rather than to
        /// `max_conns`, which at the 500k target is half a million cold slot
        /// reads per departure to re-arm, usually, nothing.
        parked_head: usize,

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
        /// resources. Runtime policy remains in `Options`; a caller that has
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
            if (comptime std.debug.runtime_safety)
                std.debug.assert(self.owner_tid == null);
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
                self.unlinkStarved(slot);
                self.unlinkParked(slot);
                // Not counted: `deinit` is the loop ending, not connections
                // being served to completion.
                _ = self.teardown(slot);
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

        /// One turn of the loop: settle deferred work, wait, dispatch, sweep.
        ///
        /// The three drivers (`run`, `runUntil`, `closeAndDrain`) differ only
        /// in when they stop and whether the caller has a deadline of its own,
        /// so the body lives here once. Three copies means a fix can land in one
        /// and not the others, and what goes missing that way is a sweep no
        /// driver announces it is skipping.
        ///
        /// The order is load-bearing. Deferred work is drained *before* the
        /// wait is sized, because draining it can create the deadline the wait
        /// must not sleep through. `caller_deadline_ms` is the driver's own
        /// bound, or null for "wait as long as the connections allow".
        fn pollOnce(self: *Self, caller_deadline_ms: ?i32) !void {
            // Per-poll batch cap, deliberately independent of
            // `BackendOptions.queue_entries`: a deeper completion queue drains across
            // more polls, while the fixed stack batch keeps this
            // allocation-free.
            const poll_batch = 256;
            var completions: [poll_batch]Completion = undefined;

            self.drainFanInDirty();
            // Owed closes are this loop's own work, not the backend's, so they
            // run before the wait rather than after it. On a backend whose
            // `shutdownFd` cannot cancel — iroh's is a documented no-op — the
            // ops these closes retire are the only reason some connections
            // ever complete, and sleeping first can mean sleeping on them.
            self.retryPendingCloses();
            self.retryListenerClose();
            if (self.shutting_down)
                self.retryWakeCancel()
            else
                self.retryWakeRearm();

            // One adapter turn per loop turn. A continuation asks only for a
            // zero-time poll, not another callback in this stack frame, so
            // ready network completions remain interleaved with adapter work.
            const adapter_ran = if (!self.shutting_down) blk: {
                const on_loop_turn = self.on_loop_turn orelse break :blk false;
                break :blk try on_loop_turn(self.make_ctx);
            } else false;

            // Wake for whichever comes first: the caller's own deadline or the
            // nearest connection deadline the reaper below enforces.
            var timeout: i32 = if (self.nextDeadlineMs()) |conn_due|
                (if (caller_deadline_ms) |caller| @min(caller, conn_due) else conn_due)
            else
                (caller_deadline_ms orelse -1);
            // Still owed one: the backend could not admit it, which is an
            // allocation failure and therefore transient. Bound the wait so
            // the retry above comes round again, instead of parking on a
            // completion that cannot arrive until it does.
            if (self.pending_close_submits != 0 or
                (self.listener_close_fd != null and !self.listener_close_pending) or
                self.wake_rearm_pending or
                self.wake_cancel_submit_pending)
            {
                timeout = if (timeout < 0) close_retry_ms else @min(timeout, close_retry_ms);
            }
            if (adapter_ran) timeout = 0;

            const n = try self.backend.poll(&completions, timeout);
            // A backend that reports more than it was given would have the
            // sweeps below read past the batch. The contract says "up to
            // `out.len`"; this is where that is consumed, so this is where it
            // is checked.
            std.debug.assert(n <= completions.len);
            // Held, not propagated yet. The three sweeps below repair what the
            // batch left behind — a connection parked buffer-starved after its
            // recycle already ran, a deadline that came due — and a dispatch
            // failure is loop-global, so for some of those connections this is
            // the last turn there is.
            const dispatched = self.dispatchBatch(completions[0..n]);
            // Every pool buffer this batch carried has been recycled, so re-arm
            // whatever parked buffer-starved during the batch. A starved
            // completion can be dispatched after the recycle that should have
            // resumed it; this sweep closes that ordering gap.
            self.resumeStarved(.all);
            self.reapDeadlines();
            self.drainFanInDirty();
            try dispatched;
        }

        /// Run the loop until `stop` says to return: `.forever` for a
        /// production server or dialer, `.{ .after_closed = n }` to return once
        /// `n` connections have been fully served and closed (the test-shaped
        /// stop condition). Per-connection failures close only their
        /// connection; the errors that escape here are loop-global, namely a
        /// backend poll failure or a listener accept re-arm failure.
        pub fn run(self: *Self, stop: Stop) !void {
            const claimed = self.latchOwner();
            if (comptime std.debug.runtime_safety) std.debug.assert(claimed);
            defer self.releaseDriverOwnership();
            try self.ensureAccepting();
            while (switch (stop) {
                .forever => true,
                .after_closed => |n| self.closed_count < n,
            }) try self.pollOnce(null);
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
        /// this loop's `poll`: nudge the armed wake channel (`armWake`; a
        /// `driver.SettleMailbox.wake` is the sanctioned entry), call a
        /// userspace backend's explicit stopper wake when it exposes one, or,
        /// on a listening loop with no wake armed, a connect-and-drop against
        /// the bound port. A flag set from a serve/vow callback on this thread
        /// needs no wake — the next loop iteration sees it.
        ///
        /// After return, slots may still hold armed recvs; call `closeAndDrain`
        /// before `deinit`.
        pub fn runUntil(self: *Self, done: *const std.atomic.Value(bool), deadline_ms: i32) !void {
            const claimed = self.latchOwner();
            if (comptime std.debug.runtime_safety) std.debug.assert(claimed);
            defer self.releaseDriverOwnership();
            try self.ensureAccepting();
            const deadline_start: ?i64 = if (deadline_ms > 0) clock.nowMonotonicMs() else null;
            while (!done.load(.acquire)) {
                const caller_timeout: ?i32 = if (deadline_start) |start| blk: {
                    const elapsed = clock.nowMonotonicMs() - start;
                    const remaining = deadline_ms - @as(i32, @intCast(elapsed));
                    if (remaining <= 0) return error.Timeout;
                    break :blk remaining;
                } else null;
                try self.pollOnce(caller_timeout);
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
            const claimed = self.latchOwner();
            if (comptime std.debug.runtime_safety) std.debug.assert(claimed);
            defer self.releaseDriverOwnership();
            // The close sweep below is idempotent — it touches only `.open` and
            // `.draining` slots — so a drain that failed part-way can be
            // retried. Returning early on the second call instead left the
            // caller no way to finish, and `deinit` then asserts on the ops
            // still in flight, or in a release build frees an outbound buffer
            // the backend is still writing from.
            const first = !self.shutting_down;
            self.shutting_down = true;
            // Do not set tearing_down yet: closeConn must still submitClose.
            // freeConnCtx skips drainActions while shutting_down.

            // Cancel a pending accept and close the listen handle first so the
            // drain poll cannot block forever on an idle acceptor. Null the
            // field before submit so `deinit` does not double-close; Backends
            // must yield an accept completion (result < 0) when one was armed.
            if (first) {
                // A queued re-arm owns no backend operation, so retiring it is
                // immediate. An admitted recv does own one and must be canceled
                // explicitly: the wake fd belongs to the mailbox, not this loop.
                self.wake_rearm_pending = false;
                if (self.wake_armed) {
                    self.wake_cancel_submit_pending = true;
                    self.retryWakeCancel();
                } else {
                    self.wake = null;
                }
                if (self.listen_fd) |fd| {
                    self.listen_fd = null;
                    self.listener_close_fd = fd;
                    // Listener submitClose owns both cancellation of the armed
                    // accept and descriptor release. shutdown is still useful
                    // to readiness backends, but io_uring cancels the exact
                    // accept request because shutdown(2) on a listening socket
                    // is not a portable cancellation mechanism.
                    self.backend.shutdownFd(fd);
                    self.retryListenerClose();
                }
            }

            for (self.conns, 0..) |*c, slot| {
                // Hard close: skip the abort flush. `closeConn` owns shutdown
                // and close submission together on every terminal path.
                if (c.state == .open or c.state == .draining) {
                    self.closeConn(slot, c);
                }
            }

            // The two sweeps `pollOnce` adds are provable no-ops here:
            // `drainFanInDirty` returns on `shutting_down`, and every stamp is
            // cleared by `closeConn`, so the reaper finds nothing.
            // The listener close and the canceled accept are distinct backend
            // operations and may complete in either order. Keep polling until
            // both retire; clearing accept_armed at submit time can otherwise
            // leave a late accept completion queued past deinit.
            while (self.anyBusy() or self.listener_close_fd != null or self.accept_armed or
                self.wake_armed or self.wake_cancel_submit_pending or self.wake_cancel_pending)
                try self.pollOnce(null);
            self.wake = null;
        }

        /// Dispatch every completion in a batch, then surface the first
        /// error.
        ///
        /// `try` inside the loop would abandon the completions behind the
        /// failing one. Each of those is the only chance to retire its op and,
        /// for a recv, to recycle its pooled buffer: dropping them leaves
        /// `ops_in_flight` above zero, so `closeAndDrain` waits on work that
        /// can never complete and `deinit` trips its in-flight assertion. The
        /// batch is consumed exactly once, whatever any one completion does.
        fn dispatchBatch(self: *Self, batch: []const Completion) !void {
            var first_err: ?anyerror = null;
            for (batch) |c| self.dispatch(c) catch |err| {
                if (first_err == null) first_err = err;
            };
            if (first_err) |err| return err;
        }

        fn anyBusy(self: *const Self) bool {
            return self.live_count != 0;
        }

        /// Resolve one complete OCapN locator through the transport resolver,
        /// then admit the dial.
        /// This is the only public dial verb: above the net boundary callers speak
        /// only `transport` + `designator` + hint, never a Backend `ConnectTarget`.
        pub fn dialLocator(
            self: *Self,
            locator: model.PeerLocator,
        ) !usize {
            self.assertOwnerOrUnclaimed();
            const target = try DialResolver.resolve(locator);
            return self.dial(target, .ordinary);
        }

        /// Admit a dial through the capacity reserved in
        /// `Options.reserved_dial_conns`. Use only for a bounded control-plane
        /// relationship whose recovery must survive ordinary connection
        /// pressure; a zero reservation refuses it.
        pub fn dialLocatorReserved(
            self: *Self,
            locator: model.PeerLocator,
        ) !usize {
            self.assertOwnerOrUnclaimed();
            const target = try DialResolver.resolve(locator);
            return self.dial(target, .reserved);
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
        fn dial(self: *Self, target: ConnectTarget, admission: DialAdmission) !usize {
            if (self.shutting_down or self.tearing_down) return error.ShuttingDown;

            const slot = self.freeSlot(admission) orelse return error.TooManyConnections;
            errdefer self.pushFreeSlot(slot);
            var peer = try self.make_peer(self.make_ctx, self.allocator);
            errdefer peer.deinit();

            const fd = try self.backend.startDial(userData(.connect, slot), target);
            // startDial submitted the connect: the slot must own the fd and the
            // in-flight op before any further failure can run, or a completion
            // would land with nowhere to go.
            const c = self.adoptSlot(slot, fd, peer, false, admission);
            c.ops_in_flight += 1;
            return slot;
        }

        fn dispatch(self: *Self, comp: Completion) !void {
            const slot = slotOf(comp.user_data);
            switch (opOf(comp.user_data)) {
                // The out-of-band wake (ADR-0102): recycle the pool buffer
                // that carried the nudge bytes, run the armed handler on this
                // owning thread, and re-arm. No slot belongs to it.
                .wake => {
                    std.debug.assert(self.wake_armed);
                    self.wake_armed = false;
                    if (comp.recv_bytes != null) self.recycleRecvBuffer(comp);
                    // Shutdown owns no callbacks and no new recv submissions.
                    // The separate cancel completion may arrive before or after
                    // this target completion, so each retires only its own seat.
                    if (self.shutting_down) {
                        // If cancellation was still being refused, the target
                        // completed naturally and there is no cancel operation
                        // left to submit or drain.
                        self.wake_cancel_submit_pending = false;
                        return;
                    }
                    // A momentarily empty buffer pool completes a recv with
                    // no data and a negative result, which is transient
                    // pressure and not a closed channel. The connection arm
                    // parks and re-arms for exactly this; the wake must too,
                    // or one starved poll deafens it for the loop's life.
                    if (comp.recv_no_buffer) {
                        self.wake_rearm_pending = true;
                    } else {
                        self.onWakeCompletion(comp.result);
                    }
                },
                .wake_cancel => {
                    std.debug.assert(self.wake_cancel_pending);
                    self.wake_cancel_pending = false;
                },
                // The only handler that may fail the loop: a dead accept re-arm
                // is loop-global. Every per-connection handler resolves its own
                // failures by closing that one connection.
                .accept => try self.onAccept(comp),
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
                .close => {
                    if (comp.result < 0) {
                        if (slot < self.conns.len) {
                            const c = &self.conns[slot];
                            if (c.state == .closing) self.backend.closeFd(c.fd);
                        }
                        if (slot == self.conns.len) {
                            if (self.listener_close_fd) |fd| self.backend.closeFd(fd);
                        }
                    }
                    if (slot == self.conns.len) {
                        self.listener_close_pending = false;
                        self.listener_close_fd = null;
                    }
                    self.retireConnOp(slot);
                },
            }
        }

        /// Keep exactly one accept outstanding. Idempotent, because `run` and
        /// `runUntil` both open by calling it and both are callable more than
        /// once; a second accept would never retire, since a completion re-arms
        /// exactly one.
        fn ensureAccepting(self: *Self) !void {
            if (self.accept_armed) return;
            const fd = self.listen_fd orelse return;
            try self.backend.submitAccept(userData(.accept, 0), fd);
            self.accept_armed = true;
        }

        fn onAccept(self: *Self, comp: Completion) !void {
            const accepted: ?Fd = if (comp.accepted_fd) |fd|
                @intCast(fd)
            else if (comp.result >= 0)
                @intCast(comp.result)
            else
                null;
            // Shutdown closed the listener (or cancelled its accept): drop any
            // racing accept and never re-arm.
            self.accept_armed = false;
            if (self.shutting_down or self.listen_fd == null) {
                if (accepted) |fd| self.backend.closeFd(fd);
                return;
            }
            // Keep one accept armed so the next connection is not missed. The
            // re-arm runs first deliberately; if it fails (loop-global, kills
            // `run`), the accepted fd must still be closed, not leaked.
            errdefer if (accepted) |fd| self.backend.closeFd(fd);
            try self.ensureAccepting();
            const fd = accepted orelse return; // transient accept failure: the re-arm recovers

            const slot = self.freeSlot(.ordinary) orelse {
                self.backend.closeFd(fd);
                return;
            };
            const peer = self.make_peer(self.make_ctx, self.allocator) catch {
                self.pushFreeSlot(slot);
                self.backend.closeFd(fd);
                return;
            };
            const adopted = self.adoptSlot(slot, fd, peer, true, .ordinary);
            self.finishConnected(slot, adopted);
        }

        fn onConnect(self: *Self, slot: usize, res: i32) void {
            const c = self.liveConn(slot) orelse return;
            if (res < 0) {
                self.closeConn(slot, c);
                return;
            }
            c.opened = true;
            self.finishConnected(slot, c);
        }

        /// Take a free slot for a new connection.
        ///
        /// The one place a `Conn` is initialized. A whole-struct assignment is
        /// how the slot's other state gets cleared, and it would clear the
        /// slot's *identity* too: `generation` is reset by the very assignment
        /// that makes the slot a different connection, which is when a holder of
        /// a stale reference most needs it to have advanced. It is carried
        /// across by hand here, so nowhere else has to remember.
        fn adoptSlot(
            self: *Self,
            slot: usize,
            fd: Fd,
            peer: engine.Peer,
            opened: bool,
            admission: DialAdmission,
        ) *Conn {
            const c = &self.conns[slot];
            const generation = c.generation;
            c.* = .{
                .state = .open,
                .opened = opened,
                .fd = fd,
                .peer = peer,
            };
            self.live_count += 1;
            std.debug.assert((slot < self.ordinary_capacity) == (admission == .ordinary));
            c.generation = generation;
            return c;
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
                // Staged, not published straight into the slot. The hook may
                // condemn this connection (a bridge drains host actions here),
                // and a close that cannot queue tears the slot down inline —
                // so by the time `make` returns, `c` can already be free and
                // on the free list. Writing a live context into a free slot
                // leaks it, because the next accept overwrites the field.
                // The slot cannot be reclaimed while this runs, so `c` still
                // names this connection when the hook returns. It may have
                // been condemned, and the teardown it deferred runs below.
                self.adopting_slot = slot;
                const ctx = make(self.make_ctx, &c.peer, slot) catch {
                    self.adopting_slot = null;
                    if (self.adopting_teardown_deferred) {
                        self.adopting_teardown_deferred = false;
                        if (self.teardown(slot)) self.closed_count += 1;
                    } else {
                        self.closeConn(slot, c);
                    }
                    return;
                };
                self.adopting_slot = null;
                // The adoption guard kept this slot stable while the hook ran,
                // so publish every successfully built context even when the
                // hook condemned the connection. Teardown then preserves the
                // public callback order: `on_close` observes the live context,
                // `free_conn_ctx` releases it, and only then does the peer die.
                c.app_ctx = ctx;
                if (self.adopting_teardown_deferred) {
                    self.adopting_teardown_deferred = false;
                    if (self.teardown(slot)) self.closed_count += 1;
                    return;
                }
                if (c.state != .open) return;
            }
            // The hook drains host actions, so a `close` for the peer it just
            // adopted can condemn this connection before it ever serves a
            // turn. Driving or arming past that would put new bytes on the
            // wire behind its abort, which `.draining` exists to forbid.
            if (c.state != .open) return;

            self.driveOut(slot, c) catch {
                self.failConn(slot, c);
                return;
            };
            if (c.state != .open) return;
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
            self.assertOwnerOrUnclaimed();
            if (self.tearing_down) return;
            const c = self.liveConn(slot) orelse return;
            self.driveOut(slot, c) catch self.failConn(slot, c);
        }

        /// The durable key (32-byte Ed25519) this connection's realizer proved
        /// its far end holds, when the backend proves one. The iroh backend
        /// reads it off the QUIC handshake (ADR-0105). Socket backends carry no
        /// lower-layer identity and answer null; the member is part of the
        /// total Backend contract (`validateBackend`). A `MakeConnCtx` hook
        /// calls this at adoption, before the connection's first byte feeds,
        /// and asserts what it returns to the engine.
        ///
        /// The *channel's* far end, never the CapTP partner: a byte-transparent
        /// relay makes those two different parties, and the engine keeps them
        /// in two fields for that reason (`engine.DurablePin`).
        pub fn verifiedChannelKey(self: *Self, slot: usize) ?[32]u8 {
            self.assertOwnerOrUnclaimed();
            const c = self.liveConn(slot) orelse return null;
            return self.backend.verifiedChannelKey(c.fd);
        }

        /// Close the connection at `slot` after a best-effort flush of
        /// whatever the engine projected onto its outbound (typically an
        /// `op:abort`) — the "arm, then close" entry a bridge's `close`
        /// action needs. No-op on a free, closing, or tearing-down slot; the
        /// teardown itself rides the ordinary close path, so in-flight ops
        /// retire before the slot is reclaimed.
        ///
        /// The first call starts the flush and waits for the partner to read
        /// it; a second call on the same slot says the caller will not wait, and
        /// hard-closes, dropping whatever has not reached the wire. Waiting
        /// is otherwise bounded by `Options.drain_kill_ms`.
        pub fn closeSlot(self: *Self, slot: usize) void {
            self.assertOwnerOrUnclaimed();
            if (self.tearing_down or slot >= self.conns.len) return;
            const c = &self.conns[slot];
            switch (c.state) {
                .open => self.failConn(slot, c),
                // Close already requested, and waiting on the partner to read its
                // abort. A second request means the caller will not wait:
                // shut the fd down so an armed recv completes at once, then
                // close, the same escalation `closeAndDrain` performs.
                .draining => {
                    self.backend.shutdownFd(c.fd);
                    self.closeConn(slot, c);
                },
                .free, .closing => {},
            }
        }

        /// Latch the owning thread at `run` entry. Setup (`init`, `dial`,
        /// `attach`) may run on a different thread before the loop starts;
        /// only the run thread may call `armOutbound`/`closeSlot`.
        fn latchOwner(self: *Self) bool {
            if (comptime !std.debug.runtime_safety) return false;
            const tid = std.Thread.getCurrentId();
            if (self.owner_tid) |owned| {
                std.debug.assert(owned == tid);
                return false;
            } else {
                self.owner_tid = tid;
                return true;
            }
        }

        /// Setup may mutate an unclaimed loop before a driver starts; once a
        /// driver owns it, every public operation must run on that same thread.
        /// This deliberately does not latch an unclaimed loop: only a driver
        /// lifetime owns the `on_driver_exit` transfer.
        fn assertOwnerOrUnclaimed(self: *const Self) void {
            if (comptime !std.debug.runtime_safety) return;
            if (self.owner_tid) |owned|
                std.debug.assert(owned == std.Thread.getCurrentId());
        }

        fn releaseDriverOwnership(self: *Self) void {
            if (self.on_driver_exit) |on_exit| on_exit(self.make_ctx);
            if (comptime !std.debug.runtime_safety) return;
            std.debug.assert(self.owner_tid != null);
            std.debug.assert(self.owner_tid.? == std.Thread.getCurrentId());
            self.owner_tid = null;
        }

        /// The connection at `slot`, when a completion landing there is still
        /// addressed to a connection that may take new work. Null drops the
        /// rest: a slot index from a torn-down (possibly already reused)
        /// connection, a `.draining` one whose terminal bytes are the last
        /// that may go out, and a `.closing` one whose remaining completions
        /// only retire ops. The two terminal states admit exactly one thing
        /// each — a send completion, and (in `.draining`) the retirement of
        /// an already-armed recv — so those two callers test state inline
        /// rather than through this helper.
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
        /// other connection's reads so many-A-to-one-B sources slow (ADR-0082).
        /// Protocol frames are never dropped; the queue is bounded at the mark
        /// plus the replies of frames already buffered.
        fn armOrPark(self: *Self, slot: usize, c: *Conn) !void {
            if (pendingOut(c) > self.outbound_high_water_bytes) {
                // A genuine sink park: this connection is not draining its own
                // outbound, so it is the slow reader the reaper targets.
                // Which kind of park this is comes from the queue depth
                // `refreshWaiting` reads, not from a flag passed alongside.
                self.markParked(slot, c, .sink);
                return;
            }
            if (self.fan_in_throttle and self.anySinkParked()) {
                // A fan-in park: an innocent fast source throttled behind some
                // other slow sink. It is a victim, not the slow reader.
                self.markParked(slot, c, .fan_in);
                return;
            }
            try self.armRecv(slot, c);
        }

        /// Park the read seat, and tell the embedder once per park.
        ///
        /// `reason` is reported, not consulted: which deadline this park
        /// answers to still comes from the connection's own queue depth in
        /// `refreshWaiting`, so the hook cannot disagree with the reaper.
        fn markParked(self: *Self, slot: usize, c: *Conn, reason: ParkReason) void {
            // A seat arriving `.starved` is already on another list, and
            // linking it would put one slot on two (see `Conn.next_link`).
            // Every caller vacates the seat first.
            std.debug.assert(c.read == .idle or c.read == .parked);
            const was_parked = c.read == .parked;
            // State first, hook last. The hook receives `slot` so it may call
            // back in — `closeSlot` is public — and anything it does must land
            // on a seat that already reads `.parked`, not be overwritten after.
            c.read = .parked;
            if (!was_parked) self.linkOnto(&self.parked_head, slot);
            self.refreshWaiting(c);
            if (!was_parked) {
                if (self.on_park) |hook| hook(self.make_ctx, slot, c.app_ctx, reason);
            }
        }

        /// True when any connection that can still write is over its outbound
        /// high-water mark (a true ADR-0042 sink park, not a fan-in source
        /// park). A `.draining` connection counts: its queued bytes are just
        /// as unread, and releasing the sources it throttles while they are
        /// still in the kernel's hands is what the fan-in mark exists to
        /// prevent.
        fn anySinkParked(self: *const Self) bool {
            return self.over_mark_count > 0;
        }

        /// Returns when this connection's wait runs out, and what the loop
        /// would call the resulting close. Null when it is not waiting on the
        /// partner.
        ///
        /// The one place that decides. `nextDeadlineMs` sizes the poll wait
        /// from this and `reapDeadlines` acts on it, so the two cannot
        /// disagree about which connections have deadlines. If they could,
        /// a connection the wait counted but the reap skipped would make
        /// `poll` return instantly forever: a busy-spin, not a leak, and the
        /// hardest failure here to see in a test.
        fn pendingDeadline(self: *const Self, c: *const Conn) ?Deadline {
            const limit, const reason: CloseReason = switch (c.state) {
                .open => .{ self.park_kill_ms orelse return null, .park_kill },
                .draining => .{ self.drain_kill_ms orelse return null, .drain_kill },
                .free, .closing => return null,
            };
            if (c.waiting_since_ms == 0) return null;
            return .{ .due = c.waiting_since_ms + @as(i64, @intCast(limit)), .reason = reason };
        }

        /// The one writer of `Conn.waiting_since_ms`, so `waiting_count` cannot
        /// drift from the number of stamped connections. Pass `0` for "not
        /// waiting".
        fn setWaiting(self: *Self, c: *Conn, stamp: i64) void {
            if ((c.waiting_since_ms == 0) != (stamp == 0)) {
                if (stamp == 0) self.waiting_count -= 1 else self.waiting_count += 1;
            }
            c.waiting_since_ms = stamp;
            // Folding a new deadline in is one comparison. A cleared one is
            // left in the cache on purpose: a stale entry can only make the
            // loop wake early, which costs a poll, while dropping one late
            // would miss a reap. `reapDeadlines` recomputes after any wake
            // that closes nothing.
            if (stamp != 0) {
                if (self.earliest_due_ms) |cached| {
                    const limit = self.limitFor(c) orelse return;
                    const due = stamp + limit;
                    if (due < cached) self.earliest_due_ms = due;
                }
            }
        }

        /// The deadline this connection's state answers to, or null when its
        /// state has none configured.
        fn limitFor(self: *const Self, c: *const Conn) ?i64 {
            return switch (c.state) {
                .open => if (self.park_kill_ms) |ms| @intCast(ms) else null,
                .draining => if (self.drain_kill_ms) |ms| @intCast(ms) else null,
                .free, .closing => null,
            };
        }

        /// Recount this connection's contribution to `over_mark_count`.
        ///
        /// Edge-triggered, one owner, one comparison. Asking the question by
        /// walking every slot would put the `O(max_conns)` shape the deadline
        /// cache exists to avoid onto a path that runs once per armed read; the
        /// queue depth already funnels through this refresh, so the count can
        /// be maintained here instead.
        fn refreshOverMark(self: *Self, c: *Conn) void {
            const over = switch (c.state) {
                .open, .draining => pendingOut(c) > self.outbound_high_water_bytes,
                .free, .closing => false,
            };
            if (over == c.over_mark) return;
            c.over_mark = over;
            if (over) {
                self.over_mark_count += 1;
                return;
            }
            self.over_mark_count -= 1;
            // The last sink just came back under the mark, and the sources it
            // was throttling have no other resume trigger. Recorded here
            // because this is the one place that knows the *transition*. Asking
            // from the send paths instead means asking on every completed
            // write, and the answer is no in the healthy steady state, so each
            // reply would pay a walk to re-arm nothing. Recorded rather than
            // performed, for the reasons `drainFanInDirty` gives.
            if (self.fan_in_throttle and self.over_mark_count == 0) self.fan_in_dirty = true;
        }

        /// Recompute whether this connection is waiting on a deadline, and
        /// stamp or clear to match.
        ///
        /// Eligibility is owned by mutation, not read back from live state at
        /// reap time: every input — the read seat, the queue depth, the
        /// connection state — calls here when it changes. That is what lets
        /// the nearest-deadline cache be trusted, and it is what gives a
        /// fan-in victim its full grace: a connection that was somebody else's
        /// victim is stamped when it becomes a slow reader in its own right,
        /// not when it first parked.
        fn refreshWaiting(self: *Self, c: *Conn) void {
            self.refreshOverMark(c);
            const eligible = switch (c.state) {
                // Over the mark is the condition, not the seat. What throttles
                // every other connection is `over_mark_count`, and that is set
                // from the queue depth alone — `armOutbound` and `onSend`'s
                // drive both push a connection past the mark while its own recv
                // is still armed. Requiring `.parked` here meant such a
                // connection throttled the whole loop and carried no deadline,
                // so `waiting_count` stayed zero, the poll waited forever, and
                // nothing could arrive to end it. `refreshOverMark` ran one
                // line above, so this is fresh.
                .open => c.over_mark and self.park_kill_ms != null,
                .draining => self.drain_kill_ms != null,
                .free, .closing => false,
            };
            const is_drain = c.state == .draining;
            if (!eligible) {
                if (c.waiting_since_ms != 0) self.setWaiting(c, 0);
                return;
            }
            // Already waiting on the same question: leave the clock running.
            if (c.waiting_since_ms != 0 and c.waiting_is_drain == is_drain) return;
            // Either not waiting, or waiting on a different question than the
            // stamp was taken for. A park stamp carried into `.draining` would
            // be measured against `drain_kill_ms`, cutting the terminal flush
            // short by however long the connection had already been parked.
            self.setWaiting(c, 0);
            self.setWaiting(c, clock.nowMonotonicMs());
            c.waiting_is_drain = is_drain;
        }

        /// Close connections whose wait on the partner has run out: a read
        /// parked under backpressure past `park_kill_ms`, and a terminal flush
        /// the partner is not draining past `drain_kill_ms`. Without the second
        /// arm a `.draining` slot is pinned for as long as the partner declines
        /// to read its abort, holding an fd, a `Peer`, and its queues.
        fn reapDeadlines(self: *Self) void {
            const due = self.earliestDue() orelse return;
            const now = clock.nowMonotonicMs();
            if (now < due) return;
            // Something was due, or the cache was stale-early. Either way the
            // next nearest has to be found again — and this walk is already
            // visiting every slot and already computing each deadline, so it
            // finds it here. Leaving the cache null costs a second full walk on
            // the next poll, over the slots this one just read.
            self.earliest_due_ms = null;
            var next_earliest: ?i64 = null;
            for (self.conns, 0..) |*c, slot| {
                const deadline = self.pendingDeadline(c) orelse continue;
                if (now < deadline.due) {
                    if (next_earliest == null or deadline.due < next_earliest.?) next_earliest = deadline.due;
                    continue;
                }
                c.close_reason = deadline.reason;
                // Shut a draining fd down so an armed recv completes at once
                // rather than waiting on the partner that already will not
                // read.
                if (c.state == .draining) self.backend.shutdownFd(c.fd);
                self.closeConn(slot, c);
            }
            // Safe to install, though not for the reason the "only ever lowers"
            // rule would give: that rule is disabled here, because the cache
            // was set null above and `setWaiting`'s fold is a no-op on a null
            // one. It is safe because no hook can run during this walk. A
            // reaped connection is over the mark or draining, which means a
            // send was submitted, which means an op is in flight — so
            // `closeConn`'s inline-teardown arm is unreachable from here and
            // `on_close` and `free_conn_ctx` never fire. A future change that
            // lets one fire has to revisit this line.
            self.earliest_due_ms = next_earliest;
        }

        /// Milliseconds until the nearest connection deadline, or null when
        /// none is pending.
        ///
        /// `poll` blocks until a completion arrives, so a deadline that is
        /// only checked *after* the poll cannot fire on a quiet loop: the
        /// connection whose deadline expired is, by definition, the one not
        /// producing completions. Every deadline the loop enforces has to be
        /// visible to the wait itself.
        fn nextDeadlineMs(self: *Self) ?i32 {
            const due = self.earliestDue() orelse return null;
            const remaining = due - clock.nowMonotonicMs();
            return if (remaining <= 0) 0 else @intCast(@min(remaining, std.math.maxInt(i32)));
        }

        /// The nearest deadline, from the cache when it holds one.
        ///
        /// Zero waiters costs nothing, and one waiter costs a comparison
        /// rather than a walk of every slot. That difference is the whole
        /// point at the 500k destination, where a table walk before each poll
        /// and again after each batch is a million cold slot reads bought by
        /// one stalled partner.
        fn earliestDue(self: *Self) ?i64 {
            if (self.waiting_count == 0) {
                self.earliest_due_ms = null;
                return null;
            }
            if (self.earliest_due_ms) |due| return due;
            var earliest: ?i64 = null;
            for (self.conns) |*c| {
                const deadline = self.pendingDeadline(c) orelse continue;
                if (earliest == null or deadline.due < earliest.?) earliest = deadline.due;
            }
            // A stamped connection that yields no deadline would send this
            // walk over every slot on each poll — the cost this cache exists
            // to avoid, and silent, because nothing observable changes.
            std.debug.assert(earliest != null);
            self.earliest_due_ms = earliest;
            return earliest;
        }

        /// Consume one recv completion's bytes while its pool buffer is still
        /// borrowed. Whole frames apply zero-copy straight from the completion
        /// view, advancing by offset; a partial tail absorbs into the bounded
        /// spill (ADR-0041) because the buffer goes back to the pool the moment
        /// this returns. The follow-up work that does not need the buffer —
        /// events, outbound drive, the next read arm — runs in
        /// `onRecvFinish`, after the recycle.
        fn onRecvConsume(self: *Self, slot: usize, comp: Completion) RecvVerdict {
            if (slot >= self.conns.len) return .done;
            const c = &self.conns[slot];
            if (c.state == .draining) {
                // A terminal failure may race an already-armed recv (for
                // example closeSlot on a quiet bridge sibling). Retire that
                // borrow without applying bytes or admitting more work: the
                // abort already queued before `.draining` is final.
                std.debug.assert(c.read == .armed);
                c.read = .idle;
                return .done;
            }
            if (c.state != .open) return .done;
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
            // this slot cannot have been *reclaimed* in between — its recv op
            // stays counted across this call, so no teardown can reach it. Its
            // state can still have changed: the recycle resumes a starved
            // connection, that can park one, and `on_park` is a public hook
            // free to close anything. `closeConn` and `failConn` both guard on
            // state, which is what covers that.
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
                // A hook may condemn its own connection (a bridge `close`
                // action for the session it is serving). That is terminal:
                // the abort is already queued, so serving further events
                // would mint replies behind it, and the drive and read-arm
                // below no longer apply. Unpolled events die with the peer.
                if (c.state != .open) return;
            }

            self.driveOut(slot, c) catch {
                self.failConn(slot, c);
                return;
            };
            if (c.state != .open) return;

            self.armOrPark(slot, c) catch self.closeConn(slot, c);
        }

        /// Push a slot onto the list at `head`. The caller guarantees it is on
        /// no list right now (see `Conn.next_link`); pushing a listed slot
        /// builds a cycle.
        fn linkOnto(self: *Self, head: *usize, slot: usize) void {
            const c = &self.conns[slot];
            c.prev_link = @intCast(self.conns.len);
            c.next_link = @intCast(head.*);
            if (head.* < self.conns.len) self.conns[head.*].prev_link = @intCast(slot);
            head.* = slot;
        }

        /// Splice a slot out of the list at `head`. `O(1)`, which is the reason
        /// the links are a pair: removal by value from a singly linked list
        /// walks it, and this runs on the close path, where a walk per departure
        /// makes a mass close quadratic.
        fn unlinkFrom(self: *Self, head: *usize, slot: usize) void {
            const c = &self.conns[slot];
            if (c.next_link < self.conns.len) self.conns[c.next_link].prev_link = c.prev_link;
            if (c.prev_link < self.conns.len) {
                self.conns[c.prev_link].next_link = c.next_link;
            } else {
                head.* = c.next_link;
            }
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
            self.linkOnto(&self.starved_head, slot);
        }

        /// Take a connection off the parked list, leaving the seat `.idle`.
        /// A seat that is not parked is not listed, so this is a no-op there.
        fn unlinkParked(self: *Self, slot: usize) void {
            const c = &self.conns[slot];
            if (c.read != .parked) return;
            c.read = .idle;
            self.unlinkFrom(&self.parked_head, slot);
        }

        /// Remove a connection from the starved list (on close) so teardown's
        /// slot reset cannot break the chain.
        fn unlinkStarved(self: *Self, slot: usize) void {
            const c = &self.conns[slot];
            if (c.read != .starved) return;
            c.read = .idle;
            self.unlinkFrom(&self.starved_head, slot);
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
                self.unlinkFrom(&self.starved_head, slot);
                c.read = .idle;
                if (c.state != .open) continue;
                // One owner for the arm-or-park decision (ADR-0042). Restating
                // its branches here is how the two drift.
                self.armOrPark(slot, c) catch {
                    self.closeConn(slot, c);
                    continue;
                };
                // Only an actual arm consumed the buffer that freed.
                if (scope == .one and c.read == .armed) return;
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
        /// Queue depth is an eligibility input, so every path that changes it
        /// ends here and refreshes. Cross-connection arms land here too.
        fn flushOutbound(self: *Self, slot: usize, c: *Conn) !void {
            defer self.refreshWaiting(c);
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
            if (c.state != .open) return;
            // Terminal failure is a lifecycle, not an outbound-queue flag.
            // From here only already-projected bytes and their send
            // completions may run; an armed recv is retired without applying.
            c.state = .draining;
            // The flush below waits on the partner, so it is bounded: a
            // partner that never reads the abort must not pin this slot. This
            // is a different wait from the slow-reader park it may replace, so
            // the refresh restarts the clock rather than inheriting it.
            self.refreshWaiting(c);
            while ((c.peer.step() catch .idle) != .idle) {}
            self.flushOutbound(slot, c) catch {
                self.closeConn(slot, c);
                return;
            };
            if (!c.write_in_flight and pendingOut(c) == 0) self.closeConn(slot, c);
        }

        fn submitSend(self: *Self, slot: usize, c: *Conn) !void {
            // The backend borrows this slice until the send completes; `front`
            // is frozen from here until `onSend` sees it drained.
            try self.backend.submitSend(userData(.send, slot), c.fd, c.front.items[c.front_off..]);
            c.write_in_flight = true;
            c.ops_in_flight += 1;
        }

        /// The partner caught up: resume a read parked at the high-water mark,
        /// and release the fan-in sources that mark was holding.
        ///
        /// Both send paths need this. A partial write can take `pendingOut`
        /// under the mark just as a full drain can, and dropping the deadline
        /// there without re-arming the read left the connection with no
        /// wakeup at all: no armed recv, no deadline, and its victims still
        /// asleep. If the remainder then stalled, nothing would ever run again
        /// on that connection.
        fn resumeIfDrained(self: *Self, slot: usize, c: *Conn) void {
            // Unconditional: a `.draining` connection's queue moves too, and
            // its `over_mark` contribution keeps fan-in victims parked until
            // it is given back. Only the re-arm below is `.open`-only.
            self.refreshWaiting(c);
            if (c.state == .open and c.read == .parked and
                pendingOut(c) <= self.outbound_high_water_bytes)
            {
                if (!(self.fan_in_throttle and self.anySinkParked())) {
                    // No refresh here: the call above already evaluated
                    // eligibility with the enclosing condition's `pendingOut`
                    // under the mark, so the stamp is clear and the over-mark
                    // recount has run. Leaving `.parked` for `.idle` cannot
                    // make an ineligible connection eligible.
                    self.unlinkParked(slot);
                    self.armRecv(slot, c) catch self.closeConn(slot, c);
                }
            }
        }

        fn onSend(self: *Self, slot: usize, res: i32) void {
            if (slot >= self.conns.len) return;
            const c = &self.conns[slot];
            if (c.state != .open and c.state != .draining) return;
            if (res <= 0) {
                self.closeConn(slot, c);
                return;
            }
            c.front_off += @intCast(res);
            if (c.front_off < c.front.items.len) {
                // Partial write: send the remainder. `front` is untouched
                // since the original submit (appends went to `back`), so the
                // resubmitted slice is still backed by live storage. The
                // advance lowered `pendingOut` and may have taken it under the
                // mark, so this is a drain like any other: the read resumes
                // and the victims wake, not merely the deadline clearing.
                self.submitSend(slot, c) catch {
                    self.closeConn(slot, c);
                    return;
                };
                self.resumeIfDrained(slot, c);
                return;
            }
            // Drained. Burst capacity frees on drain (the spill's posture,
            // ADR-0041/0042): one slow-reader episode must not pin its
            // high-water bytes for the connection's lifetime. Steady-sized
            // capacity is retained so ordinary reply traffic never reallocates.
            frame_stream.reclaimBurst(&c.front, self.allocator, steady_outbound_bytes);
            // A drained connection never pins burst capacity: this is the
            // 500k-footprint invariant a slow-drain episode must not break. The
            // live-socket measurement is step 5 work (docs/ladder.md); this pins
            // the bound loudly in every safe build, on every drain.
            std.debug.assert(c.front.capacity <= steady_outbound_bytes);
            c.front_off = 0;
            c.write_in_flight = false;
            if (c.state == .draining) {
                // Bytes queued behind the completed frozen front were already
                // present when failConn entered `.draining`; send them without
                // stepping the peer or admitting any new application work.
                if (c.back.items.len > 0) {
                    // `reclaimBurst` above emptied the front in both its
                    // arms. Swapping a non-empty front into `back` would
                    // resend bytes the partner already has, forever.
                    std.debug.assert(c.front.items.len == 0);
                    std.mem.swap(std.ArrayList(u8), &c.front, &c.back);
                    self.submitSend(slot, c) catch self.closeConn(slot, c);
                    // The swap can take this connection under the mark. It is
                    // terminal, so its own read stays down, but the refresh is
                    // what releases the sources it was throttling: they must
                    // not wait on a send that may never complete.
                    self.refreshWaiting(c);
                } else {
                    self.closeConn(slot, c);
                }
                return;
            }
            // Bytes queued on `back` while this write was in flight — and any
            // reply this drive encodes — swap into the emptied front and go
            // out now (`flushOutbound`).
            self.driveOut(slot, c) catch {
                self.failConn(slot, c);
                return;
            };
            self.resumeIfDrained(slot, c);
        }

        /// Re-evaluate fan-in throttling once for a poll batch in which one or
        /// more connections departed. Called from the loop body, never from a
        /// teardown, so the resume below cannot re-enter teardown, and a batch
        /// that closed many connections pays one table sweep rather than one
        /// per connection.
        fn drainFanInDirty(self: *Self) void {
            if (!self.fan_in_dirty) return;
            self.fan_in_dirty = false;
            // `closeAndDrain` is sweeping slots closed; arming a fresh recv
            // behind its sweep is the hazard `Bridge.freeConnCtx` refuses too.
            if (self.tearing_down or self.shutting_down) return;
            if (self.anySinkParked()) return;
            self.resumeFanInSources();
        }

        /// Re-arm connections parked solely by `fan_in_throttle` once no true
        /// ADR-0042 sink remains over the high-water mark. A seat that is still
        /// sink-parked (`pendingOut` over the mark) or no longer open is left
        /// alone, on the list, untouched.
        ///
        /// The walk follows the live list and splices in place. Detaching the
        /// list first would keep re-parks from being chased, but it opens a
        /// window: for the length of the walk a slot reads `.parked` while
        /// unreachable from `parked_head`, which is exactly the state
        /// `unlinkParked` treats as a corrupt chain, and a hook re-entering the
        /// loop meanwhile would hit it — `free_conn_ctx` drains host actions,
        /// and one of them can close a sibling. In place there is no window,
        /// and a re-park pushes onto the head the walk has already passed, so
        /// it still terminates.
        fn resumeFanInSources(self: *Self) void {
            var next = self.parked_head;
            while (next < self.conns.len) {
                const slot = next;
                const c = &self.conns[slot];
                // It left the list under us — a hook re-entered through the
                // previous iteration's close and reached this slot. Its link
                // word is no longer a parked-list link: `teardown` hands it to
                // the free list, and a re-adopting `dial` zeroes it, which
                // walks into slot 0 and, if slot 0 is an ordinary open
                // connection whose own link is still zero, never leaves. So do
                // not read it. The departure already asked for a re-sweep; ask
                // again for the rest of this list and let the batch's drain run
                // it.
                if (c.read != .parked) {
                    self.fan_in_dirty = true;
                    return;
                }
                next = c.next_link;
                if (c.state != .open or pendingOut(c) > self.outbound_high_water_bytes) continue;
                self.unlinkParked(slot);
                self.refreshWaiting(c);
                self.armOrPark(slot, c) catch self.closeConn(slot, c);
            }
        }

        fn closeConn(self: *Self, slot: usize, c: *Conn) void {
            // A free slot has an undefined `fd`, so closing one would hand the
            // backend garbage. Reaching here with one is currently impossible
            // (a recv's op stays counted across `onRecvFinish`, so no nested
            // teardown can reclaim the slot under it), but that argument spans
            // three functions and should not be the only thing standing
            // between this and a bad close.
            if (c.state == .free or c.state == .closing) return;
            self.unlinkStarved(slot);
            self.unlinkParked(slot);
            // A closing connection waits on nothing: its deadline, if any, has
            // already done its work. Dropping the stamp here keeps
            // `waiting_count` at zero on a healthy loop rather than pinned by
            // slots that are merely retiring their ops.
            self.setWaiting(c, 0);
            c.state = .closing;
            // A closing connection throttles nobody, and the slot reset at
            // teardown would otherwise drop its contribution silently.
            self.refreshOverMark(c);
            // Closing an fd does not itself cancel an async operation that
            // already holds the underlying socket (notably an io_uring recv).
            // Shutdown first on every terminal path, not only closeAndDrain,
            // so kernel operations retire even when close completes before
            // them. Userspace backends may make this a no-op and synthesize
            // those completions from submitClose instead.
            self.backend.shutdownFd(c.fd);
            self.backend.submitClose(userData(.close, slot), c.fd) catch {
                // Could not even queue the close, so this branch owns the fd:
                // the normal path closes it through the queued op, and
                // `teardown` never closes, so the two are mutually exclusive
                // and there is no double close.
                //
                // Shut it down first. `submitClose` is contracted to complete
                // whatever is pending on the fd; `closeFd` is only "release a
                // handle" and neither backend synthesizes completions for it.
                // Closing straight away would leave an armed recv and an
                // in-flight send counted forever: `closeAndDrain` would wait
                // on work that can never arrive, and `deinit` would trip its
                // assertion. A shutdown makes those complete, and the fd is
                // released once they have.
                if (c.ops_in_flight == 0) {
                    self.backend.closeFd(c.fd);
                    if (self.teardown(slot)) self.closed_count += 1;
                    return;
                }
                // Ops are still counted, and this branch cannot assume they
                // will retire on their own: `shutdownFd` unblocks an OS recv,
                // but a userspace backend is allowed to make it a no-op and
                // iroh does, so the only thing that retires those ops there is
                // the `submitClose` that just failed. Failing means the
                // backend could not allocate completion capacity, which is
                // transient, so the retry rides the poll batch.
                c.owns_fd_close = true;
                self.pending_close_submits += 1;
                return;
            };
            c.ops_in_flight += 1;
        }

        /// Arm the out-of-band wake (ADR-0102): an ordinary recv on `fd` — a
        /// socketpair half, which is a socket on purpose so every backend's
        /// existing `submitRecv` carries it — whose completion runs `handler`
        /// on the loop thread and re-arms. Call once, on the loop thread,
        /// before workers hold the write half; the fd stays caller-owned
        /// (the settle mailbox's, usually) and must outlive the loop's use.
        pub fn armWake(
            self: *Self,
            fd: Fd,
            ctx: ?*anyopaque,
            handler: *const fn (?*anyopaque) void,
        ) !void {
            self.assertOwnerOrUnclaimed();
            if (self.shutting_down or self.tearing_down) return error.ShuttingDown;
            std.debug.assert(self.wake == null); // one wake channel per loop
            self.wake = .{ .fd = fd, .ctx = ctx, .handler = handler };
            // A submit the backend cannot admit right now is ring pressure,
            // not a bad fd. Leave the channel armed-pending so the bounded
            // retry before the next wait picks it up, rather than reporting
            // a failure whose only honest recovery is that same retry.
            self.backend.submitRecv(userData(.wake, 0), fd) catch {
                self.wake_rearm_pending = true;
                return;
            };
            self.wake_armed = true;
        }

        /// A wake recv completed: run the handler and re-arm. A closed or
        /// faulted channel (teardown pulled the mailbox) stays disarmed; a
        /// re-arm the backend cannot admit right now is retried before the
        /// next wait, bounded like an owed close.
        fn onWakeCompletion(self: *Self, result: i32) void {
            const wake = self.wake orelse return;
            if (result <= 0) {
                self.wake = null;
                return;
            }
            wake.handler(wake.ctx);
            self.backend.submitRecv(userData(.wake, 0), wake.fd) catch {
                self.wake_rearm_pending = true;
                return;
            };
            self.wake_armed = true;
        }

        fn retryWakeRearm(self: *Self) void {
            if (!self.wake_rearm_pending) return;
            const wake = self.wake orelse {
                self.wake_rearm_pending = false;
                return;
            };
            self.backend.submitRecv(userData(.wake, 0), wake.fd) catch return;
            self.wake_rearm_pending = false;
            self.wake_armed = true;
        }

        /// Retire the caller-owned wake recv without touching its descriptor.
        /// A refused cancel submission mints no completion and is retried on a
        /// bounded poll; an admitted one owns a distinct completion in addition
        /// to the target recv completion.
        fn retryWakeCancel(self: *Self) void {
            if (!self.wake_cancel_submit_pending) return;
            std.debug.assert(self.wake_armed);
            std.debug.assert(!self.wake_cancel_pending);
            const wake = self.wake orelse unreachable;
            self.backend.submitCancel(
                userData(.wake_cancel, 0),
                userData(.wake, 0),
                wake.fd,
            ) catch return;
            self.wake_cancel_submit_pending = false;
            self.wake_cancel_pending = true;
        }

        /// Retry closes the backend could not admit.
        ///
        /// A table walk, and the one left on a repeated path: while any close
        /// is owed the poll bounds its wait at `close_retry_ms`, so this runs
        /// about twenty times a second over every slot. The regime is a backend
        /// that cannot allocate completion capacity, which is transient and
        /// rare, and the alternative is a fourth intrusive list for a state
        /// that is empty on every healthy loop. Named rather than removed.
        ///
        /// `submitClose` is the only thing that retires a connection's pending
        /// ops on a backend whose `shutdownFd` cannot cancel them, so a failed
        /// submit is not a state the loop may sit in. The failure is an
        /// allocation one, so the next batch usually takes it.
        fn retryPendingCloses(self: *Self) void {
            if (self.pending_close_submits == 0) return;
            for (self.conns, 0..) |*c, slot| {
                // `owns_fd_close` is set at exactly one site, the failed
                // submit below, so it doubles as the marker for a close this
                // loop still owes. Clearing it hands the fd back to the close
                // op that just landed.
                if (!c.owns_fd_close) continue;
                self.backend.submitClose(userData(.close, slot), c.fd) catch continue;
                c.owns_fd_close = false;
                c.ops_in_flight += 1;
                self.pending_close_submits -= 1;
            }
        }

        /// Submit the listener cancellation/close when backend capacity admits
        /// it. Unlike a newly accepted descriptor, the listener can have an
        /// accept operation pending; `closeFd` alone is not contracted to retire
        /// that operation. Retain the descriptor and retry instead of letting
        /// `closeAndDrain` return while the backend still owns an accept.
        fn retryListenerClose(self: *Self) void {
            if (self.listener_close_pending) return;
            const fd = self.listener_close_fd orelse return;
            self.backend.submitClose(userData(.close, self.conns.len), fd) catch return;
            self.listener_close_pending = true;
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
            // Not a tolerant decrement: a completion for a live slot always
            // corresponds to an op this loop counted, and both directions of
            // drift are serious. Under-counting strands the slot; over-counting
            // tears it down while the kernel still reads `front`.
            std.debug.assert(c.ops_in_flight > 0);
            c.ops_in_flight -= 1;
            if (c.state == .closing and c.ops_in_flight == 0) {
                if (c.owns_fd_close) self.backend.closeFd(c.fd);
                if (self.teardown(slot)) self.closed_count += 1;
            }
        }

        /// Reclaim a slot, reporting whether it actually happened.
        ///
        /// The return value is what keeps `closed_count` to one writer per
        /// reclaim. A teardown that arrives while the slot is being adopted is
        /// deferred, not performed, and `finishConnected` performs it later —
        /// so a caller that counts unconditionally counts the same connection
        /// twice, once where it asked and once where it happened. That is not
        /// bookkeeping: `closed_count` is what `run(.{ .after_closed = n })`
        /// stops on, so an over-count returns the loop with connections still
        /// open. The counters beside this one (`waiting_count`,
        /// `over_mark_count`) each have exactly one writer; this gives
        /// `closed_count` the same.
        fn teardown(self: *Self, slot: usize) bool {
            const c = &self.conns[slot];
            if (self.adopting_slot) |adopting| {
                if (adopting == slot) {
                    // `finishConnected` reclaims it once the hook returns and
                    // its context has been released.
                    self.adopting_teardown_deferred = true;
                    return false;
                }
            }
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
            const generation = c.generation;
            if (c.owns_fd_close) self.pending_close_submits -= 1;
            c.peer.deinit();
            c.spill.deinit(self.allocator);
            c.front.deinit(self.allocator);
            c.back.deinit(self.allocator);
            self.setWaiting(c, 0);
            // Unconditional, not a recompute: `deinit` tears down slots that
            // are still `.open`, where a recompute would agree they are over
            // the mark and leave the count pointing at a slot about to be
            // wiped.
            if (c.over_mark) {
                c.over_mark = false;
                self.over_mark_count -= 1;
            }
            c.* = .{};
            self.live_count -= 1;
            // The slot is somebody else's now; anyone holding a `*Conn` from
            // before this point can tell by comparing.
            c.generation = generation +% 1;
            self.pushFreeSlot(slot);

            // The connection that just left may have been the last sink over
            // the high-water mark, and the fan-in sources it throttled have no
            // other resume trigger: every terminal path returns before
            // `onSend`'s tail runs (ADR-0082). Without a resume, a closing
            // sink strands its victims parked for the loop's lifetime — they
            // are exempt from the park reaper precisely because they are
            // victims, not slow readers.
            //
            // Recorded, not performed. Resuming here would re-enter the loop
            // from inside a teardown: `resumeFanInSources` arms reads, an arm
            // failure closes, and a close whose submit fails tears down again,
            // one stack frame per slot. It would also make a mass close
            // quadratic, since every teardown would sweep the whole table.
            // The loop body drains this once per poll batch instead.
            if (self.fan_in_throttle) self.fan_in_dirty = true;
            return true;
        }

        /// The deadline accounting, reachable from `test/net` and nowhere else.
        ///
        /// `refreshWaiting` mutates `waiting_count`, `over_mark_count`, and the
        /// nearest-deadline cache. Plain `pub` would put that on the public
        /// surface of a public type, where an embedder calling it would be
        /// writing the three counters `deinit` asserts on, with no way to know
        /// it.
        ///
        /// The namespace is empty outside a test build, so it is not a naming
        /// convention asking to be respected — production code cannot reach
        /// these at all. The tests stay in `test/net`, where the tests rule
        /// places every test, so the seam comes to them.
        pub const white_box = if (@import("builtin").is_test) struct {
            pub fn refreshWaiting(self: *Self, c: *Conn) void {
                self.refreshWaiting(c);
            }
            pub fn pendingDeadline(self: *const Self, c: *const Conn) ?Deadline {
                return self.pendingDeadline(c);
            }
            pub fn nextDeadlineMs(self: *Self) ?i32 {
                return self.nextDeadlineMs();
            }
        } else struct {};

        fn freeSlot(self: *Self, admission: DialAdmission) ?usize {
            const head = switch (admission) {
                .ordinary => &self.ordinary_free_head,
                .reserved => &self.reserved_free_head,
            };
            if (head.* >= self.conns.len) return null;
            const slot = head.*;
            // Push/pop at the head only, so the free list needs no `prev_link`.
            head.* = self.conns[slot].next_link;
            return slot;
        }

        fn pushFreeSlot(self: *Self, slot: usize) void {
            std.debug.assert(self.conns[slot].state == .free);
            const head = if (slot < self.ordinary_capacity)
                &self.ordinary_free_head
            else
                &self.reserved_free_head;
            self.conns[slot].next_link = @intCast(head.*);
            head.* = slot;
        }
    };
}
