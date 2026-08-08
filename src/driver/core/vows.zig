//! Host vows and resolver pairs: the read side every asynchronous host verb
//! returns, and the settle machinery behind it.
//!
//! One of `host.zig`'s responsibilities, kept beside it rather than in it. The
//! `Host` still owns the state — the vow map, the resolver index, the id
//! sources — and still presents the `vow*`, `spawnResolver`, and `resolver*`
//! verbs as its own through decl aliases, so a caller reads one `Host`
//! surface. What lives here is the row lifecycle those verbs share: mint,
//! listener chaining, retire-on-settle, and the queued completion for an
//! embedder that only drains the action queue.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

const host_mod = @import("host.zig");
const host_pump = @import("host_pump.zig");
const served_mod = @import("served.zig");
const vocab = @import("vocab.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const HostError = host_mod.HostError;
const Served = served_mod.Served;
const asFarRef = host_mod.asFarRef;

/// One live host vow. The row holds the vow's single vat listener slot
/// from mint (`fire`), so settlement always retires the row. An
/// in-process listener chains through `inner`, set once by `vowOn`, and
/// hears the resolution borrowed (zero-copy); a vow with no listener
/// settles as a queued `settled`/`failed` completion instead, so an
/// embedder that only drains the action queue still hears every outcome.
pub const VowRow = struct {
    host: *Host,
    /// The session the vow rides, or null for a resolver row (ADR-0102),
    /// which belongs to no session: session release never drops it, the
    /// session-scoped vow verbs refuse it (`SessionlessVow`), and its
    /// retire is the resolver settle itself.
    peer_id: ?engine.PeerId,
    id: u64,
    vow: actors.Vow,
    kind: Kind = .plain,
    inner: ?actors.Listener = null,
    /// The session whose turn deferred its answer onto this resolver vow
    /// (ADR-0102), recorded by `turnForwardVow` so the settle can mark it
    /// dirty — a resolver settle is the one vat settle that runs outside
    /// any `feed`, so nothing else would encode the resolved answer.
    /// Distinct from `peer_id` on purpose: that session's release must
    /// not drop this row (the resolver stays settleable; the dead wire
    /// answer just has no one to hear it).
    forwarded_peer: ?engine.PeerId = null,

    /// What settlement does to the resolution before it is dispatched: a
    /// `fetch` vow's fulfilled far capability is enrolled under a
    /// node-unique token first (ADR-0069).
    const Kind = enum { plain, fetch };

    /// The retire listener installed at mint.
    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const row: *VowRow = @ptrCast(@alignCast(ctx.?));
        settleRow(row.host, row, resolution);
    }
};

/// A host resolver pair (ADR-0102): the vow id is the read side — its
/// whole surface is the turn-scoped forward — and the resolver id is the
/// settle authority. Separate values, so holding one never confers the
/// other.
pub const ResolverPair = struct { vow_id: u64, resolver_id: u64 };

pub const ResolverIndexEntry = struct { vow_id: u64, vat_resolver: u64 };

const Projection = union(enum) { index: i64, untag: []const u8, get: []const u8 };

/// Register a one-shot in-process listener on a host vow, which hears
/// the resolution borrowed (zero-copy) and keeps that vow's settlement
/// off the action queue. A settled vow's row is already retired, so a
/// settled id and an unknown id refuse alike with `NoSuchVow` — register
/// before the feed that can settle it (an embedder that drains the
/// action queue instead has no such window: the completion waits on the
/// queue). A second listener on a live row is refused `AlreadyListening`.
pub fn vowOn(self: *Host, vow_id: u64, listener: actors.Listener) !void {
    const resolved = try resolveVowSession(self, vow_id);
    if (resolved.row.inner != null) return actors.Error.AlreadyListening;
    resolved.row.inner = listener;
}

/// Owning session for a still-live vow, used by adapters to lower opaque
/// Host references in a pipelined send before entering the wire surface.
pub fn vowSession(self: *Host, vow_id: u64) !*HostSession {
    return (try resolveVowSession(self, vow_id)).session;
}

/// Mint a resolver pair at the host tier (ADR-0102). Legal inside a
/// behavior callback, which is the primary use: the behavior mints,
/// defers its answer onto the vow (the turn-scoped forward), hands the
/// resolver id to whatever completes the work, and returns. The vow row
/// belongs to no session, so no session's release drops it; it retires
/// with the resolver settle. On an allocation failure after the vat pair
/// minted, that pair stays until vat teardown — a bounded remainder, not
/// a dangling authority.
pub fn spawnResolver(self: *Host) !ResolverPair {
    self.assertOwner();
    const pair = try self.vat.spawnVow();
    const row = try createVowRow(self, null, pair.vow, .plain, self.next_vow);
    errdefer self.allocator.destroy(row);
    try self.resolver_index.ensureUnusedCapacity(self.allocator, 1);
    self.vows.putAssumeCapacity(row.id, row);
    self.next_vow += 1;
    const resolver_id = self.next_resolver;
    self.next_resolver += 1;
    self.resolver_index.putAssumeCapacity(resolver_id, .{
        .vow_id = row.id,
        .vat_resolver = pair.resolver,
    });
    return .{ .vow_id = row.id, .resolver_id = resolver_id };
}

/// Settle a resolver vow fulfilled (ADR-0102). Top-level: the settle
/// runs the deferred answers' listeners and pumps every session they
/// dirtied, so it refuses from inside a callback (`ReenteredHost`) — the
/// worker's completion re-enters between events, on the owning thread.
/// One attempt: the resolver is consumed up front, so a second settle
/// and an unknown id refuse alike (`AlreadySettled`). `value` must be
/// capability-free — plain data is the off-turn contract; an answer that
/// carries authority takes the existing forward-to-send path instead.
pub fn resolverFulfill(self: *Host, resolver_id: u64, value: model.Argument) !void {
    try self.refuseReentry();
    try settleResolverRow(self, resolver_id, .{ .fulfilled = value });
}

/// Settle a resolver vow broken (ADR-0102); `reason` is borrowed for the
/// call. The same contract as `resolverFulfill`.
pub fn resolverBreak(self: *Host, resolver_id: u64, reason: []const u8) !void {
    try self.refuseReentry();
    try settleResolverRow(self, resolver_id, .{ .broken = reason });
}

/// Defer `turn`'s answer onto a resolver vow (ADR-0102): the answer
/// settles when the resolver fires later, as its own top-level event.
/// Legal inside a behavior callback — the turn-scoped half of the
/// resolver pair. Only a resolver vow can carry a deferred answer; a
/// wire vow's answer belongs to its session (`NotALocalVow`). Records
/// the turn's session so the later settle can encode the resolved
/// answer.
pub fn turnForwardVow(self: *Host, turn: *actors.Turn, vow_id: u64) !void {
    const row = self.vows.get(vow_id) orelse return HostError.NoSuchVow;
    if (row.peer_id != null) return HostError.NotALocalVow;
    try turn.forwardVow(row.vow);
    // forwardVow refused every non-served turn, and every served turn in
    // this vat runs on a session's Port, so the recovery cannot miss.
    const served: *Served = @fieldParentPtr("port", turn.port.?);
    const session: *HostSession = @alignCast(@fieldParentPtr("served", served));
    row.forwarded_peer = session.peer_id;
}

/// Promise pipelining: eventual-send `msg` to a host vow before it
/// resolves, minting a new vow for this call's own answer. A local vow has
/// no wire answer to pipeline against (`NotPipelineable`).
pub fn vowSend(self: *Host, vow_id: u64, msg: actors.Message) !u64 {
    const resolved = try resolveVowSession(self, vow_id);
    const vow = try resolved.session.served.sendToAnswer(&self.vat, resolved.row.vow, msg);
    const id = try mintVow(self, resolved.session, vow, .plain);
    try host_pump.dirtyThenPump(self, resolved.session.peer_id);
    return id;
}

/// Pipeline an `op:index` projection against a far host vow, minting a new
/// vow for the projected element.
pub fn vowIndex(self: *Host, vow_id: u64, index: i64) !u64 {
    return vowProjection(self, vow_id, .{ .index = index });
}

/// Pipeline an `op:untag` projection against a far host vow, minting a new
/// vow for the unwrapped payload.
pub fn vowUntag(self: *Host, vow_id: u64, tag: []const u8) !u64 {
    return vowProjection(self, vow_id, .{ .untag = tag });
}

/// Pipeline an `op:get` projection against a far host vow, minting a new
/// vow for the named Struct field (ADR-0050).
pub fn vowGet(self: *Host, vow_id: u64, field: []const u8) !u64 {
    return vowProjection(self, vow_id, .{ .get = field });
}

/// Mint the host row for a fresh vow and install its retire listener —
/// the row is heap-boxed because its address is the listener's ctx and
/// the map may rehash. The map slot and a completion's action-queue slot
/// are both reserved before the listener goes in, so a registered fire
/// always finds its row and always lands its completion.
pub fn mintVow(self: *Host, session: *HostSession, vow: actors.Vow, kind: VowRow.Kind) !u64 {
    const row = try createVowRow(self, session, vow, kind, self.next_vow);
    errdefer self.allocator.destroy(row);
    // A fresh vow holds no listener and cannot have settled (nothing has
    // driven since the send), so `on` can only fail on OOM.
    try session.served.port.on(&self.vat, vow, .{ .ctx = row, .func = VowRow.fire });
    self.vows.putAssumeCapacity(row.id, row);
    self.next_vow += 1;
    return row.id;
}

/// The shared row construction under `mintVow` and the enliven bridges:
/// allocate the row under the caller-chosen `id` and reserve both the
/// vow-map slot and action-queue capacity for every live vow plus this
/// one, so no later fire's completion append can fail — a settled vow with
/// no completion is unrepresentable. The caller installs the vat listener,
/// then commits with `putAssumeCapacity`; an id drawn fresh from
/// `next_vow` is bumped by that caller, while a parked select-or-dial
/// enliven brings the id it minted when it staged the dial.
/// `pub` for the Host-core siblings, not for embedders: splitting a Zig
/// struct across files needs the callee visible. Host-core internal.
pub fn createVowRow(self: *Host, session: ?*HostSession, vow: actors.Vow, kind: VowRow.Kind, id: u64) !*VowRow {
    const row = try self.allocator.create(VowRow);
    errdefer self.allocator.destroy(row);
    row.* = .{
        .host = self,
        .peer_id = if (session) |s| s.peer_id else null,
        .id = id,
        .vow = vow,
        .kind = kind,
    };
    try self.vows.ensureUnusedCapacity(self.allocator, 1);
    // The vow this row is for settles exactly once.
    try self.reserveActions(1);
    return row;
}

/// Retire a vow row with its resolution: remove and free the row first —
/// every later verb on the id refuses `NoSuchVow` — then route the
/// outcome. An `inner` listener hears the resolution borrowed, exactly
/// the `actors.Listener` contract; with no listener the outcome is
/// queued as an owned `settled`/`failed` completion.
fn settleRow(self: *Host, row: *VowRow, resolution: actors.Resolution) void {
    const inner = row.inner;
    const kind = row.kind;
    const maybe_peer = row.peer_id;
    const id = row.id;
    std.debug.assert(self.vows.remove(id));
    self.allocator.destroy(row);
    // A resolver row (ADR-0102) has no session and never queues a
    // completion: the settle is the resolver holder's own act, so it
    // already knows the outcome. Defensive — the resolver verbs retire
    // their row before the vat settles, so no fire reaches here.
    const peer_id = maybe_peer orelse {
        if (inner) |listener| listener.func(listener.ctx, resolution);
        return;
    };
    const routed = if (kind == .fetch) enrollFetched(self, peer_id, resolution) else resolution;
    if (inner) |listener| {
        listener.func(listener.ctx, routed);
        return;
    }
    queueCompletion(self, peer_id, id, routed);
}

/// Settle a vow by id — the enliven bridge's path to the shared retire
/// logic. A row already gone (the session was released and dropped
/// its rows) has no one to tell.
/// `pub` for the Host-core siblings, not for embedders: splitting a Zig
/// struct across files needs the callee visible. Host-core internal.
pub fn fireVow(self: *Host, vow_id: u64, resolution: actors.Resolution) void {
    const row = self.vows.get(vow_id) orelse return;
    settleRow(self, row, resolution);
}

/// Queue a settled vow's completion for the embedder — infallible by
/// reservation (`createVowRow` and every fallible enqueue keep one spare
/// slot per live vow), so a fire can never strand. The fulfilled value
/// is deep-cloned onto the host: the settle fires inside `feed` while
/// the resolution is turn-borrowed, and the embedder drains after `feed`
/// returns, so an owning completion is the only correct holder (the
/// in-process `vowOn` path stays borrowed and pays no clone). A clone
/// failure degrades to a `failed` completion with an empty message —
/// zero-allocation — rather than a stranded vow.
fn queueCompletion(self: *Host, peer_id: engine.PeerId, vow_id: u64, resolution: actors.Resolution) void {
    switch (resolution) {
        .fulfilled => |value| {
            const cloned = model.cloneArgument(self.allocator, value) catch {
                self.actions.pushReserved(.{ .failed = .{ .peer_id = peer_id, .vow_id = vow_id, .message = "" } });
                return;
            };
            self.actions.pushReserved(.{ .settled = .{ .peer_id = peer_id, .vow_id = vow_id, .value = cloned } });
        },
        .broken => |message| {
            const owned: []const u8 = self.allocator.dupe(u8, message) catch "";
            self.actions.pushReserved(.{ .failed = .{ .peer_id = peer_id, .vow_id = vow_id, .message = owned } });
        },
        // Unreachable by construction — the host claims every inbound
        // give before the vat can settle a vow with it (auto-redeem) —
        // but a defensive break beats a crash if that invariant moves.
        .give => {
            const owned: []const u8 = self.allocator.dupe(u8, "raw handoff reached a settle listener") catch "";
            self.actions.pushReserved(.{ .failed = .{ .peer_id = peer_id, .vow_id = vow_id, .message = owned } });
        },
    }
}

fn vowProjection(self: *Host, vow_id: u64, projection: Projection) !u64 {
    const resolved = try resolveVowSession(self, vow_id);
    const source = switch (resolved.row.vow) {
        .far => |answer| answer,
        // A local vow has no wire answer to project against.
        .local => return vocab.Error.NotPipelineable,
    };
    const peer = resolved.session.served.port.peer;
    const answer = model.AnswerPosition.from(peer.allocateAnswer());
    const receiver: model.Reference = .{ .promise = .{ .answer_position = source } };
    switch (projection) {
        .index => |index| try peer.sendCopying(.{ .index = .{
            .receiver = receiver,
            .index = .{ .integer = index },
            .answer = answer,
        } }),
        .untag => |tag| try peer.sendCopying(.{ .untag = .{ .receiver = receiver, .tag = tag, .answer = answer } }),
        .get => |field| try peer.sendCopying(.{ .get = .{ .receiver = receiver, .field = field, .answer = answer } }),
    }
    const id = try mintVow(self, resolved.session, .{ .far = answer }, .plain);
    try host_pump.dirtyThenPump(self, resolved.session.peer_id);
    return id;
}

/// The live session and row a latch-legal vow verb operates on: assert the
/// owner, resolve the vow's row and its session, and refuse a settled or
/// unknown vow (its row already retired) or a dead session alike with
/// `NoSuchVow`. `vowOn`, `vowSend`, and `vowProjection` share this prelude
/// and differ only in the body that follows.
fn resolveVowSession(self: *Host, vow_id: u64) HostError!struct { row: *VowRow, session: *HostSession } {
    self.assertOwner();
    const row = self.vows.get(vow_id) orelse return HostError.NoSuchVow;
    const peer_id = row.peer_id orelse return HostError.SessionlessVow;
    const session = self.sessions.get(peer_id) orelse return HostError.NoSuchVow;
    try self.checkSession(session);
    return .{ .row = row, .session = session };
}

fn settleResolverRow(self: *Host, resolver_id: u64, resolution: actors.Resolution) !void {
    const entry = self.resolver_index.fetchRemove(resolver_id) orelse return actors.Error.AlreadySettled;
    // Retire the row before the settle, mirroring `settleRow`: every
    // later verb on the vow id refuses `NoSuchVow` from here on.
    const row = self.vows.fetchRemove(entry.value.vow_id) orelse unreachable; // index row implies vow row
    const forwarded_peer = row.value.forwarded_peer;
    self.allocator.destroy(row.value);
    switch (resolution) {
        .fulfilled => |value| try self.vat.fulfillVow(entry.value.vat_resolver, value),
        .broken => |reason| try self.vat.breakVow(entry.value.vat_resolver, reason),
        .give => unreachable, // no resolver verb spells a give
    }
    // This settle runs outside any feed, so the deferred answer's session
    // is encoded here or not at all.
    if (forwarded_peer) |peer_id| host_pump.markDirty(self, peer_id);
    try host_pump.finishVerb(self);
}

/// The fetch settlement mapping: enroll a fulfilled far capability under
/// a node-unique token *before* the outcome is dispatched, so a reply
/// that immediately re-gifts it routes to the right exporter. A
/// reference already in the token range (an auto-redeemed give settled
/// with a routable token) passes through unwrapped — enrolling a token
/// would double-wrap it into a reference no session can lower. An
/// unenrollable capability would mis-route a later re-gift, so it fails
/// loud as a break rather than surfacing half-usable.
fn enrollFetched(self: *Host, peer_id: engine.PeerId, resolution: actors.Resolution) actors.Resolution {
    if (resolution == .fulfilled) if (asFarRef(resolution.fulfilled)) |far| {
        switch (model.ImportName.classify(far.import_position.int())) {
            // Already a token: enrolling again would double-wrap it into a
            // reference no session can lower.
            .token => {},
            .wire => {
                const token = self.node.enrollForeign(peer_id, .{ .far = far }) catch |err| {
                    return .{ .broken = @errorName(err) };
                };
                return .{ .fulfilled = .{ .reference = token } };
            },
        }
    };
    return resolution;
}

/// Drop the vow rows homed on a released session, so the map does not
/// grow with session churn. The session's far rows already retired
/// through its vow break; what remains is never-fired rows whose vat
/// listener dies with the vat, freed here. Removal invalidates the
/// iterator, so each scan collects a bounded batch of doomed ids into
/// stack scratch (allocation-free — this runs inside teardown) and
/// removes them between scans; one scan per batch, not one per row.
pub fn dropVowRows(self: *Host, peer_id: engine.PeerId) void {
    var doomed: [64]u64 = undefined;
    while (true) {
        var n: usize = 0;
        var it = self.vows.iterator();
        while (it.next()) |entry| {
            const row_peer = entry.value_ptr.*.peer_id orelse continue; // a resolver row outlives every session
            if (row_peer != peer_id) continue;
            doomed[n] = entry.key_ptr.*;
            n += 1;
            if (n == doomed.len) break;
        }
        if (n == 0) return;
        for (doomed[0..n]) |id| {
            const row = self.vows.fetchRemove(id) orelse unreachable;
            self.allocator.destroy(row.value);
        }
    }
}
