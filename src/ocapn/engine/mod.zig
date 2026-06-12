//! The `Peer` you hold, and the loop that drives it. Synchronous, no I/O.
//!
//! We call this the engine, not the runtime, and that difference is the whole
//! point. pancake has no runtime in the usual sense: no scheduler, no background
//! tasks, no ambient executor driving things behind your back. The engine is the
//! explicit, synchronous alternative — you feed it frames, you call `step`, you
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
pub const negotiation = @import("negotiation.zig");
pub const pairing = @import("pairing.zig");
pub const pipeline = @import("pipeline.zig");
pub const registry = @import("registry.zig");
pub const sturdyref = @import("sturdyref.zig");
pub const v1_0 = @import("v1_0.zig");

pub const SessionRegistry = registry.SessionRegistry;
pub const StepOutcome = events.StepOutcome;
pub const EventKind = events.EventKind;
pub const DecodeError = events.DecodeError;
pub const Event = events.Event;

/// The well-known bootstrap export position every OCapN peer answers `fetch` on,
/// owned by the session and surfaced here so consumers above the engine name the
/// one authoritative value rather than re-deriving the magic `0`.
pub const BOOTSTRAP_POSITION = session.BOOTSTRAP_POSITION;
const resolutionFromResolverCallback = events.resolutionFromResolverCallback;

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

        /// Dequeue the front element, or null when drained — reclaiming the
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
        fn popBack(self: *Self) ?T {
            return self.items.pop();
        }

        /// The front element without dequeuing it, or null when drained. The
        /// returned value aliases the queued element — read it, do not own it.
        fn peek(self: *Self) ?T {
            if (self.head == self.items.items.len) return null;
            return self.items.items[self.head];
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
    answer: u64,
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
    pending_send: Queue(model.Message),
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

    /// Peer over an already-open v1.0 session with default limits — no
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
    /// here — its owner outlives every peer pointed at it.
    pub fn deinit(self: *Peer) void {
        for (self.inbound.pending()) |*frame| {
            frame.deinit();
        }
        self.inbound.deinit(self.allocator);

        for (self.pending_send.pending()) |*message| {
            freeMessage(self.allocator, message.*);
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

    /// Record and enqueue one *flat* (no-decomposition) `message` for outbound
    /// encode, taking ownership of its heap. The shared tail of `send` and the
    /// decomposed-chain links — kept separate so the chain links bypass the
    /// (already-checked) multi-hop guard, breaking the `send` recursion cycle.
    fn enqueueRecorded(self: *Peer, message: model.Message) !void {
        var owned_needs_free = true;
        errdefer if (owned_needs_free) freeMessage(self.allocator, message);

        try self.pending_send.push(self.allocator, message);
        owned_needs_free = false;
        var appended = true;
        errdefer if (appended) freeMessage(self.allocator, self.pending_send.popBack().?);

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
        return self.session_state.registerBootstrapCap(swissnum);
    }

    /// Publish a local object at export position `id` so inbound deliveries to it
    /// are admitted and surface as events. Capabilities are driven through the
    /// peer; the session's authoritative tables stay encapsulated.
    pub fn exportObject(self: *Peer, id: u64) !void {
        return self.session_state.registerExport(id);
    }

    /// Allocate the next free export position for a local object and return it —
    /// the auto-assigned counterpart of `exportObject`.
    pub fn exportNextObject(self: *Peer) !u64 {
        return self.session_state.allocateExport();
    }

    /// Track a partner-hosted object held as import position `id`, so a `far` send
    /// to it is admitted (e.g. an import handed back by a bootstrap fetch).
    pub fn importObject(self: *Peer, id: u64) !void {
        return self.session_state.registerImport(id);
    }

    /// Allocate the next outbound answer position — the question id for a deliver
    /// that wants a reply. The actor layer rides this to back an eventual-send's
    /// promise; the partner's `op:resolve` for this id settles it.
    pub fn allocateAnswer(self: *Peer) u64 {
        return self.session_state.allocateOutboundAnswer();
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
            .import_position = import_position,
            .resolution = resolution,
        });
    }

    /// Apply one forwarded resolution (ADR-0009), taking ownership of
    /// `resolution`: fire the listeners installed on `import_position` (borrowing the
    /// resolution), then store it for late listeners (moving it in) —
    /// borrow-then-move, no clone. Called by `cross_peer.drainRelayedResolutions`.
    pub fn applyRelayedResolution(self: *Peer, import_position: u64, resolution: model.Resolution) !void {
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
            self.emitAbortForError(err);
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
    fn recordFailure(self: *Peer, err: anyerror) void {
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

        // One inbound frame per step. `pop` transfers ownership into dispatch (on
        // success the frame moves into the surfaced event, zero copy; on error
        // dispatch frees it) and reclaims the backing once inbound is drained —
        // the consumed frames below the head were moved out, so reclaim never
        // double-frees. The inner dispatch is used here (not `dispatchOwnedFrame`)
        // because `step`'s own exit projects the abort for every failure; the
        // wrapped form would emit it twice.
        if (self.inbound.pop()) |frame| {
            try self.dispatchOwnedFrameInner(frame);
            return .progress;
        }

        const message = self.pending_send.pop() orelse return .idle;
        defer freeMessage(self.allocator, message);

        // Goblins V1.0 has no wire `op:resolve`: a semantic `Resolve` ships as an
        // `op:deliver` to the partner's resolver import (`v1_0`, ADR-0010). The
        // callback's args borrow `message`, which the `defer` above frees after
        // encode completes.
        if (self.session_state.needsV1_0Translation() and message == .resolve) {
            // If the answer has a resolver import (from the partner's
            // `resolve_me_desc`), encode as a resolver-callback deliver. If
            // not (e.g. a promise settled through `op:listen` listeners
            // only), skip the wire encode — the listener fire below handles
            // notification.
            if (self.session_state.resolverForInboundAnswer(message.resolve.answer) != null) {
                try v1_0.encodeResolveAsCallback(self, message.resolve);
            }
        } else {
            // V1.0 augments an answered deliver with a synthesized resolver
            // export at encode time, committing the resolver link as it does.
            const wire_message = if (self.session_state.needsV1_0Translation() and message == .deliver)
                try v1_0.installResolverForOutboundDeliver(self, message.deliver)
            else
                message;
            var frame = try codec.dispatch.encodeMessageForProfile(
                self.session_state.codec,
                self.allocator,
                self.session_state.wire_profile,
                wire_message,
            );
            errdefer frame.deinit();
            try self.outbound.push(self.allocator, frame);
        }

        // A sent `op:resolve` settles one of our inbound answers; drain the calls
        // the partner pipelined against it, then fire its listeners (ADR-0007
        // § Queue ownership and drain — calls first, since a drained call may
        // settle further answers). The resolution frame is already on `outbound`,
        // so a drain
        // refusal surfaces as a step error without un-sending the resolution.
        if (message == .resolve) {
            try pipeline.drainPipelinedCalls(self, message.resolve);
            try pipeline.drainProjections(self, message.resolve);
            try pipeline.fireListenersOnResolve(self, message.resolve);
            // Store the resolution so late pipelined calls redirect and late
            // listeners fire with the correct value. Reference resolutions are
            // pipelining redirect targets; all resolutions are needed for late
            // `op:listen` fires.
            const stored = try model.cloneResolution(self.allocator, message.resolve.resolution);
            self.session_state.storeResolution(message.resolve.answer, stored) catch |err| {
                freeResolution(self.allocator, stored);
                return err;
            };
        }
        return .progress;
    }

    /// Retry every parked `withdraw-gift` whose gift is now deposited: re-run
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
        try self.dispatchOwnedFrame(owned);
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
                self.emitAbortForError(error.MalformedFrame);
                return error.MalformedFrame;
            },
            .too_large => {
                self.emitAbortForError(error.FrameTooLarge);
                return error.FrameTooLarge;
            },
            .decoded => |decoded| {
                // The prefix decoded under this same codec, so its shape is
                // registered; a null would mean the dispatchers disagree.
                const shape = codec.dispatch.frameShape(self.session_state.codec) orelse {
                    self.emitAbortForError(error.MalformedFrame);
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
                self.applyDecodedOwnedFrame(owned, decoded.body) catch |err| {
                    self.emitAbortForError(err);
                    return err;
                };
                return .{ .consumed = decoded.consumed };
            },
        }
    }

    /// Dispatch an owned inbound frame, taking ownership.
    ///
    /// On success the frame moves into the surfaced event (zero copy). On any
    /// error the frame is released and session state is left unchanged: the event
    /// is enqueued before `recordRecv`, with rollback if authority rejects it, so
    /// session state never advances without a matching event and vice versa.
    ///
    /// A rejection that names a protocol violation (codec-malformed frame or a
    /// session state-machine refusal) projects to a typed outbound `op:abort`
    /// and closes the session (`abort_projection`) before the error surfaces:
    /// the partner sees a fail-loud abort, and the caller still receives the
    /// typed error (and should flush `takeOutbound` to send the abort frame).
    fn dispatchOwnedFrame(self: *Peer, frame_in: foundation.Frame) !void {
        return self.dispatchOwnedFrameInner(frame_in) catch |err| {
            self.emitAbortForError(err);
            return err;
        };
    }

    /// Best-effort emit of the outbound `op:abort` an inbound failure projects to
    /// (`abort_projection.abortForError`), then close if the projection says
    /// so. The abort frame is encoded directly (aborts are always admitted) and
    /// appended to `outbound`; it bypasses `recordSend`, which would reject it
    /// against the post-failure session state. Swallows its own allocation
    /// failures so the original dispatch error is never masked — but still closes
    /// when the projection requires it, since the decision to abort stands
    /// regardless of whether the frame could be encoded.
    fn emitAbortForError(self: *Peer, err: anyerror) void {
        self.recordFailure(err);
        const projected = abort_projection.abortForError(err) orelse return;
        defer if (projected.close) self.session_state.close();

        const message: model.Message = .{ .abort = .{
            .kind = projected.kind,
            .message = projected.message,
        } };
        var frame = codec.dispatch.encodeMessageForProfile(
            self.session_state.codec,
            self.allocator,
            self.session_state.wire_profile,
            message,
        ) catch return;
        self.outbound.push(self.allocator, frame) catch frame.deinit();
    }

    fn dispatchOwnedFrameInner(self: *Peer, frame_in: foundation.Frame) !void {
        const decoded_body = codec.dispatch.decodeBody(self.session_state.codec, frame_in.view()) catch |err| {
            var frame = frame_in;
            frame.deinit();
            return err;
        };
        try self.applyDecodedOwnedFrame(frame_in, decoded_body);
    }

    /// Apply an already-decoded inbound frame: install listeners, enqueue a
    /// pipelined call, surface the event, and record authority. This is the
    /// shared tail of the owned-frame boundary (`dispatchOwnedFrameInner`) and the
    /// byte-stream framer (`recvStreamPrefix`), so an inbound frame is parsed
    /// exactly once regardless of how it arrived.
    ///
    /// `decoded_body` may borrow `frame_in`'s own bytes (frame boundary) or a
    /// separate stream buffer that outlives this call (`recvStreamPrefix`). It
    /// must stay valid until apply completes; afterwards the retained event owns
    /// only `frame_in` and the borrow is dropped.
    fn applyDecodedOwnedFrame(self: *Peer, frame_in: foundation.Frame, decoded_body: model.view.Body) !void {
        var frame = frame_in;
        var stored = false;
        errdefer if (!stored) frame.deinit();

        // Apply the session's state-admission gate before any authority mutation
        // below. The pipelined-call enqueue, listener install, and V1.0 resolver
        // registration all run ahead of `recordRecvView`/`recordRecv`, and the
        // pipelined path returns without ever reaching them — so without this a
        // closed (or negotiating) session would mutate authority for an inbound
        // kind it must refuse. `recordRecv*` re-checks the gate; the check is pure.
        try self.session_state.admits(decoded_body);

        // A verifying peer authenticates the partner's `op:start-session` before
        // learning its key: real Ed25519 over the captured location bytes. The
        // session core runs no crypto, so this engine-boundary check gates the
        // handshake; a failure returns `InvalidStartSessionSignature`, which
        // projects an abort and leaves the session un-opened (the key is never
        // learned, since `recordRecvView` below does not run).
        if (self.verify_partner_handshake and decoded_body == .start_session) {
            try verifyPartnerStartSession(self.allocator, decoded_body.start_session);
        }

        // An inbound `op:listen` against one of our pending inbound answers
        // registers the listener so the resolution fires it (ADR-0007 §
        // op:listen). Installed before the event/`recordRecv` so a refusal
        // leaves nothing surfaced. Non-promise targets and listens on unknown
        // answers fall through to ordinary recv handling.
        if (decoded_body == .listen) {
            try pipeline.maybeInstallInboundListener(self, decoded_body.listen);
        }

        // An inbound deliver takes exactly one of four routes; the classifier
        // holds the probe order, so the precedence is data here, not call-site
        // ordering (see `classifyInboundDeliver`).
        var tag = eventKindFromBody(decoded_body);
        var resolve_answer: ?u64 = null;
        var v1_0_resolve: ?model.Resolve = null;
        defer if (v1_0_resolve) |resolve| freeMessage(self.allocator, .{ .resolve = resolve });
        var bootstrap_action: ?bootstrap.Action = null;
        if (decoded_body == .deliver) {
            switch (try self.classifyInboundDeliver(decoded_body.deliver)) {
                // Surfaces as a semantic `Resolve` (ADR-0010): the resolution is
                // materialized owned because `recordRecv` below retains it.
                .v1_0_resolve => |answer| {
                    tag = .resolve;
                    resolve_answer = answer;
                    v1_0_resolve = .{
                        .answer = answer,
                        .resolution = try (try resolutionFromResolverCallback(decoded_body.deliver.args))
                            .toOwned(self.allocator),
                    };
                },
                // Queued or redirected against the answer it pipelined on
                // (ADR-0007); nothing surfaces for this frame.
                .pipelined => {
                    frame.deinit();
                    return;
                },
                // Answered automatically once authority records the deliver
                // (ADR-0006 responder half); the action applies below.
                .bootstrap => |action| bootstrap_action = action,
                .ordinary => {},
            }
        }

        try self.events.push(self.allocator, .{ .frame = frame, .tag = tag, .resolve_answer = resolve_answer, .codec = self.session_state.codec });
        stored = true;
        var appended = true;
        errdefer if (appended) {
            var removed = self.events.popBack().?;
            removed.frame.deinit();
        };

        if (v1_0_resolve) |resolve| {
            try self.session_state.recordRecv(.{ .resolve = resolve });
        } else {
            try self.session_state.recordRecvView(decoded_body);
        }
        appended = false;

        // op:get / op:index / op:untag responder (ADR-0050): apply above
        // installed the projected answer; anchor the projection on the
        // receiver. The view's field/tag bytes borrow the frame, so the owned
        // dupe happens here, while the borrow is still valid.
        switch (decoded_body) {
            .get => |get| try pipeline.respondToProjection(self, get.receiver, .{ .field = get.field }, get.answer),
            .index => |idx| try pipeline.respondToProjection(self, idx.receiver, .{ .index = idx.index }, idx.answer),
            .untag => |untag| try pipeline.respondToProjection(self, untag.receiver, .{ .untag = untag.tag }, untag.answer),
            else => {},
        }

        if (bootstrap_action) |action| {
            switch (action) {
                .fetch => |req| try self.sendCopying(bootstrap.resolveForSwissnum(&self.session_state, req)),
                .deposit_gift => |req| {
                    if (try bootstrap.resolveForDeposit(&self.session_state, self.giftRegistry(), req)) |msg| {
                        try self.sendCopying(msg);
                    }
                },
                .withdraw_gift => |req| {
                    switch (try bootstrap.resolveForWithdraw(self.allocator, &self.session_state, self.giftRegistry(), req)) {
                        .settled => |msg| try self.sendCopying(msg),
                        // The gift's deposit has not arrived yet (it travels on
                        // a different session); park the withdraw — `step`
                        // settles it once the deposit lands.
                        .awaiting_deposit => {
                            if (self.pending_withdraws.items.len >= self.session_state.limits.max_pending_withdraws) {
                                return session.Error.PendingWithdrawCapExceeded;
                            }
                            const owned = try (model.view.Handoff{ .receive = req.receive }).toOwned(self.allocator);
                            errdefer model.freeHandoff(self.allocator, owned);
                            try self.pending_withdraws.append(self.allocator, .{
                                .handoff = owned,
                                .answer = req.answer,
                            });
                        },
                    }
                },
            }
        }
    }

    /// The one route an inbound `op:deliver` takes, decided by
    /// `classifyInboundDeliver`. The variants are mutually exclusive by
    /// construction: a resolver-callback targets a resolver export, a pipelined
    /// call targets a `desc:answer` promise, and a bootstrap deliver targets the
    /// bootstrap export — three disjoint target shapes.
    const InboundDeliverClass = union(enum) {
        /// A V1.0 resolver-callback (ADR-0010) settling the inbound answer
        /// carried here; the frame surfaces as a semantic `Resolve`.
        v1_0_resolve: u64,
        /// Pipelined against an answer we owe (ADR-0007): the call was queued or
        /// redirected during classification, so the frame surfaces nothing.
        pipelined,
        /// A bootstrap-protocol deliver (ADR-0006): the caller applies the
        /// action after authority records the deliver.
        bootstrap: bootstrap.Action,
        /// An ordinary deliver, surfaced to the application as-is.
        ordinary,
    };

    /// Classify an inbound `op:deliver` into the one route it takes. The three
    /// special-case probes live here in their load-bearing order, so the
    /// precedence is data at the call site rather than comment-enforced
    /// sequencing:
    ///
    /// 1. V1.0 resolver classification runs first. Classification installs the
    ///    partner's resolver as a side effect, and a pipelined deliver carrying
    ///    `resolve_me_desc` needs that resolver installed before its frame is
    ///    released, so the V1.0 translation finds it when the drained call
    ///    resolves later.
    /// 2. Pipelining runs after V1.0 classify: an inbound deliver whose target
    ///    is a still-pending answer is queued until that answer resolves
    ///    (ADR-0007).
    /// 3. The bootstrap probe runs last, so a pipelined call is never mistaken
    ///    for a bootstrap fetch, and a resolver-only fetch has its virtual
    ///    answer installed before the bootstrap action is computed.
    fn classifyInboundDeliver(self: *Peer, deliver: model.view.Deliver) !InboundDeliverClass {
        if (self.session_state.needsV1_0Translation()) {
            if (try v1_0.interceptInboundDeliver(self, deliver)) |answer| {
                return .{ .v1_0_resolve = answer };
            }
        }
        if (try pipeline.maybeEnqueuePipelinedCall(self, deliver)) {
            return .pipelined;
        }
        if (try bootstrap.pendingBootstrapAction(deliver, &self.session_state)) |action| {
            return .{ .bootstrap = action };
        }
        return .ordinary;
    }

    /// Take the next surfaced event, or null when none is queued. The caller
    /// owns the returned event and must `deinit` it after dispatch.
    pub fn pollEvent(self: *Peer) ?Event {
        return self.events.pop();
    }

    /// Borrow the next surfaced event without consuming it, or null when none is
    /// queued. The returned value aliases the still-queued event's frame — read
    /// it (e.g. `view()`), do not `deinit` it; a following `pollEvent` consumes
    /// and owns the real one. Lets a consumer that may reject the event (a typed
    /// projection that cannot represent an argument) leave it queued for the
    /// opaque-frame fallback instead of dequeuing it into the void.
    pub fn peekEvent(self: *Peer) ?Event {
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

/// The `EventKind` a decoded body surfaces as — a 1:1 body-tag mapping. The one
/// re-tag (a V1.0 resolver-callback deliver surfacing as `.resolve`) is decided
/// by the inbound classifier (`classifyInboundDeliver`), not here.
fn eventKindFromBody(body: model.view.Body) EventKind {
    return switch (body) {
        .deliver => .deliver,
        .resolve => .resolve,
        .gc_export => .gc_export,
        .gc_answer => .gc_answer,
        .handoff => .handoff,
        .start_session => .start_session,
        .abort => .abort,
        .listen => .listen,
        .get => .get,
        .index => .index,
        .untag => .untag,
    };
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

// The owned-message ownership lifecycle lives at the model layer (`model.owned`)
// so the session's pipelining tables can own and release queued messages without
// reaching up into the engine. The outbound queue moves through `send`; the
// one boundary copy (`sendCopying`) goes through `cloneMessage`.
const cloneMessage = model.cloneMessage;
const freeMessage = model.freeMessage;
const freeResolution = model.freeResolution;
