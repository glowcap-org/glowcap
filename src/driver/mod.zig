//! The native Zig application surface over CapTP sessions and transport I/O.
//!
//! `actors.Vat` is a sync, no-I/O turn loop. `net` is where I/O lives.
//! A networked Zig app normally has to open a socket, bind a vat to the peer, pump
//! the connection, and dispatch each surfaced event into the vat. `BlockingSession`
//! is that composition. It owns no protocol the engine lacks, and it hides no
//! allocation or I/O. Every read and write is one explicit `step`. A host that
//! wants to answer until the partner leaves can call `serve`. Either way, the
//! caller owns the allocator, the buffers, and the peer's lifetime. This layer is
//! above both `actors` and `net`, so it is the one place that may touch
//! `std.Io` and the actor turn loop at the same time. It is not part of the
//! no-I/O core.
//!
//! The sans-io half of the driver — the serve core `Served` (which carries the
//! publish/spawn/fetch verbs), its `ServeOptions`, and the shared vocabulary
//! (`Error`, `Identity`, `Capability`, `Settled`) — lives one layer down in
//! `driver_core`, which `arch-check` bans from touching I/O. This root
//! re-exports them so callers keep reaching them as `driver.Served`,
//! `driver.Error`, and so on, and adds the I/O members that must stay above the
//! ban: the `drawSessionSecret` entropy boundary and the transport surfaces
//! themselves. The surfaces live in sibling files and are re-exported here, so
//! every driver surface is reached through this one root: the borrowing,
//! caller-pumped `BlockingSession` and its transport constructors in
//! `blocking_session.zig`, and the owning, one-call `Session`/`Server` views
//! in `session.zig`. Zig-owned fan-out at scale is the byte-fed
//! `driver.core.Host` under a completion loop: TCP ships as `net.TcpLoop` plus
//! `driver.Bridge` (ADR-0076); iroh ships as `completion.Loop(iroh.Backend, iroh.DialResolver)`
//! plus the same `driver.Bridge` (ADR-0057 + ADR-0076).

const std = @import("std");

const foundation = @import("foundation");
const driver_core = @import("driver_core");

/// The sans-io driver core layer (`driver_core`), re-exported whole so a
/// consumer can reach the byte-fed host core and its vocabulary as
/// `driver.core.Host`, `driver.core.HostAction`, and so on — the layer
/// `driver.Bridge` + `completion.Loop` feed over the wire.
pub const core = driver_core;

/// The off-turn settle mailbox (ADR-0102 stage 4): a worker thread posts a
/// resolver settle from anywhere, and the thread that owns the Host applies
/// it at its next iteration, woken through the mailbox's socketpair. See
/// `settle_mailbox.zig`.
pub const settle_mailbox = @import("settle_mailbox.zig");
pub const SettleMailbox = settle_mailbox.SettleMailbox;

// The sans-io serve core, vocabulary, and shared verbs live in `driver_core`
// (I/O-banned by arch-check); re-exported so callers keep reaching them as
// `driver.Served`, `driver.Error`, `driver.Capability`, and so on.
pub const Served = driver_core.Served;
pub const DriveError = driver_core.DriveError;
pub const ServeOptions = driver_core.ServeOptions;
pub const BeforeServeHook = driver_core.BeforeServeHook;
pub const Error = driver_core.Error;
pub const OperationFailure = @import("operation_failure.zig").OperationFailure;
pub const SettleCapture = driver_core.SettleCapture;
pub const SettleFlag = driver_core.SettleFlag;
/// A cooperative fetch-then-deliver in flight (see
/// `driver_core.Served.PendingSend`).
pub const PendingSend = driver_core.Served.PendingSend;
pub const FetchCapture = driver_core.FetchCapture;
pub const Identity = driver_core.Identity;
pub const AcceptIdentity = driver_core.AcceptIdentity;
pub const Vow = driver_core.Vow;
/// The opaque Host-scoped capability identity the owning tier speaks
/// (ADR-0096); the borrowing tier's export-bound spelling is `Exported`.
pub const Capability = driver_core.Capability;
pub const Exported = driver_core.Exported;
pub const Value = driver_core.Value;
pub const Reply = driver_core.Reply;
pub const Hosting = driver_core.Hosting;
pub const HostTurn = driver_core.HostTurn;
pub const Settled = driver_core.Settled;
pub const unreachable_client_designator = driver_core.unreachable_client_designator;
/// The turn-time spawn-at-export verb (see `driver_core`'s `spawnAt`): a
/// behavior handler holds only `turn.vat`, so this free form exists alongside
/// `Served.spawn` for exactly that caller.
pub const spawnAt = driver_core.spawnAt;

const crypto = foundation.crypto;

/// Draw a fresh random session secret from `io` at the I/O boundary, never in the
/// no-I/O core. The raw seed is wiped off the stack after `fromSeed` consumes it,
/// so the ephemeral secret does not linger. The `BlockingSession` handshake halves
/// and the Bridge embedder's identity key use this one entropy boundary.
pub fn drawSessionSecret(io: std.Io) Error!crypto.SecretKey {
    var seed: [crypto.SEED_BYTES]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    io.randomSecure(&seed) catch return Error.HandshakeEntropyFailed;
    return crypto.SecretKey.fromSeed(seed);
}

const blocking_session = @import("blocking_session.zig");
/// The borrowing, caller-pumped session surface and transport-neutral constructors
/// that bind one (see `blocking_session.zig`).
pub const BlockingSession = blocking_session.BlockingSession;
pub const connectVia = blocking_session.connectVia;
pub const connectUri = blocking_session.connectUri;
pub const acceptVia = blocking_session.acceptVia;

const bridge = @import("bridge.zig");
/// The completion-loop to byte-fed `driver.core.Host` bridge, generic over
/// the loop type (see `bridge.zig`). One completion-loop thread serving a
/// full multi-session CapTP host — cross-session flushes armed through
/// `Loop.armOutbound`, the budgeted drive, and the host's action queue
/// answered at this tier's entropy boundary (ADR-0076). This is the Zig
/// multi-session CapTP *scale* spine; the blocking application tier is the
/// owning face `driver.HostRuntime` (ADR-0090) over that same core. Neither is a
/// second core of its own — that is the type that stays deleted.
pub const Bridge = bridge.Bridge;

const session = @import("session.zig");
/// The owning native runtime (ADR-0090): transport I/O and a blocking,
/// poll-multiplexed pump around one byte-fed Host. `connect`/`listen` build one
/// underneath; an app that wants several sessions under one Host identity
/// builds it explicitly.
const host_runtime = @import("host_runtime.zig");
pub const HostRuntime = host_runtime.HostRuntime;
pub const default_handshake_timeout_ms = driver_core.default_handshake_timeout_ms;
pub const default_handshake_budget = driver_core.default_handshake_budget;
pub const default_wire_buffer_bytes = host_runtime.default_wire_buffer_bytes;
pub const default_listener_setup_ms = host_runtime.default_listener_setup_ms;
pub const default_settle_ms = host_runtime.default_settle_ms;
pub const default_settle_budget: driver_core.Budget = .{ .ms = @intCast(host_runtime.default_settle_ms) };
pub const default_max_pending_opens = host_runtime.default_max_pending_opens;
/// The owning, one-call application session `connect`/`listen` hand back
/// (see `session.zig`), re-exported so callers reach them as
/// `driver.Session`, `driver.connect`, `driver.listen`.
pub const Session = session.Session;
pub const Promise = session.Promise;
pub const Server = session.Server;
pub const SessionOptions = session.SessionOptions;
/// How long a CapTP wait may take. Deliberately has no default in
/// `SessionOptions`: an unbounded wait against a partner that goes silent parks
/// the caller forever, so the choice is spelled rather than inherited.
pub const Budget = driver_core.Budget;
/// What explicit owner close does with work admitted before its barrier.
pub const PendingWork = driver_core.PendingWork;
/// How long finish may wait before it escalates to cancellation.
pub const CloseGrace = driver_core.CloseGrace;
/// The shared close barrier's observable result.
pub const CloseOutcome = driver_core.CloseOutcome;
pub const connect = session.connect;
pub const connectUriOwned = session.connectUriOwned;
pub const listen = session.listen;

const dial_retry = @import("dial_retry.zig");
/// CapTP-honest dial continuity (ADR-0082): DialError classification, discovery
/// budget, and dial-retry. Not a Session facade — rebuild yields a new session.
pub const DialRetry = dial_retry.DialRetry;
pub const DialPolicy = dial_retry.DialPolicy;
pub const DialOutcome = dial_retry.DialOutcome;
pub const OnDialOutcome = dial_retry.OnDialOutcome;
pub const isTransientDialError = dial_retry.isTransient;
pub const discovery_retry_ms = driver_core.discovery_retry_ms;
pub const discovery_max_attempts = driver_core.discovery_max_attempts;
