//! The byte-fed Host session wire: the session shell, outbound frame drain,
//! transport-packet framing, stream delimiting, and retained-tail resumption.
//!
//! This is an internal owner. Consumers reach the supported type and verbs
//! through `host.zig`; sibling `pub` declarations provide only Zig cross-file
//! visibility and do not widen `driver.core`'s namespace.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");

const host_mod = @import("../host.zig");
const served_mod = @import("../served.zig");
const vocab = @import("../vocab.zig");
const publish = @import("../publish.zig");
const host_pump = @import("pump.zig");

const Host = host_mod.Host;
const HostError = host_mod.HostError;
const Served = served_mod.Served;
const crypto = foundation.crypto;

/// One packet-fed CapTP session shell: a node-registered peer under a `Served`
/// serve core, minted by `Host.openDialedLocator` /
/// `Host.openAcceptedAdvertised` and freed by `Host.releaseSession`. This is
/// not a `net.Connection` — it is the CapTP
/// partner the host routes and serves; the ABI name stays
/// `GlowcapHostSession`. The embedder writes what `takeTransportOutbound`
/// drains and feeds what it reads through `Host.feedTransportPacket` (never
/// the `Served` directly, so the host's action pump always runs).
pub const HostSession = struct {
    host: *Host,
    peer_handle: engine.PeerHandle,
    served: Served,
    /// The actual netlayer name this session was opened through. Owned by
    /// the shell; sturdyref peer equality includes it and never infers it from
    /// a partner's signed claim.
    transport: []const u8,
    role: Role,
    /// Compact accounting, lifecycle, and intrusive queue membership for this
    /// shell. See `ControlWord`; this is operational storage, not CapTP state.
    control: ControlWord = .{},
    /// The 32-byte seed of the key this session signs with: its keyed hello,
    /// and every handoff record naming this session (ADR-0097). Held per
    /// session because session identity and durable node identity are different
    /// facts. The Host derives it from a process-fresh, domain-separated root
    /// and monotonic counter; reconnecting cannot recreate an earlier session's
    /// key or side name.
    session_seed: [crypto.SEED_BYTES]u8 = undefined,
    /// The sealed byte channel this session's wire runs through (ADR-0107),
    /// or null for every unsealed session — one nullable pointer on the
    /// shell, with the channel itself heap-boxed only when a sealed transport
    /// is opened. Created by the open verbs in `sessions.zig`, freed with the
    /// shell.
    sealed: ?*foundation.sealed.SealedChannel = null,
    /// Transport-packet boundary semantics for this session, copied from the
    /// Host transport profile at mint time. Storing it here keeps the wire path
    /// allocation-free and lookup-free, including route-bundle dials
    /// after their selected concrete path has been opened.
    wire_framing: model.transport.WireFraming,
    /// Partner session key this shell is indexed under in `Host.partner_by_side`,
    /// set in `indexPartnerKey` (before apply writes `partnerSessionKey`).
    /// Lets `unindexSession` stay O(1) without scanning the map.
    indexed_partner_key: ?[crypto.PEER_KEY_BYTES]u8 = null,

    /// Encoded outbound bytes this session may leave parked before another
    /// application or inbound producer is refused. Minted with the peer's
    /// other limits: changing Host options later affects only future sessions.
    outbound_high_water_bytes: usize,

    /// The unconsumed stream tail `Host.feedBytes` keeps between chunks: a
    /// partial frame straddling two reads, or the frames one read coalesced
    /// behind the handshake hello (feeding stops at session-open). Owned by
    /// the shell and freed with it; capacity a burst grew past
    /// `steady_feed_tail_bytes` returns when the tail fully drains.
    ///
    /// It is the same `foundation.Spill` the `net` tier folds its parser over,
    /// which is why the boundedness ADR-0041 argues holds here too. The tiers
    /// differ only in what a drained tail keeps: a stream reader spills for an
    /// oversize frame and frees the burst, while straddling a chunk boundary is
    /// ordinary here, so this one keeps a steady size.
    feed_tail: foundation.Spill = .{},
    /// A complete frame remains in `feed_tail` because a prior frame in the
    /// same read crossed the outbound waterline or hit retryable pressure.
    /// The core queues a FLUSH wake; once the embedder has drained outbound,
    /// `takeStreamOutbound` resumes this tail under the ordinary Host latch.
    feed_resume_pending: bool = false,

    /// Which half of the handshake this session is, carrying the one datum
    /// only the dialing half has: the partner designator it dialed — the key
    /// the crossed-hellos tiebreak looks an outbound up by. Host-owned bytes,
    /// freed with the shell.
    pub const Role = union(enum) {
        dialed: []const u8,
        accepted,
    };

    /// Application lifecycle above the peer's negotiating/open/closed protocol
    /// state. A released shell has no observable `closed` phase.
    pub const LifecyclePhase = enum(u2) { active, finishing, cancel_pending, terminating };

    /// One compact control word per session. The operation ceiling is an
    /// explicit admission boundary: reaching it refuses the next operation
    /// before that operation can commit. The remaining bits are existing
    /// intrusive memberships and one-shot facts; packing them together keeps
    /// session close inside the footprint budget.
    const ControlWord = packed struct(u32) {
        pending_operations: u24 = 0,
        phase: LifecyclePhase = .active,
        /// The Port's Vat ingress was removed by condemnation/teardown.
        ingress_cancelled: bool = false,
        /// Intrusive membership in the Host's encode-work FIFO.
        flush_pending: bool = false,
        /// Intrusive embedder-action memberships.
        flush_action_pending: bool = false,
        close_action_pending: bool = false,
        /// The live trace reported this session's open.
        trace_open_noted: bool = false,
        /// An admitted session-open operation is still pending: set beside
        /// `beginSessionOperation` when the shell enrolls, retired by
        /// `finishSessionOpen`.
        open_pending: bool = false,
    };

    pub fn lifecyclePhase(self: *const HostSession) LifecyclePhase {
        return self.control.phase;
    }

    pub fn pendingOperations(self: *const HostSession) u24 {
        return self.control.pending_operations;
    }

    pub fn isTerminating(self: *const HostSession) bool {
        return self.lifecyclePhase() == .terminating;
    }

    pub fn ingressCancelled(self: *const HostSession) bool {
        return self.control.ingress_cancelled;
    }

    pub fn captpVersion(self: *const HostSession) model.CaptpVersion {
        return self.served.port.peer.session_state.captp_version;
    }

    /// The profile this session settled with its partner. Before the keyed
    /// handshake opens, the session fields still carry negotiation inputs and
    /// are not an observable profile.
    pub fn settledProfile(self: *const HostSession) ?engine.negotiation.Negotiated {
        if (!self.sessionOpen()) return null;
        const state = self.served.port.peer.session_state;
        return .{
            .captp_version = state.captp_version,
            .codec = state.codec,
            .features = state.features,
        };
    }

    pub fn lastAbort(self: *const HostSession) ?engine.AbortInfo {
        return self.served.port.peer.lastAbort();
    }

    /// Drain one encoded outbound frame for the embedder to write, or null
    /// when the queue is empty. Owned: the caller frees the returned frame.
    /// Top-level: refused under the callback latch — the enclosing verb's
    /// unwind is still encoding, so a mid-callback drain would race it.
    ///
    /// On a sealed session (ADR-0107) what drains is wire bytes the embedder
    /// writes verbatim, with no outer framing of its own: the pending
    /// handshake message first, then each encoded frame sealed into records
    /// (the outer Syrup prefix rides inside the plaintext). Until the
    /// handshake completes, encoded CapTP frames stay queued and this returns
    /// null once the handshake bytes drain. A frame that cannot be sealed is
    /// unrecoverable — it has left the queue and no plaintext may follow —
    /// so the session is condemned without an abort echo and the caller sees
    /// `SealedChannelFailed` (or the allocation failure that forced it).
    pub fn takeOutbound(self: *HostSession) HostError!?foundation.Frame {
        try self.host.refuseReentry();
        // Taking bytes is what makes queued pressure actionable, so a refused
        // resume pump gets its bounded retry (see `Host.resume_pump_refused`),
        // and the Node actions this session's pressure parked come back to the
        // queue on the seats their parking reserved (ADR-0145).
        self.host.resume_pump_refused = false;
        host_pump.requeueParkedNodeActions(self.host, self.peer_handle);
        const channel = self.sealed orelse {
            const frame = self.served.takeOutbound() orelse return null;
            self.traceOutboundFrame(&frame);
            return frame;
        };
        if (channel.takeWire(self.host.allocator) catch return HostError.OutOfMemory) |wire| return wire;
        if (!channel.isOpen()) return null;
        var frame = self.served.takeOutbound() orelse return null;
        self.traceOutboundFrame(&frame);
        defer frame.deinit();
        return channel.sealFrame(self.host.allocator, frame.bytes()) catch |err| {
            channel.fail();
            host_pump.retireSealedSession(self.host, self);
            return if (err == error.OutOfMemory) HostError.OutOfMemory else HostError.SealedChannelFailed;
        };
    }

    /// One transport-ready packet: `prefixBytes()` followed by the owned
    /// payload. Clear byte streams carry the canonical outer Syrup byte-string
    /// prefix; message-framed transports and sealed channels use an empty
    /// prefix. This is the sole authority for that distinction.
    pub const TransportOutbound = struct {
        payload: foundation.Frame,
        prefix: [foundation.stream_framing.prefix_buffer_bytes]u8 = undefined,
        prefix_len: usize = 0,

        pub fn prefixBytes(self: *const TransportOutbound) []const u8 {
            return self.prefix[0..self.prefix_len];
        }
    };

    pub const StreamOutbound = TransportOutbound;

    pub fn takeStreamOutbound(self: *HostSession) HostError!?StreamOutbound {
        while (true) {
            if (try self.takeOutbound()) |payload| {
                var outbound = StreamOutbound{ .payload = payload };
                if (self.sealed == null) {
                    outbound.prefix_len = foundation.stream_framing.renderPrefix(
                        &outbound.prefix,
                        payload.bytes().len,
                    ).len;
                }
                return outbound;
            }
            if (!self.feed_resume_pending) return null;
            try resumeFeedTail(self.host, self);
        }
    }

    pub fn takeTransportOutbound(self: *HostSession) HostError!?TransportOutbound {
        return switch (self.wire_framing) {
            .byte_stream => self.takeStreamOutbound(),
            .message => if (try self.takeOutbound()) |payload|
                TransportOutbound{ .payload = payload }
            else
                null,
        };
    }

    /// Resume input already retained by a previous feed, without treating an
    /// empty transport packet as new input. Byte streams may have a held tail;
    /// message-framed transports never do.
    pub fn resumeFeed(self: *HostSession) !void {
        try self.host.refuseReentry();
        try self.host.checkSession(self);
        if (self.wire_framing != .byte_stream) return;

        const was_open = self.served.port.peer.sessionIsOpen();
        if (self.feed_tail.isActive() or self.feed_resume_pending) {
            try resumeFeedTail(self.host, self);
            if (!was_open and self.served.port.peer.sessionIsOpen()) return;
        }
        if (self.sealed) |channel| {
            if (channel.hasStagedInbound()) {
                try self.host.feedBytes(self, &.{});
                if (!was_open and self.served.port.peer.sessionIsOpen()) return;
            }
            if (was_open and self.feed_tail.isActive())
                try resumeFeedTail(self.host, self);
        }
    }

    /// The live trace's outbound seat — the mirror of the inbound seat in
    /// `hostBeforeServe`: every frame leaves through this drain, so a
    /// deliver's verb and wire bytes are reported here, where the encoded
    /// frame exists. A send-time fact would predate the deferred encode
    /// (no bytes to report) and would report near sends that never touch
    /// the wire. One borrowed view decode per outbound frame, paid only
    /// while a sink is installed; a non-deliver frame or one without a
    /// symbol verb is protocol traffic the trace skips, as inbound.
    fn traceOutboundFrame(self: *HostSession, frame: *const foundation.Frame) void {
        const host = self.host;
        if (host.trace_sink == null) return;
        const state = self.served.port.peer.session_state;
        // best-effort: tracing is observation only; a frame the tap cannot
        // decode is skipped, never the send it observes.
        const body = engine.decodeBodyView(state.codec, state.captp_version, frame.view()) catch return;
        if (body != .deliver) return;
        // best-effort: the same observation-only skip as the decode above.
        const first = body.deliver.args.at(0) catch return;
        if (first != .symbol) return;
        host.traceMessage(self, true, first.symbol, frame.bytes());
    }

    /// Whether the keyed handshake has completed and the session is open.
    pub fn sessionOpen(self: *const HostSession) bool {
        return self.served.port.peer.sessionIsOpen();
    }

    /// Whether the CapTP session is terminal while this byte-fed shell remains
    /// retained for final transport work and explicit release.
    pub fn sessionClosed(self: *const HostSession) bool {
        return self.served.port.peer.sessionIsClosed();
    }

    /// The key this session signs with (ADR-0097). One derivation from
    /// `session_seed`, so the hello signature and every handoff record naming
    /// this session are made by the same key, and no caller reaches for the
    /// node's durable key to stand in for it.
    pub fn sessionSecret(self: *const HostSession) crypto.SecretKey {
        return crypto.SecretKey.fromSeed(self.session_seed);
    }

    /// Whether inbound bytes are parked where no readiness wait can see them:
    /// paused outer frames in `feed_tail`, or a sealed session's staged
    /// channel bytes (ADR-0107). An embedder resumes them through
    /// `HostSession.resumeFeed`; every byte-fed pump asks this one question
    /// instead of reaching into the two owners separately.
    pub fn pausedInboundPending(self: *const HostSession) bool {
        if (self.feed_tail.isActive()) return true;
        if (self.sealed) |channel| return channel.hasStagedInbound();
        return false;
    }
};

/// Encode `session`'s enqueued outbound and queue its flush action — the public
/// entry point for the pump every host verb ends with, for an embedder (the
/// owning face, ADR-0090) that drove the served core directly with a
/// session-local verb and owes the wire the encode.
pub fn flushSession(self: *Host, session: *HostSession) !void {
    // Latch-legal on purpose, like the `dirtyThenPump` it invokes: a nested
    // verb inside a listener enqueues, and the enclosing top-level verb's
    // unwind encodes — so a session verb that ends in this flush keeps working
    // from callback context, the same contract the old owning tier's pure
    // `served.*` forwards carried.
    self.assertOwner();
    try self.checkSession(session);
    try host_pump.dirtyThenPump(self, session.peer_handle);
}

/// Break every far vow still parked on `session`'s Vat. The partner's retained
/// abort diagnostic wins when one arrived; otherwise `message` is used.
pub fn breakFarVows(self: *Host, session: *HostSession, message: []const u8) !void {
    try self.refuseReentry();
    try self.checkSession(session);
    self.in_callback = true;
    session.served.port.breakFarVows(session.served.closeReason(message));
    self.in_callback = false;
    try host_pump.finishVerb(self);
}

/// Apply the core-owned terminal consequences of an adapter-observed physical
/// transport loss. The adapter reports the fact; the Host seals admission,
/// retires routing authority, breaks pending work, and queues the idempotent
/// close notification here.
pub fn transportClosed(self: *Host, session: *HostSession, message: []const u8) !void {
    try self.refuseReentry();
    try self.checkOwnedSession(session);
    self.in_callback = true;
    var first_error: ?anyerror = null;
    host_pump.retireTransportClosed(self, session, session.served.closeReason(message)) catch |err| {
        first_error = err;
    };
    self.in_callback = false;
    host_pump.finishVerb(self) catch |err| {
        if (first_error == null) first_error = err;
    };
    if (first_error) |err| return err;
}

/// The verified session signer, its signed locator claim, and any matching
/// authenticated-channel provenance. Returned views borrow session-owned bytes
/// and remain valid until the session is released.
pub fn partnerIdentity(self: *Host, session: *HostSession) !vocab.PartnerIdentity {
    self.assertOwner();
    try self.checkSession(session);
    const peer = session.served.port.peer;
    if (!peer.verify_partner_handshake) return HostError.PartnerUnverified;
    const key = peer.session_state.partnerSessionKey() orelse
        return HostError.HandshakeIncomplete;
    const designator = peer.session_state.partnerDesignator() orelse "";
    return .{
        .session_key = key,
        .designator = designator,
        .locator_record = peer.session_state.partnerLocatorRaw() orelse "",
        .provenance = publish.durableProvenance(peer, designator),
    };
}

/// Record the durable key proved by the realizer of `session`'s byte channel
/// (ADR-0105). This must arrive before the partner hello is applied; repeating
/// the same evidence is idempotent and conflicting evidence is refused.
pub fn bindVerifiedChannelKey(self: *Host, session: *HostSession, designator: []const u8) !void {
    self.assertOwner();
    try self.checkSession(session);
    const key = crypto.PeerKey.fromDesignator(designator) orelse
        return HostError.InvalidChannelKey;
    // A sealed channel already testified during its handshake. An embedder may
    // repeat the same fact, but cannot introduce a second realizer.
    if (session.sealed != null) {
        if (session.served.port.peer.verifiedChannelKey()) |existing| {
            if (existing.eql(key)) return;
        }
        return HostError.ChannelKeyConflict;
    }
    const peer = session.served.port.peer;
    if (peer.session_state.partnerDesignator() != null)
        return HostError.HandshakeAlreadyApplied;
    if (peer.verifiedChannelKey()) |existing| {
        if (!existing.eql(key)) return HostError.ChannelKeyConflict;
        return;
    }
    peer.bindVerifiedChannelKey(key);
}

/// Per-session static-footprint ceiling for the byte-fed host shell. It is
/// the third per-session static allocation on the 500k Bridge path (ADR-0076),
/// beside `engine.Peer` (gated at 1 KiB in `engine`) and the completion loop's
/// `Conn` wrapper (gated at 128 bytes of overhead in `net.completion`). One
/// `HostSession`, and therefore one inline `Served` Port, is minted per adopted
/// session in `mintShell`; the Vat is Host-wide and charged once per Host.
/// `engine.Peer` itself lives behind a pointer here, gated on its own. Crossing
/// this ceiling is a design event that raises the budget here and in
/// `docs/ladder.md` step 2 together, with the bytes justified, never a check to
/// route around.
/// The shell holds per-session identity, lifecycle, and Port state. Answer
/// notification consumption lives on existing Session rows. The Port keeps
/// one answer cutoff for bulk breaks. Its indexed listener map costs 16 bytes
/// more than a hash map header and supports O(1) removal during a cancellable
/// bulk drain. No completed-answer map is retained.
pub const host_session_struct_budget_bytes = 528;
comptime {
    if (@sizeOf(HostSession) > host_session_struct_budget_bytes) @compileError(std.fmt.comptimePrint(
        "driver_core.HostSession is {d} bytes, over the {d}-byte per-session shell budget (docs/ladder.md step 2). " ++
            "A larger shell is a withdrawal from the 500k footprint budget; raise the source constant and documented budget together.",
        .{ @sizeOf(HostSession), host_session_struct_budget_bytes },
    ));
}

/// Retained-capacity bound for a session's `feed_tail` between bursts — the
/// engine's steady-queue posture at the byte-fed tier. A burst that grew the
/// tail past this frees the excess when the tail drains, at the price of one
/// growth re-allocation when the next burst begins.
const steady_feed_tail_bytes: usize = 4096;

/// Apply one borrowed frame, then drive the event and outbound consequences
/// that frame committed. Only receive/admission errors escape as retryable for
/// the caller's bytes. Once `recvBorrowed` succeeds, local allocator or
/// outbound pressure parks the remaining drive on the Host dirty queue instead
/// of making an applied frame look unconsumed.
pub fn feedBorrowedCommitted(session: *HostSession, frame: foundation.FrameView) !void {
    try session.served.port.peer.recvBorrowed(frame);
    session.served.driveFed(&session.host.vat) catch |err| switch (err) {
        error.OutOfMemory, error.OutboundBackpressure => {
            host_pump.markDirty(session.host, session.peer_handle);
            return;
        },
        error.EventServeOutOfMemory => return err,
        else => {
            // The frame is authoritative and cannot be replayed. Give a
            // protocol-shaped failure its typed abort; a host-internal error
            // has no wire projection, but still closes this consumed session.
            session.served.port.peer.emitFailure(err);
            if (session.served.port.peer.sessionIsOpen())
                session.served.port.peer.closeSession();
            return err;
        },
    };
}

/// Feed one plaintext stream chunk through the tail-and-parse machinery: with
/// no pending tail, parse the borrowed chunk in place and retain only an
/// incomplete suffix; while a tail is active, extend it (the one bounded
/// copy) and parse from there. The one body both `Host.feedBytes` arms share:
/// the unsealed verb hands it the caller's bytes, the sealed arm each opened
/// record's plaintext.
pub fn feedStreamChunk(gpa: std.mem.Allocator, session: *HostSession, bytes: []const u8, was_open: bool) !void {
    const tail = &session.feed_tail;
    if (!tail.isActive()) {
        const parsed = try parseOuterStreamPrefix(session, bytes, was_open);
        if (parsed.consumed < bytes.len) {
            try tail.absorbBytes(gpa, bytes[parsed.consumed..]);
            if (parsed.needs_resume) host_pump.scheduleFeedResume(session.host, session);
        }
        return;
    }
    try tail.absorbBytes(gpa, bytes);
    const parsed = try parseOuterStreamPrefix(session, tail.bytes(), was_open);
    tail.consume(gpa, parsed.consumed, steady_feed_tail_bytes);
    if (parsed.needs_resume) host_pump.scheduleFeedResume(session.host, session);
}

/// Delimit and dispatch complete outer Syrup byte strings from `bytes`. Each
/// body is exactly one bare codec frame. The opening hello remains the pause
/// boundary, so any following outer frames stay in the caller-owned tail.
const StreamParse = struct {
    consumed: usize,
    /// The suffix starts with a complete frame held only by local pressure,
    /// rather than an incomplete frame or the post-handshake setup boundary.
    needs_resume: bool = false,
};

fn parseOuterStreamPrefix(session: *HostSession, bytes: []const u8, was_open: bool) !StreamParse {
    var consumed: usize = 0;
    while (consumed < bytes.len) {
        // A prior frame in this same chunk may have crossed the waterline.
        // Stop before dispatching another frame; the caller retains the suffix
        // in `feed_tail`, so replay is neither required nor permitted.
        if (consumed != 0 and session.served.queuedOutboundBytes() >= session.outbound_high_water_bytes)
            return .{ .consumed = consumed, .needs_resume = true };
        const outer = switch (foundation.stream_framing.parsePrefix(
            bytes[consumed..],
            session.served.port.peer.limits().max_frame_bytes,
        )) {
            .incomplete => break,
            .malformed => {
                session.served.port.peer.emitFailure(error.MalformedFrame);
                session.served.port.peer.stepToIdle() catch |err| session.served.port.peer.recordFailure(err);
                return error.MalformedFrame;
            },
            .too_large => {
                session.served.port.peer.emitFailure(error.FrameTooLarge);
                session.served.port.peer.stepToIdle() catch |err| session.served.port.peer.recordFailure(err);
                return error.FrameTooLarge;
            },
            .decoded => |decoded| decoded,
        };
        const shape = engine.frameShape(session.served.port.peer.inboundCodec()) orelse {
            session.served.port.peer.emitFailure(error.MalformedFrame);
            session.served.port.peer.stepToIdle() catch |err| session.served.port.peer.recordFailure(err);
            return error.MalformedFrame;
        };
        feedBorrowedCommitted(session, .{
            .bytes = outer.body,
            .shape = shape,
        }) catch |err| {
            // A prior prefix already applied makes this chunk committed. Keep
            // the unapplied suffix and resume it from the core-issued wake; an
            // OOM on the first direct frame still leaves the borrowed chunk
            // retryable by its caller.
            if (err == error.OutOfMemory and consumed != 0)
                return .{ .consumed = consumed, .needs_resume = true };
            return err;
        };
        consumed += outer.consumed;
        if (!was_open and session.served.port.peer.sessionIsOpen()) break;
    }
    return .{ .consumed = consumed };
}

/// Resume retained stream input without adding new transport bytes. This is a
/// Host drive: callbacks run under the same latch and unwind pump as an
/// ordinary feed, so bindings need no special retry rule.
fn resumeFeedTail(self: *Host, session: *HostSession) HostError!void {
    if (!session.feed_resume_pending and !session.feed_tail.isActive()) return;
    session.feed_resume_pending = false;
    const was_open = session.served.port.peer.sessionIsOpen();
    host_pump.dispatchUnderLatch(self, session, struct {
        gpa: std.mem.Allocator,
        c: *HostSession,
        was_open: bool,
        pub fn call(s: @This()) !void {
            try feedStreamChunk(s.gpa, s.c, &.{}, s.was_open);
        }
    }{ .gpa = self.allocator, .c = session, .was_open = was_open }) catch |err| {
        return switch (err) {
            // No authority moved: the owned tail remains the retry source.
            // `dispatchUnderLatch` has already queued the next FLUSH wake.
            error.OutOfMemory => retry: {
                session.feed_resume_pending = true;
                break :retry HostError.OutOfMemory;
            },
            // The event was removed before its application turn could be
            // served, so replay would duplicate protocol authority. Fail the
            // session closed and surface the resource cause to the drainer.
            error.EventServeOutOfMemory => committed_oom: {
                session.served.port.peer.recordFailure(err);
                host_pump.condemnAndClose(self, session, .resource_exhausted, "retained stream dispatch failed under memory pressure");
                break :committed_oom HostError.OutOfMemory;
            },
            // Backpressure preserves the same owned suffix. It is distinct
            // from allocation pressure so a direct core consumer can drain
            // and retry according to the public Host error contract.
            error.OutboundBackpressure => retry: {
                session.feed_resume_pending = true;
                break :retry HostError.OutboundBackpressure;
            },
            // A retained frame has no caller left that can own an arbitrary
            // dispatch error. Preserve the concrete cause in the peer's abort
            // and terminal state; the stream projection reports that state.
            else => terminal: {
                session.served.port.peer.recordFailure(err);
                host_pump.condemnAndClose(self, session, .other, @errorName(err));
                break :terminal HostError.SessionCondemned;
            },
        };
    };
}

// ── The byte pump ────────────────────────────────────────────────────────
