//! Publication for the byte-fed host core: the Host and durable name
//! registries, the swiss minting behind a durable name, and the resolver the
//! node consults when a fetch names one.
//!
//! One of `host.zig`'s responsibilities.
//! The `Host` owns the registries and presents every publish verb as
//! its own through decl aliases.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

const host_mod = @import("host.zig");
const capability = @import("capability.zig");
const vocab = @import("vocab.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const HostError = host_mod.HostError;
const localActorId = @import("host/capabilities/identity.zig").localActorId;
const foundation = @import("foundation");
const crypto = foundation.crypto;

/// One host-wide publication: a swiss name discovers one Host-Vat actor. The
/// actor is the identity. A Port projection is minted only when that Port
/// fetches the name (or an embedder explicitly asks for its position). A fetch
/// never leaves a per-session copy of the alias behind, so replacing or
/// removing the name changes every later fetch on every session, while the
/// Port's reverse row keeps a repeated fetch on one session reusing its
/// existing export. A session also has its own bootstrap table, which answers
/// only its partner. `publication_lookup.resolveFetch` consults this registry
/// first.
pub const Publication = struct {
    name: []u8,
    actor: actors.Ref,
    active: bool = true,
};

/// `pub` for the Host-core siblings, not for embedders. Host-core internal.
pub fn resolvePublishedTarget(ctx: ?*anyopaque, scope: engine.PeerHandle, swissnum: []const u8) !?model.ExportPosition {
    const host: *Host = @ptrCast(@alignCast(ctx.?));
    const session = host.sessions.get(scope) orelse return null;
    const row = host.publications.get(host.publication_secret, swissnum) orelse return null;
    if (!row.active) return null;
    return (try session.served.port.projectActor(&host.vat, row.actor)).export_position;
}

/// Bind a freshly Host-spawned actor. Internal to this file's publish verbs,
/// so an unscoped `actors.Ref` from another Vat can never enter this Host's
/// publication namespace.
/// The alias row adopts the fresh actor's spawn root (ADR-0014): binding
/// takes no extra retain, replacement releases the displaced actor's
/// adopted root, and `unpublish` releases the row's. A caller-chosen
/// mutable name structurally cannot enter the reserved durable namespace
/// (ADR-0007): the prefix, not a tombstone, is what keeps an old
/// sturdyref from being retargeted after restart.
pub fn bindPublication(self: *Host, name: []const u8, actor: actors.Ref) !void {
    try self.claimOwner();
    try self.admitApplicationOperation();
    if (engine.isDurableSwiss(name)) return error.ReservedDurableNamespace;
    if (self.publications.getPtr(self.publication_secret, name)) |existing| {
        const displaced = existing.actor;
        existing.actor = actor;
        self.vat.releaseActor(localActorId(displaced) catch unreachable);
        return;
    }
    const owned = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(owned);
    try self.publications.putNoClobber(self.publication_secret, self.allocator, owned, .{ .name = owned, .actor = actor });
}

/// Spawn `initial` in this Host's Vat and bind `name` as a Host-wide alias.
/// Replacement changes discovery only. Existing capabilities keep reaching
/// the displaced actor until Host teardown.
pub fn publish(self: *Host, name: []const u8, comptime Behavior: type, initial: Behavior) !actors.Ref {
    var initial_pending = true;
    defer if (initial_pending) self.vat.discardInitial(Behavior, initial);
    try self.refuseReentry();
    try self.admitApplicationOperation();
    initial_pending = false;
    const actor = try self.vat.spawn(Behavior, initial);
    errdefer self.vat.discardFreshActor(actor);
    try bindPublication(self, name, actor);
    return actor;
}

/// Admit a hosted spawn. `hosted` transfers on every outcome, so a refusal
/// here frees its context before the Vat could own it.
fn admitHostedSpawn(self: *Host, hosted: actors.HostedActor) !void {
    errdefer hosted.discard();
    try self.refuseReentry();
    try self.admitApplicationOperation();
}

/// Foreign-callback twin of `publish`. `hosted` transfers into the
/// Vat on every outcome, preserving one owner for its context.
pub fn publishHosted(self: *Host, name: []const u8, hosted: actors.HostedActor) !actors.Ref {
    try admitHostedSpawn(self, hosted);
    const actor = try self.vat.spawnHosted(hosted);
    errdefer self.vat.discardFreshActor(actor);
    try bindPublication(self, name, actor);
    return actor;
}

/// Remove the host-wide alias `name`. Discovery-only, alias-only
/// (ADR-0026): a later fetch of the name misses on every session, while
/// capabilities already issued, live Port projections, and deposited
/// gifts keep naming the exact actor, which stays in the Host Vat until
/// teardown. An absent alias is refused `UnknownPublication`, so a typo
/// is loud instead of an idempotent no-op.
pub fn unpublish(
    self: *Host,
    name: []const u8,
) error{ ReenteredHost, WrongThread, HostClosing, UnknownPublication, ReservedDurableNamespace }!void {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    // The mutable-alias verb refuses durable rows: a minted sturdyref's
    // name is removed only through `removeDurable`, so the two authority
    // surfaces stay distinct (ADR-0007).
    if (engine.isDurableSwiss(name)) return error.ReservedDurableNamespace;
    const removed = self.publications.fetchRemove(self.publication_secret, name) orelse return error.UnknownPublication;
    // Key and row name are one allocation (`bindPublication`); free once.
    self.allocator.free(removed.value.name);
    // Release the alias root the row adopted (ADR-0014): with no other
    // rooting relationship, the actor is reclaimed here rather than at
    // Host teardown.
    self.vat.releaseActor(localActorId(removed.value.actor) catch unreachable);
}

/// A minted durable swiss name: fixed-size, POD, returned by value so
/// the caller owns the bytes with no allocation (ADR-0007).
pub const DurableSwiss = struct {
    pub const Entropy = [engine.durable_swiss_entropy_len]u8;
    pub const fromEntropy = mintDurableSwiss;
    bytes: [engine.durable_swiss_len]u8,

    /// Decode only the canonical spelling minted by fromEntropy.
    pub fn parse(name: []const u8) ?Entropy {
        if (name.len != engine.durable_swiss_len or !std.mem.startsWith(u8, name, engine.durable_swiss_prefix)) return null;
        var entropy: Entropy = undefined;
        for (&entropy, 0..) |*byte, i| {
            const digits = name[engine.durable_swiss_prefix.len + i * 2 ..][0..2];
            for (digits) |digit| if (!std.ascii.isDigit(digit) and (digit < 'a' or digit > 'f')) return null;
            byte.* = std.fmt.parseInt(u8, digits, 16) catch return null;
        }
        return entropy;
    }

    pub fn slice(self: *const DurableSwiss) []const u8 {
        return self.bytes[0..];
    }
};

/// Mint a durable swiss name from caller-supplied entropy: the reserved
/// prefix plus the hex spelling of `entropy`. Entropy stays an explicit
/// input because this core is sans-io. The driver tier draws it at the
/// I/O boundary (ADR-0007).
pub fn mintDurableSwiss(entropy: [engine.durable_swiss_entropy_len]u8) DurableSwiss {
    var out: DurableSwiss = undefined;
    @memcpy(out.bytes[0..engine.durable_swiss_prefix.len], engine.durable_swiss_prefix);
    const hex = "0123456789abcdef";
    for (entropy, 0..) |byte, i| {
        out.bytes[engine.durable_swiss_prefix.len + i * 2] = hex[byte >> 4];
        out.bytes[engine.durable_swiss_prefix.len + i * 2 + 1] = hex[byte & 0xf];
    }
    return out;
}

/// Publish `initial` under a freshly minted durable swiss name
/// (ADR-0007): unpredictable, never minted twice by the Host (an embedder that
/// republishes removed entropy rebinds the name), removable only through
/// `removeDurable`, and structurally disjoint from every mutable alias.
/// The active table is still checked before insertion, so even an
/// entropy-collision fails loud instead of retargeting. The row adopts
/// the spawn root (ADR-0014). Persistence stays above this sans-I/O core:
/// an embedder retains the entropy and publication identity, then republishes
/// them during startup. A fresh Host begins with an empty
/// registry, so an old sturdyref fails closed until that replay occurs.
pub fn publishDurable(
    self: *Host,
    entropy: [engine.durable_swiss_entropy_len]u8,
    comptime Behavior: type,
    initial: Behavior,
) !DurableSwiss {
    var initial_pending = true;
    defer if (initial_pending) self.vat.discardInitial(Behavior, initial);
    try self.refuseReentry();
    try self.admitApplicationOperation();
    initial_pending = false;
    const actor = try self.vat.spawn(Behavior, initial);
    errdefer self.vat.discardFreshActor(actor);
    return bindDurable(self, entropy, actor);
}

/// Foreign-callback twin of `publishDurable`. `hosted` transfers into the
/// Vat on every outcome, preserving one owner for its context.
pub fn publishHostedDurable(
    self: *Host,
    entropy: [engine.durable_swiss_entropy_len]u8,
    hosted: actors.HostedActor,
) !DurableSwiss {
    try admitHostedSpawn(self, hosted);
    const actor = try self.vat.spawnHosted(hosted);
    errdefer self.vat.discardFreshActor(actor);
    return bindDurable(self, entropy, actor);
}

pub fn bindDurable(self: *Host, entropy: [engine.durable_swiss_entropy_len]u8, actor: actors.Ref) !DurableSwiss {
    try self.claimOwner();
    const minted = mintDurableSwiss(entropy);
    if (self.publications.contains(self.publication_secret, minted.slice())) return error.DurableNameCollision;
    const owned = try self.allocator.dupe(u8, minted.slice());
    errdefer self.allocator.free(owned);
    try self.publications.putNoClobber(self.publication_secret, self.allocator, owned, .{ .name = owned, .actor = actor });
    return minted;
}

/// Publish already-held local authority under a durable name. The publication
/// takes its own root. Failure leaves the caller's capability unchanged.
pub fn publishDurableCapability(self: *Host, entropy: [engine.durable_swiss_entropy_len]u8, ref: @import("capability.zig").Ref) !DurableSwiss {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    const actor = self.localActorFor(ref) orelse return error.NotLocal;
    self.vat.retainActor(actor.local);
    errdefer self.vat.releaseActor(actor.local);
    return bindDurable(self, entropy, actor);
}

/// Owns a hidden registry row and Host pending-work lease until commit/cancel.
/// Move this value. Copying it does not create another reservation.
pub const DurableReservation = struct {
    host: ?*Host,
    swiss: DurableSwiss,
    lifetime: Host.PendingWorkLease,

    pub fn commit(self: *DurableReservation) void {
        const host = self.host orelse return;
        host.assertOwner();
        host.publications.getPtr(host.publication_secret, self.swiss.slice()).?.active = true;
        self.host = null;
        self.lifetime.complete();
    }

    pub fn cancel(self: *DurableReservation) void {
        const host = self.host orelse return;
        host.assertOwner();
        const removed = host.publications.fetchRemove(host.publication_secret, self.swiss.slice()).?;
        std.debug.assert(!removed.value.active);
        host.allocator.free(removed.value.name);
        host.vat.releaseActor(removed.value.actor.local);
        self.host = null;
        self.lifetime.complete();
    }
};

/// Reserve exact held authority without exposing its name to fetch. All fallible
/// allocation occurs here. Confirmed storage can activate the row infallibly.
pub fn reserveDurableCapability(self: *Host, entropy: DurableSwiss.Entropy, ref: capability.Ref) !DurableReservation {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    const actor = self.localActorFor(ref) orelse return error.NotLocal;
    const minted = mintDurableSwiss(entropy);
    if (self.publications.get(self.publication_secret, minted.slice())) |row| {
        if (!std.meta.eql(row.actor, actor)) return error.DurableNameCollision;
        if (!row.active) return error.PublicationPending;
        return .{ .host = null, .swiss = minted, .lifetime = .{ .host = null } };
    }
    var lifetime = try self.admitPendingWork();
    errdefer lifetime.complete();
    self.vat.retainActor(actor.local);
    errdefer self.vat.releaseActor(actor.local);
    const swiss = try bindDurable(self, entropy, actor);
    self.publications.getPtr(self.publication_secret, swiss.slice()).?.active = false;
    return .{ .host = self, .swiss = swiss, .lifetime = lifetime };
}

/// Remove a minted durable publication (ADR-0007): its live row is
/// reclaimed, future enlivenment of the old sturdyref misses, and a status-allow: replacement state identity
/// later mint never reuses the bytes. Alias-only like
/// `unpublish`: issued capabilities and deposited gifts keep the exact
/// actor. It releases the row's adopted root (ADR-0014). A name
/// outside the durable namespace is refused: mutable aliases leave
/// through `unpublish`.
pub fn removeDurable(
    self: *Host,
    swiss: []const u8,
) error{ ReenteredHost, WrongThread, HostClosing, UnknownPublication, NotDurableName }!void {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    try removeDurableRow(self, swiss);
}

/// Linear custody of one existing publication hidden during an uncertain
/// retirement. The row retains its exact actor and allocation until this
/// receipt either restores visibility or commits removal. Move, never copy.
pub const DurableRetirement = struct {
    host: ?*Host,
    swiss: DurableSwiss,

    pub fn finish(self: *DurableRetirement, committed: bool) void {
        const host = self.host orelse return;
        host.assertOwner();
        const row = host.publications.getPtr(host.publication_secret, self.swiss.slice()).?;
        std.debug.assert(!row.active);
        if (!committed and host.lifecyclePhase().serving()) {
            row.active = true;
        } else {
            const removed = host.publications.fetchRemove(host.publication_secret, self.swiss.slice()).?;
            host.allocator.free(removed.value.name);
            host.vat.releaseActor(removed.value.actor.local);
        }
        self.host = null;
    }
};

/// Hide existing discovery for an already-submitted durable retirement.
/// Cleanup remains legal after close. The receipt can only restore this exact
/// row; it cannot mint a name or acquire authority from a supplied capability.
pub fn fenceDurableRetirement(self: *Host, swiss: DurableSwiss) error{ ReenteredHost, WrongThread }!?DurableRetirement {
    try self.refuseReentry();
    const row = self.publications.getPtr(self.publication_secret, swiss.slice()) orelse return null;
    if (!row.active) return null;
    row.active = false;
    return .{ .host = self, .swiss = swiss };
}

fn removeDurableRow(self: *Host, swiss: []const u8) error{ UnknownPublication, NotDurableName }!void {
    if (!engine.isDurableSwiss(swiss)) return error.NotDurableName;
    if (self.publications.get(self.publication_secret, swiss)) |row| if (!row.active) return error.UnknownPublication;
    const removed = self.publications.fetchRemove(self.publication_secret, swiss) orelse return error.UnknownPublication;
    self.allocator.free(removed.value.name);
    self.vat.releaseActor(localActorId(removed.value.actor) catch unreachable);
}

/// What authenticated the durable identity a partner advertised (ADR-0028).
/// A thin alias over the engine's own derivation, so the byte-fed tier, the
/// live trace, and every C consumer read the one verdict the pre-open
/// chokepoint already reached.
/// `pub` for the Host-core siblings, not for embedders. Host-core internal.
pub fn durableProvenance(
    peer: *const engine.Peer,
    designator: []const u8,
) vocab.DurableProvenance {
    return peer.partnerDurableProvenance(designator);
}

/// The Port position serving `name` on `session`: a name this session's
/// own publish bound resolves in its bootstrap registry, and a Host-wide
/// alias lazily projects its Vat actor onto the session's Port. Null when
/// neither namespace holds the name.
pub fn publishedPosition(self: *Host, session: *HostSession, name: []const u8) !?u64 {
    try self.claimOwner();
    try self.checkSession(session);
    if (session.served.port.peer.session_state.bootstrapLookup(name)) |position| return position.int();
    const position = try resolvePublishedTarget(self, session.peer_handle, name) orelse return null;
    return position.int();
}

/// Return the Host-scoped capability published under `name` for `session`.
/// Publication lookup and capability retention are one core operation, while
/// the Port position remains lazy until the capability is marshalled.
pub fn publishedCapability(self: *Host, session: *HostSession, name: []const u8) !?capability.Ref {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    try self.admitSessionOperation(session);
    try self.checkSession(session);
    const actor = if (session.served.port.peer.session_state.bootstrapLookup(name)) |position|
        session.served.refForExport(position.int()) orelse return error.NoSuchActor
    else if (self.publications.get(self.publication_secret, name)) |row|
        if (row.active) row.actor else return null
    else
        return null;
    return @as(?capability.Ref, try self.retainLocalCapability(actor));
}
