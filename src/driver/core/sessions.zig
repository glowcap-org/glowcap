//! Session lifecycle for the byte-fed host core: minting a node-registered
//! CapTP session shell, the dialed and accepted open paths over it, the
//! directories that find a live session again (by dialed designator, partner
//! key, or durable peer identity), and the one teardown funnel every release,
//! condemnation, and failed open goes through.
//!
//! One of `host.zig`'s responsibilities, kept beside it rather than in it.
//! The `Host` still owns the state — the session map, the side indexes, the
//! seed counter — and still presents `openDialedLocator`,
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
const dial_plan = @import("dial_plan.zig");
const capability_promise = @import("capability_promise.zig");
const publication = @import("sessions/publication.zig");
const served_mod = @import("served.zig");
const vocab = @import("vocab.zig");
const crossed_hellos = @import("crossed_hellos.zig");
const directory = @import("sessions/directory.zig");
const vow_release = @import("vows/release.zig");
const handoff_mod = @import("handoff.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const HostError = host_mod.HostError;
const SessionReleaseError = host_mod.SessionReleaseError;
const DialTarget = host_mod.DialTarget;
const Served = served_mod.Served;
const crypto = foundation.crypto;
const session_seed_domain = host_mod.session_seed_domain;
const DialSource = union(enum) { mint: void, over: *engine.Peer };

/// Mint the dialing half of a session to the peer `locator` names:
/// register the outbound with the crossed-hellos table, register the session
/// on the node, and sign and encode `op:start-session` with this session's key,
/// carrying this node's selected acceptable location. The hello
/// is encoded before this returns; the embedder drains it with `takeOutbound`
/// (a flush action is queued) and drives the handshake byte-fed. URI holders
/// parse first (`model.uri.parsePeer`) — same spine as
/// `glowcap_host_session_open_dialed_locator`. The locator is borrowed for
/// the call. The loop-fed bridge adopts with `openDialedOver` after
/// `Loop.dialLocator` completes; this path mints the peer.
pub fn openDialedLocator(self: *Host, locator: model.PeerLocator) !*HostSession {
    // Knowledge is recorded whenever the handed form carries it, whatever
    // this host's own profile: a baseline hello stamps nothing regardless,
    // and the give path still wants to know a partner is glowcap (ADR-0118).
    const knows = engine.Peer.dialedLocatorIdentifiesGlowcap(locator);
    return openDialedKnowing(self, .mint, locator.transport, locator.designator, knows);
}

/// Realize one dial effect the core admitted before its current close barrier.
/// The ticket, not an adapter-side lifecycle exception, is the authority that
/// permits minting its session while Host finish is sealed.
pub fn openPendingDial(self: *Host, ticket: engine.Node.PendingId, route_index: usize) !?*HostSession {
    try self.refuseReentry();
    switch (self.lifecyclePhase()) {
        .active, .finishing => {},
        .terminating, .closed => return null,
    }
    const view = self.node.pendingDial(ticket, route_index) orelse return null;
    const locator = view.locator;
    // Wire-carried locators are bare on onion, so a redeem dial never has
    // partner knowledge to record (ADR-0118).
    return try openDialedCommitted(self, .mint, locator.transport, locator.designator, false, view.demanded_partner_key);
}

/// `openDialedLocator` over a peer the embedder owns and pins at a stable
/// address: identical wiring — crossed-hellos outbound registration, the
/// initiator hello carrying the Node-owned acceptable location, the key-scheme
/// dial's demand on the partner
/// (`engine.Peer.demandPartnerDurableKey`) — minus ownership.
/// The node routes through the adopted peer but never frees it: the
/// embedder frees the peer itself, only after `releaseSession`. This is the
/// completion loop's dialed adoption seam — the dial half of
/// `openAcceptedAdvertisedOver` (ADR-0076 loop-side dial executor).
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

/// Shared dialed-open core: `openDialedLocator` mints a node-owned peer;
/// `openDialedOver` adopts an embedder-owned one. Everything else is one
/// path — crossed-hellos, role, keyed pin, hello — so the two entry
/// points cannot drift.
pub fn openDialedKnowing(
    self: *Host,
    source: DialSource,
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
    source: DialSource,
    transport: []const u8,
    partner_designator: []const u8,
    partner_known_glowcap: bool,
    demanded_partner_key: ?crypto.PeerKey,
) !*HostSession {
    const advertised = try requireAcceptableLocator(self);
    // The dial's own admission before anything is minted, so a refusal here
    // has nothing to unwind; the blocking tier asks the same question.
    const admission = try dial_plan.admitDial(try self.transportProfile(transport), partner_designator);
    try refuseDuplicateDialForDemand(self, transport, partner_designator, demanded_partner_key);
    // The designator is borrowed all the way to `mintShell`, which dupes it
    // into the shell. One owner from birth: `freeSessionShell` is the only
    // free, so a refusal below can unwind the mint without this frame
    // holding an obligation to discharge as well.
    const session = switch (source) {
        .mint => try mint(self, .{ .dialed = partner_designator }, transport),
        .over => |peer| try mintOver(self, peer, .{ .dialed = partner_designator }, transport),
    };
    // Before the hello: the stamp reads this when it assembles the signed
    // location (ADR-0118).
    if (partner_known_glowcap) session.served.port.peer.noteKnownGlowcapPartner();
    if (admission.sealed_channel) {
        attachSealedChannel(self, session, .initiator) catch |err| {
            failOpen(self, session);
            return err;
        };
    }
    // Register the outbound before any bytes move: a crossed inbound
    // start-session from the same partner must find this dial (ADR-0030).
    // The mint above moves none, so this is still ahead of the hello.
    //
    // Two identities, two roles (ADR-0097). `partner_designator` is the
    // durable peer this dial races for: it decides *which two attempts
    // are racing*. The identifier beside it is this outbound session
    // attempt's own identity: it decides *which of the two survives*. Registering after the mint is what lets the
    // second one be the session's key rather than the host's: they are the
    // same value only when a host signs every session with its durable
    // key, and reading the wrong one would order the tiebreak by a
    // quantity both connection attempts to a peer share.
    const our_session_id = crypto.derivePublicIdentifier(session.sessionSecret().publicKey());
    const dial_target = target(session.transport, session.role.dialed);
    self.hellos.registerOutbound(self.allocator, dial_target, our_session_id) catch |err| {
        failOpen(self, session);
        return err;
    };
    errdefer self.hellos.unregister(self.allocator, dial_target);
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
/// when nothing is selected yet. An explicitly set advertised locator (a
/// rendezvous route carrying its relay hint, a published address) is the
/// deployment's claim of reachability; an accept that overwrote it with the
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
        return HostError.UnknownTransport;
    const plan = dial_plan.planAccept(scheme, server_designator, accepted_local_addr);
    var hint_buf: [1]model.HintEntry = undefined;
    const candidate: model.PeerLocator = .{
        .transport = transport,
        .designator = plan.designator,
        .hints = model.Hints.forDirectAddresses(plan.direct_addresses_hint, &hint_buf),
    };
    const complete = try self.prepareAdvertisedLocator(self.allocator, candidate);
    defer model.freePeerLocator(self.allocator, complete);
    try self.node.ensureAdvertisedLocator(complete);
}

/// Mint the accepting half of a session using this node's selected acceptable
/// location, which may intentionally use another transport (ADR-0109).
pub fn openAcceptedAdvertised(self: *Host, transport: []const u8) !*HostSession {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    const advertised = try requireAcceptableLocator(self);
    const profile = try self.transportProfile(transport);
    if (profile.dial_shape == .route_bundle) return HostError.UnknownTransport;
    const session = try mint(self, .accepted, transport);
    if (profile.sealed_channel) {
        attachSealedChannel(self, session, .responder) catch |err| {
            failOpen(self, session);
            return err;
        };
    }
    return acceptedHelloAndEnroll(self, session, advertised);
}

/// `openAcceptedAdvertised` over an embedder-owned, pinned peer. The node
/// routes through the peer but never frees it.
pub fn openAcceptedAdvertisedOver(self: *Host, peer: *engine.Peer, transport: []const u8) !*HostSession {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    const advertised = try requireAcceptableLocator(self);
    const profile = try self.transportProfile(transport);
    if (profile.dial_shape == .route_bundle) return HostError.UnknownTransport;
    const session = try mintOver(self, peer, .accepted, transport);
    if (profile.sealed_channel) {
        attachSealedChannel(self, session, .responder) catch |err| {
            failOpen(self, session);
            return err;
        };
    }
    return acceptedHelloAndEnroll(self, session, advertised);
}

/// Box the sealed byte channel onto a freshly minted shell (ADR-0107): derive
/// the ephemeral seed from this session's unique signing seed under a separate
/// KDF domain, borrow the host's durable key while the channel derives and
/// signs its identity proof, and start the role's half. The dialing side reads
/// the responder key off the shell's own
/// dialed designator and turns it into the same demand a key-scheme dial
/// makes, so the chokepoint weighs the partner's claim against what was
/// dialed. The caller unwinds a refusal with `failOpen`; the shell frees the
/// channel in `freeSessionShell`.
fn attachSealedChannel(self: *Host, session: *HostSession, role: enum { initiator, responder }) !void {
    var ephemeral_seed: [crypto.SEED_BYTES]u8 = undefined;
    defer std.crypto.secureZero(u8, &ephemeral_seed);
    var hasher = std.crypto.hash.Blake3.initKdf("glowcap noise ephemeral v1", .{});
    hasher.update(&session.session_seed);
    hasher.final(&ephemeral_seed);
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
                error.InvalidEphemeral => return HostError.SealedChannelFailed,
                else => return HostError.SealedChannelFailed,
            };
        },
        .responder => foundation.sealed.SealedChannel.initResponder(
            &identity,
            ephemeral_seed,
            session.transport,
        ) catch return HostError.SealedChannelFailed,
    };
    session.sealed = channel;
}

// ── Session directories (`sessions/directory.zig`) ──────────────────────────
// Finding a live session again — by dialed target, proved durable peer, or
// side index — plus the duplicate refusals and index upkeep those lookups
// power. `sessions/directory.zig` owns the bodies.
pub const liveSessionForDial = directory.liveSessionForDial;
pub const refuseDuplicateDial = directory.refuseDuplicateDial;
pub const refuseDuplicateDialForDemand = directory.refuseDuplicateDialForDemand;
pub const refuseDuplicatePartnerKey = directory.refuseDuplicatePartnerKey;
pub const indexPartnerKey = directory.indexPartnerKey;
pub const unindexSession = directory.unindexSession;
pub const liveIndexedSession = directory.liveIndexedSession;
pub const dialedSessionFor = directory.dialedSessionFor;
const durablePeerKeyFor = directory.durablePeerKeyFor;
const target = directory.target;

/// Each call derives a distinct seed from the host's root and a
/// monotonic counter, so two sessions never sign with the same key and a
/// host restarted with a fresh root cannot recreate a prior session's
/// handoff names. The derivation is keyed and domain-separated, so the
/// root is not recoverable from a session key and these bytes cannot
/// collide with another use of the same material.
pub fn nextSessionSeed(self: *Host) [crypto.SEED_BYTES]u8 {
    self.session_seed_counter += 1;
    var counter_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &counter_bytes, self.session_seed_counter, .little);
    var out: [crypto.SEED_BYTES]u8 = undefined;
    var hasher = std.crypto.hash.Blake3.initKdf(session_seed_domain, .{});
    hasher.update(&self.session_seed_root);
    hasher.update(&counter_bytes);
    hasher.final(&out);
    return out;
}

pub fn resolveSessionSecret(ctx: ?*anyopaque, peer_handle: engine.PeerHandle) ?crypto.SecretKey {
    const self: *Host = @ptrCast(@alignCast(ctx orelse return null));
    const session = self.sessions.get(peer_handle) orelse return null;
    if (session.isTerminating() or !session.sessionOpen()) return null;
    return session.sessionSecret();
}

/// Refuse a durable identity this host does not own. The caller first decides
/// from the transport scheme that the designator is a key; byte shape alone
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
    try session.served.port.peer.sendKeyedStartSessionAdvertised(advertised, session.sessionSecret());
    enroll(self, session);
    try host_pump.dirtyThenPump(self, session.peer_handle);
    return session;
}

/// The accepted-open tail. On onion alone, an acceptor configured for an
/// upgraded profile defers its hello until the initiator's arrives, because
/// only that hello can say whether the partner is glowcap and therefore
/// which preference ours may state (ADR-0118); the before-serve hook
/// answers it (`Host.hostBeforeServe`). A default-profile acceptor gains
/// nothing from waiting — its answer is bare either way — so it keeps the
/// eager hello, and every other transport says hello at accept exactly as
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
/// resolutions can never arrive), retire it from the node — whose
/// fail-closed sweep queues the fail actions that break *sibling*
/// sessions' answers — and free the shell. The sibling fails fire
/// inside this call, through the same pump every verb ends with.
pub fn releaseSession(self: *Host, session: *HostSession) SessionReleaseError!void {
    try self.refuseReentry();
    try self.checkOwnedSession(session);
    self.in_callback = true;
    {
        defer self.in_callback = false;
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

    if (session.role == .dialed)
        self.hellos.unregister(self.allocator, target(session.transport, session.role.dialed));
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

/// One node-registered CapTP session shell over a node-owned peer: mint the
/// peer, apply the host posture, and allocate the `HostSession`. The
/// map slot is reserved here so `enroll` cannot fail; a caller that fails
/// after this unwinds with `failOpen`.
/// What a mint is told about the half being minted. The transport and
/// dialed designator are borrowed here: `mintShell` copies them into one
/// shell-owned identity block, so a caller never transfers ownership.
pub const RoleSpec = union(enum) {
    dialed: []const u8,
    accepted,
};

pub fn mint(self: *Host, spec: RoleSpec, transport: []const u8) !*HostSession {
    try self.sessions.ensureUnusedCapacity(self.allocator, 1);
    try self.pending_flush.ensureTotalCapacity(self.allocator, self.sessions.count() + 1);
    // The session being minted owes a flush and a close of its own.
    try self.reserveActions(2);
    if (spec == .dialed) try self.dialed_by_target.ensureUnusedCapacity(self.allocator, 1);
    const peer_handle = try self.node.registerPeer(negotiatingOptions(
        self,
    ));
    errdefer self.node.removePeer(peer_handle);
    return mintShell(self, self.node.peer(peer_handle).?, peer_handle, spec, transport);
}

/// `mint` over a peer the embedder already owns and pins at a stable
/// address (`engine.Node.registerPeerOver`): the node routes through it
/// and the host serves it, but neither ever frees it — `releaseSession` and
/// `deinit` only unregister the slot, and the embedder frees the peer
/// after `releaseSession`. This is how a peer-owning loop, whose fixed slots
/// hold each peer inline, puts its sessions under one host.
pub fn mintOver(self: *Host, peer: *engine.Peer, spec: RoleSpec, transport: []const u8) !*HostSession {
    try self.sessions.ensureUnusedCapacity(self.allocator, 1);
    try self.pending_flush.ensureTotalCapacity(self.allocator, self.sessions.count() + 1);
    // The session being minted owes a flush and a close of its own.
    try self.reserveActions(2);
    if (spec == .dialed) try self.dialed_by_target.ensureUnusedCapacity(self.allocator, 1);
    const peer_handle = try self.node.registerPeerOver(peer);
    errdefer self.node.removePeer(peer_handle);
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
    var options = negotiatingOptions(self);
    if (profile.max_packet_bytes != 0)
        options.limits.max_frame_bytes = @min(options.limits.max_frame_bytes, profile.max_packet_bytes);
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
        .session_seed = nextSessionSeed(
            self,
        ),
        .served = Served.over(self.allocator, peer),
        .transport = owned_transport,
        .role = role,
        .wire_framing = profile.wire_framing,
        .outbound_high_water_bytes = self.opts.outboundHighWaterBytes(),
    };
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

const transport_resolver_vtable: engine.Node.RuntimeTransportResolver.VTable = .{
    .designator_scheme = resolveTransportDesignator,
    .session_transport = resolveSessionTransport,
};

pub fn enroll(self: *Host, session: *HostSession) void {
    session.served.serve_options = .{ .hook_ctx = session, .before_serve = Host.hostBeforeServe };
    session.served.port.setResolveInterceptor(.{ .ctx = session, .func = Host.hostResolveInterceptor });
    self.sessions.putAssumeCapacity(session.peer_handle, session);
    std.debug.assert(!session.control.open_pending);
    session.control.open_pending = true;
    self.beginSessionOperation(session);
    if (session.role == .dialed) {
        self.dialed_by_target.putAssumeCapacity(
            target(session.transport, session.role.dialed),
            session.peer_handle,
        );
    }
}

/// Retire one admitted session-open operation after either handshake success
/// or terminal teardown. The shell remains a live resource after success, but
/// it is no longer pending work for Host finish.
pub fn finishSessionOpen(self: *Host, session: *HostSession) void {
    if (!session.control.open_pending) return;
    session.control.open_pending = false;
    self.finishSessionOperation(session);
}

pub const publish = publication.publish;
pub const publishHosted = publication.publishHosted;
pub const spawn = publication.spawn;
pub const spawnHosted = publication.spawnHosted;

/// Free one session's owned shell after it has been unregistered from every
/// index and its Vat ingress has been canceled: the served Port, unconsumed feed tail, connection identity bytes,
/// then the shell itself. Every session teardown funnels through here so no
/// path drops one of these frees. Call only after `unindexSession` (and, for
/// a dialed session, `hellos.unregister`): the transport and designator bytes
/// back the dial index key until this frees their shared block.
pub fn freeSessionShell(self: *Host, session: *HostSession) void {
    finishSessionOpen(self, session);
    host_close.removeSessionCloseTiming(self, session.peer_handle);
    // The export range is not given back here: `engine.Node.removePeer`
    // reclaims it from the peer that held it, so the draw and the return
    // sit on the same side of the boundary.
    host_pump.removeDirtySession(self, session);
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
