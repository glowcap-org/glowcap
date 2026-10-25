//! Session lifecycle for the byte-fed host core: minting a node-registered
//! CapTP session shell, the dialed and accepted open paths over it, the
//! directories that find a live session again (by dialed designator, partner
//! key, or durable peer identity), and the one teardown funnel every release,
//! condemnation, and failed open goes through.
//!
//! One of `host.zig`'s responsibilities.
//! The `Host` owns the state (the session map, the side indexes, the
//! seed counter) and presents `openDialedLocator`,
//! `openAcceptedAdvertised`, `releaseSession`, and their siblings as its own
//! verbs through decl aliases, so a caller reads one `Host` surface.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

const host_mod = @import("host.zig");
const host_close = @import("host/close.zig");
const host_pump = @import("host/pump.zig");
const host_transports = @import("host/transports.zig");
const dial_plan = @import("dial_plan.zig");
const capability_promise = @import("capability_promise.zig");
const publication = @import("sessions/publication.zig");
const served_mod = @import("served.zig");
const vocab = @import("vocab.zig");
const crossed_hellos = @import("crossed_hellos.zig");
const directory = @import("sessions/directory.zig");
const secrets = @import("sessions/secrets.zig");
const vow_release = @import("vows/release.zig");
const handoff_mod = @import("handoff.zig");
const interception = @import("host/interception.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const HostError = host_mod.HostError;
const SessionReleaseError = host_mod.SessionReleaseError;
const DialTarget = host_mod.DialTarget;
const Served = served_mod.Served;
const crypto = foundation.crypto;
/// Who owns the peer a session shell is minted over: the node mints its own,
/// or the embedder pins one at a stable address and the node only routes
/// through it (`engine.Node.registerPeerOver`), never freeing it.
const PeerSource = union(enum) { mint: void, over: *engine.Peer };

/// Mint the dialing half of a session to the peer `locator` names:
/// register the outbound with the crossed-hellos table, register the session
/// on the node, and sign and encode `op:start-session` with this session's key,
/// carrying this node's selected acceptable location. The hello
/// is encoded before this returns. The embedder drains it with `takeOutbound`
/// (a flush action is queued) and drives the handshake byte-fed. URI holders
/// parse first (`model.uri.parsePeer`), the same spine as
/// `glowcap_host_session_open_dialed_locator`. The locator is borrowed for
/// the call. The loop-fed bridge adopts with `openDialedOver` after
/// `Loop.dialLocator` completes. This path mints the peer.
pub fn openDialedLocator(self: *Host, locator: model.PeerLocator) !*HostSession {
    // Knowledge is recorded whenever the handed form carries it, whatever
    // this host's own profile: a baseline hello stamps nothing regardless,
    // and the give path still wants to know a partner is glowcap (ADR-0042).
    const knows = engine.Peer.dialedLocatorIdentifiesGlowcap(locator);
    return openDialedKnowing(self, .mint, locator.transport, locator.designator, knows);
}

/// Realize one dial effect the core admitted before its current close barrier.
/// The ticket, not an adapter-side lifecycle exception, is the authority that
/// permits minting its session while Host finish is sealed.
pub fn openPendingDial(self: *Host, ticket: engine.Node.PendingId, route_index: usize) !?*HostSession {
    try self.refuseReentry();
    if (!self.lifecyclePhase().serving()) return null;
    const view = self.node.pendingDial(ticket, route_index) orelse return null;
    const locator = view.locator;
    // Wire-carried locators are bare on onion, so a redeem dial never has
    // partner knowledge to record (ADR-0042).
    return try openDialedCommitted(self, .mint, locator.transport, locator.designator, false, view.demanded_partner_key);
}

/// `openDialedLocator` over a peer the embedder owns and pins at a stable
/// address. The wiring is identical (crossed-hellos outbound registration, the
/// initiator hello carrying the Node-owned acceptable location, and the key-scheme
/// dial's demand on the partner, `engine.Peer.demandPartnerDurableKey`) except for
/// ownership.
/// The node routes through the adopted peer but never frees it: the
/// embedder frees the peer itself, only after `releaseSession`. This is the
/// completion loop's dialed adoption seam, the dial half of
/// `openAcceptedAdvertisedOver` (ADR-0018 loop-side dial executor).
pub fn openDialedOver(
    self: *Host,
    peer: *engine.Peer,
    locator: model.PeerLocator,
) !*HostSession {
    const knows = engine.Peer.dialedLocatorIdentifiesGlowcap(locator);
    return openDialedKnowing(self, .{ .over = peer }, locator.transport, locator.designator, knows);
}

pub fn openDialedOverPending(
    self: *Host,
    peer: *engine.Peer,
    view: engine.Node.PendingDialView,
) !*HostSession {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    const locator = view.locator;
    return openDialedCommitted(self, .{ .over = peer }, locator.transport, locator.designator, false, view.demanded_partner_key);
}

/// Shared dialed-open core: `openDialedLocator` mints a node-owned peer.
/// `openDialedOver` adopts an embedder-owned one. Everything else is one
/// path (crossed-hellos, role, keyed pin, hello), so the two entry
/// points cannot drift.
pub fn openDialedKnowing(
    self: *Host,
    source: PeerSource,
    transport: []const u8,
    partner_designator: []const u8,
    partner_known_glowcap: bool,
) !*HostSession {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    return openDialedCommitted(self, source, transport, partner_designator, partner_known_glowcap, null);
}

fn openDialedCommitted(
    self: *Host,
    source: PeerSource,
    transport: []const u8,
    partner_designator: []const u8,
    partner_known_glowcap: bool,
    demanded_partner_key: ?crypto.PeerKey,
) !*HostSession {
    const advertised = try requireAcceptableLocator(self);
    // The dial's own admission before anything is minted, so a refusal here
    // has nothing to unwind.
    const admission = try dial_plan.admitDial(try self.transportProfile(transport), partner_designator);
    try refuseDuplicateDialForDemand(self, transport, partner_designator, demanded_partner_key);
    // The designator is borrowed all the way to `mintShell`, which dupes it
    // into the shell. One owner from birth: `freeSessionShell` is the only
    // free, so a refusal below can unwind the mint without this frame
    // holding an obligation to discharge as well.
    const session = try mint(self, source, .{ .dialed = partner_designator }, transport);
    // Before the hello: the stamp reads this when it assembles the signed
    // location (ADR-0042).
    if (partner_known_glowcap) session.served.port.peer.noteKnownGlowcapPartner();
    if (admission.sealed_channel) {
        attachSealedChannel(self, session, .initiator) catch |err| {
            failOpen(self, session);
            return err;
        };
    }
    // The dial's own demand, before the hello. The shared open tail's
    // `errdefer failOpen` covers hello failures.
    if (admission.demanded_key) |expected|
        session.served.port.peer.demandPartnerDurableKey(expected);
    if (demanded_partner_key) |key|
        session.served.port.peer.demandPartnerDurableKey(key);

    return helloAndEnroll(self, session, advertised);
}

/// Ensure an accepted session will have an acceptable location without
/// displacing deployment policy. Resolves what this accept would sign
/// (`dial_plan.planAccept`), completes it, and retains it, selecting it only
/// when nothing is selected yet. An explicitly set advertised locator (a status-allow: pending state or quoted runtime label
/// rendezvous route carrying its relay hint, a published address) is the
/// deployment's claim of reachability. An accept that overwrote it with the
/// listener-derived fallback would strip the hints a handoff recipient needs
/// to dial this peer back.
pub fn ensureAcceptAdvertisedLocator(
    self: *Host,
    scheme: model.transport.DesignatorScheme,
    server_designator: []const u8,
    accepted_local_addr: []const u8,
    transport: []const u8,
) !void {
    if ((try self.transportProfile(transport)).dial_shape == .route_bundle)
        return error.UnknownTransport;
    const plan = dial_plan.planAccept(scheme, server_designator, accepted_local_addr);
    var hint_buf: [1]model.HintEntry = undefined;
    const candidate: model.PeerLocator = .{
        .transport = transport,
        .designator = plan.designator,
        .hints = model.Hints.forDirectAddresses(plan.direct_addresses_hint, &hint_buf),
    };
    var hint_storage: engine.Peer.HelloHints = .{};
    defer hint_storage.deinit(self.allocator);
    const complete = try host_transports.borrowPreparedAdvertisedLocator(self, candidate, &hint_storage);
    try self.node.ensureAdvertisedLocator(complete);
}

/// Mint the accepting half of a session using this node's selected acceptable
/// location, which may use another transport (ADR-0028).
pub fn openAcceptedAdvertised(self: *Host, transport: []const u8) !*HostSession {
    return openAccepted(self, .mint, transport);
}

/// `openAcceptedAdvertised` over an embedder-owned, pinned peer. The node
/// routes through the peer but never frees it.
pub fn openAcceptedAdvertisedOver(self: *Host, peer: *engine.Peer, transport: []const u8) !*HostSession {
    return openAccepted(self, .{ .over = peer }, transport);
}

fn openAccepted(self: *Host, source: PeerSource, transport: []const u8) !*HostSession {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    const advertised = try requireAcceptableLocator(self);
    const profile = try self.transportProfile(transport);
    if (profile.dial_shape == .route_bundle) return error.UnknownTransport;
    const session = try mint(self, source, .accepted, transport);
    if (profile.sealed_channel) {
        attachSealedChannel(self, session, .responder) catch |err| {
            failOpen(self, session);
            return err;
        };
    }
    return acceptedHelloAndEnroll(self, session, advertised);
}

/// Box the sealed byte channel onto a freshly minted shell (ADR-0041): derive
/// the ephemeral seed from this session's unique signing seed under a separate
/// KDF domain, borrow the host's durable key while the channel derives and
/// signs its identity proof, and start the role's half. The dialing side reads
/// the responder key off the shell's own
/// dialed designator and turns it into the same demand a key-scheme dial
/// makes, so the chokepoint weighs the partner's claim against what was
/// dialed. The caller unwinds a refusal with `failOpen`. The shell frees the
/// channel in `freeSessionShell`.
fn attachSealedChannel(self: *Host, session: *HostSession, role: enum { initiator, responder }) !void {
    var ephemeral_seed = secrets.noiseEphemeralSeed(session.session_seed);
    defer std.crypto.secureZero(u8, &ephemeral_seed);
    var identity = self.node.secretKey();
    defer std.crypto.secureZero(u8, std.mem.asBytes(&identity));
    const channel = try self.allocator.create(foundation.sealed.SealedChannel);
    errdefer self.allocator.destroy(channel);
    channel.* = switch (role) {
        .initiator => blk: {
            const remote = crypto.PeerKey.fromDesignator(session.role.dialed) orelse
                return error.InvalidAddress;
            session.served.port.peer.demandPartnerDurableKey(remote);
            break :blk foundation.sealed.SealedChannel.initInitiator(
                &identity,
                remote,
                ephemeral_seed,
                session.transport,
            ) catch |err| switch (err) {
                // A designator whose key is degenerate for Diffie-Hellman
                // names a peer no handshake can reach: an undialable address.
                error.InvalidRemoteKey, error.IdentityElement => return error.InvalidAddress,
                else => return error.SealedChannelFailed,
            };
        },
        .responder => foundation.sealed.SealedChannel.initResponder(
            &identity,
            ephemeral_seed,
            session.transport,
        ) catch return error.SealedChannelFailed,
    };
    session.sealed = channel;
}

// ── Session directories (`sessions/directory.zig`) ──────────────────────────
// Finding a live session again (by dialed target, proved durable peer, or
// side index), plus the duplicate refusals and index upkeep those lookups
// power. `sessions/directory.zig` owns the bodies.
pub const liveSessionForDial = directory.liveSessionForDial;
pub const refuseDuplicateDial = directory.refuseDuplicateDial;
pub const refuseDuplicateDialForDemand = directory.refuseDuplicateDialForDemand;
pub const refuseDuplicatePartnerKey = directory.refuseDuplicatePartnerKey;
pub const DuplicatePartnerError = directory.DuplicatePartnerError;
pub const indexPartnerKey = directory.indexPartnerKey;
pub const unindexSession = directory.unindexSession;
pub const liveIndexedSession = directory.liveIndexedSession;
pub const dialedSessionFor = directory.dialedSessionFor;
const durablePeerKeyFor = directory.durablePeerKeyFor;
const target = directory.target;
pub const nextSessionSeed = secrets.nextSessionSeed;
const wireHashSalt = secrets.wireHashSalt;

pub fn resolveSessionSecret(ctx: ?*anyopaque, peer_handle: engine.PeerHandle) ?crypto.SecretKey {
    const self: *Host = @ptrCast(@alignCast(ctx orelse return null));
    const session = self.sessions.get(peer_handle) orelse return null;
    if (session.isTerminating() or !session.sessionOpen()) return null;
    return session.sessionSecret();
}

/// Refuse a durable identity this host does not own. The caller first decides
/// from the transport scheme that the designator is a key. Byte shape alone
/// carries no such authority.
pub fn refuseUnheldIdentity(self: *const Host, designator: []const u8) error{UnheldIdentity}!void {
    const claimed = crypto.PeerKey.fromDesignator(designator) orelse return error.UnheldIdentity;
    const held = self.node.secretKey().publicKey();
    if (!std.mem.eql(u8, claimed.asBytes(), held.asBytes())) return error.UnheldIdentity;
}

fn requireAcceptableLocator(self: *const Host) HostError!model.PeerLocator {
    return self.node.acceptableLocator() orelse
        HostError.MissingAdvertisedLocator;
}

/// Sign exactly one Node-owned locator snapshot, then enroll and pump the
/// session. `errdefer failOpen` unwinds a failed hello.
pub fn helloAndEnroll(self: *Host, session: *HostSession, advertised: model.PeerLocator) !*HostSession {
    errdefer failOpen(self, session);
    var secret = session.sessionSecret();
    defer std.crypto.secureZero(u8, std.mem.asBytes(&secret));
    try session.served.port.peer.sendKeyedStartSessionAdvertised(advertised, secret);
    enroll(self, session);
    try host_pump.dirtyThenPump(self, session.peer_handle);
    return session;
}

/// The accepted-open tail. On onion alone, an acceptor configured for an
/// upgraded profile defers its hello until the initiator's arrives, because
/// only that hello can say whether the partner is glowcap and therefore
/// which preference ours may state (ADR-0042). The before-serve hook
/// answers it (`interception.hostBeforeServe`). A default-profile acceptor gains
/// nothing from waiting: its answer is bare either way, so it keeps the
/// eager hello, and every other transport says hello at accept as
/// the dial side does.
fn acceptedHelloAndEnroll(self: *Host, session: *HostSession, advertised: model.PeerLocator) !*HostSession {
    if (std.mem.eql(u8, session.transport, model.transport.onion) and
        session.served.port.peer.session_state.statesUpgradedProfile())
    {
        errdefer failOpen(self, session);
        enroll(self, session);
        try host_pump.dirtyThenPump(self, session.peer_handle);
        return session;
    }
    return helloAndEnroll(self, session, advertised);
}

/// Release one session: break its still-parked far vows (their
/// resolutions can never arrive), retire it from the node (whose
/// fail-closed sweep queues the fail actions that break *sibling*
/// sessions' answers), and free the shell. The sibling fails fire
/// inside this call, through the same pump every verb ends with.
pub fn releaseSession(self: *Host, session: *HostSession) SessionReleaseError!void {
    try self.refuseReentry();
    try self.checkOwnedSession(session);
    {
        const hold = self.callback_latch.hold();
        defer hold.release();
        // Retire Vat admission before the one-way session transition. Failure
        // here mutates nothing and leaves the caller's handle valid. Once it
        // succeeds, every remaining release step is infallible or retains its
        // own deferred work, so no error can invite reuse of a freed shell.
        try cancelSessionIngress(self, session, session.served.closeReason("connection released"));
        self.traceClose(session);
        // A release is terminal even when the embedder skipped the explicit
        // close verb. Record that fact before breaking vows so their completion
        // classification comes from core lifecycle, not adapter call order.
        host_close.markSessionTerminating(self, session);
        session.served.port.breakFarVows(session.served.closeReason("connection released"));
    }

    finishSessionOpen(self, session);
    unindexSession(self, session);
    const peer_handle = session.peer_handle;
    _ = self.capabilities.invalidatePeer(peer_handle);
    capability_promise.sessionReleased(self, peer_handle, session.served.closeReason("connection released"));
    vow_release.dropSessionRows(self, session, session.served.closeReason("connection released"));
    std.debug.assert(self.sessions.remove(peer_handle));
    freeSessionShell(self, session);
    self.node.removePeer(peer_handle);
    host_pump.finishVerb(self) catch |err| switch (err) {
        // Dirty-FIFO capacity was reserved when each shell was minted, and
        // a receiver drive that hits OOM requeues itself before returning.
        // The exact wake therefore remains retryable by the next Host verb;
        // condemning unrelated sessions would turn coordination pressure
        // into a Host-wide authority failure.
        error.OutOfMemory => {},
        else => condemnRemainingSessions(self, "session release cleanup failed"),
    };
}

pub fn cancelSessionIngress(self: *Host, session: *HostSession, reason: []const u8) actors.IngressCancellationError!void {
    if (session.control.ingress_cancelled) return;
    try self.vat.cancelIngress(session.served.port.ingress, reason);
    session.control.ingress_cancelled = true;
}

pub fn condemnRemainingSessions(self: *Host, message: []const u8) void {
    var sessions = self.sessions.valueIterator();
    while (sessions.next()) |remaining|
        host_pump.condemnAndClose(self, remaining.*, .resource_exhausted, message);
}

/// What a mint is told about the half being minted. The transport and
/// dialed designator are borrowed here: `mintShell` copies them into one
/// shell-owned identity block, so a caller never transfers ownership.
pub const RoleSpec = union(enum) {
    dialed: []const u8,
    accepted,
};

/// One node-registered CapTP session shell: register the peer `source`
/// names, apply the host posture, and allocate the `HostSession`. The
/// session's row is reserved here so `enroll` cannot fail. A caller that
/// fails after this unwinds with `failOpen`. A pinned peer is routed through
/// and served but never freed: `releaseSession` and `deinit` only
/// unregister its slot, and the embedder frees it after `releaseSession`,
/// which is how a peer-owning loop with fixed inline slots puts its sessions
/// under one host.
pub fn mint(self: *Host, source: PeerSource, spec: RoleSpec, transport: []const u8) !*HostSession {
    try self.pending_flush.ensureTotalCapacity(self.allocator, self.sessions.count() + 1);
    try self.held_releases.ensureTotalCapacity(self.allocator, self.sessions.count() + 1);
    // The session being minted owes a flush and a close of its own.
    try self.reserveActions(2);
    if (spec == .dialed) {
        try self.dialed_by_target.ensureUnusedCapacity(self.allocator, 1);
        try self.hellos.reserveOutbound(self.allocator);
    }
    const peer_handle = switch (source) {
        .mint => try self.node.registerPeer(negotiatingOptions(self)),
        .over => |peer| try self.node.registerPeerOver(peer),
    };
    errdefer self.node.removePeer(peer_handle);
    try self.sessions.reserve(self.allocator, peer_handle);
    const peer = switch (source) {
        .mint => self.node.peer(peer_handle).?,
        .over => |peer| peer,
    };
    return mintShell(self, peer, peer_handle, spec, transport);
}

/// The host posture imposed on every minted or adopted peer. The export
/// range is not in it: `engine.Node` hands each session one at
/// registration, so no posture can carry one and none can overwrite one.
pub fn negotiatingOptions(self: *const Host) engine.Peer.NegotiatingOptions {
    return .{
        .codec = self.opts.codec,
        .captp_version = self.opts.captp_version,
        .features = self.opts.features,
        .verify_partner_handshake = self.opts.verify_partner,
        .limits = self.opts.limits,
        .outbound_high_water_bytes = self.opts.outboundHighWaterBytes(),
    };
}

/// The shared mint tail: impose the host's peer posture through the
/// engine's `reposture` verb (asserted negotiating, no bytes moved) and
/// allocate the shell, for minted and adopted peers alike. The export range
/// is not among the knobs: `engine.Node` draws one at registration on both
/// paths, and `reposture` cannot overwrite it because `NegotiatingOptions`
/// does not carry one.
pub fn mintShell(self: *Host, peer: *engine.Peer, peer_handle: engine.PeerHandle, spec: RoleSpec, transport: []const u8) !*HostSession {
    const profile = try self.transportProfile(transport);
    var session_seed = nextSessionSeed(self);
    defer std.crypto.secureZero(u8, &session_seed);
    var options = negotiatingOptions(self);
    if (profile.max_packet_bytes != 0)
        options.limits.max_frame_bytes = @min(options.limits.max_frame_bytes, profile.max_packet_bytes);
    options.wire_hash_salt = wireHashSalt(session_seed);
    peer.reposture(options);
    const session = try self.allocator.create(HostSession);
    errdefer self.allocator.destroy(session);
    const designator_len = switch (spec) {
        .dialed => |designator| designator.len,
        .accepted => 0,
    };
    const identity_len = std.math.add(usize, transport.len, designator_len) catch return error.OutOfMemory;
    const identity = try self.allocator.alloc(u8, identity_len);
    errdefer self.allocator.free(identity);
    @memcpy(identity[0..transport.len], transport);
    const owned_transport = identity[0..transport.len];
    const role: HostSession.Role = switch (spec) {
        .dialed => |designator| blk: {
            @memcpy(identity[transport.len..], designator);
            break :blk .{ .dialed = identity[transport.len..] };
        },
        .accepted => .accepted,
    };
    session.* = .{
        .host = self,
        .peer_handle = peer_handle,
        .session_seed = session_seed,
        .served = Served.over(self.allocator, peer),
        .transport = owned_transport,
        .role = role,
        .wire_framing = profile.wire_framing,
        .outbound_high_water_bytes = self.opts.outboundHighWaterBytes(),
    };
    // A refused mint frees the shell, so its seed is wiped first, as
    // `freeSessionShell` wipes a retired one.
    errdefer std.crypto.secureZero(u8, &session.session_seed);
    // `Host.init` returns by value, so only a live Host method knows the
    // object's stable address. Store the seam once per Node (reassigning
    // the same value on later mints is harmless) rather than in each Peer.
    // The projection and gifter callbacks live with the publication and
    // handoff code in `host.zig`; the wiring is theirs too.
    handoff_mod.wireNodeServices(self);
    self.node.setSessionSecretResolver(.{ .ctx = self, .resolve = resolveSessionSecret });
    self.node.setTransportResolver(.{ .ctx = self, .vtable = &transport_resolver_vtable });
    session.served.port.ingress = try self.vat.openIngress();
    session.served.local_turn_budget = self.opts.local_turn_budget;
    return session;
}

fn resolveTransportDesignator(ctx: ?*anyopaque, transport: []const u8) ?model.transport.DesignatorScheme {
    const self: *Host = @ptrCast(@alignCast(ctx.?));
    return self.designatorScheme(transport) catch null;
}

fn resolveSessionTransport(ctx: ?*anyopaque, peer_handle: engine.PeerHandle) ?[]const u8 {
    const self: *Host = @ptrCast(@alignCast(ctx.?));
    const session = self.sessions.get(peer_handle) orelse return null;
    return session.transport;
}

const transport_resolver_vtable: engine.Node.TransportResolver.VTable = .{
    .designator_scheme = resolveTransportDesignator,
    .session_transport = resolveSessionTransport,
};

pub fn enroll(self: *Host, session: *HostSession) void {
    session.served.serve_options = .{ .hook_ctx = session, .before_serve = interception.hostBeforeServe };
    session.served.port.setResolveInterceptor(.{ .ctx = session, .func = interception.hostResolveInterceptor });
    self.sessions.placeReserved(session.peer_handle, session);
    std.debug.assert(!session.control.open_pending);
    session.control.open_pending = true;
    self.beginSessionOperation(session);
    if (session.role == .dialed) {
        const dial_target = target(session.transport, session.role.dialed);
        self.dialed_by_target.putAssumeCapacity(dial_target, session.peer_handle);
        // The crossed-hellos entry, before any bytes move (ADR-0012): the
        // hello is queued but leaves in the pump that follows enrollment.
        // It lives while the open is pending, so `finishSessionOpen` removes
        // it when the partner's hello lands or the dial dies, and a later
        // peer naming this address cannot condemn an open session.
        //
        // Two identities, two roles (ADR-0028). The target is the durable
        // peer this dial races for: it decides *which two attempts are
        // racing*. The identifier beside it is this outbound session
        // attempt's own key, not the host's: it decides *which of the two
        // survives*. The two are the same value only when a host signs
        // every session with its durable key, and ordering by that would
        // order the tiebreak by a quantity both attempts to a peer share.
        self.hellos.registerOutbound(dial_target, crypto.derivePublicIdentifier(session.sessionPublicKey()));
    }
}

/// Retire one admitted session-open operation after either handshake success
/// or terminal teardown. The shell remains a live resource after success, but
/// it is no longer pending work for Host finish. status-allow: lifecycle transition
pub fn finishSessionOpen(self: *Host, session: *HostSession) void {
    if (!session.control.open_pending) return;
    session.control.open_pending = false;
    if (session.role == .dialed) self.hellos.unregister(
        target(session.transport, session.role.dialed),
        crypto.derivePublicIdentifier(session.sessionPublicKey()),
    );
    self.finishSessionOperation(session);
}

pub const publish = publication.publish;
pub const publishHosted = publication.publishHosted;
pub const spawn = publication.spawn;
pub const spawnHosted = publication.spawnHosted;

/// Free one session's owned shell after it has been unregistered from every
/// canceled: the served Port, unconsumed feed tail, connection identity bytes,
/// then the shell itself. Every session teardown funnels through here so no
/// path drops one of these frees. Call only after `unindexSession`: the
/// transport and designator bytes back the dial index key, and the
/// crossed-hellos entry `finishSessionOpen` drops first, until this frees
/// their shared block.
pub fn freeSessionShell(self: *Host, session: *HostSession) void {
    finishSessionOpen(self, session);
    host_close.removeSessionCloseTiming(self, session.peer_handle);
    // The export range is not given back here: `engine.Node.removePeer`
    // reclaims it from the peer that held it, so the draw and the return
    // sit on the same side of the boundary.
    host_pump.removeDirtySession(self, session);
    host_pump.removeHeldReleases(self, session);
    host_pump.requeueParkedNodeActions(self, session.peer_handle);
    session.served.deinit(&self.vat);
    session.feed_tail.deinit(self.allocator);
    if (session.sealed) |channel| {
        channel.deinit(self.allocator);
        self.allocator.destroy(channel);
        session.sealed = null;
    }
    const identity_len = session.transport.len + switch (session.role) {
        .dialed => |designator| designator.len,
        .accepted => 0,
    };
    self.allocator.free(session.transport.ptr[0..identity_len]);
    std.crypto.secureZero(u8, &session.session_seed);
    self.allocator.destroy(session);
}

pub fn failOpen(self: *Host, session: *HostSession) void {
    unindexSession(self, session);
    // tolerant: enrolled only when the failure came after `enroll`.
    _ = self.sessions.remove(session.peer_handle);
    finishSessionOpen(self, session);
    const peer_handle = session.peer_handle;
    host_pump.removeFreshSessionActions(self, session);
    self.vat.discardFreshIngress(session.served.port.ingress);
    session.control.ingress_cancelled = true;
    freeSessionShell(self, session);
    self.node.removePeer(peer_handle);
}
