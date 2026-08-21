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
const engine = @import("engine");

const crypto = foundation.crypto;

pub const Error = error{
    /// The driver could not allocate ownership state for the requested
    /// operation.
    OutOfMemory,
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
    /// The OS entropy source could not fill a durable swiss mint (ADR-0098).
    MintEntropyFailed,
    /// A keyed handshake made no progress within its caller-set budget: the
    /// partner accepted the socket but never spoke. The blocking
    /// `BlockingSession` handshake breaks with this reason when its bounded
    /// `handshake` budget elapses, instead of parking the fiber for the
    /// connection's life; a host-owned redeem dial reserves it for the same
    /// silent-exporter case (ADR-0081).
    HandshakeTimedOut,
    /// A Runtime or Host finish-close exhausted its explicit grace budget.
    /// Teardown still escalates to cancel and reaches the closed barrier
    /// before this outcome is reported.
    CloseTimedOut,
    /// A blocking answer-wait (`settle` / `call` / `fetch`) made no progress
    /// within its caller-set budget: the partner opened a session then stalled
    /// without settling the vow. Bounded via `BlockingSession.settle`. Sibling
    /// of `HandshakeTimedOut` for post-handshake waits (ADR-0076 follow-up).
    WaitTimedOut,
    /// A locator named a transport no registered netlayer hosts.
    UnknownTransport,
    /// Two providers registered the same transport symbol with different
    /// designator semantics. A Host admits one meaning per symbol for its
    /// lifetime; composition is refused before either provider can open a
    /// session under an ambiguous locator.
    TransportSemanticsConflict,
    /// A second provider attempted to own a transport symbol already present
    /// in this Host's dispatch table.
    TransportAlreadyRegistered,
    /// A provider supplied an empty transport symbol.
    InvalidTransportName,
    /// `Session.adopt` was asked to combine a `HostRuntime` with a session
    /// minted by another runtime's core Host. Adoption transfers one existing
    /// runtime/session relationship; it cannot establish a foreign one.
    SessionNotOwned,
    /// A runtime wire has already been transferred into an owning `Session`
    /// handle. A second adoption would create duplicate release authority.
    SessionAlreadyOwned,
    /// `HostRuntime.Options` supplied a zero frame admission cap or wire
    /// buffer size, or no capacity for pending session opens. Every bound must
    /// be positive.
    InvalidBufferConfiguration,
    /// This host already has `Options.max_pending_opens` transport connects or
    /// CapTP handshakes in flight. Let one settle before admitting another.
    PendingOpenLimitReached,
    /// A listener for this canonical transport profile is pending or active.
    /// Close or cancel that listener before starting another on the profile.
    ListenerProfileInUse,
    /// An owning Host or Runtime has sealed its terminal close barrier and no
    /// longer admits application operations or transport opens.
    HostClosing,
    /// This session has sealed its terminal close barrier. Protocol ingress
    /// remains live while admitted work finishes, but no new application
    /// operation may target it.
    SessionClosing,
    /// A Server method that requires its listener or owning runtime was called
    /// after `Server.close`. Close itself is idempotent; every other operation
    /// refuses before touching the released runtime lease.
    ServerClosed,
    /// The owning host face was asked to bind a session over a transport that
    /// reports no pollable fd (inproc by design, a userspace stream). A
    /// blocking multiplex cannot wait on a stream with no readiness signal;
    /// the transport must supply a multiplexed resident or use another driver
    /// whose readiness contract it can satisfy.
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
    /// This face was wired to advertise a durable key it cannot sign for
    /// (ADR-0105): an `Identity.keyed` whose `designator` names some other
    /// peer's key, or a keyed listener bound under a key that is not the one
    /// the host was built on. The mismatch is refused where it was wired
    /// rather than on the first accept. Same name and meaning as
    /// `driver_core.HostError.UnheldIdentity`, which the byte-fed tier raises
    /// for the same condition.
    UnheldIdentity,
    /// A sealed-channel locator (`noise-*`, ADR-0107) reached the borrowing
    /// blocking tier. The core Host runs the sealed channel, and
    /// `BlockingSession` does not stand on one, so nothing here would seal
    /// the wire; the open is refused rather than speaking cleartext CapTP
    /// under a sealed name. Dial these through `driver.connect` /
    /// `driver.listen` or any core-Host embedding.
    SealedChannelRequiresHost,
};

/// The ordinary finite budget for a CapTP handshake after a byte channel opens.
/// Public surfaces may expose it as a default, while `SessionOptions` still
/// requires callers to spell their wait policy.
pub const default_handshake_timeout_ms: i32 = 10_000;
pub const default_handshake_budget: Budget = .{ .ms = default_handshake_timeout_ms };

/// Shared discovery-posture dial defaults (pkarr / n0 DNS propagation).
/// Attempts include the first dial; sleeps happen only between transient
/// failures. `driver.DialRetry` owns the retry executor above CapTP.
pub const discovery_retry_ms: u64 = 3_000;
pub const discovery_max_attempts: u32 = 24;

/// Bound on one synchronous local `Forward` chase in a Host turn or binding
/// trampoline. The wire path defers each hop onto a fresh turn; local proxy
/// composition needs a finite loop guard.
pub const max_local_forward_hops: usize = 256;

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
/// `unbounded` stays available explicitly because an in-process pair and a
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

/// What a transport's locator designator means. The model vocabulary owns the
/// type and exhaustive metadata; runtime residents derive their declarations
/// from it.
pub const DesignatorScheme = model.transport.DesignatorScheme;

/// Which hints a locator carries is the netlayer's own business, so there is
/// deliberately no table here saying who publishes dial addresses. The netlayer
/// answers that by materializing its complete listener locator. On the byte-fed
/// path the embedder owns the transport and answers the same question.
/// `dial_plan.planAccept` passes that answer through rather than second-guessing
/// it; a table here would be a second authority for one fact, free to drift from
/// the vtable that produces the value.
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

/// The durable-locator posture a driver half advertises in its keyed
/// `op:start-session`. The session signing key is always drawn separately per
/// connection. Every transport-neutral dial (`connectVia`) and accept
/// (`acceptVia`) carries this posture explicitly: an ephemeral dialer has no
/// stable designator of its own, while a keyed peer names the durable
/// designator its endpoint is reachable as.
pub const Identity = union(enum) {
    /// Draw a fresh random session key at the I/O boundary for this one
    /// session. The ordinary client posture: a dialer that does not itself
    /// listen signs the unreachable-client placeholder as its own designator.
    /// On accept, the listener's bound designator is still signed — a host is
    /// always reachable.
    ephemeral,
    /// Hold `secret` as this caller's *durable* identity and advertise
    /// `designator` as its own dialable designator. `secret` is the secret half
    /// of the key the netlayer endpoint is built on, so it is what a partner
    /// re-dials across a restart. The key each session *signs its hello with*
    /// is drawn per connection and is a different value.
    ///
    /// `designator` is the caller's own address on a transport that names
    /// peers by address. On a key-scheme transport there is one legal value,
    /// `secret`'s own public key: naming any other is `Error.UnheldIdentity`,
    /// since this endpoint does not hold it.
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

/// The three identity facts learned for a partner: the verified session public
/// key, the location claim signed by that key, and any matching authenticated
/// channel provenance for the claim.
///
/// This is the received counterpart to `Identity`, which describes what this
/// side advertises. A keyed `op:start-session` carries an Ed25519 signature
/// over its `<my-location …>` record. Verification proves control of
/// `session_key` and that this session signer made the locator claim. It does
/// not prove that the signer owns the durable key or address in that locator.
/// Only `provenance` answers whether the realized channel independently
/// authenticated a durable key matching `designator`.
///
/// Every field borrows session-owned bytes. They are written once when the
/// partner's handshake half arrives and are never rewritten, so they stay valid
/// until the session is released.
pub const PartnerIdentity = struct {
    /// The partner's verified session public key. Never empty: a session cannot
    /// open under verification without one.
    session_key: []const u8,
    /// The designator the verified session signer claimed and signed, or empty
    /// when its signed location carried none. This is not durable-identity
    /// authentication by itself.
    designator: []const u8,
    /// The verbatim `<ocapn-peer …>` location record, or empty when the apply
    /// path captured no raw bytes.
    locator_record: []const u8,

    /// How the durable identity in `designator` was authenticated, if at all
    /// (ADR-0097). Session identity, durable identity, and this provenance are
    /// three separate facts; a caller that needs an authenticated durable peer
    /// asks `durableIdentityAuthenticated`, never key equality.
    provenance: DurableProvenance = .unauthenticated,

    /// Whether the durable identity this partner advertised was
    /// cryptographically authenticated by the realized channel. This is the
    /// predicate an API that requires a proved durable peer asks. It stays
    /// independent of whether the claimed designator happens to equal the
    /// session key.
    pub fn durableIdentityAuthenticated(self: PartnerIdentity) bool {
        return self.provenance != .unauthenticated;
    }

    /// Whether `designator` is literally this partner's session key, in the
    /// canonical hex encoding used by a key designator.
    ///
    /// **A diagnostic, not an authentication predicate** (ADR-0097). Fresh
    /// sessions normally use a key distinct from the durable key a locator
    /// names, so this normally answers false even for an authenticated partner.
    /// Ask `durableIdentityAuthenticated` when durable authentication matters.
    ///
    /// An `address` transport such as `tcp` designates a socket address, which
    /// the handshake signature covers but which the key does not determine, so
    /// this is false for a verified `tcp` partner and false is the correct
    /// answer rather than a failure.
    pub fn designatorIsSessionKey(self: PartnerIdentity) bool {
        const key = crypto.PeerKey.fromSlice(self.session_key) catch return false;
        const expected = key.toDesignator();
        return std.mem.eql(u8, self.designator, &expected);
    }
};

/// How a partner's advertised durable identity was authenticated (ADR-0105),
/// the third fact `PartnerIdentity` reports beside session key and designator.
/// It answers "what proved this name", never "who is this" — an unauthenticated
/// partner still has a session key and may still have signed a location.
///
/// `engine.DurableProvenance` is the one definition and
/// `engine.Peer.partnerDurableProvenance` the one derivation, because the
/// verdict is reached at the pre-open chokepoint from the evidence one session
/// holds. This alias is how the byte-fed tier and the C ABI name it without
/// reaching into the engine.
pub const DurableProvenance = engine.DurableProvenance;

/// The responder's durable-locator posture for `listen` / `acceptVia`. An
/// accepting host advertises its listener's bound designator, so unlike the
/// dialer's `Identity` there is no designator to carry. `ephemeral` supplies no
/// durable key. `keyed` supplies the caller-held endpoint key from which a
/// key-scheme listener derives its stable designator. Both draw a separate
/// signing key per accepted session.
pub const AcceptIdentity = union(enum) {
    ephemeral,
    keyed: crypto.SecretKey,
};

/// The borrowing tier's handle to an eventual result: `actors.Vow`,
/// re-exported so a consumer holding only the driver vocabulary can name it
/// without reaching into the actor layer. `BlockingSession.settleVow` drives
/// it to a `Settled`; the owning tier returns a Host-accounted `driver.Promise`.
pub const Vow = actors.Vow;

/// A local actor bound to an export position, the borrowing tier's form
/// of "capability I host": `ref` is the vat-local reference, so the
/// application can near-call or `send` to the actor it just published or
/// spawned without redoing vat bookkeeping, and `nearRef()` returns the
/// explicit wire reference the export position marshals to. This type lives
/// on the serve core and the borrowing `BlockingSession` tier, where the
/// caller owns the peer and wire positions are the caller's own vocabulary.
/// The owning host tier speaks the opaque Host-scoped `Capability` instead
/// (ADR-0096) and never surfaces these fields.
pub const Exported = struct {
    /// The export position the session allocated for this actor.
    position: u64,
    /// The vat-local reference to the same actor, for local sends and calls.
    ref: actors.Ref,

    /// The explicit wire reference this capability marshals to: a near object
    /// at `position`.
    pub fn nearRef(self: Exported) model.Reference {
        return .{ .near = model.NearRef.object(self.position) };
    }

    /// The capability as a ready-to-send argument, so handing a partner a
    /// callback reads `.args = &.{ cap.arg() }`. This is `nearRef` wrapped in
    /// the `.reference` argument arm.
    pub fn arg(self: Exported) model.Argument {
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
pub fn spawnAt(turn: *actors.Turn, comptime Behavior: type, initial: Behavior) !Exported {
    const port = turn.port orelse return actors.Error.NotConnected;
    const position = try port.peer.exportNextObject();
    errdefer port.peer.session_state.releaseUnsharedExport(.from(position));
    const ref = try turn.vat.spawn(Behavior, initial);
    errdefer turn.vat.discardFreshActor(ref);
    try port.bindExport(turn.vat, ref, position);
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
/// `fetchSettled` on `BlockingSession`, and `call` / `fetchSettled` /
/// `Promise.settle` on `Session`. Lives on
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
    /// Position-only capability shapes that remain valid after the listener's
    /// borrowed settlement returns. A byte-fed peer yields `.far`; a Host fetch
    /// enrolls the same import into Node identity first and yields `.routed`.
    pub const Capability = union(enum) {
        far: model.FarRef,
        routed: model.RoutedRef,

        pub fn reference(self: Capability) model.Reference {
            return switch (self) {
                .far => |far| .{ .far = far },
                .routed => |routed| .{ .routed = routed },
            };
        }
    };

    outcome: ?union(enum) { capability: Capability, broken, not_a_capability } = null,

    pub fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *FetchCapture = @ptrCast(@alignCast(ctx.?));
        self.outcome = switch (resolution) {
            .fulfilled => |arg| switch (arg) {
                .reference => |reference| switch (reference) {
                    .far => |far| .{ .capability = .{ .far = far } },
                    .routed => |routed| .{ .capability = .{ .routed = routed } },
                    else => .not_a_capability,
                },
                else => .not_a_capability,
            },
            .give => .not_a_capability,
            .broken => .broken,
        };
    }
};
