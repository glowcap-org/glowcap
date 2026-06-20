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
//! The driver reaches a transport two ways. `connectTcp` and `acceptTcp` are
//! the tcp-named conveniences that pick tcp explicitly. `connectVia` and
//! `acceptVia` take a `[]const net.netlayer.Netlayer` and dispatch on the
//! locator's transport symbol at runtime. A transport the driver never names can
//! dial and host through the same code once its netlayer is in the slice. There is no
//! `TcpVat`, and `ConnectedVat` itself is transport-neutral: a caller that already
//! holds a `net.Connection` over any stream uses `ConnectedVat.over`
//! directly.
//!
//! This file is the driver root: the vocabulary every driver embedding shares
//! (`Error`, `Identity`, `Capability`, `Settled`, `ServeOptions`) and the verbs
//! the surfaces ride once, `publishNamed`, `spawnAt`, `sendBootstrapFetch`, and
//! the `drawSessionSecret` entropy boundary. The surfaces themselves live in
//! sibling files and are re-exported here, so every driver surface is reached
//! through this one root: the borrowing, caller-pumped `ConnectedVat` and its
//! transport constructors in `connected_vat.zig`; the owning, one-call
//! `Connection`/`Server` host and client in `connection.zig`; and the
//! completion-loop fan-out drivers `LoopHost` and `LoopDialer` in `loop.zig`.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

pub const crossed_hellos = @import("crossed_hellos.zig");
pub const gc = @import("gc.zig");

const loop = @import("loop.zig");
/// The completion-loop hosting fan-out (see `loop.zig`), re-exported so callers
/// keep reaching it as `driver.LoopHost`.
pub const LoopHost = loop.LoopHost;
/// The completion-loop client fan-out (see `loop.zig`), re-exported so callers
/// keep reaching it as `driver.LoopDialer`.
pub const LoopDialer = loop.LoopDialer;

const crypto = foundation.crypto;

pub const Error = error{
    /// A `fetch` ran to a clean connection close before the capability resolved.
    ConnectionClosed,
    /// A `fetch` settled broken: the partner answered the bootstrap fetch with a
    /// break (an unpublished name, a refused handoff). The break reason is
    /// turn-borrowed and not retained here; a caller that needs it uses
    /// `ConnectedVat.fetchSettled`, which returns the reason in caller-owned
    /// memory.
    FetchBroken,
    /// A `fetch` fulfilled with something other than a far capability, so there
    /// is no reference to return.
    FetchNotACapability,
    /// The OS entropy source could not fill the session seed for the handshake.
    HandshakeEntropyFailed,
    /// A shared driver verb (`publishNamed`, `spawnAt`, `sendBootstrapFetch`)
    /// was given a vat with no bound peer; only a peer-bound vat can export or
    /// fetch over the wire.
    NotConnected,
    /// A locator named a transport no registered netlayer hosts.
    UnknownTransport,
    /// `callReference` was given a target that is not an eventual-send target:
    /// a `sturdy`, `broken`, or bare `promise` reference. Only a near (local
    /// export) or far (partner-hosted) object reference is callable.
    UncallableTarget,
};

/// Draw a fresh random session secret from `io` at the I/O boundary, never in the
/// no-I/O core. The raw seed is wiped off the stack after `fromSeed` consumes it,
/// so the ephemeral secret does not linger. The `ConnectedVat` handshake halves
/// and the loop drivers' identity keys (`LoopHost`, `LoopDialer`) use this one
/// entropy boundary.
pub fn drawSessionSecret(io: std.Io) Error!crypto.SecretKey {
    var seed: [crypto.SEED_BYTES]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    io.randomSecure(&seed) catch return Error.HandshakeEntropyFailed;
    return crypto.SecretKey.fromSeed(seed);
}

/// The identity a driver half signs its keyed `op:start-session` with. Every
/// transport-neutral dial (`connectVia`) and accept (`acceptVia`) carries one
/// explicitly — there is no implicit default key. The two arms make the only two
/// postures unrepresentable as each other: an ephemeral dialer has no
/// stable designator to advertise, and a keyed peer always names the designator
/// its key is reachable as.
pub const Identity = union(enum) {
    /// Draw a fresh random session key at the I/O boundary for this one
    /// session. The ordinary client posture: a dialer that does not itself
    /// listen advertises no dialable designator of its own. On accept, the
    /// listener's bound designator is still signed — a host is always reachable.
    ephemeral,
    /// Sign the handshake with a caller-held `secret` and advertise
    /// `designator` as the caller's own dialable designator. Under key
    /// unification `secret` is the secret half of the key the netlayer endpoint
    /// is built on and `designator` is that endpoint's node id, so the partner's
    /// verified session pubkey equals the transport node id equals the signed
    /// designator — one key is transport identity, locator designator, and
    /// session signing key at once.
    keyed: struct { secret: crypto.SecretKey, designator: []const u8 },

    /// The dialable designator a *dialer* advertises for this identity: empty
    /// for an ephemeral client, the keyed designator otherwise. A host's
    /// designator comes from its listener, not from here.
    pub fn dialedDesignator(self: Identity) []const u8 {
        return switch (self) {
            .ephemeral => "",
            .keyed => |k| k.designator,
        };
    }
};

/// A handle to the eventual result of a `Connection.send` / `sendToAnswer` —
/// `actors.Promise`, re-exported so a consumer holding only the driver
/// vocabulary (the C ABI session archive) can name it without reaching into the
/// actor layer. `settlePromise` drives it to a `Settled`.
pub const Promise = actors.Promise;

/// A capability to a local actor this vat hosts. Pass it to a partner as a
/// `send` argument, and use it locally too: `ref` is the vat-local reference,
/// so the application can near-call or `send` to the actor it just published
/// or spawned without redoing vat bookkeeping. `nearRef()` returns the
/// explicit wire reference the export position marshals to, so the Zig
/// surface keeps that conversion visible rather than implicit.
pub const Capability = struct {
    /// The export position the session allocated for this actor.
    position: u64,
    /// The vat-local reference to the same actor, for local sends and calls.
    ref: actors.Ref,

    /// The explicit wire reference this capability marshals to: a near object
    /// at `position`.
    pub fn nearRef(self: Capability) model.Reference {
        return .{ .near = model.NearRef.object(self.position) };
    }

    /// The capability as a ready-to-send argument, so handing a partner a
    /// callback reads `.args = &.{ cap.arg() }`. This is `nearRef` wrapped in
    /// the `.reference` argument arm.
    pub fn arg(self: Capability) model.Argument {
        return .{ .reference = self.nearRef() };
    }
};

/// How a `call` (or `fetchSettled`) settled. Both arms are materialized into
/// the caller-supplied allocator — typically an arena the caller resets — so
/// nothing in the result borrows the turn that settled it. A caller that used
/// a plain allocator instead of an arena frees the result with `deinit`.
pub const Settled = union(enum) {
    fulfilled: model.Argument,
    broken: []const u8,

    /// Free what `call` / `fetchSettled` materialized into `allocator`: the
    /// fulfilled argument's deep clone, or the broken reason's dupe. A caller
    /// that settled into an arena it resets never needs this.
    pub fn deinit(self: Settled, allocator: std.mem.Allocator) void {
        switch (self) {
            .fulfilled => |argument| model.freeArgument(allocator, argument),
            .broken => |reason| allocator.free(reason),
        }
    }
};

/// A hook run before the vat serves each drained event. Return true to claim
/// the event and skip the vat's serve dispatch; a hook error propagates out of
/// `step` / `flush` / `stepReadable`.
pub const BeforeServeHook = *const fn (ctx: ?*anyopaque, cv: *ConnectedVat, event: *engine.Event) anyerror!bool;

/// Adapter options for a live connection. Crossed-hellos and stateless GC are
/// driver policy, not CapTP semantics added below the engine.
pub const ServeOptions = struct {
    crossed_hellos: ?*crossed_hellos.Registry = null,
    /// Emit `op:gc-exports` / `op:gc-answers` after each inbound deliver/resolve
    /// the vat does not retain imports from.
    gc_stateless: bool = false,
    hook_ctx: ?*anyopaque = null,
    before_serve: ?BeforeServeHook = null,
};

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
/// A `Node` connection handle (`engine.ConnId`), re-exported so embedders name an
/// exporter/recipient connection as `driver.ConnId`.
pub const ConnId = engine.ConnId;

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

/// Publish `Behavior` on `vat` (which must be peer-bound) so a partner can
/// `fetch` it by `name` (name first, matching every binding's `publish`). This
/// is the `registerBootstrapCap`, spawn, and publish sequence, factored so the
/// connection-per-thread `ConnectedVat` and the loop host share one
/// definition. Returns the capability at its allocated export position,
/// carrying the vat-local `ref` so the publisher can keep talking to its own
/// actor.
pub fn publishNamed(vat: *actors.Vat, name: []const u8, comptime Behavior: type, initial: Behavior) !Capability {
    const peer = vat.peer orelse return Error.NotConnected;
    const position = try peer.registerBootstrapCap(name);
    const ref = try vat.spawn(Behavior, initial);
    try vat.bindExport(ref, position);
    return .{ .position = position, .ref = ref };
}

/// Spawn `initial` on `vat` (which must be peer-bound) at a fresh export
/// position and return a capability to it. The position comes from the session's
/// one export allocator — the counter that also mints resolver and bootstrap
/// exports — so a spawned actor can never alias a position the session hands out
/// for anything else. The export is live the moment this returns: the partner
/// can invoke the capability whether or not the caller has sent it the
/// reference. An actor that must stay unreachable until granted is spawned with
/// `Vat.spawn`, which mints no export. `ConnectedVat.spawn` and
/// `LoopDialer.Client.spawn` share this one definition, the same way
/// `publishNamed` is shared.
pub fn spawnAt(vat: *actors.Vat, comptime Behavior: type, initial: Behavior) !Capability {
    const peer = vat.peer orelse return Error.NotConnected;
    const position = try peer.exportNextObject();
    const ref = try vat.spawn(Behavior, initial);
    try vat.bindExport(ref, position);
    return .{ .position = position, .ref = ref };
}

/// Enqueue the bootstrap `fetch` for `name` on `vat` (which must be peer-bound)
/// and return the promise of the partner's answer: import the well-known
/// bootstrap export, then eventual-send `fetch(name)` to it. This is the one
/// definition of the bootstrap-fetch deliver shape. `ConnectedVat.fetch`
/// drives the returned promise to settlement; `LoopDialer.Client.fetch` hands
/// it to the completion loop.
pub fn sendBootstrapFetch(vat: *actors.Vat, name: []const u8) !actors.Promise {
    const peer = vat.peer orelse return Error.NotConnected;
    try peer.importObject(engine.BOOTSTRAP_POSITION);
    return vat.send(
        .{ .far = model.FarRef.object(engine.BOOTSTRAP_POSITION) },
        .{ .verb = "fetch", .args = &.{.{ .bytes = name }} },
    );
}
