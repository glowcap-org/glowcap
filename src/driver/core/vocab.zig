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
const actors = @import("actors");

const crypto = foundation.crypto;

pub const Error = error{
    /// A `fetch` ran to a clean connection close before the capability resolved.
    ConnectionClosed,
    /// A `fetch` settled broken: the partner answered the bootstrap fetch with a
    /// break (an unpublished name, a refused handoff). The break reason is
    /// turn-borrowed and not retained here; a caller that needs it uses
    /// `BlockingSession.fetchSettled`, which returns the reason in caller-owned
    /// memory.
    FetchBroken,
    /// A `fetch` fulfilled with something other than a far capability, so there
    /// is no reference to return.
    FetchNotACapability,
    /// A bound listener could not report a dialable designator: the caller's
    /// buffer was too small, or the transport faulted. It is an error rather
    /// than an empty slice because an empty designator that reaches a signed
    /// locator publishes an address nobody can dial, and the accept path that
    /// consumes it refuses that condition loudly one layer down.
    DesignatorUnavailable,
    /// The OS entropy source could not fill the session seed for the handshake.
    HandshakeEntropyFailed,
    /// A keyed handshake made no progress within its caller-set budget: the
    /// partner accepted the socket but never spoke. The blocking
    /// `BlockingSession` handshake breaks with this reason when its bounded
    /// `handshake` budget elapses, instead of parking the fiber for the
    /// connection's life; a host-owned redeem dial reserves it for the same
    /// silent-exporter case (ADR-0081).
    HandshakeTimedOut,
    /// A blocking answer-wait (`settle` / `call` / `fetch`) made no progress
    /// within its caller-set budget: the partner opened a session then stalled
    /// without settling the vow. Bounded via `BlockingSession.settle`. Sibling
    /// of `HandshakeTimedOut` for post-handshake waits (ADR-0076 follow-up).
    WaitTimedOut,
    /// A locator named a transport no registered netlayer hosts.
    UnknownTransport,
    /// `Server.close` was called while accepted views still hold sessions of
    /// the host it would free. Release every `*Session` from `accept` first.
    SessionsStillOpen,
    /// The owning host face was asked to bind a session over a transport that
    /// reports no pollable fd (inproc by design, a userspace stream). A
    /// blocking multiplex cannot wait on a stream with no readiness signal;
    /// the completion loop is the tier that serves those transports.
    TransportNotPollable,
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

/// How long a CapTP wait may take. It lives here beside `HandshakeTimedOut`
/// and `WaitTimedOut`, the two ways a bounded budget ends; the blocking
/// driver holds the fields, and the byte-fed host tier has no blocking wait
/// to bound.
///
/// The owning `SessionOptions` gives it no default, and that is the point of
/// the type there: every other option has a wrong value that costs memory or
/// speed, but a wait budget has a wrong value that costs the process. A
/// partner can complete the socket connect and then say nothing at all, and
/// an unbounded wait parks the caller on it forever, so the owning tier asks
/// the question where it cannot be skipped.
///
/// `unbounded` stays available, spelled out, because an in-process pair and a
/// harness that drives both ends genuinely want it. A `.ms` of zero or less
/// is a budget that has already expired: a wait under it times out
/// immediately, in every build mode, rather than inheriting the OS poll
/// convention that reads zero or a negative as forever.
pub const Budget = union(enum) {
    /// Wait as long as it takes. Right when you control both ends; a hang
    /// against anything that can go silent.
    unbounded,
    /// Give up after this many milliseconds. Zero or less has already
    /// expired: the wait times out at once instead of reading zero as
    /// forever.
    ms: i32,
};

/// What a transport's locator designator is, the byte-fed mirror of
/// `net.netlayer.DesignatorScheme`: `address` means the designator is where to
/// dial; `key` means it is the peer's Ed25519 public key in canonical hex, so
/// a dial pins the partner's session identity to it. Two spellings exist
/// because `driver_core` is sans-io and holds transport *strings*, never
/// netlayers: where a transport has a netlayer resident, that vtable's
/// `designator_scheme` is the authoritative declaration on every I/O path
/// (`driver.connectVia` reads it) and this string table mirrors it, so a
/// transport added to one is added to the other — `zig build meta-check` holds
/// the mirror in sync. A resident-less key transport has no vtable to mirror
/// (`keyed-relay`, whose byte path is a browser WebSocket rendezvous rather
/// than a Zig netlayer, ADR-0088): for it this byte-fed string table is the
/// sole authority.
pub const DesignatorScheme = enum { address, key };

/// The designator scheme for a transport symbol (see `DesignatorScheme`).
/// `keyed-tcp` and `iroh` both use a key designator: the dialed locator's
/// designator *is* the partner's Ed25519 public key in canonical hex, and the
/// byte-fed host pins the handshake to it (`Host.openDialedLocator` then
/// `expectPartnerKey`). Binding-hosted iroh servers mint one seed for the
/// endpoint and the `Node` so designator, session key, and netlayer identity
/// stay one value (ADR-0075).
pub fn designatorSchemeForTransport(transport: []const u8) DesignatorScheme {
    if (std.mem.eql(u8, transport, model.transport.keyed_tcp)) return .key;
    if (std.mem.eql(u8, transport, model.transport.iroh)) return .key;
    // `webrtc` names a peer by its Ed25519 key; the channel comes up through a
    // signaling exchange rather than a dialable address (ADR-0089), and the keyed
    // handshake pins the designator exactly as keyed-tcp/iroh do.
    if (std.mem.eql(u8, transport, model.transport.webrtc)) return .key;
    // `keyed-relay` names a peer by key alone with no dialable address — its byte
    // path is a relay rendezvous, not a socket (ADR-0088). The keyed handshake
    // pins the designator exactly as keyed-tcp/iroh do.
    if (std.mem.eql(u8, transport, model.transport.keyed_relay)) return .key;
    return .address;
}

/// `keyed-tcp` requires a non-empty direct-addresses hint on accept; other
/// key-designator transports (iroh) may omit it (discovery can resolve by
/// node id alone). Kept next to `designatorSchemeForTransport` so sans-io
/// transport-string policy lives in one table.
pub fn requiresDirectAddressesHint(transport: []const u8) bool {
    return std.mem.eql(u8, transport, model.transport.keyed_tcp);
}

/// The locator hint entry name that carries dial addresses when the
/// designator is a key (`keyed-tcp`, `iroh`). Same literal as
/// `model.transport.hint_direct_addresses` / `net.netlayer.hint_direct_addresses`.
pub const hint_direct_addresses = model.transport.hint_direct_addresses;

/// The `tcp` designator a dialer that does not itself listen signs as its own
/// dialable address: a placeholder no partner can reach. A dialer advertises
/// this because the keyed session's identity is its signing key, not its
/// address, so a partner verifies the signature over these bytes rather than
/// dialing them back. Every never-listening dialer signs the one value —
/// `Identity.ephemeral` and a `Host` that never binds a listener — so the
/// placeholder never drifts between them.
pub const unreachable_client_designator = "127.0.0.1:0";

/// The identity a driver half signs its keyed `op:start-session` with. Every
/// transport-neutral dial (`connectVia`) and accept (`acceptVia`) carries one
/// explicitly — there is no implicit default key. The two arms make the only two
/// postures unrepresentable as each other: an ephemeral dialer has no
/// stable designator of its own (it signs the unreachable-client placeholder),
/// and a keyed peer always names the designator its key is reachable as.
pub const Identity = union(enum) {
    /// Draw a fresh random session key at the I/O boundary for this one
    /// session. The ordinary client posture: a dialer that does not itself
    /// listen signs the unreachable-client placeholder as its own designator.
    /// On accept, the listener's bound designator is still signed — a host is
    /// always reachable.
    ephemeral,
    /// Sign the handshake with a caller-held `secret` and advertise
    /// `designator` as the caller's own dialable designator. Under key
    /// unification `secret` is the secret half of the key the netlayer endpoint
    /// is built on and `designator` is that endpoint's node id, so the partner's
    /// verified session pubkey equals the transport node id equals the signed
    /// designator — one key is transport identity, locator designator, and
    /// session signing key at once.
    keyed: struct { secret: crypto.SecretKey, designator: []const u8 },

    /// The dialable designator a *dialer* advertises for this identity: the
    /// unreachable-client placeholder for an ephemeral client (same bytes
    /// `Host` and tcp-named constructors sign), the keyed designator otherwise.
    /// A host's designator comes from its listener, not from here.
    pub fn dialedDesignator(self: Identity) []const u8 {
        return switch (self) {
            .ephemeral => unreachable_client_designator,
            .keyed => |k| k.designator,
        };
    }
};

/// The partner identity a session's handshake proved: the partner's session
/// public key, the location designator it signed, and the verbatim
/// `<ocapn-peer …>` record those came from.
///
/// This is the counterpart to `Identity`, which is what *this* side signs. It
/// answers "who am I talking to" without taking the partner's word for it. A
/// keyed `op:start-session` carries an Ed25519 signature over the partner's own
/// `<my-location …>` record, and the engine verifies that signature before the
/// session opens and before any of these bytes are learned. The signed span
/// covers the whole location record, so `designator` is bound to `session_key`
/// by the same signature.
///
/// That binding is the point. An application can require that a locator a
/// caller *claims* names the key the caller actually proved, and refuse the
/// mismatch, which is what `designatorIsSessionKey` answers.
///
/// Every field borrows session-owned bytes. They are written once when the
/// partner's handshake half arrives and are never rewritten, so they stay valid
/// until the session is released.
pub const PartnerIdentity = struct {
    /// The partner's verified session public key. Never empty: a session cannot
    /// open under verification without one.
    session_key: []const u8,
    /// The designator the partner signed, or empty when its signed location
    /// carried none.
    designator: []const u8,
    /// The verbatim `<ocapn-peer …>` location record, or empty when the apply
    /// path captured no raw bytes.
    locator_record: []const u8,

    /// Whether `designator` is exactly this partner's proved session key, in the
    /// canonical hex a key designator is spelled in.
    ///
    /// This only means anything for a transport whose designator *is* a key, the
    /// `DesignatorScheme.key` set that `designatorSchemeForTransport` names. For
    /// those, a true answer says the partner proved it owns the name it is
    /// advertising. An `address` transport such as `tcp` designates a socket
    /// address, which the handshake signature covers but which the key does not
    /// determine, so this is false for a verified `tcp` partner and false is the
    /// correct answer rather than a failure.
    ///
    /// A caller that wants "this locator is the partner's own" therefore checks
    /// the transport's scheme first, and treats an address transport as a
    /// question this cannot answer.
    pub fn designatorIsSessionKey(self: PartnerIdentity) bool {
        const key = crypto.PeerKey.fromSlice(self.session_key) catch return false;
        const expected = key.toDesignator();
        return std.mem.eql(u8, self.designator, &expected);
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

/// A handle to the eventual result of a `Session.send` / `sendToAnswer` —
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
pub fn spawnAt(turn: *actors.Turn, comptime Behavior: type, initial: Behavior) !Capability {
    const port = turn.port orelse return actors.Error.NotConnected;
    const position = try port.peer.exportNextObject();
    errdefer port.peer.session_state.releaseUnsharedExport(.from(position));
    const ref = try turn.vat.spawn(Behavior, initial);
    errdefer turn.vat.discardFreshActor(ref);
    try port.bindExport(ref, position);
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
    /// `desc:handoff-give` addressed to this session's session key. This
    /// arm surfaces only on the borrowing `BlockingSession` tier, where
    /// "no router" is the caller's explicit choice; every host-backed tier —
    /// the owning face (ADR-0090), the Bridge, the bindings — claims the
    /// give and redeems it itself, so its calls settle with the introduced
    /// capability instead. The payload is materialized into the call's
    /// allocator like any other outcome.
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
/// `fetchSettled` on `BlockingSession` / `Session`. Lives on
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

    /// The one blocking-wait epilogue `BlockingSession` / `Session` share: an
    /// allocation failure
    /// recorded mid-fire surfaces as OOM, an unfired capture means the partner
    /// left before the vow settled.
    pub fn finish(self: *const SettleCapture) !Settled {
        if (self.failed) return error.OutOfMemory;
        return self.settled orelse Error.ConnectionClosed;
    }
};

/// Wraps a blocking caller's listener so its drive loop can see when the vow
/// settles. Lives on the waiting verb's stack for that bounded drive;
/// `BlockingSession` / `Session` wait through it.
pub const SettleFlag = struct {
    inner: actors.Listener,
    done: bool = false,

    pub fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *SettleFlag = @ptrCast(@alignCast(ctx.?));
        self.done = true;
        self.inner.func(self.inner.ctx, resolution);
    }
};

/// What a bootstrap fetch settled to, recorded by `BlockingSession` /
/// `Session` fetch waits. The listener runs during the settling step with a
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
