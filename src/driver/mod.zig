//! A connection-bound vat driver: the application surface for native Zig.
//!
//! `actors.Vat` is a sync, no-I/O turn loop. `net` is where I/O lives.
//! A networked Zig app normally has to open a socket, bind a vat to the peer, pump
//! the connection, and dispatch each surfaced event into the vat. `ConnectedVat`
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
//! caller-pumped `ConnectedVat` and its transport constructors in
//! `connected_vat.zig`, and the owning, one-call `Connection`/`Server` host
//! and client in `connection.zig`. Zig-owned fan-out at scale is the byte-fed
//! `driver.core.Host` under whatever loop feeds it; the iroh netlayer ships
//! one such loop (`iroh.LoopHost`).

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");
const driver_core = @import("driver_core");

/// The sans-io driver core layer (`driver_core`), re-exported whole so a
/// consumer can reach the byte-fed host core and its vocabulary as
/// `driver.core.Host`, `driver.core.HostAction`, and so on — the layer the
/// blocking `Host` below is a socket loop over.
pub const core = driver_core;

// The sans-io serve core, vocabulary, and shared verbs live in `driver_core`
// (I/O-banned by arch-check); re-exported so callers keep reaching them as
// `driver.Served`, `driver.Error`, `driver.Capability`, and so on.
pub const Served = driver_core.Served;
pub const ServeOptions = driver_core.ServeOptions;
pub const BeforeServeHook = driver_core.BeforeServeHook;
pub const makeKeyedPeer = driver_core.makeKeyedPeer;
pub const Error = driver_core.Error;
pub const SettleCapture = driver_core.SettleCapture;
pub const SettleFlag = driver_core.SettleFlag;
pub const FetchCapture = driver_core.FetchCapture;
pub const Identity = driver_core.Identity;
pub const AcceptIdentity = driver_core.AcceptIdentity;
pub const Vow = driver_core.Vow;
pub const Capability = driver_core.Capability;
pub const Settled = driver_core.Settled;
pub const unreachable_client_designator = driver_core.unreachable_client_designator;
/// The turn-time spawn-at-export verb (see `driver_core`'s `spawnAt`): a
/// behavior handler holds only `turn.vat`, so this free form exists alongside
/// `Served.spawn` for exactly that caller.
pub const spawnAt = driver_core.spawnAt;

const crypto = foundation.crypto;

/// Draw a fresh random session secret from `io` at the I/O boundary, never in the
/// no-I/O core. The raw seed is wiped off the stack after `fromSeed` consumes it,
/// so the ephemeral secret does not linger. The `ConnectedVat` handshake halves
/// and the blocking host tier's identity key use this one entropy boundary.
pub fn drawSessionSecret(io: std.Io) Error!crypto.SecretKey {
    var seed: [crypto.SEED_BYTES]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    io.randomSecure(&seed) catch return Error.HandshakeEntropyFailed;
    return crypto.SecretKey.fromSeed(seed);
}

const connected_vat = @import("connected_vat.zig");
/// The borrowing, caller-pumped vat surface and the transport constructors that
/// bind one (see `connected_vat.zig`), re-exported so callers reach them as
/// `driver.ConnectedVat`, `driver.connectVia`, and so on.
pub const ConnectedVat = connected_vat.ConnectedVat;
pub const connectTcp = connected_vat.connectTcp;
pub const acceptTcp = connected_vat.acceptTcp;
pub const connectVia = connected_vat.connectVia;
pub const connectUri = connected_vat.connectUri;
pub const acceptVia = connected_vat.acceptVia;

/// The sans-io cross-connection handoff router (`engine.Node`, ADR-0066),
/// re-exported so a native driver embedder reaches it as `driver.Node`. It lives
/// in the engine core because it is pure routing data; this is the ergonomic
/// alias next to the other driver surfaces. It owns the per-connection peers, the
/// shared gift registry, and the redeemed-token / foreign-home routing tables
/// that make three-party handoff transparent; the vat stays above it.
pub const Node = engine.Node;
/// The native multi-connection tier: the blocking I/O binding over the
/// sans-io host core (`driver.core.Host`, ADR-0072). The decisions — routing,
/// give origination, auto-redeem, crossed-hellos — live in the core; this
/// tier owns the sockets, the blocking pumps, and the entropy boundary, and
/// answers the core's action queue the way every language binding does.
const host = @import("host.zig");
pub const BlockingHost = host.BlockingHost;
/// A `Node` connection handle (`engine.ConnId`), re-exported so embedders name an
/// exporter/recipient connection as `driver.ConnId`.
pub const ConnId = engine.ConnId;

const loop_bridge = @import("loop_bridge.zig");
/// The `net.Loop` → byte-fed `driver.core.Host` bridge (see
/// `loop_bridge.zig`): one completion-loop thread serving a full
/// multi-connection node — cross-connection flushes armed through
/// `Loop.armOutbound`, the budgeted drive, and the host's action queue
/// answered at this tier's entropy boundary (ADR-0076).
pub const LoopBridge = loop_bridge.LoopBridge;

const connection = @import("connection.zig");
/// The owning, one-call application connection `connect`/`listen` hand back
/// (see `connection.zig`), re-exported so callers reach them as
/// `driver.Connection`, `driver.connect`, `driver.listen`.
pub const Connection = connection.Connection;
pub const Server = connection.Server;
pub const ConnectionOptions = connection.ConnectionOptions;
pub const connect = connection.connect;
pub const connectUriOwned = connection.connectUriOwned;
pub const listen = connection.listen;
