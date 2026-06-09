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

const codec = @import("../codec/mod.zig");
const foundation = @import("../foundation/mod.zig");
const model = @import("../model/mod.zig");
const session = @import("../session/mod.zig");

pub const abort_projection = @import("abort_projection.zig");
pub const bootstrap = @import("bootstrap.zig");
pub const cross_peer = @import("cross_peer.zig");
pub const fetch = @import("fetch.zig");
pub const handoff_gifter = @import("handoff_gifter.zig");
pub const handoff_recipient = @import("handoff_recipient.zig");
pub const negotiation = @import("negotiation.zig");
pub const pairing = @import("pairing.zig");
pub const pipeline = @import("pipeline.zig");
pub const registry = @import("registry.zig");
pub const sturdyref = @import("sturdyref.zig");

pub const SessionRegistry = registry.SessionRegistry;

pub const StepOutcome = enum {
    idle,
    progress,
};

pub const EventKind = enum {
    deliver,
    resolve,
    gc_export,
    gc_answer,
    handoff,
    start_session,
    abort,
    listen,
    get,
    index,
};

/// Error decoding an inbound frame into the codec-neutral [`model.view.Body`]:
/// a codec parse failure or a lazy-sequence projection failure. Codec-dispatch
/// (per the session's negotiated codec) folds each codec's error set in here.
pub const DecodeError = codec.dispatch.Error || model.view.ProjectError;

/// An application-visible event.
///
/// The event owns the originating wire frame in the session's negotiated codec.
/// Typed access is a borrowed projection over that frame (`view`); owned
/// materialization (`decodeOwned`) happens only when the caller asks. The engine
/// never stores a decoded copy alongside the frame, and the C ABI hands the frame
/// bytes back without re-encoding, so the event surface stays codec-neutral and
/// copy-free past the single retain.
pub const Event = struct {
    frame: foundation.Frame,
    tag: EventKind,
    /// The codec that carried `frame` — the session's negotiated
    /// [`model.CodecId`]. `view` / `decodeOwned` route through the codec-dispatch
    /// boundary on it, so the event surface stays codec-neutral.
    codec: model.CodecId,
    /// Off-wire answer-id for a Goblins V1.0 resolver-callback (ADR-0010). V1.0
    /// has no wire `op:resolve`: the retained `frame` is the `op:deliver` to a
    /// resolver capability, whose semantic answer-id lives in session
    /// bookkeeping rather than on the wire. Set only when `tag == .resolve` and
    /// the frame is a translated deliver; `view()` re-projects it as a `Resolve`.
    resolve_answer: ?u64 = null,

    pub fn kind(self: Event) EventKind {
        return self.tag;
    }

    pub fn bytes(self: *const Event) []const u8 {
        return self.frame.bytes();
    }

    /// Borrowed typed projection over the retained frame. No allocation, no copy.
    ///
    /// For a V1.0 resolver-callback (`resolve_answer != null`) the frame is the
    /// wire `op:deliver`; this re-projects it as the semantic `Resolve` it stands
    /// for — the answer-id comes from the captured `resolve_answer`, the
    /// resolution payload still borrows the frame's deliver args.
    pub fn view(self: *const Event) DecodeError!model.view.Body {
        const wire = try codec.dispatch.decodeBody(self.codec, self.frame.view());
        if (self.resolve_answer) |answer| {
            return .{ .resolve = .{
                .answer = answer,
                .resolution = try resolutionFromResolverCallback(wire.deliver.args),
            } };
        }
        return wire;
    }

    /// Materialize an owned codec-neutral message from the retained frame. Only
    /// when the caller needs ownership independent of this event's frame. This
    /// materializes the wire frame as-is (an off-wire V1.0 resolver-callback
    /// surfaces as its `op:deliver`); [`view`] performs the semantic `Resolve`
    /// reprojection.
    pub fn decodeOwned(self: *const Event, event_allocator: std.mem.Allocator) !model.Message {
        const body = try codec.dispatch.decodeBody(self.codec, self.frame.view());
        return body.toOwned(event_allocator);
    }

    pub fn deinit(self: *Event) void {
        self.frame.deinit();
    }
};

/// The caller-owned protocol peer: owns a `Session`, an inbound frame queue, an
/// outbound message queue, and an event queue. Sync and no-I/O: the adapter
/// drives it by feeding frames in with `feedInbound` or `recvBorrowed`, calling
/// `step`, draining `outbound`, then polling events. Construct via [`pairing`];
/// the caller `deinit`s it.
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

        /// Append to the back.
        fn push(self: *Self, allocator: std.mem.Allocator, value: T) !void {
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

pub const Peer = struct {
    allocator: std.mem.Allocator,
    session_state: session.Session,
    inbound: Queue(foundation.Frame),
    pending_send: Queue(model.Message),
    outbound: Queue(foundation.Frame),
    events: Queue(Event),
    /// Resolutions forwarded for handoff-imported promises (ADR-0009) awaiting
    /// the cross-peer [`cross_peer.drainRelayedResolutions`] drain. Each entry
    /// owns its resolution until drained.
    pending_relayed_resolutions: std.ArrayList(cross_peer.PendingRelayedResolution),
    /// Optional exporter-scoped gift table shared across direct sessions to the
    /// same local vat. `deposit-gift` arrives on the gifter session, while
    /// `withdraw-gift` arrives on the recipient session.
    handoff_gifts: ?*bootstrap.GiftRegistry = null,
    /// Bounds the chain of local deliveries a single resolution can trigger
    /// (a drained pipelined call resolving to a local export, whose own
    /// resolution drains more calls). Capped by `SessionLimits.max_local_deliveries`.
    local_delivery_depth: usize = 0,
    /// When set, an inbound `op:start-session` is admitted only if its location
    /// signature verifies against the claimed `session_pubkey` over the canonical
    /// `<my-location …>` bytes (ADR-0006), at the engine boundary — the session
    /// core still runs no crypto. A failure projects an
    /// `InvalidStartSessionSignature` abort and the session never opens.
    /// [`initNegotiating`] turns this on: a peer doing a real keyed handshake
    /// authenticates its partner by default (the secure default the whole
    /// application surface inherits). The raw [`init`] peer leaves it off (it
    /// never handshakes), and the stub-key in-process fixtures plus the Cap'n
    /// Proto path opt out through [`NegotiatingOptions`] — their handshakes carry
    /// no real signature, and the raw-locator capture verification needs is
    /// Syrup-only.
    verify_partner_handshake: bool = false,

    pub fn init(allocator: std.mem.Allocator) Peer {
        return initWithSession(allocator, session.Session.init(allocator));
    }

    /// Negotiated knobs for [`initNegotiatingWith`]. A negotiating peer is always
    /// on the canonical Goblins v1.0 wire profile (that is not a knob); both peers
    /// of a pair must carry the *same* `codec` and `features` — the intersection
    /// [`negotiation.negotiate`] computes — so neither exercises a capability the
    /// other did not advertise. Defaults match [`initNegotiating`].
    pub const NegotiatingOptions = struct {
        codec: model.CodecId = .syrup,
        features: model.FeatureSet = model.FeatureSet.full(),
        /// Verify the partner's `op:start-session` signature ([`Peer.verify_partner_handshake`]).
        /// On by default: a keyed handshake authenticates its partner. Only the
        /// stub-key in-process fixtures and the Cap'n Proto path (whose canonical
        /// signing input is Syrup-defined, so the raw-locator capture is absent)
        /// set this false.
        verify_partner_handshake: bool = true,
    };

    /// A peer that begins in the `negotiating` state on the canonical Goblins
    /// v1.0 wire profile, awaiting the `op:start-session` handshake. The
    /// in-process handshake driver ([`pairing`]) constructs both peers this
    /// way before shuttling their handshake frames to quiescence.
    pub fn initNegotiating(allocator: std.mem.Allocator) Peer {
        return initNegotiatingWith(allocator, .{});
    }

    /// A negotiating peer carrying the handshake-negotiated `codec` and
    /// `features` ([`negotiation.Negotiated`]). The in-process driver
    /// ([`pairing`]) constructs both peers of a pair from one negotiated result.
    pub fn initNegotiatingWith(allocator: std.mem.Allocator, options: NegotiatingOptions) Peer {
        var peer = initWithSession(allocator, session.Session.initWith(allocator, .{
            .negotiating = true,
            .codec = options.codec,
            .wire_profile = model.WireProfile.v1_0,
            .features = options.features,
        }));
        peer.verify_partner_handshake = options.verify_partner_handshake;
        return peer;
    }

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
        self.session_state.deinit();
    }

    /// Enqueue an owned `message` for outbound encode, taking ownership of its
    /// heap. The canonical, copy-free path: a caller that built the message moves
    /// it in; the peer frees it after `step` encodes it (or here, if recording it
    /// fails). Borrowed or static input goes through [`sendCopying`] instead.
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
    /// encode, taking ownership of its heap. The shared tail of [`send`] and the
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
    /// link is flat by construction, so it enqueues through [`enqueueRecorded`]
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

    /// Boundary convenience over [`send`] for callers that hold *borrowed* or
    /// static message data they keep owning (the handshake / handoff drivers,
    /// tests, the FFI edge). Names the one copy explicitly per project values;
    /// the internal spine moves through [`send`] and never lands here.
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
    /// as [`sendCopying`] documents.
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
    /// the auto-assigned counterpart of [`exportObject`].
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

    /// Enqueue a forwarded resolution for handoff-imported promise `import_id`
    /// (ADR-0009), taking ownership of `resolution`. The cross-peer phase
    /// ([`cross_peer.drainRelayedResolutions`]) later fires the import's
    /// listeners with it. The application-facing entry point for the introducing
    /// session forwarding a third-party promise's resolution; on enqueue failure
    /// the resolution is freed.
    pub fn relayResolution(self: *Peer, import_id: u64, resolution: model.Resolution) !void {
        errdefer freeResolution(self.allocator, resolution);
        try self.pending_relayed_resolutions.append(self.allocator, .{
            .import_id = import_id,
            .resolution = resolution,
        });
    }

    /// Apply one forwarded resolution (ADR-0009), taking ownership of
    /// `resolution`: fire the listeners installed on `import_id` (borrowing the
    /// resolution), then store it for late listeners (moving it in) —
    /// borrow-then-move, no clone. Called by [`cross_peer.drainRelayedResolutions`].
    pub fn applyRelayedResolution(self: *Peer, import_id: u64, resolution: model.Resolution) !void {
        self.fireImportedPromiseListeners(import_id, resolution) catch |err| {
            freeResolution(self.allocator, resolution);
            return err;
        };
        // recordRelayedResolution moves `resolution` into storage on success and
        // frees it on an unknown-import error, so it owns it on both outcomes.
        try self.session_state.recordRelayedResolution(import_id, resolution);
    }

    /// Transfer an owned inbound frame into the peer for the next `step` dispatch.
    ///
    /// On success the peer owns `frame`; on error the caller remains
    /// responsible for releasing it.
    pub fn feedInbound(self: *Peer, frame: foundation.Frame) !void {
        try self.inbound.push(self.allocator, frame);
    }

    pub fn step(self: *Peer) !StepOutcome {
        // One inbound frame per step. `pop` transfers ownership into dispatch (on
        // success the frame moves into the surfaced event, zero copy; on error
        // dispatch frees it) and reclaims the backing once inbound is drained —
        // the consumed frames below the head were moved out, so reclaim never
        // double-frees.
        if (self.inbound.pop()) |frame| {
            try self.dispatchOwnedFrame(frame);
            return .progress;
        }

        const message = self.pending_send.pop() orelse return .idle;
        defer freeMessage(self.allocator, message);

        // Goblins V1.0 has no wire `op:resolve`: a semantic `Resolve` ships as an
        // `op:deliver` to the partner's resolver import. The 2-element arg list
        // lives on the stack for the encode call only; its payload borrows
        // `message`, which the `defer` above frees after encode completes.
        if (self.session_state.needsV1_0Translation() and message == .resolve) {
            // V1.0 has no wire `op:resolve`. If the answer has a resolver
            // import (from the partner's `resolve_me_desc`), encode as a
            // resolver-callback deliver. If not (e.g. a promise settled
            // through `op:listen` listeners only), skip the wire encode — the
            // listener fire below handles notification.
            if (self.session_state.resolverForInboundAnswer(message.resolve.answer) != null) {
                try self.encodeResolverCallback(message.resolve);
            }
        } else {
            const wire_message = try self.prepareOutboundWireMessage(message);
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
            try self.drainPipelinedCalls(message.resolve);
            try self.fireListenersOnResolve(message.resolve);
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

    /// Encode a semantic `Resolve` as its V1.0 resolver-callback `op:deliver`
    /// (ADR-0010), addressed to the partner's resolver import recorded when their
    /// augmented deliver arrived. The resolution becomes `['fulfill, payload]` or
    /// `['break, <error>]` args; both borrow `resolve` for the encode call.
    fn encodeResolverCallback(self: *Peer, resolve: model.Resolve) !void {
        const resolver_import = self.session_state.resolverForInboundAnswer(resolve.answer) orelse
            return error.MissingV1_0Resolver;
        var args: [2]model.Argument = switch (resolve.resolution) {
            .fulfill => |value| .{ .{ .symbol = "fulfill" }, value },
            .break_ => |err| .{ .{ .symbol = "break" }, .{ .@"error" = err } },
        };
        const wire: model.Message = .{ .deliver = .{
            .target = .{ .far = model.FarRef.promise(resolver_import) },
            .args = &args,
            .answer = null,
            .resolve_me_desc = null,
        } };
        var frame = try codec.dispatch.encodeMessageForProfile(
            self.session_state.codec,
            self.allocator,
            self.session_state.wire_profile,
            wire,
        );
        errdefer frame.deinit();
        try self.outbound.push(self.allocator, frame);
    }

    /// Register an inbound `op:listen`'s listener against the targeted answer so
    /// our eventual `op:resolve` fires it (ADR-0007 § op:listen). Mirrors the
    /// V1.0 resolver-import pattern: the partner introduces their listener object
    /// as a descriptor we import; we reach it later via the matching `far`. A
    /// non-promise target or a listen on an answer we don't owe resolution for is
    /// not an error — it falls through to ordinary recv handling.
    fn maybeInstallInboundListener(self: *Peer, listen: model.view.Listen) !void {
        switch (listen.target) {
            .promise => |promise| {
                const answer = promise.answer_id;
                const entry = self.session_state.inboundAnswer(answer) orelse return;
                const position = referencePosition(listen.listener) orelse return;
                try self.session_state.registerImport(position);
                const listener_entry: session.ListenerEntry = .{
                    .target = .{ .far = model.FarRef.object(position) },
                    .wants_partial = listen.wants_partial,
                };
                if (entry.status == .fulfilled or entry.status == .broken) {
                    const resolution: model.Resolution = if (self.session_state.peekResolution(answer)) |r|
                        r.*
                    else
                        .{ .break_ = .{ .message = "promise already settled" } };
                    const action = try pipeline.classifyListenerDrain(self.allocator, listener_entry, resolution);
                    try self.applyListenerAction(action);
                } else {
                    try self.session_state.installListener(answer, listener_entry);
                }
            },
            // A listen on one of our exports: the partner sent `desc:export N`,
            // which is `.near` after the perspective flip. If N is an inbound
            // answer (e.g. a promise returned by the promise-resolver actor),
            // install the listener. If already resolved, fire immediately.
            .near => |near| {
                const answer = near.export_id;
                const entry = self.session_state.inboundAnswer(answer) orelse return;
                const position = referencePosition(listen.listener) orelse return;
                try self.session_state.registerImport(position);
                const listener_entry: session.ListenerEntry = .{
                    .target = .{ .far = model.FarRef.object(position) },
                    .wants_partial = listen.wants_partial,
                };
                if (entry.status == .fulfilled or entry.status == .broken) {
                    // Already resolved — fire the listener now against the stored
                    // resolution (if available), or a generic break.
                    const resolution: model.Resolution = if (self.session_state.peekResolution(answer)) |r|
                        r.*
                    else
                        .{ .break_ = .{ .message = "promise already settled" } };
                    const action = try pipeline.classifyListenerDrain(self.allocator, listener_entry, resolution);
                    try self.applyListenerAction(action);
                } else {
                    try self.session_state.installListener(answer, listener_entry);
                }
            },
            // An `op:listen` on a handoff-imported promise (ADR-0009): the target
            // names one of our imports — post-flip (ADR-0010) `<desc:import-*>`
            // decodes to a `far` whose import_id is the import. Only a
            // third-party-hosted import admits a relayed-resolution listener;
            // a direct-partner import (or unknown id) falls through to ordinary
            // recv handling.
            .far => |far| {
                const import_id = far.import_id;
                if (!self.session_state.isThirdPartyImport(import_id)) return;
                const position = referencePosition(listen.listener) orelse return;
                try self.session_state.registerImport(position);
                try self.session_state.installImportedPromiseListener(import_id, .{
                    .target = .{ .far = model.FarRef.object(position) },
                    .wants_partial = listen.wants_partial,
                });
                // Late listener: if the relayed resolution already arrived, fire
                // it now (the relay drain that recorded it already drained the
                // listeners present at that time).
                try self.maybeFireLateImportedListener(import_id);
            },
            .sturdy, .broken => return,
        }
    }

    /// Handle an inbound `op:deliver` that pipelines against an answer we owe,
    /// returning whether it was handled. A non-promise target or an unknown answer
    /// returns `false` (the caller surfaces it normally). If the answer is still
    /// pending, the owned call is queued and drained when we resolve it. If the
    /// answer is *already resolved* and we kept its (reference) resolution, the call
    /// is redirected against that resolution right now — the same
    /// [`dispatchDrainedCall`] path a call queued before resolution takes. This is
    /// the case a live Goblins enliven-and-call in one breath hits: we auto-serve
    /// the bootstrap fetch synchronously, so the answer is resolved in an earlier
    /// `step` than the pipelined deliver's frame is processed. A resolved answer
    /// with no stored redirect target returns `false` and surfaces raw.
    ///
    /// Either path validates the borrowed view (same reference/argument/depth
    /// checks as a direct deliver) before materializing it owned. An enqueue refusal
    /// (e.g. a cap) propagates and the session frees the call.
    fn maybeEnqueuePipelinedCall(self: *Peer, deliver: model.view.Deliver) !bool {
        if (deliver.target != .promise) return false;
        const answer = deliver.target.promise.answer_id;
        const entry = self.session_state.inboundAnswer(answer) orelse return false;

        // The V1.0 resolver for this deliver's `resolve_me_desc` was already
        // installed by `classifyInboundV1_0Deliver` in `applyDecodedOwnedFrame`,
        // which runs before this function.

        if (entry.status == .pending) {
            try self.session_state.validatePipelinedDeliver(deliver);
            // Install the queued call's own answer so further pipelined calls
            // can target it (a multi-hop pipeline: A→B→C queues B on A, then
            // C targets B's answer — C needs B's answer to exist).
            if (deliver.answer) |call_answer| {
                try self.session_state.installInboundAnswer(call_answer);
            }
            const owned = try (model.view.Body{ .deliver = deliver }).toOwned(self.allocator);
            try self.session_state.enqueuePipelinedCall(answer, owned);
            return true;
        }

        // Already resolved. Redirect against the kept resolution if we have one;
        // a break with no resolution stored propagates directly.
        if (self.session_state.peekResolution(answer)) |resolution| {
            try self.session_state.validatePipelinedDeliver(deliver);
            const owned = try (model.view.Body{ .deliver = deliver }).toOwned(self.allocator);
            self.local_delivery_depth = 0;
            try self.dispatchDrainedCall(answer, owned, resolution.*);
            return true;
        }
        // The answer resolved but no reference resolution was kept (a break or
        // non-reference fulfill). Propagate the break to the caller's answer/resolver.
        if (entry.status == .broken or entry.status == .fulfilled) {
            const owned = try (model.view.Body{ .deliver = deliver }).toOwned(self.allocator);
            try self.dispatchDrainedCall(answer, owned, .{ .break_ = .{ .message = "pipelined target already broken" } });
            return true;
        }
        return false;
    }

    /// Drain the calls the partner pipelined against the answer a just-sent
    /// `op:resolve` settles, dispatching each against the resolution (ADR-0007
    /// § Queue ownership and drain). Queued inbound targets always carry an empty path: a
    /// multi-hop pipeline is decomposed at the *sender* into single-hop frames
    /// ([`sendDecomposedPipeline`]), so every `desc:answer` on the wire is flat.
    fn drainPipelinedCalls(self: *Peer, resolve: model.Resolve) !void {
        // `local_delivery_depth` bounds the local deliveries *one* resolution's
        // drain produces (a drained call resolving to a local export). The drain
        // fans out only across the calls queued on this answer — it never
        // synchronously re-enters, since each local delivery surfaces an event the
        // application resolves on a later turn. So the bound is per-resolution and
        // resets here; left as a peer-lifetime counter it would wedge a long-lived
        // peer after `max_local_deliveries` legitimate deliveries across the whole
        // connection. The cross-turn chain is application-paced, not unbounded
        // auto-recursion, and a promise cycle is caught separately on requeue.
        self.local_delivery_depth = 0;
        const calls = try self.session_state.takePipelinedCalls(resolve.answer);
        defer self.allocator.free(calls);

        var index: usize = 0;
        errdefer for (calls[index..]) |queued| freeMessage(self.allocator, queued);

        while (index < calls.len) {
            const queued = calls[index];
            index += 1;
            try self.dispatchDrainedCall(resolve.answer, queued, resolve.resolution);
        }
    }

    /// Dispatch one drained pipelined call (owned) against `resolution`, taking
    /// ownership of `queued`. A `Far` resolution forwards the call on the wire; a
    /// `Near` delivers it locally; another promise re-queues it; every other
    /// shape (broken / sturdy / non-reference / break) drops it.
    fn dispatchDrainedCall(self: *Peer, answer: u64, queued: model.Message, resolution: model.Resolution) !void {
        const reference: ?model.Reference = switch (resolution) {
            .fulfill => |arg| if (arg == .reference) arg.reference else null,
            .break_ => null,
        };
        switch (reference orelse {
            // No reference target (break or non-reference fulfill). Propagate
            // the break so the partner isn't left hanging on any answer or
            // V1.0 resolver the queued call expected.
            const call_answer = queued.deliver.answer orelse blk: {
                // V1.0 resolver-only: look up the virtual answer.
                if (queued.deliver.resolve_me_desc) |rmd| {
                    const id = switch (rmd) {
                        .far => |far| far.import_id,
                        .near => |near| near.export_id,
                        else => break :blk @as(?u64, null),
                    };
                    break :blk self.session_state.answerForResolverImport(id);
                }
                break :blk @as(?u64, null);
            };
            if (call_answer) |ca| {
                const break_reason: model.Error = switch (resolution) {
                    .break_ => |err| err,
                    .fulfill => .{ .message = "pipelined target resolved to a non-reference value" },
                };
                self.sendCopying(.{ .resolve = .{
                    .answer = ca,
                    .resolution = .{ .break_ = break_reason },
                } }) catch {};
            }
            freeMessage(self.allocator, queued);
            return;
        }) {
            .far => |far| try self.send(pipeline.rewriteDeliverTarget(self.allocator, queued, .{ .far = far })),
            .near => |near| try self.deliverDrainedCallLocally(queued, near),
            .promise => |promise| {
                const batch = self.allocator.alloc(model.Message, 1) catch |err| {
                    freeMessage(self.allocator, queued);
                    return err;
                };
                batch[0] = queued;
                try self.session_state.requeuePipelinedCalls(promise.answer_id, &.{answer}, batch);
            },
            .sturdy, .broken => freeMessage(self.allocator, queued),
        }
    }

    /// Deliver a drained pipelined call to a local export `near` resolved its
    /// target to: rewrite the target, install the call's own answer as one we now
    /// owe, and surface a synthesized `op:deliver` event so the application
    /// dispatches it as if it had arrived directly. Bounded by
    /// `SessionLimits.max_local_deliveries` to stop a resolution chain looping.
    fn deliverDrainedCallLocally(self: *Peer, queued: model.Message, near: model.NearRef) !void {
        if (self.local_delivery_depth >= self.session_state.limits.max_local_deliveries) {
            freeMessage(self.allocator, queued);
            return error.LocalDeliveryCapExceeded;
        }
        // Re-target at the export the resolution named. A delivery to a local
        // export is wire-shaped as `desc:export` (a `far` here) — the same shape
        // a directly-received deliver to that export carries — so the synthesized
        // event is indistinguishable from one that arrived on the wire.
        // The rewritten call is serialized into its own frame below, so its heap
        // is always released here regardless of the append outcome.
        const rewritten = pipeline.rewriteDeliverTarget(
            self.allocator,
            queued,
            .{ .far = .{ .import_id = near.export_id } },
        );
        defer freeMessage(self.allocator, rewritten);

        if (rewritten.deliver.answer) |call_answer| {
            try self.session_state.installInboundAnswer(call_answer);
        }
        var frame = try codec.dispatch.encodeMessageForProfile(
            self.session_state.codec,
            self.allocator,
            self.session_state.wire_profile,
            rewritten,
        );
        errdefer frame.deinit();
        try self.events.push(self.allocator, .{ .frame = frame, .tag = .deliver, .resolve_answer = null, .codec = self.session_state.codec });
        self.local_delivery_depth += 1;
    }

    /// Drain the listeners registered against the answer a just-sent
    /// `op:resolve` settles, firing each per the (resolution × `wants_partial`)
    /// matrix (ADR-0007 § Listener fire matrix). Each fire moves onto `pending_send` via
    /// [`send`] so a later `step` encodes it; partial promises re-anchor the
    /// listener on the next answer.
    fn fireListenersOnResolve(self: *Peer, resolve: model.Resolve) !void {
        const listeners = try self.session_state.takePipelinedListeners(resolve.answer);
        defer self.allocator.free(listeners);

        var index: usize = 0;
        // On any mid-drain failure, release the targets of the listeners not yet
        // consumed; entries already moved into an action are owned by it.
        errdefer for (listeners[index..]) |entry| model.freeReference(self.allocator, entry.target);

        while (index < listeners.len) {
            const entry = listeners[index];
            index += 1;
            const action = try pipeline.classifyListenerDrain(self.allocator, entry, resolve.resolution);
            try self.applyListenerAction(action);
        }
    }

    /// Fire every listener installed on handoff-imported promise `import_id`
    /// (ADR-0009) with `resolution`, draining the listener list. `resolution` is
    /// borrowed — each fire clones the payload it carries — so the caller keeps
    /// ownership. Each fire moves onto `pending_send` via [`send`]. Imported-
    /// promise listeners fire unconditionally (no `wants_partial` re-anchor; a
    /// relayed resolution is the settled value).
    fn fireImportedPromiseListeners(self: *Peer, import_id: u64, resolution: model.Resolution) !void {
        const listeners = try self.session_state.takeImportedPromiseListeners(import_id);
        defer self.allocator.free(listeners);

        var index: usize = 0;
        errdefer for (listeners[index..]) |entry| model.freeReference(self.allocator, entry.target);

        while (index < listeners.len) {
            const entry = listeners[index];
            index += 1;
            const fire = try pipeline.synthesizeListenerFire(self.allocator, entry.target, resolution);
            try self.send(fire);
        }
    }

    /// Fire a just-installed listener on `import_id` if its relayed resolution
    /// already arrived (ADR-0009 late-listener immediate fire). The stored
    /// resolution is borrowed for the fire and left in place for further late
    /// listeners.
    fn maybeFireLateImportedListener(self: *Peer, import_id: u64) !void {
        const resolution = (self.session_state.importedPromiseResolution(import_id) orelse return).*;
        try self.fireImportedPromiseListeners(import_id, resolution);
    }

    /// Apply one [`pipeline.ListenerDrainAction`], taking ownership of the heap
    /// it carries: a fire moves onto `pending_send`; a re-anchored entry moves
    /// back into the listener table on its next answer.
    fn applyListenerAction(self: *Peer, action: pipeline.ListenerDrainAction) !void {
        switch (action) {
            .fire => |fire| try self.send(fire),
            .fire_and_reinstall => |fr| {
                self.send(fr.fire) catch |err| {
                    model.freeReference(self.allocator, fr.entry.target);
                    return err;
                };
                try self.session_state.installListener(fr.next_answer, fr.entry);
            },
            .reinstall => |ri| try self.session_state.installListener(ri.next_answer, ri.entry),
        }
    }

    fn prepareOutboundWireMessage(self: *Peer, message: model.Message) !model.Message {
        if (!self.session_state.wire_profile.isGoblinsV1_0()) {
            return message;
        }
        return switch (message) {
            .deliver => |deliver| blk: {
                if (deliver.answer == null or deliver.resolve_me_desc != null) {
                    break :blk message;
                }
                // Synthesize a promise-shaped resolver export and commit the
                // answer→export link so the partner's subsequent resolver-callback
                // deliver translates back into a semantic `Resolve`.
                const resolver_export = try self.session_state.allocateExport();
                try self.session_state.installOutboundResolver(deliver.answer.?, resolver_export);
                break :blk .{
                    .deliver = .{
                        .target = deliver.target,
                        .args = deliver.args,
                        .answer = deliver.answer,
                        .resolve_me_desc = .{ .near = model.NearRef.promise(resolver_export) },
                    },
                };
            },
            else => message,
        };
    }

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
    /// [`recvBorrowed`]: the active codec's decoder finds the frame boundary as
    /// it decodes (one parse, no separate scanner), authority is applied through
    /// the same borrowed-validate path, and only then is the frame retained
    /// (the single intentional copy, as on `recvBorrowed`). `buffer` must stay
    /// valid for the call; afterwards the consumed bytes may be discarded.
    ///
    /// A malformed frame or one exceeding `SessionLimits.max_frame_bytes`
    /// projects to a typed outbound `op:abort` and closes the session
    /// ([`abort_projection`]) before the error surfaces, exactly as the frame
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
                const owned = try ownedFrameFromView(self.allocator, .{
                    .bytes = buffer[0..decoded.consumed],
                    .shape = shape,
                });
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
    /// and closes the session ([`abort_projection`]) before the error surfaces:
    /// the partner sees a fail-loud abort, and the caller still receives the
    /// typed error (and should flush `takeOutbound` to send the abort frame).
    fn dispatchOwnedFrame(self: *Peer, frame_in: foundation.Frame) !void {
        return self.dispatchOwnedFrameInner(frame_in) catch |err| {
            self.emitAbortForError(err);
            return err;
        };
    }

    /// Best-effort emit of the outbound `op:abort` an inbound failure projects to
    /// ([`abort_projection.abortForError`]), then close if the projection says
    /// so. The abort frame is encoded directly (aborts are always admitted) and
    /// appended to `outbound`; it bypasses `recordSend`, which would reject it
    /// against the post-failure session state. Swallows its own allocation
    /// failures so the original dispatch error is never masked — but still closes
    /// when the projection requires it, since the decision to abort stands
    /// regardless of whether the frame could be encoded.
    fn emitAbortForError(self: *Peer, err: anyerror) void {
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
    /// shared tail of the owned-frame boundary ([`dispatchOwnedFrameInner`]) and the
    /// byte-stream framer ([`recvStreamPrefix`]), so an inbound frame is parsed
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
            try self.maybeInstallInboundListener(decoded_body.listen);
        }

        // V1.0 resolver installation runs before pipelining: a pipelined deliver
        // with `resolve_me_desc` needs its resolver installed now (before the frame
        // is freed and we return), so the V1.0 translation finds it when the
        // drained call resolves later.
        var tag = eventKindFromBody(decoded_body);
        var resolve_answer: ?u64 = null;
        var v1_0_resolve: ?model.Resolve = null;
        defer if (v1_0_resolve) |resolve| freeMessage(self.allocator, .{ .resolve = resolve });
        if (self.session_state.needsV1_0Translation() and decoded_body == .deliver) {
            if (try self.classifyInboundV1_0Deliver(decoded_body.deliver)) |answer| {
                tag = .resolve;
                resolve_answer = answer;
                v1_0_resolve = .{
                    .answer = answer,
                    .resolution = try (try resolutionFromResolverCallback(decoded_body.deliver.args))
                        .toOwned(self.allocator),
                };
            }
        }

        // Pipelining: an inbound deliver whose target is a still-pending answer
        // is queued until that answer resolves (ADR-0007). Runs after V1.0
        // classify so the resolver for the pipelined call's `resolve_me_desc` is
        // already installed before the frame is released.
        if (decoded_body == .deliver and try self.maybeEnqueuePipelinedCall(decoded_body.deliver)) {
            frame.deinit();
            return;
        }

        // An inbound `op:deliver` to our bootstrap export carrying `['fetch
        // <swissnum>]` is a bootstrap-fetch we answer automatically (ADR-0006
        // responder half). Runs after pipelining so a pipelined call is never
        // mistaken for a bootstrap fetch, and after V1.0 classify so a
        // resolver-only fetch has its virtual answer installed.
        const bootstrap_action: ?bootstrap.Action = if (decoded_body == .deliver)
            try bootstrap.pendingBootstrapAction(decoded_body.deliver, &self.session_state)
        else
            null;

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

        if (bootstrap_action) |action| {
            switch (action) {
                .fetch => |req| try self.sendCopying(bootstrap.resolveForSwissnum(&self.session_state, req)),
                .deposit_gift => |req| {
                    const maybe_msg = if (self.handoff_gifts) |gifts|
                        try bootstrap.resolveForDepositWithRegistry(&self.session_state, gifts, req)
                    else
                        try bootstrap.resolveForDeposit(&self.session_state, req);
                    if (maybe_msg) |msg| {
                        try self.sendCopying(msg);
                    }
                },
                .withdraw_gift => |req| {
                    const msg = if (self.handoff_gifts) |gifts|
                        try bootstrap.resolveForWithdrawWithRegistry(self.allocator, &self.session_state, gifts, req)
                    else
                        try bootstrap.resolveForWithdraw(self.allocator, &self.session_state, req);
                    try self.sendCopying(msg);
                },
            }
        }
    }

    /// Classify an inbound V1.0 deliver. Returns the answer-id a resolver-callback
    /// resolves — the caller surfaces a semantic `Resolve` — or null for an
    /// ordinary deliver, first installing the partner's resolver import if the
    /// deliver advertised one in `resolve_me_desc`.
    fn classifyInboundV1_0Deliver(self: *Peer, deliver: model.view.Deliver) !?u64 {
        if (referencePosition(deliver.target)) |position| {
            if (self.session_state.answerForResolverExport(position)) |answer| {
                return answer;
            }
        }
        if (deliver.resolve_me_desc) |rmd| {
            if (referencePosition(rmd)) |import_id| {
                // V1.0 resolver: the partner introduces their resolver export as
                // our import. Use the deliver's answer if present; otherwise
                // allocate a fresh virtual answer (the V1.0 fetch-with-resolver
                // pattern the OCapN suite uses: no answer-position on the wire,
                // only a resolve-me-desc).
                const answer = deliver.answer orelse blk: {
                    const virtual = self.session_state.allocateInboundAnswer();
                    // Install before the resolver row below: a swallowed failure
                    // here would leave `v1_0_inbound_resolvers` referencing a
                    // virtual answer absent from `inbound_answers`, breaking the
                    // authoritative-state invariant on OOM.
                    try self.session_state.installInboundAnswer(virtual);
                    break :blk virtual;
                };
                try self.session_state.installInboundResolver(answer, import_id);
            }
        }
        return null;
    }

    pub fn pollEvent(self: *Peer) ?Event {
        return self.events.pop();
    }

    /// The kind of the next queued event without consuming it, so a caller can
    /// route to a kind-specific decode (the C ABI's typed `poll_event_*` path).
    pub fn peekEventKind(self: *Peer) ?EventKind {
        return (self.events.peek() orelse return null).tag;
    }
};

/// The export/import position a reference names, or null for a pipeline promise.
/// Mirrors the V1.0 resolver-callback target lookup: both a near export and a far
/// import collapse to the bare position id the resolver bookkeeping is keyed on.
fn referencePosition(reference: model.view.Reference) ?u64 {
    return switch (reference) {
        .near => |near| near.export_id,
        .far => |far| far.import_id,
        .promise, .sturdy, .broken => null,
    };
}

/// Project a V1.0 resolver-callback deliver's args (`['fulfill, payload]` or
/// `['break, <error>]`) into a borrowed [`model.view.Resolution`] over the
/// frame. The tag is a `symbol` on the neutral view (the reduced legacy decoder
/// collapsed it to `bytes`).
fn resolutionFromResolverCallback(
    args: model.view.Args,
) model.view.ProjectError!model.view.Resolution {
    const tag_arg = try args.at(0);
    const payload = try args.at(1);
    const tag_symbol = switch (tag_arg) {
        .symbol => |symbol| symbol,
        else => return error.MalformedView,
    };
    if (std.mem.eql(u8, tag_symbol, "fulfill")) {
        return .{ .fulfill = payload };
    }
    if (std.mem.eql(u8, tag_symbol, "break")) {
        // The break reason is whatever the resolver was given. pancake encodes its
        // own breaks as a `desc:error`, but a real Goblins promise that breaks from
        // a thrown exception marshals the reason as a record (e.g.
        // `<exn:fail:mystery …>`) or any other passable — not a `desc:error`. So
        // accept any payload and render it to the break's message rather than
        // faulting the dispatch: an error carries its message, a string/symbol its
        // text, a tagged record its tag, and anything else a generic label. The
        // rendered bytes are borrowed from the frame (or static) and duped by the
        // caller's `toOwned`. The full structure of a non-error reason is not
        // preserved — `model.Resolution.break_` is a message — only its label.
        const message: []const u8 = switch (payload) {
            .@"error" => |err| err.message,
            .string, .symbol, .keyword => |text| text,
            .tagged => |tagged| tagged.tag,
            else => "remote promise broken",
        };
        return .{ .break_ = .{ .message = message } };
    }
    return error.MalformedView;
}

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
    };
}

/// Verify the partner's `op:start-session` location signature: real Ed25519 over
/// the canonical `<my-location …>` wrapping of the *exact received* location
/// bytes (`acceptable_location_raw`), against the claimed `session_pubkey`. A
/// malformed key/signature, an absent raw capture (non-Syrup projection), or a
/// failed check is `InvalidStartSessionSignature`, which the abort projection
/// maps to a handshake-time `invalid_start_session_signature`. Allocates the
/// canonical bytes transiently; nothing is retained.
fn verifyPartnerStartSession(allocator: std.mem.Allocator, ss: model.view.StartSession) !void {
    const crypto = foundation.crypto;
    const pubkey = crypto.PeerKey.fromSlice(ss.session_pubkey) catch
        return error.InvalidStartSessionSignature;
    const sig = switch (ss.acceptable_location_sig) {
        .halves => |h| crypto.Signature.fromParts(h.r, h.s) catch
            return error.InvalidStartSessionSignature,
        .raw => |raw| blk: {
            if (raw.len != crypto.SIGNATURE_BYTES) return error.InvalidStartSessionSignature;
            break :blk crypto.Signature.fromBytes(raw[0..crypto.SIGNATURE_BYTES].*);
        },
    };
    if (ss.acceptable_location_raw.len == 0) return error.InvalidStartSessionSignature;
    const signed = try codec.syrup.canonicalLocationSignedBytesRaw(allocator, ss.acceptable_location_raw);
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
            errdefer allocator.free(storage);
            return foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));
        },
        .word => {
            const storage = try allocator.alignedAlloc(u8, .fromByteUnits(8), frame.bytes.len);
            errdefer allocator.free(storage);
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
