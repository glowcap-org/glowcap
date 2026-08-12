//! Publication for the byte-fed host core: the giftable and durable name
//! registries, the swiss minting behind a durable name, and the resolver the
//! node consults when a fetch names one.
//!
//! One of `host.zig`'s responsibilities, kept beside it rather than in it.
//! The `Host` still owns the registries and presents every publish verb as
//! its own through decl aliases.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

const host_mod = @import("host.zig");
const host_pump = @import("host_pump.zig");
const vocab = @import("vocab.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const HostError = host_mod.HostError;
const actorIdOf = host_mod.actorIdOf;
const foundation = @import("foundation");
const crypto = foundation.crypto;

/// `pub` for the Host-core siblings, not for embedders. Host-core internal.
pub fn resolvePublishedTarget(ctx: ?*anyopaque, scope: engine.PeerId, swissnum: []const u8) !?model.ExportPosition {
    const host: *Host = @ptrCast(@alignCast(ctx.?));
    const session = host.sessions.get(scope) orelse return null;
    const row = host.giftables.get(swissnum) orelse return null;
    return (try session.served.port.projectActor(&host.vat, row.actor)).export_position;
}

/// Wire a minted session into the host: the before-serve hook offers
/// every inbound resolve to the node before the vat sees it (and
/// auto-redeems gives), and the resolve interceptor turns a served reply
/// that fulfills with a foreign-homed capability into a signed give.
/// Infallible: `mint` reserved the session map slot and, for dialed
/// sessions, the designator-index slot. Dialed sessions join the
/// designator index here (key borrows `role.dialed`).
/// Bind a freshly Host-spawned actor. Private so an unscoped `actors.Ref`
/// from another Vat can never enter this Host's publication namespace.
/// The alias row adopts the fresh actor's spawn root (ADR-0101): binding
/// takes no extra retain, replacement releases the displaced actor's
/// adopted root, and `unpublish` releases the row's. A caller-chosen
/// mutable name structurally cannot enter the reserved durable namespace
/// (ADR-0098): the prefix, not a tombstone, is what keeps an old
/// sturdyref from being retargeted after restart.
pub fn bindPublication(self: *Host, name: []const u8, actor: actors.Ref) !void {
    self.assertOwner();
    if (engine.isDurableSwiss(name)) return error.ReservedDurableNamespace;
    if (self.giftables.getPtr(name)) |existing| {
        const displaced = existing.actor;
        existing.actor = actor;
        self.vat.releaseActor(actorIdOf(displaced));
        return;
    }
    const owned = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(owned);
    try self.giftables.putNoClobber(self.allocator, owned, .{ .name = owned, .actor = actor });
}

/// Spawn `initial` in this Host's Vat and bind `name` as a Host-wide alias.
/// Replacement changes discovery only; existing capabilities keep reaching
/// the displaced actor until Host teardown.
pub fn publishGiftable(self: *Host, name: []const u8, comptime Behavior: type, initial: Behavior) !actors.Ref {
    try self.refuseReentry();
    const actor = try self.vat.spawn(Behavior, initial);
    errdefer self.vat.discardFreshActor(actor);
    try bindPublication(self, name, actor);
    return actor;
}

/// Foreign-callback twin of `publishGiftable`. `hosted` transfers into the
/// Vat on every outcome, preserving one owner for its context.
pub fn publishHostedGiftable(self: *Host, name: []const u8, hosted: actors.HostedActor) !actors.Ref {
    try self.refuseReentry();
    const actor = try self.vat.spawnHosted(hosted);
    errdefer self.vat.discardFreshActor(actor);
    try bindPublication(self, name, actor);
    return actor;
}

/// Remove the host-wide alias `name`. Discovery-only, alias-only
/// (ADR-0096): a later fetch of the name misses on every session, while
/// capabilities already issued, live Port projections, and deposited
/// gifts keep naming the exact actor, which stays in the Host Vat until
/// teardown. An absent alias is refused `UnknownPublication`, so a typo
/// is loud instead of an idempotent no-op.
pub fn unpublish(self: *Host, name: []const u8) error{ UnknownPublication, ReservedDurableNamespace }!void {
    self.assertOwner();
    // The mutable-alias verb refuses durable rows: a minted sturdyref's
    // name is removed only through `removeDurable`, so the two authority
    // surfaces stay distinct (ADR-0098).
    if (engine.isDurableSwiss(name)) return error.ReservedDurableNamespace;
    const removed = self.giftables.fetchRemove(name) orelse return error.UnknownPublication;
    // Key and row name are one allocation (`bindPublication`); free once.
    self.allocator.free(@constCast(removed.value.name));
    // Release the alias root the row adopted (ADR-0101): with no other
    // rooting relationship, the actor is reclaimed here rather than at
    // Host teardown.
    self.vat.releaseActor(actorIdOf(removed.value.actor));
}

/// A minted durable swiss name: fixed-size, POD, returned by value so
/// the caller owns the bytes with no allocation (ADR-0098).
pub const DurableSwiss = struct {
    bytes: [engine.durable_swiss_len]u8,

    pub fn slice(self: *const DurableSwiss) []const u8 {
        return self.bytes[0..];
    }
};

/// Mint a durable swiss name from caller-supplied entropy: the reserved
/// prefix plus the hex spelling of `entropy`. Entropy stays an explicit
/// input because this core is sans-io; the driver tier draws it at the
/// I/O boundary (ADR-0098).
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
/// (ADR-0098): unpredictable, never reassigned, removable only through
/// `removeDurable`, and structurally disjoint from every mutable alias.
/// The active table is still checked before insertion, so even an
/// entropy-collision fails loud instead of retargeting. The row adopts
/// the spawn root (ADR-0101). Durability across process restart requires
/// durable registry storage, which remains unimplemented: today a
/// restart makes the old sturdyref miss, which is the fail-closed half
/// of the contract.
pub fn publishDurable(
    self: *Host,
    entropy: [engine.durable_swiss_entropy_len]u8,
    comptime Behavior: type,
    initial: Behavior,
) !DurableSwiss {
    try self.refuseReentry();
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
    try self.refuseReentry();
    const actor = try self.vat.spawnHosted(hosted);
    errdefer self.vat.discardFreshActor(actor);
    return bindDurable(self, entropy, actor);
}

pub fn bindDurable(self: *Host, entropy: [engine.durable_swiss_entropy_len]u8, actor: actors.Ref) !DurableSwiss {
    self.assertOwner();
    const minted = mintDurableSwiss(entropy);
    if (self.giftables.contains(minted.slice())) return error.DurableNameCollision;
    const owned = try self.allocator.dupe(u8, minted.slice());
    errdefer self.allocator.free(owned);
    try self.giftables.putNoClobber(self.allocator, owned, .{ .name = owned, .actor = actor });
    return minted;
}

/// Remove a minted durable publication (ADR-0098): its live row is
/// reclaimed, future enlivenment of the old sturdyref misses, and a
/// later mint never deliberately reuses the bytes. Alias-only like
/// `unpublish` — issued capabilities and deposited gifts keep the exact
/// actor — and it releases the row's adopted root (ADR-0101). A name
/// outside the durable namespace is refused: mutable aliases leave
/// through `unpublish`.
pub fn removeDurable(self: *Host, swiss: []const u8) error{ UnknownPublication, NotDurableName }!void {
    self.assertOwner();
    if (!engine.isDurableSwiss(swiss)) return error.NotDurableName;
    const removed = self.giftables.fetchRemove(swiss) orelse return error.UnknownPublication;
    self.allocator.free(@constCast(removed.value.name));
    self.vat.releaseActor(actorIdOf(removed.value.actor));
}

/// What authenticated the durable identity a partner advertised (ADR-0105).
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
    self.assertOwner();
    try self.checkSession(session);
    if (session.served.port.peer.session_state.bootstrapLookup(name)) |position| return position.int();
    const position = try resolvePublishedTarget(self, session.peer_id, name) orelse return null;
    return position.int();
}
