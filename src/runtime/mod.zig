const std = @import("std");

const codec = @import("../codec/mod.zig");
const foundation = @import("../foundation/mod.zig");
const model = @import("../model/mod.zig");
const session = @import("../session/mod.zig");

pub const abort_projection = @import("abort_projection.zig");
pub const bootstrap = @import("bootstrap.zig");
pub const cross_peer = @import("cross_peer.zig");
pub const factories = @import("factories.zig");
pub const fetch = @import("fetch.zig");
pub const negotiation = @import("negotiation.zig");
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
/// materialization (`decodeOwned`) happens only when the caller asks. The runtime
/// never stores a decoded copy alongside the frame, and the C ABI hands the frame
/// bytes back without re-encoding, so the event surface stays codec-neutral and
/// copy-free past the single retain.
pub const Event = struct {
    frame: foundation.Frame,
    tag: EventKind,
    /// The codec that carried `frame` — the session's negotiated
    /// [`model.CodecId`] (Invariant 4). `view` / `decodeOwned` route through
    /// the codec-dispatch seam on it, so the event surface stays codec-neutral.
    codec: model.CodecId,
    /// Off-wire answer-id for a Goblins V1.0 resolver-callback (ADR-0023). V1.0
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

pub const Peer = struct {
    allocator: std.mem.Allocator,
    session_state: session.Session,
    inbound: std.ArrayList(foundation.Frame),
    inbound_head: usize,
    pending_send: std.ArrayList(model.Message),
    pending_send_head: usize,
    outbound: std.ArrayList(foundation.Frame),
    outbound_head: usize,
    events: std.ArrayList(Event),
    events_head: usize,
    /// Resolutions forwarded for handoff-imported promises (ADR-0009) awaiting
    /// the cross-peer [`cross_peer.drainRelayedResolutions`] drain. Each entry
    /// owns its resolution until drained.
    pending_relayed_resolutions: std.ArrayList(cross_peer.PendingRelayedResolution),
    /// Bounds the chain of local deliveries a single resolution can trigger
    /// (a drained pipelined call resolving to a local export, whose own
    /// resolution drains more calls). Capped by `SessionLimits.max_local_deliveries`.
    local_delivery_depth: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Peer {
        return initWithSession(allocator, session.Session.init(allocator));
    }

    /// A peer that begins in the `negotiating` state on the canonical Goblins
    /// v1.0 wire profile, awaiting the `op:start-session` handshake. The
    /// in-process handshake driver ([`factories`]) constructs both peers this
    /// way before shuttling their handshake frames to quiescence.
    pub fn initNegotiating(allocator: std.mem.Allocator) Peer {
        return initNegotiatingWithFeatures(allocator, model.FeatureSet.full());
    }

    /// A negotiating peer on the canonical Goblins v1.0 wire profile whose
    /// session carries the handshake-negotiated `features` (the intersection
    /// computed by [`negotiation.negotiate`]). Both peers of a pair must be
    /// constructed with the *same* negotiated set so neither exercises a
    /// capability the other did not advertise.
    pub fn initNegotiatingWithFeatures(allocator: std.mem.Allocator, features: model.FeatureSet) Peer {
        return initNegotiatingWithCodecAndFeatures(allocator, .syrup, features);
    }

    /// As [`initNegotiatingWithFeatures`], recording the handshake-negotiated
    /// [`model.CodecId`] so the peer's session dispatches its frames to the
    /// chosen codec (Invariant 4). Both peers of a pair must negotiate the same
    /// codec — the in-process driver ([`factories`]) constructs them from one
    /// [`negotiation.Negotiated`].
    pub fn initNegotiatingWithCodecAndFeatures(
        allocator: std.mem.Allocator,
        codec_id: model.CodecId,
        features: model.FeatureSet,
    ) Peer {
        return initWithSession(allocator, session.Session.initNegotiatingWithCodecProfileAndFeatures(
            allocator,
            codec_id,
            model.WireProfile.v1_0,
            features,
        ));
    }

    pub fn initWithSession(allocator: std.mem.Allocator, session_state: session.Session) Peer {
        return .{
            .allocator = allocator,
            .session_state = session_state,
            .inbound = .empty,
            .inbound_head = 0,
            .pending_send = .empty,
            .pending_send_head = 0,
            .outbound = .empty,
            .outbound_head = 0,
            .events = .empty,
            .events_head = 0,
            .pending_relayed_resolutions = .empty,
        };
    }

    pub fn deinit(self: *Peer) void {
        for (self.inbound.items[self.inbound_head..]) |*frame| {
            frame.deinit();
        }
        self.inbound.deinit(self.allocator);

        for (self.pending_send.items[self.pending_send_head..]) |*message| {
            freeMessage(self.allocator, message.*);
        }
        self.pending_send.deinit(self.allocator);

        for (self.outbound.items[self.outbound_head..]) |*frame| {
            frame.deinit();
        }
        self.outbound.deinit(self.allocator);

        for (self.events.items[self.events_head..]) |*event| {
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
        // recorded + enqueued through this same path (ADR-0007 § Decision 1).
        // The Cap'n Proto codec (not implemented) is the only shape that would
        // carry a path operand directly, without decomposition.
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

        try self.pending_send.append(self.allocator, message);
        owned_needs_free = false;
        var appended = true;
        errdefer if (appended) freeMessage(self.allocator, self.pending_send.pop().?);

        try self.session_state.recordSend(message);
        appended = false;
    }

    /// Decompose a multi-hop pipelined deliver and enqueue each single-hop link
    /// in send order (ADR-0007 § Decision 1), taking ownership of `message`. Each
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

    /// Expose a local capability behind `swissnum` for inbound bootstrap-fetch
    /// (ADR-0006 responder half). Allocates a fresh export, maps the swissnum to
    /// it, and returns the export id. The adapter calls this at config time; an
    /// inbound `'fetch` for the swissnum is then served automatically by
    /// `dispatchOwnedFrameInner`.
    pub fn registerBootstrapCap(self: *Peer, swissnum: []const u8) !u64 {
        return self.session_state.registerBootstrapCap(swissnum);
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
        try self.inbound.append(self.allocator, frame);
    }

    pub fn step(self: *Peer) !StepOutcome {
        if (self.inbound_head != self.inbound.items.len) {
            const frame = self.inbound.items[self.inbound_head];
            self.inbound_head += 1;
            // Transfer ownership into dispatch: on success the frame moves into
            // the surfaced event (zero copy); on error dispatch frees it.
            try self.dispatchOwnedFrame(frame);
            return .progress;
        }
        // Inbound fully drained: reclaim the backing slots. Consumed frames were
        // moved out (into events or freed on error), so the stale values below
        // the head are not owned here and clearing never double-frees.
        reclaimDrained(foundation.Frame, &self.inbound, &self.inbound_head);

        if (self.pending_send_head == self.pending_send.items.len) {
            reclaimDrained(model.Message, &self.pending_send, &self.pending_send_head);
            return .idle;
        }

        const message = self.pending_send.items[self.pending_send_head];
        self.pending_send_head += 1;
        defer freeMessage(self.allocator, message);

        // Goblins V1.0 has no wire `op:resolve`: a semantic `Resolve` ships as an
        // `op:deliver` to the partner's resolver import. The 2-element arg list
        // lives on the stack for the encode call only; its payload borrows
        // `message`, which the `defer` above frees after encode completes.
        if (self.session_state.needsV1_0Translation() and message == .resolve) {
            try self.encodeResolverCallback(message.resolve);
        } else {
            const wire_message = try self.prepareOutboundWireMessage(message);
            var frame = try codec.dispatch.encodeMessageForProfile(
                self.session_state.codec,
                self.allocator,
                self.session_state.wire_profile,
                wire_message,
            );
            errdefer frame.deinit();
            try self.outbound.append(self.allocator, frame);
        }

        // A sent `op:resolve` settles one of our inbound answers; drain the calls
        // the partner pipelined against it, then fire its listeners (ADR-0007
        // § Decision 5 — calls first, since a drained call may settle further
        // answers). The resolution frame is already on `outbound`, so a drain
        // refusal surfaces as a step error without un-sending the resolution.
        if (message == .resolve) {
            try self.drainPipelinedCalls(message.resolve);
            try self.fireListenersOnResolve(message.resolve);
        }
        return .progress;
    }

    /// Encode a semantic `Resolve` as its V1.0 resolver-callback `op:deliver`
    /// (ADR-0023), addressed to the partner's resolver import recorded when their
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
        try self.outbound.append(self.allocator, frame);
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
                if (self.session_state.inboundAnswer(answer) == null) return;
                const position = referencePosition(listen.listener) orelse return;
                // Idempotent register, then a POD `far` listener target — no heap.
                try self.session_state.registerImport(position);
                try self.session_state.installListener(answer, .{
                    .target = .{ .far = model.FarRef.object(position) },
                    .wants_partial = listen.wants_partial,
                });
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
            // A listen on `<desc:export>` (our own export) decodes to `near`
            // post-flip; export listeners are not implemented, so it falls
            // through unchanged. A sturdy / broken listener target is never a
            // valid listen target.
            .near, .sturdy, .broken => return,
        }
    }

    /// Enqueue an inbound `op:deliver` that pipelines against a still-pending
    /// answer, returning whether it was handled. A non-promise target, an
    /// unknown answer, or an already-resolved answer returns `false` (the caller
    /// surfaces it normally). On `true` the owned message lives on the answer's
    /// queue; an enqueue refusal (e.g. cap) propagates and the session frees it.
    fn maybeEnqueuePipelinedCall(self: *Peer, deliver: model.view.Deliver) !bool {
        if (deliver.target != .promise) return false;
        const answer = deliver.target.promise.answer_id;
        const entry = self.session_state.inboundAnswer(answer) orelse return false;
        if (entry.status != .pending) return false;
        const body = model.view.Body{ .deliver = deliver };
        const owned = try body.toOwned(self.allocator);
        try self.session_state.enqueuePipelinedCall(answer, owned);
        return true;
    }

    /// Drain the calls the partner pipelined against the answer a just-sent
    /// `op:resolve` settles, dispatching each against the resolution (ADR-0007
    /// § Decision 5). Queued inbound targets always carry an empty path: a
    /// multi-hop pipeline is decomposed at the *sender* into single-hop frames
    /// ([`sendDecomposedPipeline`]), so every `desc:answer` on the wire is flat.
    fn drainPipelinedCalls(self: *Peer, resolve: model.Resolve) !void {
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
        try self.events.append(self.allocator, .{ .frame = frame, .tag = .deliver, .resolve_answer = null, .codec = self.session_state.codec });
        self.local_delivery_depth += 1;
    }

    /// Drain the listeners registered against the answer a just-sent
    /// `op:resolve` settles, firing each per the (resolution × `wants_partial`)
    /// matrix (ADR-0007 § Decision 5). Each fire moves onto `pending_send` via
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
        if (self.outbound_head == self.outbound.items.len) {
            reclaimDrained(foundation.Frame, &self.outbound, &self.outbound_head);
            return null;
        }
        const frame = self.outbound.items[self.outbound_head];
        self.outbound_head += 1;
        return frame;
    }

    /// Dispatch a borrowed inbound frame. The borrowed bytes are transient, so
    /// the runtime copies them once into an owned frame to retain the event. This
    /// is the single intentional copy on the borrowed inbound path.
    pub fn recvBorrowed(self: *Peer, frame: foundation.FrameView) !void {
        const owned = try ownedFrameFromView(self.allocator, frame);
        try self.dispatchOwnedFrame(owned);
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
        self.outbound.append(self.allocator, frame) catch frame.deinit();
    }

    fn dispatchOwnedFrameInner(self: *Peer, frame_in: foundation.Frame) !void {
        var frame = frame_in;
        var stored = false;
        errdefer if (!stored) frame.deinit();

        const decoded_body = try codec.dispatch.decodeBody(self.session_state.codec, frame.view());

        // An inbound `op:listen` against one of our pending inbound answers
        // registers the listener so the resolution fires it (ADR-0007 §
        // op:listen). Installed before the event/`recordRecv` so a refusal
        // leaves nothing surfaced. Non-promise targets and listens on unknown
        // answers fall through to ordinary recv handling.
        if (decoded_body == .listen) {
            try self.maybeInstallInboundListener(decoded_body.listen);
        }

        // An inbound `op:deliver` whose target is a still-pending answer we owe
        // resolution for is a pipelined call (ADR-0007). We hold it owned on that
        // answer's queue until we resolve it, then drain + redirect it — so it
        // surfaces no application event now and the borrowed frame is released.
        if (decoded_body == .deliver and try self.maybeEnqueuePipelinedCall(decoded_body.deliver)) {
            frame.deinit();
            return;
        }

        // An inbound `op:deliver` to our bootstrap export carrying `['fetch
        // <swissnum>]` is a bootstrap-fetch we answer automatically (ADR-0006
        // responder half). Recognized here (borrowing the frame the event will
        // own); the synthesized `Resolve` is enqueued after `recordRecv` below so
        // the inbound answer is installed first. The deliver still surfaces as an
        // event for observability.
        const bootstrap_request: ?bootstrap.Request = if (decoded_body == .deliver)
            try bootstrap.pendingBootstrapRequest(decoded_body.deliver)
        else
            null;

        var tag = eventKindFromBody(decoded_body);
        var resolve_answer: ?u64 = null;

        // The session is codec-neutral and never sees codec views, so validation
        // works against an owned codec-neutral message materialized from the same
        // view (no second parse). It is released here and never retained; the
        // event keeps only the originating frame.
        //
        // Goblins V1.0 exception: an inbound deliver to one of our resolver
        // exports is the partner resolving an answer (ADR-0023). It validates as
        // a semantic `Resolve` whose answer-id comes from bookkeeping, not the
        // wire, so the session sees a borrowed `Resolve` projected from the frame
        // (no allocation, transient — `recordRecv` reads only the discriminant).
        var record_message: model.Message = undefined;
        var record_owned = false;
        if (self.session_state.needsV1_0Translation() and decoded_body == .deliver) {
            if (try self.classifyInboundV1_0Deliver(decoded_body.deliver)) |answer| {
                tag = .resolve;
                resolve_answer = answer;
                record_message = .{ .resolve = .{
                    .answer = answer,
                    .resolution = borrowedResolution(try resolutionFromResolverCallback(decoded_body.deliver.args)),
                } };
            } else {
                record_message = try decoded_body.toOwned(self.allocator);
                record_owned = true;
            }
        } else {
            record_message = try decoded_body.toOwned(self.allocator);
            record_owned = true;
        }
        defer if (record_owned) freeMessage(self.allocator, record_message);

        try self.events.append(self.allocator, .{ .frame = frame, .tag = tag, .resolve_answer = resolve_answer, .codec = self.session_state.codec });
        stored = true;
        var appended = true;
        errdefer if (appended) {
            var removed = self.events.pop().?;
            removed.frame.deinit();
        };

        try self.session_state.recordRecv(record_message);
        appended = false;

        if (bootstrap_request) |req| {
            try self.sendCopying(bootstrap.resolveForSwissnum(&self.session_state, req));
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
        if (deliver.answer) |answer| {
            if (deliver.resolve_me_desc) |rmd| {
                if (referencePosition(rmd)) |import_id| {
                    // The partner introduces their resolver export as our import;
                    // register it so the augmented deliver validates and we can
                    // address it when we resolve the answer.
                    try self.session_state.registerImport(import_id);
                    try self.session_state.installInboundResolver(answer, import_id);
                }
            }
        }
        return null;
    }

    pub fn pollEvent(self: *Peer) ?Event {
        if (self.events_head == self.events.items.len) {
            reclaimDrained(Event, &self.events, &self.events_head);
            return null;
        }
        const event = self.events.items[self.events_head];
        self.events_head += 1;
        return event;
    }
};

/// Reset a head-indexed queue once fully drained (`head == len`): clear the
/// backing list and rewind the head to 0 so a long-lived [`Peer`] reuses slots
/// instead of growing one entry per message processed. The entries below the
/// head were already moved out by their consumer, so clearing never frees them.
fn reclaimDrained(comptime T: type, list: *std.ArrayList(T), head: *usize) void {
    if (head.* == 0) return;
    list.clearRetainingCapacity();
    head.* = 0;
}

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
        return switch (payload) {
            .@"error" => |err| .{ .break_ = err },
            else => error.MalformedView,
        };
    }
    return error.MalformedView;
}

/// Lift a borrowed [`model.view.Resolution`] into a borrowed model
/// [`model.Resolution`] — no allocation; the payload still references the
/// originating frame. The session's resolve apply reads only the fulfill/break
/// discriminant, so the transient borrow is sufficient for `recordRecv`.
fn borrowedResolution(resolution: model.view.Resolution) model.Resolution {
    return switch (resolution) {
        .fulfill => |arg| .{ .fulfill = borrowedArgument(arg) },
        .break_ => |err| .{ .break_ = .{ .message = err.message } },
    };
}

fn borrowedReference(reference: model.view.Reference) model.Reference {
    return switch (reference) {
        .near => |near| .{ .near = near },
        .far => |far| .{ .far = far },
        .promise => |promise| .{ .promise = .{ .answer_id = promise.answer_id } },
        .sturdy => |sturdy| .{ .sturdy = .{
            .peer = .{
                .transport = sturdy.peer.transport,
                .designator = sturdy.peer.designator,
                .hints = sturdy.peer.hints,
            },
            .swissnum = sturdy.swissnum,
        } },
        .broken => |broken| .{ .broken = .{ .message = broken.message } },
    };
}

fn borrowedArgument(argument: model.view.Argument) model.Argument {
    return switch (argument) {
        .bytes => |bytes| .{ .bytes = bytes },
        .symbol => |symbol| .{ .symbol = symbol },
        .string => |string| .{ .string = string },
        .keyword => |keyword| .{ .keyword = keyword },
        .integer => |integer| .{ .integer = integer },
        .boolean => |boolean| .{ .boolean = boolean },
        .float64 => |float64| .{ .float64 = float64 },
        .void => .{ .void = {} },
        .reference => |reference| .{ .reference = borrowedReference(reference) },
        .@"error" => |err| .{ .@"error" = .{ .message = err.message } },
        // Container / handoff fulfill payloads cannot be borrowed as an owned
        // model slice; this projection feeds only `recordRecv`, which reads the
        // resolution discriminant and never the fulfill value, so collapsing to
        // void here is sound (the value is discarded).
        .list, .set, .tagged, .handoff => .{ .void = {} },
    };
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

/// Copy borrowed wire bytes into an owned frame that respects the frame shape's
/// alignment, so a surfaced event can outlive the borrowed inbound buffer.
fn ownedFrameFromView(allocator: std.mem.Allocator, frame: foundation.FrameView) !foundation.Frame {
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
// reaching up into the runtime. The outbound queue moves through `send`; the
// one boundary copy (`sendCopying`) goes through `cloneMessage`.
const cloneMessage = model.cloneMessage;
const freeMessage = model.freeMessage;
const freeResolution = model.freeResolution;
