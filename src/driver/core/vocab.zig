//! The sans-io driver vocabulary: the error set, the signing identities, the
//! capability and settled-outcome types, and the turn-time `spawnAt` verb — the
//! words every driver embedding shares, none of which touch a socket. The
//! publish and fetch verbs live on `Served`, the type whose peer binding they
//! require; `spawnAt` stays free because a behavior handler holds only its
//! `turn.vat`. The I/O entropy boundary (`drawSessionSecret`) and the transport
//! surfaces stay above this in the `driver` layer.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

const crypto = foundation.crypto;

/// Build one negotiating peer for a loop-served connection: apply the frame
/// cap, then sign and queue the keyed `op:start-session` for a `transport`
/// locator naming `designator`. Every loop driver's per-connection peer —
/// tcp host, tcp dialer, iroh host — is this one shape; they differ only in
/// the transport symbol and the designator they sign, so the handshake
/// construction cannot drift between transports. Sans-io: the secret is drawn
/// at the caller's I/O boundary (`drawSessionSecret`).
pub fn makeKeyedPeer(
    allocator: std.mem.Allocator,
    frame_cap: usize,
    verify_partner: bool,
    transport: []const u8,
    designator: []const u8,
    secret: crypto.SecretKey,
) !engine.Peer {
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = verify_partner, .limits = .{ .max_frame_bytes = frame_cap } });
    errdefer peer.deinit();
    try peer.sendKeyedStartSession(.v1_0, .{
        .transport = transport,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    }, secret);
    return peer;
}

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
    /// A host-owned redeem dial's keyed handshake made no progress within its
    /// budget: the exporter accepted the socket but never spoke. The redeem
    /// breaks with this reason instead of wedging the blocking host forever.
    HandshakeTimedOut,
    /// A locator named a transport no registered netlayer hosts.
    UnknownTransport,
    /// `callReference` was given a target that is not an eventual-send target:
    /// a `sturdy`, `broken`, or bare `promise` reference. Only a near (local
    /// export) or far (partner-hosted) object reference is callable.
    UncallableTarget,
    /// The promise is vat-local: pipelining rides a wire answer, and a local
    /// promise has none. Await it and send to the settled value instead.
    NotPipelineable,
    /// An `.ephemeral` accept identity was given to a listener whose
    /// designator scheme is `key` (keyed TCP, iroh): the signed designator
    /// derives from the identity key there, and a throwaway key cannot
    /// produce the durable designator the transport advertises. Accept with
    /// `.{ .keyed = secret }` holding the listener's identity key.
    EphemeralIdentityOnKeyedTransport,
};

/// What a transport's locator designator is, the byte-fed mirror of
/// `net.netlayer.DesignatorScheme`: `address` means the designator is where to
/// dial; `key` means it is the peer's Ed25519 public key in canonical hex, so
/// a dial pins the partner's session identity to it. Two spellings exist
/// because `driver_core` is sans-io and holds transport *strings*, never
/// netlayers: the netlayer vtable's `designator_scheme` is the authoritative
/// declaration on every I/O path (`driver.connectVia` reads it), and this
/// string table is the same fact for the byte-fed host tier
/// (`Host.openDialedLocator`), which never sees a vtable. A transport added to
/// one must be added to the other.
pub const DesignatorScheme = enum { address, key };

/// The designator scheme for a transport symbol (see `DesignatorScheme`).
/// `keyed-tcp` is the one key-designator transport the byte-fed tier pins
/// today. `iroh` is deliberately *not* mapped here yet: its designator is a
/// key, but the binding-hosted iroh servers still sign sessions with a node
/// identity distinct from the endpoint key (the channel authenticates the
/// endpoint), so pinning byte-fed iroh dials waits for the per-binding key
/// unification pass (ADR-0075 § deferrals).
pub fn designatorSchemeForTransport(transport: []const u8) DesignatorScheme {
    if (std.mem.eql(u8, transport, "keyed-tcp")) return .key;
    return .address;
}

/// The `tcp` designator a dialer that does not itself listen signs as its own
/// dialable address: a placeholder no partner can reach. A dialer advertises
/// this because the keyed session's identity is its signing key, not its
/// address, so a partner verifies the signature over these bytes rather than
/// dialing them back. Every never-listening dialer signs the one value —
/// `ConnectedVat.openKeyedSession`, and a `Host` that never binds a
/// listener — so the placeholder never drifts between them.
pub const unreachable_client_designator = "127.0.0.1:0";

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

/// The responder's signing posture for `listen` / `acceptVia`. An accepting
/// host always signs its listener's own bound designator — the address a
/// partner can actually dial — so unlike the dialer's `Identity` there is no
/// designator to carry: `ephemeral` draws a fresh key per accepted session,
/// and `keyed` signs with the caller-held secret (a handoff exporter that must
/// present one stable key across sessions, or key unification where the
/// secret is the netlayer endpoint's own key).
pub const AcceptIdentity = union(enum) {
    ephemeral,
    keyed: crypto.SecretKey,
};

/// A handle to the eventual result of a `Connection.send` / `sendToAnswer` —
/// `actors.Vow`, re-exported so a consumer holding only the driver
/// vocabulary (the C ABI session archive) can name it without reaching into the
/// actor layer. `settleVow` drives it to a `Settled`.
pub const Vow = actors.Vow;

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

/// Spawn `initial` on `vat` at a fresh export position and return a capability
/// to it. This is the turn-time form: a behavior handler holds only its
/// `turn.vat`, so this is how a running actor mints a new capability mid-turn
/// (`Served.spawn` is the same operation for a caller that holds the serve
/// core). The position comes from the session's one export allocator — the
/// counter that also mints resolver and bootstrap exports — so a spawned actor
/// can never alias a position the session hands out for anything else. The
/// position is *reserved* here: the partner can address the capability only
/// once it first marshals onto the wire — typically riding this turn's own
/// reply — or after an explicit grant through `peer.exportObject` (ADR-0074).
/// A peerless vat is refused with the actor layer's own `NotConnected`. An
/// actor that should have no wire position at all is spawned with `Vat.spawn`,
/// which mints no export.
pub fn spawnAt(vat: *actors.Vat, comptime Behavior: type, initial: Behavior) !Capability {
    const peer = vat.peer orelse return actors.Error.NotConnected;
    const position = try peer.exportNextObject();
    const ref = try vat.spawn(Behavior, initial);
    try vat.bindExport(ref, position);
    return .{ .position = position, .ref = ref };
}

/// How a `call` (or `fetchSettled`) settled. Both arms are materialized into
/// the caller-supplied allocator — typically an arena the caller resets — so
/// nothing in the result borrows the turn that settled it. A caller that used
/// a plain allocator instead of an arena frees the result with `deinit`.
pub const Settled = union(enum) {
    fulfilled: model.Argument,
    broken: []const u8,
    /// The answer fulfilled with a three-party introduction: a signed
    /// `desc:handoff-give` addressed to this connection's session key. This
    /// arm surfaces only on the single-connection tier (`ConnectedVat`,
    /// `Connection`); a host tier claims every give and redeems it itself, so
    /// a host call settles with the introduced capability instead. The
    /// payload is materialized into the call's allocator like any other
    /// outcome.
    give: actors.Give,

    /// Free what `call` / `fetchSettled` materialized into `allocator`: the
    /// fulfilled argument's deep clone, the broken reason's dupe, or the
    /// give projection's three byte slices. A caller that settled into an
    /// arena it resets never needs this.
    pub fn deinit(self: Settled, allocator: std.mem.Allocator) void {
        switch (self) {
            .fulfilled => |argument| model.freeArgument(allocator, argument),
            .broken => |reason| allocator.free(reason),
            .give => |give| {
                allocator.free(give.give_bytes);
                allocator.free(give.exporter_locator_uri);
                allocator.free(give.recipient_key);
            },
        }
    }
};

/// Captures a settling resolution into a caller-owned allocator as a
/// `Settled`: the listener behind every blocking `call` / `settleVow` /
/// `fetchSettled` (`ConnectedVat` and the blocking `Host` share it). Lives on
/// the caller's stack for that bounded drive. The listener contract cannot
/// carry an error, so an allocation failure is recorded and surfaced after
/// the drive returns.
pub const SettleCapture = struct {
    arena: std.mem.Allocator,
    settled: ?Settled = null,
    failed: bool = false,

    pub fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *SettleCapture = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .fulfilled => |arg| {
                const owned_arg = model.cloneArgument(self.arena, arg) catch {
                    self.failed = true;
                    return;
                };
                self.settled = .{ .fulfilled = owned_arg };
            },
            .give => |give| {
                // Three dupes into a caller allocator that may be plain (the
                // verb contract allows a non-arena): free the earlier ones if
                // a later dupe fails, so a partial `.give` never leaks. An
                // arena caller sees these frees as no-ops.
                const bytes = self.arena.dupe(u8, give.give_bytes) catch {
                    self.failed = true;
                    return;
                };
                const uri = self.arena.dupe(u8, give.exporter_locator_uri) catch {
                    self.arena.free(bytes);
                    self.failed = true;
                    return;
                };
                const key = self.arena.dupe(u8, give.recipient_key) catch {
                    self.arena.free(uri);
                    self.arena.free(bytes);
                    self.failed = true;
                    return;
                };
                self.settled = .{ .give = .{
                    .give_bytes = bytes,
                    .exporter_locator_uri = uri,
                    .recipient_key = key,
                } };
            },
            .broken => |reason| {
                const owned_reason = self.arena.dupe(u8, reason) catch {
                    self.failed = true;
                    return;
                };
                self.settled = .{ .broken = owned_reason };
            },
        }
    }

    /// The one blocking-wait epilogue both tiers share: an allocation failure
    /// recorded mid-fire surfaces as OOM, an unfired capture means the partner
    /// left before the vow settled.
    pub fn finish(self: *const SettleCapture) !Settled {
        if (self.failed) return error.OutOfMemory;
        return self.settled orelse Error.ConnectionClosed;
    }
};

/// Wraps a blocking caller's listener so its drive loop can see when the vow
/// settles. Lives on the waiting verb's stack for that bounded drive; both
/// blocking tiers (`ConnectedVat` and the blocking `Host`) wait through it.
pub const SettleFlag = struct {
    inner: actors.Listener,
    done: bool = false,

    pub fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *SettleFlag = @ptrCast(@alignCast(ctx.?));
        self.done = true;
        self.inner.func(self.inner.ctx, resolution);
    }
};

/// What a bootstrap fetch settled to, recorded by both blocking tiers'
/// fetch waits. The listener runs during the settling step with a
/// turn-borrowed resolution, so it records only the shape and the POD far
/// ref, never a borrow of the resolution's bytes. The break reason is
/// deliberately not copied; a caller that needs it uses the settled-outcome
/// verbs instead.
pub const FetchCapture = struct {
    outcome: ?union(enum) { capability: model.FarRef, broken, not_a_capability } = null,

    pub fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *FetchCapture = @ptrCast(@alignCast(ctx.?));
        self.outcome = switch (resolution) {
            .fulfilled => |arg| switch (arg) {
                .reference => |reference| switch (reference) {
                    .far => |far| .{ .capability = far },
                    else => .not_a_capability,
                },
                else => .not_a_capability,
            },
            .give => .not_a_capability,
            .broken => .broken,
        };
    }
};
