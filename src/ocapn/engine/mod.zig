//! The `Peer` you hold, and the loop that drives it. Synchronous, no I/O.
//!
//! We call this the engine, not the runtime, and that difference is the whole
//! point. pancake has no runtime in the usual sense: no scheduler, no background
//! tasks, no ambient executor driving things behind your back. The engine is the
//! explicit, synchronous alternative, you feed it frames, you call `step`, you
//! drain and poll. When the project's values say "no hidden runtime", this layer
//! is what they mean stays absent.
//!
//! A `Peer` is the engine object an adapter hangs onto. It owns a `Session`,
//! keeps one queue of inbound frames and one of outbound messages, and surfaces
//! events for your application to handle. It does no I/O and runs no scheduler of
//! its own. You drive it: feed it frames with `feedInbound` or `recvBorrowed`,
//! call `step` to turn queued work into wire bytes, drain `outbound`, and poll for
//! events. Everything that touches the outside world lives above this layer.

const std = @import("std");

const codec = @import("codec");
const foundation = @import("foundation");
const model = @import("model");
const session = @import("session");

pub const abort_projection = @import("abort_projection.zig");
pub const bootstrap = @import("bootstrap.zig");
pub const cross_peer = @import("cross_peer.zig");
pub const events = @import("events.zig");
pub const fetch = @import("fetch.zig");
pub const handoff_gifter = @import("handoff_gifter.zig");
pub const handoff_recipient = @import("handoff_recipient.zig");
pub const handoff_re_encode = @import("handoff_re_encode.zig");
pub const negotiation = @import("negotiation.zig");
const node = @import("node.zig");
/// The sans-io cross-connection handoff router (ADR-0066): a tier above the
/// per-connection `Peer` that owns the retained node identity, the shared gift
/// registry, and the redeemed-token / foreign-home routing that makes
/// three-party handoff transparent. It lives in the engine core (not the
/// I/O-bearing driver) because it is pure routing data, so the sans-io C ABI and
/// native callers reach it without dragging in a transport.
pub const Node = node.Node;
/// A `Node` connection handle (ADR-0066), re-exported alongside `Node`.
pub const ConnId = node.ConnId;
pub const pairing = @import("pairing.zig");
pub const pipeline = @import("pipeline.zig");
pub const sturdyref = @import("sturdyref.zig");
pub const v1_0 = @import("v1_0.zig");

pub const StepOutcome = events.StepOutcome;
pub const EventKind = events.EventKind;
pub const Event = events.Event;

/// Verbatim byte span of the `<desc:sig-envelope <desc:handoff-give …> …>` a
/// recipient relays unaltered to the exporter. Surfaced here so the C ABI
/// projects a received give without reaching past the engine into the codec.
pub const spanSignedHandoffGive = codec.syrup.spanSignedHandoffGive;

/// Encode a verbatim `<ocapn-peer …>` Syrup record carrying hint entries, so a
/// gifter can name an exporter reachable only by a dial hint (an iroh exporter's
/// direct addresses). The recipient re-parses it with `codec.syrup.readLocatorOwned`
/// (see `handoff_recipient.exporterLocatorUri`).
/// Surfaced here so the C ABI builds a give location without reaching past the
/// engine into the codec.
pub const encodePeerLocatorRecord = codec.syrup.encodePeerLocatorRecord;

/// The well-known bootstrap export position every OCapN peer answers `fetch` on,
/// owned by the session and surfaced here so consumers above the engine name the
/// one authoritative value rather than re-deriving the magic `0`.
pub const BOOTSTRAP_POSITION = session.BOOTSTRAP_POSITION;

/// The inbound receive/dispatch spine (`recvBorrowed`/`recvStreamPrefix`/`step`
/// call in here). Factored out of the `Peer` body as free functions over
/// `*Peer`, the same shape `v1_0`/`pipeline` use.
const inbound = @import("inbound.zig");

/// The errors the engine itself mints on the dispatch / step spine, as opposed
/// to the codec and session error sets it forwards. Enumerated as one explicit
/// set so the abort taxonomy gate (`test/engine/error_taxonomy_test.zig`) can
/// sweep it: a new engine-minted error that falls through
/// `abort_projection.classify` to `.foreign` fails the gate instead of silently
/// surfacing as a host-internal failure with no abort.
pub const EngineError = error{
    /// One resolution's drain produced more local deliveries than
    /// `SessionLimits.max_local_deliveries` admits (`pipeline.deliverDrainedCallLocally`).
    LocalDeliveryCapExceeded,
    /// A V1.0 `op:resolve` reached encode with no resolver row recorded for its
    /// answer (`v1_0.encodeResolveAsCallback`).
    MissingV1_0Resolver,
    /// A `field` pipeline step reached the Syrup decomposer, which has no wire
    /// shape for it (`pipeline.decomposeOutboundDeliver`).
    UnsupportedPipelineOp,
    /// The partner's `op:start-session` location signature failed to verify.
    InvalidStartSessionSignature,
    /// A streamed inbound frame exceeded `SessionLimits.max_frame_bytes`
    /// (`Peer.recvStreamPrefix`).
    FrameTooLarge,
};

/// A FIFO with a drain cursor: `push` appends, `pop` advances a head index and
/// reclaims the backing (rewind the head, retain capacity) once fully drained,
/// so steady enqueue/dequeue neither grows without bound nor shifts on every
/// pop. The four peer queues (inbound frames, pending sends, outbound frames,
/// events) share this one shape instead of open-coding a parallel `_head` field.
fn Queue(comptime T: type) type {
    return struct {
        items: std.ArrayList(T) = .empty,
        head: usize = 0,

        const Self = @This();

        /// Append to the back. `pub` so the `pipeline` drain half (the same
        /// engine, split by file) can surface a synthesized local-delivery
        /// event; the queue type itself stays private to the engine.
        pub fn push(self: *Self, allocator: std.mem.Allocator, value: T) !void {
            try self.items.append(allocator, value);
        }

        /// Reserve room for one more `push`, so a follow-up `pushAssumeCapacity`
        /// cannot fail. The pair lets a caller make the *enqueue* infallible after
        /// a fallible step that has already transferred ownership (a sent resolve
        /// whose resolution moved into the answer store), keeping record+enqueue
        /// atomic without an undo path.
        fn ensureUnusedCapacityForOne(self: *Self, allocator: std.mem.Allocator) !void {
            try self.items.ensureUnusedCapacity(allocator, 1);
        }

        fn pushAssumeCapacity(self: *Self, value: T) void {
            self.items.appendAssumeCapacity(value);
        }

        /// Dequeue the front element, or null when drained, reclaiming the
        /// backing slots (rewind the head, retain capacity) at that point.
        fn pop(self: *Self) ?T {
            if (self.head == self.items.items.len) {
                if (self.head != 0) {
                    self.items.clearRetainingCapacity();
                    self.head = 0;
                }
                return null;
            }
            const value = self.items.items[self.head];
            self.head += 1;
            // A queue kept non-empty under sustained load never reaches the
            // drain-reset above, so the consumed prefix would grow without
            // bound. Once the dead prefix dominates the backing, slide the live
            // tail to the front, holding the backing to O(live depth).
            if (self.head >= 64 and self.head * 2 >= self.items.items.len) {
                const live = self.items.items[self.head..];
                std.mem.copyForwards(T, self.items.items[0..live.len], live);
                self.items.shrinkRetainingCapacity(live.len);
                self.head = 0;
            }
            return value;
        }

        /// Remove and return the most-recently pushed element, for `errdefer`
        /// undo of an append whose follow-up failed. Null when empty.
        pub fn popBack(self: *Self) ?T {
            return self.items.pop();
        }

        /// A borrowed pointer to the front element without dequeuing it, or null
        /// when drained. The pointer aliases the queued element and stays valid
        /// until the next queue mutation, read through it, do not own it.
        fn peek(self: *Self) ?*const T {
            if (self.head == self.items.items.len) return null;
            return &self.items.items[self.head];
        }

        /// The not-yet-dequeued elements, for type-specific teardown before
        /// `deinit` (the queue owns the slots, not how to free a `T`).
        fn pending(self: *Self) []T {
            return self.items.items[self.head..];
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.items.deinit(allocator);
        }
    };
}

/// The typed cause of a locally-detected failure, kept readable on the peer so
/// an adapter-level consumer can diagnose a refusal without bypassing the
/// adapter (a `PumpError.ProtocolAbort` names only the family; this names the
/// member). Every field is plain data or a static string from the projection
/// table / `@errorName`, so holding one allocates nothing and frees nothing.
/// This is strictly the *locally projected* side: a partner's `op:abort`
/// arrives as an `Event` of kind `.abort` and is not recorded here.
pub const AbortInfo = struct {
    /// Whether the codec, the session, or a host-internal (`foreign`) failure
    /// refused the dispatch.
    domain: abort_projection.Domain,
    /// The `op:abort` kind projected onto the wire, or null when the failure
    /// surfaces without one (`SessionClosed`, host-internal errors).
    kind: ?model.AbortKind,
    /// The static diagnostic the projected abort carried ("" when none).
    message: []const u8,
    /// `@errorName` of the originating Zig error.
    error_name: []const u8,
};

/// One inbound `withdraw-gift` parked until its gift is deposited (ADR-0056).
/// Owns `handoff` (always the `.receive` arm); freed when the withdraw settles
/// or at `Peer.deinit`.
const PendingWithdraw = struct {
    handoff: model.Handoff,
    answer: model.AnswerId,
};

/// One slot in the outbound queue. Most kinds queue a fully-built `message` the
/// queue owns until `step` encodes it. A sent `op:resolve` is the exception: its
/// resolution lives in the answer store (it moved there at record time), so the
/// queue holds only `settled_answer` — the position of the inbound answer it
/// settles — and `step` reads the resolution back from the store to encode.
/// That single store ownership is the point: the resolution is not copied into a
/// frame here and the store there, and an inbound `op:gc-answers` that drops the
/// row between record and emit simply leaves nothing to encode (a self-contained
/// frame copy would dangle on exactly that sequence; this carrier cannot).
const Outbound = union(enum) {
    message: model.Message,
    settled_answer: model.AnswerId,

    fn deinit(self: Outbound, allocator: std.mem.Allocator) void {
        switch (self) {
            // The store owns a settled answer's resolution and frees it at answer
            // GC or session teardown (`deinitAnswerEntry`); the carrier owns
            // nothing.
            .settled_answer => {},
            .message => |message| freeMessage(allocator, message),
        }
    }
};

/// The caller-owned CapTP engine: one peer per session, no I/O, no hidden
/// scheduler. The host feeds inbound frames (`recvBorrowed` / `feedInbound`),
/// advances the peer with `step`, drains `outbound`, and reads surfaced
/// events; everything the peer queues is allocated on its `allocator` and
/// freed in `deinit`.
pub const Peer = struct {
    allocator: std.mem.Allocator,
    session_state: session.Session,
    inbound: Queue(foundation.Frame),
    pending_send: Queue(Outbound),
    outbound: Queue(foundation.Frame),
    events: Queue(Event),
    /// Resolutions forwarded for handoff-imported promises (ADR-0009) awaiting
    /// the cross-peer `cross_peer.drainRelayedResolutions` drain. Each entry
    /// owns its resolution until drained.
    pending_relayed_resolutions: std.ArrayList(cross_peer.PendingRelayedResolution),
    /// The peer's private gift / handoff-count authority (ADR-0056), consulted
    /// through `giftRegistry` unless a host shares one across peers via
    /// `shared_gift_registry`. Owned: freed in `deinit`.
    own_gift_registry: bootstrap.GiftRegistry = .{},
    /// Inbound `withdraw-gift`s parked because their gift is not deposited yet
    /// (ADR-0056): the deposit travels on a different session, so the withdraw
    /// can arrive first. Each entry owns its handoff-receive; `step` retries
    /// them against `giftRegistry()` and settles the answer once the gift
    /// lands. Bounded by `SessionLimits.max_pending_withdraws`.
    pending_withdraws: std.ArrayList(PendingWithdraw) = .empty,
    /// Optional vat-scoped gift registry shared across direct sessions to the
    /// same local vat — `deposit-gift` arrives on the gifter session, while
    /// `withdraw-gift` arrives on the recipient session. Borrowed, never owned:
    /// the host that wires several peers to one registry keeps it alive past
    /// every peer's `deinit`, frees it itself, and owns any cross-thread locking
    /// (the engine is externally synchronized).
    shared_gift_registry: ?*bootstrap.GiftRegistry = null,
    /// Bounds the chain of local deliveries a single resolution can trigger
    /// (a drained pipelined call resolving to a local export, whose own
    /// resolution drains more calls). Capped by `SessionLimits.max_local_deliveries`.
    local_delivery_depth: usize = 0,
    /// When set, an inbound `op:start-session` is admitted only if its location
    /// signature verifies against the claimed `session_pubkey` over the canonical
    /// `<my-location …>` bytes (ADR-0006), at the engine boundary — the session
    /// core still runs no crypto. A failure projects an
    /// `InvalidStartSessionSignature` abort and the session never opens.
    /// `initNegotiating` turns this on: a peer doing a real keyed handshake
    /// authenticates its partner by default (the secure default the whole
    /// application surface inherits). The raw `init` peer leaves it off (it
    /// never handshakes), and the stub-key in-process fixtures opt out through
    /// `NegotiatingOptions` because their handshakes carry no real signature.
    verify_partner_handshake: bool = false,
    /// The typed cause of the most recent local dispatch failure — read it
    /// through `lastAbort`. Overwritten on each failure; never reset on
    /// success, so it stays readable after the error has propagated.
    last_abort: ?AbortInfo = null,

    /// Peer over an already-open v1.0 session with default limits, no
    /// handshake will run. A real connection starts with `initNegotiating`
    /// and authenticates `op:start-session` instead.
    pub fn init(allocator: std.mem.Allocator) Peer {
        return initWithSession(allocator, session.Session.init(allocator));
    }

    /// Already-open v1.0 fixture peer for tests that inject frames directly.
    /// Real sessions should start with `initNegotiating` and authenticate
    /// `op:start-session`; PreSpec should arrive through negotiation, not through
    /// this raw-open shortcut.
    pub fn initRawOpenFixture(allocator: std.mem.Allocator) Peer {
        return initWithSession(allocator, session.Session.initWith(allocator, .{
            .wire_profile = model.WireProfile.v1_0,
        }));
    }

    /// Negotiated knobs for `initNegotiatingWith`. Profile, codec, and feature
    /// set are independent axes; both peers of a pair must carry the same
    /// negotiated values so neither exercises a profile, codec, or capability the
    /// other did not advertise. Defaults match the Goblins interop target:
    /// authenticated OCapN v1.0 over Syrup.
    pub const NegotiatingOptions = struct {
        wire_profile: model.WireProfile = model.WireProfile.v1_0,
        codec: model.CodecId = .syrup,
        features: model.FeatureSet = model.FeatureSet.full(),
        /// Resource bounds for the session (`session.SessionLimits`), fixed at
        /// construction so a caller never has to reach into `session_state`.
        limits: session.SessionLimits = .{},
        /// Verify the partner's `op:start-session` signature (`Peer.verify_partner_handshake`).
        /// On by default: a keyed handshake authenticates its partner. Only the
        /// stub-key in-process fixtures set this false.
        verify_partner_handshake: bool = true,
    };

    /// A peer that begins in the `negotiating` state on the default Goblins
    /// interop target (`v1_0` + Syrup), awaiting the `op:start-session`
    /// handshake. Use `initNegotiatingWith` when Pancake-to-Pancake negotiation
    /// selected a different profile or codec.
    pub fn initNegotiating(allocator: std.mem.Allocator) Peer {
        return initNegotiatingWith(allocator, .{});
    }

    /// A negotiating peer carrying the handshake-negotiated `codec` and
    /// `features` (`negotiation.Negotiated`). The in-process driver
    /// (`pairing`) constructs both peers of a pair from one negotiated result.
    pub fn initNegotiatingWith(allocator: std.mem.Allocator, options: NegotiatingOptions) Peer {
        var peer = initWithSession(allocator, session.Session.initWith(allocator, .{
            .negotiating = true,
            .codec = options.codec,
            .wire_profile = options.wire_profile,
            .features = options.features,
            .limits = options.limits,
        }));
        peer.verify_partner_handshake = options.verify_partner_handshake;
        return peer;
    }

    /// Peer adopting a caller-built session; every `init*` shorthand
    /// delegates here. The peer owns `session_state` from this call on and
    /// tears it down in `deinit`.
    pub fn initWithSession(allocator: std.mem.Allocator, session_state: session.Session) Peer {
        return .{
            .allocator = allocator,
            .session_state = session_state,
            .inbound = .{},
            .pending_send = .{},
            .outbound = .{},
            .events = .{},
            .pending_relayed_resolutions = .empty,
        };
    }

    /// Frees everything the peer still owns: queued inbound/outbound frames,
    /// pending messages and events, parked withdraws and relayed resolutions,
    /// the private gift registry, and the session with its tables. A shared
    /// gift registry (`shared_gift_registry`) is the one thing not freed
    /// here, its owner outlives every peer pointed at it.
    pub fn deinit(self: *Peer) void {
        for (self.inbound.pending()) |*frame| {
            frame.deinit();
        }
        self.inbound.deinit(self.allocator);

        for (self.pending_send.pending()) |*item| {
            item.deinit(self.allocator);
        }
        self.pending_send.deinit(self.allocator);

        for (self.outbound.pending()) |*frame| {
            frame.deinit();
        }
        self.outbound.deinit(self.allocator);

        for (self.events.pending()) |*event| {
            event.frame.deinit();
        }
        self.events.deinit(self.allocator);

        for (self.pending_relayed_resolutions.items) |pending| {
            freeResolution(self.allocator, pending.resolution);
        }
        self.pending_relayed_resolutions.deinit(self.allocator);

        for (self.pending_withdraws.items) |pending| {
            model.freeHandoff(self.allocator, pending.handoff);
        }
        self.pending_withdraws.deinit(self.allocator);
        self.own_gift_registry.deinit(self.allocator);
        self.session_state.deinit();
    }

    /// The gift / handoff-count authority this peer consults: the host-shared
    /// registry when one is wired, otherwise the peer's own.
    pub fn giftRegistry(self: *Peer) *bootstrap.GiftRegistry {
        return self.shared_gift_registry orelse &self.own_gift_registry;
    }

    /// Enqueue an owned `message` for outbound encode, taking ownership of its
    /// heap. The canonical, copy-free path: a caller that built the message moves
    /// it in; the peer frees it after `step` encodes it (or here, if recording it
    /// fails). Borrowed or static input goes through `sendCopying` instead.
    pub fn send(self: *Peer, message: model.Message) !void {
        // A multi-hop pipelined deliver (promise target carrying a non-empty
        // path) has no single-frame Syrup shape — `desc:answer` carries no path
        // operand — so it decomposes into a chain of single-hop links, each
        // recorded + enqueued through this same path
        // (ADR-0007 § Multi-hop decomposition at the sender). The Cap'n Proto
        // codec is the only shape that would carry a path operand directly,
        // without decomposition.
        if (message == .deliver and
            message.deliver.target == .promise and
            !message.deliver.target.promise.path.isEmpty())
        {
            return self.sendDecomposedPipeline(message);
        }

        return self.enqueueRecorded(message);
    }

    /// Commit a prepared bootstrap-fetch (`fetch.prepareFetchSwissnum`, or
    /// `sturdyref.prepareEnliven`'s fresh arm) onto the wire. On a V1.0 session
    /// the prepared deliver advertises its own resolver export in
    /// `resolve_me_desc`; this installs the answer-to-resolver link the encoder's
    /// own deliver synthesis would otherwise mint, so the partner's
    /// resolver-callback deliver projects back as a resolve keyed on
    /// `prepared.answer_position`. Consumes `prepared.message` (moved into `send`,
    /// or freed if the resolver install fails). The V1.0 resolver link is engine
    /// authority; callers route through this verb rather than touching the
    /// session table.
    pub fn sendPreparedFetch(self: *Peer, prepared: fetch.PreparedFetch) !void {
        if (prepared.message.deliver.resolve_me_desc != null) {
            self.session_state.installOutboundResolver(prepared.answer_position, prepared.resolver_export) catch |err| {
                freeMessage(self.allocator, prepared.message);
                return err;
            };
        }
        try self.send(prepared.message);
    }

    /// Record and enqueue one *flat* (no-decomposition) `message` for outbound
    /// encode, taking ownership of its heap. The shared tail of `send` and the
    /// decomposed-chain links — kept separate so the chain links bypass the
    /// (already-checked) multi-hop guard, breaking the `send` recursion cycle.
    fn enqueueRecorded(self: *Peer, message: model.Message) !void {
        // A sent `op:resolve` moves its resolution into the answer store at
        // record time (`recordSend` consumes it), so the queue carries only the
        // settled answer position. Reserve the carrier slot *before* recording:
        // the resolution transfer is then committed by an infallible push, never
        // by an undo — a record that succeeded but failed to enqueue would settle
        // the answer with no frame to carry it to the partner.
        if (message == .resolve) {
            const answer = message.resolve.answer;
            try self.pending_send.ensureUnusedCapacityForOne(self.allocator);
            try self.session_state.recordSend(message);
            self.pending_send.pushAssumeCapacity(.{ .settled_answer = answer });
            return;
        }

        var owned_needs_free = true;
        errdefer if (owned_needs_free) freeMessage(self.allocator, message);

        try self.pending_send.push(self.allocator, .{ .message = message });
        owned_needs_free = false;
        var appended = true;
        errdefer if (appended) self.pending_send.popBack().?.deinit(self.allocator);

        try self.session_state.recordSend(message);
        appended = false;
    }

    /// Decompose a multi-hop pipelined deliver and enqueue each single-hop link
    /// in send order (ADR-0007 § Multi-hop decomposition at the sender), taking
    /// ownership of `message`. Each
    /// link is flat by construction, so it enqueues through `enqueueRecorded`
    /// directly. On a mid-chain failure the unsent remainder is released; links
    /// already handed to `enqueueRecorded` are owned by it.
    fn sendDecomposedPipeline(self: *Peer, message: model.Message) !void {
        const chain = pipeline.decomposeOutboundDeliver(self.allocator, &self.session_state, message) catch |err| {
            // Decomposition never partially consumes `message` before failing.
            freeMessage(self.allocator, message);
            return err;
        };
        defer self.allocator.free(chain.intermediates);

        var next: usize = 0;
        var terminal_owned = true;
        errdefer {
            for (chain.intermediates[next..]) |link| freeMessage(self.allocator, link);
            if (terminal_owned) freeMessage(self.allocator, chain.terminal);
        }
        while (next < chain.intermediates.len) {
            const link = chain.intermediates[next];
            // `enqueueRecorded` owns `link` on both outcomes (consumed on success,
            // freed on error); advance past it before the call so the errdefer
            // can't double-free it.
            next += 1;
            try self.enqueueRecorded(link);
        }
        terminal_owned = false;
        try self.enqueueRecorded(chain.terminal);
    }

    /// Boundary convenience over `send` for callers that hold *borrowed* or
    /// static message data they keep owning (the handshake / handoff drivers,
    /// tests, the FFI edge). Names the one copy explicitly per project values;
    /// the internal spine moves through `send` and never lands here.
    pub fn sendCopying(self: *Peer, message: model.Message) !void {
        const owned = try cloneMessage(self.allocator, message);
        return self.send(owned);
    }

    /// Queue a keyed `op:start-session` over `secret`'s Ed25519 key. The canonical
    /// signing input for `<my-location …>` is profile-defined and lives in the
    /// codec, so this is the one place that builds it: it signs the canonical
    /// bytes of `locator`, then enqueues a `start_session` carrying the session
    /// public key, the locator, and the signature. A negotiating peer drives this
    /// to an open session once the partner's own start-session arrives. The signed
    /// locator is what the partner verifies, so `locator` must be the one the
    /// partner expects (for a Goblins partner, a `tcp` transport with `#f`-encoded
    /// empty hints). Borrowed inputs are cloned into the outbound queue, exactly
    /// as `sendCopying` documents.
    pub fn sendKeyedStartSession(
        self: *Peer,
        version: model.CaptpVersion,
        locator: model.PeerLocator,
        secret: foundation.crypto.SecretKey,
    ) !void {
        const pubkey = secret.publicKey();
        const signed = try codec.syrup.canonicalLocationSignedBytes(self.allocator, locator);
        defer self.allocator.free(signed);
        const sig = foundation.crypto.sign(&secret, signed);
        try self.sendCopying(.{ .start_session = .{
            .captp_version = version,
            .session_pubkey = .{ .bytes = pubkey.asBytes() },
            .acceptable_location = locator,
            .acceptable_location_sig = .{ .bytes = sig.asBytes() },
        } });
    }

    /// Queue the recipient half of a three-party handoff: sign a
    /// `desc:handoff-receive` over `give_bytes` keyed by `secret`, mint the
    /// monotonic handoff-count from this peer's gift registry, and queue
    /// `withdraw-gift` to the exporter's bootstrap object under `answer`. The
    /// exporter session must be open — its partner key names the receive's
    /// session — or this fails with `error.NoExporterKey`. This is the one
    /// definition of the withdraw deliver shape; `Node.sendWithdraw` and the C
    /// ABI both drive it. `give_bytes` is borrowed for the call.
    pub fn sendWithdrawGift(
        self: *Peer,
        secret: foundation.crypto.SecretKey,
        give_bytes: []const u8,
        answer: model.AnswerId,
    ) !void {
        const exporter_key = self.session_state.partnerSessionKey() orelse return error.NoExporterKey;
        const signed = try handoff_recipient.signedReceiveFromGiveBytes(
            self.allocator,
            self.session_state.limits,
            self.giftRegistry(),
            secret,
            secret.publicKey(),
            exporter_key,
            give_bytes,
        );
        // `signed.message()` borrows `signed`; both outlive `sendCopying`, which
        // deep-copies the deliver before this returns.
        var handoff = model.Handoff{ .receive = signed.message() };
        try self.sendCopying(.{ .deliver = .{
            .target = .{ .far = model.FarRef.object(BOOTSTRAP_POSITION) },
            .args = &.{ .{ .symbol = "withdraw-gift" }, .{ .handoff = &handoff } },
            .answer = answer,
        } });
    }

    /// Queue a `deposit-gift` to this (exporter) session's bootstrap object: a
    /// fire-and-forget `op:deliver` carrying the gift id and the gifted
    /// reference, so the exporter records the gift a later `withdraw-gift`
    /// redeems. This is the one definition of the deposit deliver shape;
    /// `Node.originateGive` and the C ABI both drive it. `gift_id` is borrowed
    /// and `gifted` is borrowed; both are cloned into the outbound queue.
    pub fn sendDepositGift(self: *Peer, gift_id: []const u8, gifted: model.Reference) !void {
        try self.sendCopying(.{ .deliver = .{
            .target = .{ .far = model.FarRef.object(BOOTSTRAP_POSITION) },
            .args = &.{ .{ .symbol = "deposit-gift" }, .{ .bytes = gift_id }, .{ .reference = gifted } },
            .answer = null,
        } });
    }

    /// Resolve `answer` (a question a recipient asked this gifter) with a signed
    /// `desc:handoff-give`: queue an `op:resolve` whose fulfill carries
    /// `give_bytes` verbatim, so the encoder emits the exact bytes the gifter
    /// signed and the recipient redeems them transparently. Only `raw_signed` is
    /// set; the empty descriptor fields are never read on the verbatim path. This
    /// is the one definition of the resolve-give shape; `Node.originateGive` and
    /// the C ABI both drive it. `give_bytes` is borrowed for the call.
    pub fn sendResolveHandoffGive(self: *Peer, answer: model.AnswerId, give_bytes: []const u8) !void {
        var handoff = model.Handoff{ .give = .{
            .recipient_key = "",
            .exporter_location = "",
            .gifter_exporter_session = "",
            .gifter_side = "",
            .gift_id = "",
            .signature = "",
            .raw_signed = give_bytes,
        } };
        try self.sendCopying(.{ .resolve = .{
            .answer = answer,
            .resolution = .{ .fulfill = .{ .handoff = &handoff } },
        } });
    }

    /// Whether the session has completed the `op:start-session` handshake and is
    /// open for traffic. An adapter pumps the handshake frames, then checks this
    /// before sending application messages.
    pub fn sessionIsOpen(self: *const Peer) bool {
        return self.session_state.state == .open;
    }

    /// Expose a local capability behind `swissnum` for inbound bootstrap-fetch
    /// (ADR-0006 responder half). Allocates a fresh export, maps the swissnum to
    /// it, and returns the export id. The adapter calls this at config time; an
    /// inbound `'fetch` for the swissnum is then served automatically by
    /// `dispatchOwnedFrameInner`.
    pub fn registerBootstrapCap(self: *Peer, swissnum: []const u8) !u64 {
        return (try self.session_state.registerBootstrapCap(swissnum)).int();
    }

    /// Publish a local object at export position `id` so inbound deliveries to it
    /// are admitted and surface as events. Capabilities are driven through the
    /// peer; the session's authoritative tables stay encapsulated.
    pub fn exportObject(self: *Peer, id: u64) !void {
        return self.session_state.registerExport(model.ExportId.from(id));
    }

    /// Allocate the next free export position for a local object and return it,
    /// the auto-assigned counterpart of `exportObject`.
    pub fn exportNextObject(self: *Peer) !u64 {
        return (try self.session_state.allocateExport()).int();
    }

    /// Track a partner-hosted object held as import position `id`, so a `far` send
    /// to it is admitted (e.g. an import handed back by a bootstrap fetch).
    pub fn importObject(self: *Peer, id: u64) !void {
        return self.session_state.registerImport(model.ImportId.from(id));
    }

    /// Allocate the next outbound answer position, the question id for a deliver
    /// that wants a reply. The actor layer rides this to back an eventual-send's
    /// promise; the partner's `op:resolve` for this id settles it.
    pub fn allocateAnswer(self: *Peer) u64 {
        return self.session_state.allocateOutboundAnswer().int();
    }

    /// Enqueue a forwarded resolution for handoff-imported promise `import_position`
    /// (ADR-0009), taking ownership of `resolution`. The cross-peer phase
    /// (`cross_peer.drainRelayedResolutions`) later fires the import's
    /// listeners with it. The application-facing entry point for the introducing
    /// session forwarding a third-party promise's resolution; on enqueue failure
    /// the resolution is freed.
    pub fn relayResolution(self: *Peer, import_position: u64, resolution: model.Resolution) !void {
        errdefer freeResolution(self.allocator, resolution);
        try self.pending_relayed_resolutions.append(self.allocator, .{
            .import_position = model.ImportId.from(import_position),
            .resolution = resolution,
        });
    }

    /// Apply one forwarded resolution (ADR-0009), taking ownership of
    /// `resolution`: fire the listeners installed on `import_position` (borrowing the
    /// resolution), then store it for late listeners (moving it in),
    /// borrow-then-move, no clone. Called by `cross_peer.drainRelayedResolutions`.
    pub fn applyRelayedResolution(self: *Peer, import_position: model.ImportId, resolution: model.Resolution) !void {
        pipeline.fireImportedPromiseListeners(self, import_position, resolution) catch |err| {
            freeResolution(self.allocator, resolution);
            return err;
        };
        // recordRelayedResolution moves `resolution` into storage on success and
        // frees it on an unknown-import error, so it owns it on both outcomes.
        try self.session_state.recordRelayedResolution(import_position, resolution);
    }

    /// Transfer an owned inbound frame into the peer for the next `step` dispatch.
    ///
    /// On success the peer owns `frame`; on error the caller remains
    /// responsible for releasing it.
    pub fn feedInbound(self: *Peer, frame: foundation.Frame) !void {
        try self.inbound.push(self.allocator, frame);
    }

    /// Drive the peer one unit of work: dispatch one queued inbound frame, or
    /// encode one pending outbound message onto `outbound`. Returns `.progress`
    /// when it did either and `.idle` when both queues were empty. Any failure
    /// fails closed, exactly like the inbound boundary: it is recorded as the
    /// typed `lastAbort`, projected to an outbound `op:abort` when the
    /// projection has one, and closes the session per the projection, before
    /// the error propagates. Host-internal errors (out of memory, …) carry no
    /// abort and leave the session as it was.
    pub fn step(self: *Peer) !StepOutcome {
        return self.stepInner() catch |err| {
            inbound.emitAbortForError(self, err);
            return err;
        };
    }

    /// Read the typed cause of the most recent local dispatch failure, or null
    /// if none has occurred. The fields are static — nothing to free — and the
    /// value is overwritten by the next failure, so copy it out before driving
    /// the peer again if it must outlive the next call.
    pub fn lastAbort(self: *const Peer) ?AbortInfo {
        return self.last_abort;
    }

    /// Classify `err` and keep it readable through `lastAbort`. Idempotent for
    /// one failure: the inbound path records inside `emitAbortForError` and
    /// again in `step`'s exit, overwriting with the same classification.
    pub fn recordFailure(self: *Peer, err: anyerror) void {
        const classified = abort_projection.classify(err);
        self.last_abort = .{
            .domain = classified.domain,
            .kind = if (classified.abort) |a| a.kind else null,
            .message = if (classified.abort) |a| a.message else "",
            .error_name = @errorName(err),
        };
    }

    fn stepInner(self: *Peer) !StepOutcome {
        // A parked `withdraw-gift` settles once its deposit arrives — possibly
        // on another peer sharing this registry — so every step re-checks
        // before other work. The empty-list fast path costs one length read.
        try self.settlePendingWithdraws();

        // One unit of work per step: dispatch one inbound frame, else encode one
        // pending outbound message. `pop` transfers ownership into dispatch (on
        // success the frame moves into the surfaced event, zero copy; on error
        // dispatch frees it) and reclaims the backing once inbound is drained,
        // the consumed frames below the head were moved out, so reclaim never
        // double-frees. The inner dispatch is used here (not `dispatchOwnedFrame`)
        // because `step`'s own exit projects the abort for every failure; the
        // wrapped form would emit it twice.
        if (self.inbound.pop()) |frame| {
            try inbound.dispatchOwnedFrameInner(self, frame);
            return .progress;
        }

        switch (self.pending_send.pop() orelse return .idle) {
            .message => |message| {
                defer freeMessage(self.allocator, message);
                try self.emitOutboundMessage(message);
            },
            .settled_answer => |answer| {
                // The resolution lives in the answer store (it moved there at
                // record time). Borrow it to encode and to drive the local
                // settlement, the store keeps owning it. If an inbound
                // `op:gc-answers` dropped the row between record and now, the
                // resolve is moot: the row's pipelined calls, projections, and
                // listeners were freed with it, so there is nothing to emit or
                // settle.
                const stored = self.session_state.peekResolution(answer) orelse return .progress;
                const resolve: model.Resolve = .{ .answer = answer, .resolution = stored.* };
                try self.emitOutboundMessage(.{ .resolve = resolve });
                // A sent `op:resolve` also settles one of our inbound answers locally.
                try self.settleSentResolve(resolve);
            },
        }
        return .progress;
    }

    /// Encode one popped pending message onto `outbound`, applying the V1.0
    /// translations that have no wire form under PreSpec (`v1_0`, ADR-0010):
    ///   - a semantic `Resolve` ships as a resolver-callback `op:deliver` to the
    ///     partner's resolver import, or is dropped when only `op:listen`
    ///     listeners settle the answer (the listener fire in `settleSentResolve`
    ///     handles notification);
    ///   - an answered `op:deliver` gains a synthesized resolver export at encode
    ///     time, committing the resolver link as it does;
    ///   - a projection trails an `op:listen` that carries its new answer's
    ///     resolution back, since the projection ops carry no inline resolver
    ///     (ADR-0050, ADR-0052). The listen must follow the op that opened the
    ///     answer on the wire, so it is pushed after the encode.
    /// PreSpec encodes the message as it stands. Borrows `message`; the caller
    /// owns and frees it.
    fn emitOutboundMessage(self: *Peer, message: model.Message) !void {
        const needs_v1_0 = self.session_state.needsV1_0Translation();

        if (needs_v1_0 and message == .resolve) {
            if (self.session_state.resolverForInboundAnswer(message.resolve.answer) != null) {
                try v1_0.encodeResolveAsCallback(self, message.resolve);
            }
            return;
        }

        const wire_message = if (needs_v1_0 and message == .deliver)
            try v1_0.installResolverForOutboundDeliver(self, message.deliver)
        else
            message;
        {
            var frame = try codec.dispatch.encodeMessageForProfile(
                self.session_state.codec,
                self.allocator,
                self.session_state.wire_profile,
                wire_message,
            );
            errdefer frame.deinit();
            try self.outbound.push(self.allocator, frame);
        }

        if (needs_v1_0) switch (message) {
            .get => |g| try v1_0.installListenerForOutboundProjection(self, g.answer),
            .index => |i| try v1_0.installListenerForOutboundProjection(self, i.answer),
            .untag => |u| try v1_0.installListenerForOutboundProjection(self, u.answer),
            else => {},
        };
    }

    /// Settle the local consequences of a just-sent `op:resolve`: drain the
    /// calls the partner pipelined against the answer and the projections
    /// anchored on it (calls first — a drained call may settle further answers,
    /// ADR-0007 § Queue ownership and drain), then fire its listeners. The
    /// resolution itself is already stored — `applySentResolve` stored it when
    /// this resolve was recorded (`recordSend` routes a sent resolve there), the
    /// same moment the answer's status flipped — so a
    /// pipelined call, projection, or `op:listen` that arrived between record and
    /// this emit already saw the settled answer with its value on hand and was
    /// served directly; only the calls / projections / listeners that anchored
    /// while the answer was still pending remain for these drains. The resolution
    /// frame is already on `outbound`, so a drain refusal surfaces as a step
    /// error without un-sending it. Borrows `resolve`; the caller owns and frees
    /// it.
    fn settleSentResolve(self: *Peer, resolve: model.Resolve) !void {
        try pipeline.drainPipelinedCalls(self, resolve);
        try pipeline.drainProjections(self, resolve);
        try pipeline.fireListenersOnResolve(self, resolve);
    }

    /// Retry every parked `withdraw-gift` whose gift is already deposited: re-run
    /// the verified withdraw responder and enqueue its answer. An entry whose
    /// gift is still missing stays parked; a settled entry (fulfilled *or*
    /// refused with a typed break) is freed here.
    fn settlePendingWithdraws(self: *Peer) !void {
        if (self.pending_withdraws.items.len == 0) return;
        var index: usize = 0;
        while (index < self.pending_withdraws.items.len) {
            const entry = &self.pending_withdraws.items[index];
            if (!self.giftRegistry().giftLive(entry.handoff.receive.signed_give.gift_id)) {
                index += 1;
                continue;
            }
            const view_handoff = model.view.Handoff.fromOwned(&entry.handoff);
            switch (try bootstrap.resolveForWithdraw(self.allocator, &self.session_state, self.giftRegistry(), .{
                .receive = view_handoff.receive,
                .answer = entry.answer,
            })) {
                .settled => |msg| try self.sendCopying(msg),
                // The row vanished between the deposited check and the resolve;
                // leave the entry parked for the next step.
                .awaiting_deposit => {
                    index += 1;
                    continue;
                },
            }
            const settled = self.pending_withdraws.swapRemove(index);
            model.freeHandoff(self.allocator, settled.handoff);
        }
    }

    /// Dequeue the next encoded outbound frame, transferring ownership to the
    /// caller (who frees it with `Frame.deinit` or hands it to a transport that
    /// does). Returns null when the queue is drained.
    pub fn takeOutbound(self: *Peer) ?foundation.Frame {
        return self.outbound.pop();
    }

    /// Dispatch a borrowed inbound frame. The borrowed bytes are transient, so
    /// the engine copies them once into an owned frame to retain the event. This
    /// is the single intentional copy on the borrowed inbound path.
    pub fn recvBorrowed(self: *Peer, frame: foundation.FrameView) !void {
        const owned = try ownedFrameFromView(self.allocator, frame);
        try inbound.dispatchOwnedFrame(self, owned);
    }

    /// Outcome of framing one message off the front of a byte-stream buffer.
    pub const RecvStream = union(enum) {
        /// A complete frame was decoded, validated, and applied; the caller may
        /// drop (`toss`) the first `consumed` bytes of the buffer.
        consumed: usize,
        /// The buffer holds only part of a frame; the caller reads more and
        /// retries with the extended buffer (the leading bytes are unchanged).
        incomplete,
    };

    /// Frame, decode, validate, and apply the one message at the front of a
    /// borrowed byte-stream `buffer`, reporting how many bytes it consumed — or
    /// that more bytes are needed. This is the byte-stream generalization of
    /// `recvBorrowed`: the active codec's decoder finds the frame boundary as
    /// it decodes (one parse, no separate scanner), authority is applied through
    /// the same borrowed-validate path, and only then is the frame retained
    /// (the single intentional copy, as on `recvBorrowed`). `buffer` must stay
    /// valid for the call; afterwards the consumed bytes may be discarded.
    ///
    /// A malformed frame or one exceeding `SessionLimits.max_frame_bytes`
    /// projects to a typed outbound `op:abort` and closes the session
    /// (`abort_projection`) before the error surfaces, exactly as the frame
    /// boundary does. `.incomplete` is not an error: no abort, no state change.
    pub fn recvStreamPrefix(self: *Peer, buffer: []const u8) !RecvStream {
        const prefix = codec.dispatch.decodePrefix(
            self.session_state.codec,
            buffer,
            self.session_state.limits.max_frame_bytes,
        );
        switch (prefix) {
            .incomplete => return .incomplete,
            .malformed => {
                inbound.emitAbortForError(self, error.MalformedFrame);
                return error.MalformedFrame;
            },
            .too_large => {
                inbound.emitAbortForError(self, error.FrameTooLarge);
                return error.FrameTooLarge;
            },
            .decoded => |decoded| {
                // The prefix decoded under this same codec, so its shape is
                // registered; a null would mean the dispatchers disagree.
                const shape = codec.dispatch.frameShape(self.session_state.codec) orelse {
                    inbound.emitAbortForError(self, error.MalformedFrame);
                    return error.MalformedFrame;
                };
                // A failed materialization is recorded like every other inbound
                // failure (it is foreign — no abort — but `lastAbort` must
                // still name it).
                const owned = ownedFrameFromView(self.allocator, .{
                    .bytes = buffer[0..decoded.consumed],
                    .shape = shape,
                }) catch |err| {
                    self.recordFailure(err);
                    return err;
                };
                inbound.applyDecodedOwnedFrame(self, owned, decoded.body) catch |err| {
                    inbound.emitAbortForError(self, err);
                    return err;
                };
                return .{ .consumed = decoded.consumed };
            },
        }
    }

    /// Take the next surfaced event, or null when none is queued. The caller
    /// owns the returned event and must `deinit` it after dispatch.
    pub fn pollEvent(self: *Peer) ?Event {
        return self.events.pop();
    }

    /// Borrow a const pointer to the next surfaced event without consuming it, or
    /// null when none is queued. The pointer aliases the still-queued event's
    /// frame, so you can read it (`view()`) but cannot `deinit` it, that is the
    /// queue's to do when a following `pollEvent` consumes and owns the real one.
    /// The borrow stays valid until the next `pollEvent`. This lets a consumer
    /// that may reject the event (a typed projection that cannot represent an
    /// argument) leave it queued for the opaque-frame fallback instead of
    /// dequeuing it into the void.
    pub fn peekEvent(self: *Peer) ?*const Event {
        return self.events.peek();
    }

    /// The kind of the next queued event without consuming it, so a caller can
    /// route to a kind-specific decode (the C ABI's typed `poll_event_*` path).
    pub fn peekEventKind(self: *Peer) ?EventKind {
        return (self.events.peek() orelse return null).tag;
    }
};

/// The per-session inline footprint budget, held by the compiler.
///
/// A `Peer` is what one CapTP session costs before it touches the heap, and the
/// 500k-connection destination treats that cost as a budget: a field added here
/// is a withdrawal from it. One kilobyte is the committed ceiling, so half a
/// million idle sessions stay under 0.5 GiB of inline state and the heap-warmed
/// footprint stays the number the ladder's rung 2 quotes. The runtime half of the
/// budget — the heap a warmed session grows — is held by
/// `test/engine/footprint_budget_test.zig`. Crossing this ceiling is not a build
/// failure to route around; it is a design event that raises the budget here, in
/// the ladder, and in the vision, together, with the bytes justified.
pub const peer_session_struct_budget_bytes = 1024;
comptime {
    if (@sizeOf(Peer) > peer_session_struct_budget_bytes) @compileError(std.fmt.comptimePrint(
        "engine.Peer is {d} bytes, over the {d}-byte per-session struct budget (docs/ladder.md rung 2). " ++
            "A larger session struct is a withdrawal from the 500k footprint budget — raise the budget deliberately, do not route around it.",
        .{ @sizeOf(Peer), peer_session_struct_budget_bytes },
    ));
}

/// Verify the partner's `op:start-session` location signature: real Ed25519 over
/// the profile-level canonical `<my-location …>` signing input, against the
/// claimed `session_pubkey`. Syrup supplies the exact received location bytes so
/// Goblins-style hint spelling is preserved; codecs without that raw capture
/// canonicalize the neutral locator into the same signing domain. A malformed
/// key/signature or failed check is `InvalidStartSessionSignature`, which the
/// abort projection maps to a handshake-time `invalid_start_session_signature`.
/// Allocates the canonical bytes transiently; nothing is retained. The one
/// start-session verification body: `Peer`'s inbound dispatch runs it when
/// `verify_partner_handshake` is set, and the in-process keyed pairing driver
/// (`pairing.pairedWithKeys`) runs the same body over each drained handshake
/// event, so the two paths cannot drift.
pub fn verifyPartnerStartSession(allocator: std.mem.Allocator, ss: model.view.StartSession) !void {
    const crypto = foundation.crypto;
    const pubkey = crypto.PeerKey.fromSlice(ss.session_pubkey) catch
        return error.InvalidStartSessionSignature;
    const sig = switch (ss.acceptable_location_sig) {
        .halves => |h| crypto.Signature.fromParts(h.r, h.s) catch
            return error.InvalidStartSessionSignature,
        .raw => |raw| crypto.Signature.fromSlice(raw) catch
            return error.InvalidStartSessionSignature,
    };
    const signed = if (ss.acceptable_location_raw) |raw|
        try codec.syrup.canonicalLocationSignedBytesRaw(allocator, raw)
    else signed: {
        const location = try ss.acceptable_location.toOwned(allocator);
        defer model.freePeerLocator(allocator, location);
        break :signed try codec.syrup.canonicalLocationSignedBytes(allocator, location);
    };
    defer allocator.free(signed);
    crypto.verify(pubkey, signed, sig) catch return error.InvalidStartSessionSignature;
}

/// Copy borrowed wire bytes into an owned frame that respects the frame shape's
/// alignment, so a surfaced event (or a netlayer's owned frame handed across the
/// C ABI) can outlive the borrowed inbound buffer. The single shape-aware
/// materialization: a `word` frame is over-aligned to 8 bytes so it satisfies
/// `Frame` shape validation; a `byte` frame takes natural alignment. The copy is
/// named here, the one boundary that retains.
pub fn ownedFrameFromView(allocator: std.mem.Allocator, frame: foundation.FrameView) !foundation.Frame {
    switch (frame.shape) {
        .byte => {
            const storage = try allocator.dupe(u8, frame.bytes);
            return foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));
        },
        .word => {
            const storage = try allocator.alignedAlloc(u8, .fromByteUnits(8), frame.bytes.len);
            @memcpy(storage, frame.bytes);
            return foundation.Frame.initOwned(allocator, storage, .word, .fromByteUnits(8));
        },
    }
}

const cloneMessage = model.cloneMessage;
const freeMessage = model.freeMessage;
const freeResolution = model.freeResolution;
