//! Completion-loop configuration and embedder callback vocabulary.
//!
//! This module owns policy and callback shapes only. Runtime state remains
//! inline in \`Loop\`, and the supported completion namespace aliases these
//! declarations without exporting this internal leaf.

const std = @import("std");
const engine = @import("engine");
const contract = @import("../contract.zig");
const tcp_keepalive = @import("../tcp_keepalive.zig");

const CloseReport = contract.CloseReport;

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
/// `make_conn_ctx` ran), and a `CloseReport` captured before peer teardown.
/// `report.opened` distinguishes a completed connect/accept from a refusal;
/// `report.failure` carries a recorded typed cause. This is the loop's only
/// failure surface for a dialed connection,
/// `dial` returns before the connect completes, so a refused dial is
/// observable nowhere else.
///
/// `slot` is the connection's loop index: refused dials tear down before
/// `make_conn_ctx` runs (`conn_ctx` is null), so an embedder correlating an
/// in-flight dial to a ticket needs the slot — `conn_ctx` alone cannot name
/// it (ADR-0076 loop-side dial executor). `report.reason` names which of the
/// loop's reclaims fired, or `.ordinary` for everything else.
pub const OnClose = *const fn (ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, report: CloseReport) void;

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
    /// one slot and fires `on_close` with its report, leaving the rest of the
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
    /// Opt-in TCP keepalive. When set, all of idle/interval/count must apply
    /// before an accepted or dialed connection is served. TCP-backed adapters
    /// configure their physical socket; a transport without TCP keepalive
    /// semantics refuses and closes that connection with a typed report. Null
    /// — the default — leaves sockets without keepalive (NODELAY only). Do not "just enable"
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
