//! Bootstrap-object methods the engine answers automatically (ADR-0006 / ADR-0009).
//!
//! `fetch` resolves a swissnum to a local export. `deposit-gift` / `withdraw-gift`
//! are the exporter-side handoff bootstrap methods. Each Peer owns its session's
//! `gifts.GiftRegistry` (ADR-0100). The session spine still validates frame
//! well-formedness, while the verified responders in this module resolve the
//! required live sessions before any gift moves.

const std = @import("std");

const model = @import("model");
const crypto = @import("foundation").crypto;
const session_mod = @import("session");
const handoff_names = @import("handoff_names.zig");
const PeerHandle = @import("peer_handle.zig").PeerHandle;
const signatures = @import("bootstrap/signatures.zig");
pub const gifts = @import("bootstrap/gifts.zig");

/// A recognized inbound bootstrap-fetch.
pub const FetchRequest = struct {
    swissnum: []const u8,
    answer: model.AnswerName,
};

/// Session-stamped context borrowed by the composition during fetch admission.
/// The composition sees only names the session's own publications missed.
pub const FetchContext = struct {
    swissnum: []const u8,
    answer: session_mod.AnswerTarget,
};
pub const FetchOutcome = union(enum) {
    found: model.ExportPosition,
    missing,
    deferred,
    refused: anyerror,
};

/// A recognized inbound `deposit-gift` bootstrap call.
pub const DepositRequest = struct {
    gift_id: []const u8,
    gifted: model.view.Reference,
    answer: ?model.AnswerName,
};

/// A recognized inbound `withdraw-gift` bootstrap call.
pub const WithdrawRequest = struct {
    receive: model.view.HandoffReceive,
    answer: model.AnswerName,
};

pub const Request = union(enum) {
    fetch: FetchRequest,
    deposit_gift: DepositRequest,
    withdraw_gift: WithdrawRequest,
};

/// Match a give's side and session name against one already-authenticated
/// gifter session. The caller owns authentication and session lookup. This
/// helper single-sources the OCapN name derivation after those checks.
pub fn gifterKeyForSession(
    session: *const session_mod.Session,
    gifter_side: [32]u8,
    session_name: []const u8,
) ?[32]u8 {
    if (session_name.len != 32) return null;
    const partner_key = session.partnerSessionKey() orelse return null;
    const derived_gifter_side = handoff_names.sideName(partner_key) catch return null;
    if (!std.mem.eql(u8, &derived_gifter_side, &gifter_side)) return null;
    const local_key = session.localSessionKey() orelse return null;
    const local_side = handoff_names.sideName(local_key) catch return null;
    const expected_session = handoff_names.sessionName(gifter_side, local_side);
    if (!std.mem.eql(u8, session_name, &expected_session)) return null;
    var key: [32]u8 = undefined;
    @memcpy(&key, partner_key);
    return key;
}

/// Recognize an inbound bootstrap `op:deliver`, or null when the deliver is not a
/// bootstrap method this peer auto-answers. The bootstrap object is one of *our*
/// exports, so only a `.near` target can name it (`exportPosition`). A `.far`
/// target whose partner-named import position happens to be 0 falls through to
/// ordinary handling instead of being auto-served.
pub fn pendingBootstrapAction(
    deliver: model.view.Deliver,
    prepared_virtual_answer: ?model.VirtualAnswer,
) model.view.ProjectError!?Request {
    const target_export = deliver.target.exportPosition() orelse return null;
    if (target_export.int() != session_mod.BOOTSTRAP_POSITION) return null;

    // Forward peel: one linear pass over the arg region, matching validate.zig,
    // no `len()` pre-walk and no per-index `at(i)` re-scan from byte 0.
    var it = deliver.args.iterator();
    const method = switch ((try it.next()) orelse return null) {
        .symbol => |symbol| symbol,
        else => return null,
    };

    if (std.mem.eql(u8, method, "deposit-gift")) {
        const gift_id = switch ((try it.next()) orelse return null) {
            .bytes => |bytes| bytes,
            else => return null,
        };
        const gifted = switch ((try it.next()) orelse return null) {
            .reference => |reference| reference,
            else => return null,
        };
        if ((try it.next()) != null) return null;
        const answer = preparedAnswerForDeliver(deliver, prepared_virtual_answer);
        return .{ .deposit_gift = .{ .gift_id = gift_id, .gifted = gifted, .answer = answer } };
    }

    const answer = preparedAnswerForDeliver(deliver, prepared_virtual_answer) orelse return null;

    if (std.mem.eql(u8, method, "fetch")) {
        const swissnum = switch ((try it.next()) orelse return null) {
            .bytes => |bytes| bytes,
            else => return null,
        };
        if ((try it.next()) != null) return null;
        return .{ .fetch = .{ .swissnum = swissnum, .answer = answer } };
    }

    if (std.mem.eql(u8, method, "withdraw-gift")) {
        const handoff = switch ((try it.next()) orelse return null) {
            .handoff => |h| h,
            else => return null,
        };
        if ((try it.next()) != null) return null;
        const receive = switch (handoff) {
            .receive => |receive| receive,
            .give => return null,
        };
        return .{ .withdraw_gift = .{ .receive = receive, .answer = answer } };
    }

    return null;
}

/// The answer available during inbound classification, before a prepared V1.0
/// resolver-only answer has committed its Session link.
fn preparedAnswerForDeliver(
    deliver: model.view.Deliver,
    virtual_answer: ?model.VirtualAnswer,
) ?model.AnswerName {
    if (deliver.answer) |answer| return .fromWire(answer);
    if (virtual_answer) |answer| return .fromVirtual(answer);
    return null;
}

/// The inbound answer a deliver settles. It is the deliver's wire answer
/// position, or, for a V1.0 resolver-only deliver that carried no wire answer,
/// the virtual answer the engine installed for the resolver import (ADR-0065).
/// The resolve-me-desc may arrive `.far` (inbound from the wire) or `.near` (a
/// synthesized pipelined-drain event that round-tripped through encode/decode
/// and flipped the perspective). `position` accepts both, since near and far
/// name one integer space. This is the one owner of that mapping. The actor
/// layer reaches it through `Peer.answerForDeliver` and never re-decodes the
/// resolver descriptor. It is generic over the deliver representation: the
/// borrowed `model.view.Deliver` (inbound wire) and the owned `model.Deliver`
/// (a queued pipelined call) both carry `.answer` and a `.resolve_me_desc` with
/// `.position()`.
pub fn answerForDeliver(deliver: anytype, session: *const session_mod.Session) ?model.AnswerName {
    return if (deliver.answer) |answer| .fromWire(answer) else blk: {
        if (deliver.resolve_me_desc) |rmd| {
            if (rmd.position()) |import_position| {
                break :blk session.answerForResolverImport(model.ImportPosition.from(import_position));
            }
        }
        break :blk null;
    };
}

pub fn resolveForSwissnum(
    session: *session_mod.Session,
    local_projection: ?gifts.LocalObjectProjection,
    scope: ?PeerHandle,
    request: FetchRequest,
) !?model.Resolution {
    // The session's own publication answers first, so no publication made
    // outside the session can take over a name inside it.
    const outcome: FetchOutcome = if (session.bootstrapLookup(request.swissnum)) |position|
        .{ .found = position }
    else if (local_projection) |p|
        try p.resolve_fetch(p.ctx, scope orelse return session_mod.Error.InvalidGift, .{
            .swissnum = request.swissnum,
            .answer = session.answerTargetNamed(request.answer) orelse return error.InvalidReference,
        })
    else
        .missing;
    return switch (outcome) {
        .found => |position| .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = position } } } },
        .deferred => null,
        // Named: one owned diagnostic on refusal. Successful fetch is POD;
        // the ordinary settlement queue consumes either resolution.
        .missing => .{ .@"break" = .{ .message = try session.allocator.dupe(u8, "unknown swissnum") } },
        .refused => |err| .{ .@"break" = .{ .message = try session.allocator.dupe(u8, @errorName(err)) } },
    };
}

pub fn resolveForDeposit(
    session: *session_mod.Session,
    registry: *gifts.GiftRegistry,
    local_projection: ?gifts.LocalObjectProjection,
    scope: ?PeerHandle,
    request: DepositRequest,
) !?model.Resolution {
    try session.validateHandoffGiftId(request.gift_id);
    const gifted = try request.gifted.toOwned(session.allocator);
    var transferred = false;
    errdefer if (!transferred) model.freeReference(session.allocator, gifted);
    // A near is a name in the depositing session. A Host composition captures
    // the exact local target now, while both the Port and position are known.
    // A standalone Peer has no local-object identity seam, so it cannot carry
    // a session-local near across the two sessions handoff requires.
    if (gifted == .near) {
        if (local_projection) |p| {
            const target = p.capture(p.ctx, scope orelse return session_mod.Error.InvalidGift, gifted.near.export_position) orelse return session_mod.Error.InvalidGift;
            transferred = true;
            model.freeReference(session.allocator, gifted);
            registry.depositLocalTarget(
                session.allocator,
                session.limits,
                local_projection,
                request.gift_id,
                target,
            ) catch |err| {
                // The capture retained the deposit root (ADR-0101); a refused
                // deposit must hand it back or the actor leaks unrooted.
                p.release_target(p.ctx, target);
                return err;
            };
            if (request.answer == null) return null;
            return .{ .fulfill = .{ .void = {} } };
        }
        return session_mod.Error.InvalidGift;
    }
    // A far is the same argument from the import side, and it has no swissnum
    // door to come in through. It names an object the *gifter* hosts, which is
    // not something this exporter can serve to anyone; handed back verbatim on
    // the recipient's session it would say `<desc:export N>` for an export that
    // session never made. Refusing it here blames the gifter, on the gifter's
    // own session, at the moment it deposits. Left to be discovered at withdraw
    // it would instead abort the recipient's session, which is a seam a gifter
    // could aim: `Session.validateSend` refuses the fulfill (the backstop that
    // also covers the in-process `gifts.GiftRegistry.depositOwned`), and by then the
    // party that earned the refusal is no longer the party that pays it.
    if (gifted == .far) return session_mod.Error.InvalidGift;
    // This registry belongs to the depositing session. The give's signed
    // session name selects it at withdrawal, so no peer-supplied namespace key
    // is retained beside the gift id.
    try registry.depositOwned(session.allocator, session.limits, local_projection, request.gift_id, gifted);
    transferred = true;
    if (request.answer == null) return null;
    return .{ .fulfill = .{ .void = {} } };
}

/// The withdraw responder's verdict.
pub const WithdrawOutcome = union(enum) {
    /// The withdraw settled: an owned resolution plus, on success, an
    /// infallible gift commit. The caller queues the settlement before applying
    /// the commit, so allocation failure leaves the gift retryable.
    settled: PreparedWithdraw,
    /// The gift id names no *live* deposit, the gift is unknown, or its prior
    /// row is already consumed and awaits a re-deposit. `deposit-gift` and
    /// `withdraw-gift` travel on different sessions, so the withdraw can
    /// legitimately arrive first, and the protocol expects the exporter to
    /// answer once the deposit lands rather than refuse (the upstream OCapN
    /// suite pins this). The caller parks the withdraw. `Peer.step` retries
    /// parked withdraws, and one whose deposit never arrives stays parked until
    /// session teardown, deadlines belong to the application, above glowcap.
    awaiting_deposit: struct {
        receive: PendingReceive,
        gifter_peer_handle: PeerHandle,
    },
};

/// The verified subset a withdrawal needs after its deposit was absent. The
/// signatures, locator, receiving names, and verbatim signed envelope have
/// already done their work and are not retained. Only `gift_id` is variable
/// partner-sized storage. The authenticated keys/session name are fixed-width.
pub const PendingReceive = struct {
    handoff_count: u64,
    recipient_key: [crypto.PEER_KEY_BYTES]u8,
    gifter_exporter_session: [32]u8,
    gifter_side: [32]u8,
    gift_id: []u8,

    fn initVerified(allocator: std.mem.Allocator, receive: model.view.HandoffReceive) error{OutOfMemory}!?PendingReceive {
        var recipient_key: [crypto.PEER_KEY_BYTES]u8 = undefined;
        var gifter_exporter_session: [32]u8 = undefined;
        var gifter_side: [32]u8 = undefined;
        // Production resolution establishes these widths, but the sans-I/O
        // resolver seam is application-supplied. Reject a permissive custom
        // resolver's malformed signed names before fixed-width copies.
        if (receive.signed_give.recipient_key.len != recipient_key.len or
            receive.signed_give.gifter_exporter_session.len != gifter_exporter_session.len or
            receive.signed_give.gifter_side.len != gifter_side.len)
        {
            return null;
        }
        @memcpy(&recipient_key, receive.signed_give.recipient_key);
        @memcpy(&gifter_exporter_session, receive.signed_give.gifter_exporter_session);
        @memcpy(&gifter_side, receive.signed_give.gifter_side);
        return .{
            .handoff_count = receive.handoff_count,
            .recipient_key = recipient_key,
            .gifter_exporter_session = gifter_exporter_session,
            .gifter_side = gifter_side,
            .gift_id = try allocator.dupe(u8, receive.signed_give.gift_id),
        };
    }

    pub fn retainedBytes(self: PendingReceive) usize {
        return self.gift_id.len;
    }

    pub fn deinit(self: *PendingReceive, allocator: std.mem.Allocator) void {
        allocator.free(self.gift_id);
    }
};

fn pendingGiftClaim(receive: PendingReceive) gifts.WithdrawGiftClaim {
    return .{
        .handoff_count = receive.handoff_count,
        .gift_id = receive.gift_id,
        .recipient_key = &receive.recipient_key,
    };
}

pub const PreparedWithdraw = struct {
    answer: model.AnswerName,
    resolution: ?model.Resolution,
    commit: ?struct {
        prepared: gifts.GiftRegistry.PreparedWithdrawCommit,
        gift_registry: *gifts.GiftRegistry,
        projection: ?struct {
            seam: gifts.LocalObjectProjection,
            scope: PeerHandle,
            target: u64,
            projected: gifts.ProjectedLocalTarget,
        } = null,
    } = null,

    pub fn deinit(self: *PreparedWithdraw, allocator: std.mem.Allocator) void {
        if (self.resolution) |resolution| model.freeResolution(allocator, resolution);
        self.resolution = null;
        if (self.commit) |commit| if (commit.projection) |projection| {
            projection.seam.rollback(
                projection.seam.ctx,
                projection.scope,
                projection.target,
                projection.projected,
            );
        };
        self.commit = null;
    }

    pub fn takeResolution(self: *PreparedWithdraw) !model.Resolution {
        const resolution = self.resolution orelse return error.PreparedSettlementConsumed;
        self.resolution = null;
        return resolution;
    }

    /// Finish a successfully queued withdrawal. Every fallible resource was
    /// reserved by `resolveForWithdraw`. This consumes the gift infallibly and
    /// preserves a newly shared Port projection.
    pub fn apply(self: *PreparedWithdraw, allocator: std.mem.Allocator, projection: ?gifts.LocalObjectProjection, counters: *gifts.GiftRegistry) void {
        const commit = self.commit orelse return;
        if (counters.commitWithdraw(commit.gift_registry, allocator, projection, commit.prepared)) |moved|
            model.freeReference(allocator, moved);
        self.commit = null;
    }
};

fn preparedBreak(allocator: std.mem.Allocator, answer: model.AnswerName, reason: []const u8) !PreparedWithdraw {
    return .{
        .answer = answer,
        .resolution = .{ .@"break" = .{ .message = try allocator.dupe(u8, reason) } },
    };
}

/// The gifter side a signed give names, fixed-width for the session resolver.
/// A give whose side name is not 32 bytes never verified. A zero side matches
/// no deposited row, so it falls through to `InvalidGift`.
fn giveGifterSide(give: model.view.HandoffGive) [32]u8 {
    var gifter: [32]u8 = undefined;
    if (give.gifter_side.len == gifter.len) {
        @memcpy(&gifter, give.gifter_side);
    } else {
        gifter = @as([32]u8, @splat(0));
    }
    return gifter;
}

/// Resolve a borrowed give to the still-open Gifter–Exporter session it names.
/// This performs no allocation or signature work, so admission checks can run
/// before materializing untrusted handoff data.
pub fn liveGifterSession(resolver: ?gifts.GifterSessionResolver, give: model.view.HandoffGive) ?gifts.GifterSession {
    const r = resolver orelse return null;
    return r.resolve(r.ctx, giveGifterSide(give), give.gifter_exporter_session);
}

pub fn resolveForWithdraw(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    counters: *gifts.GiftRegistry,
    gifter_session_resolver: ?gifts.GifterSessionResolver,
    local_projection: ?gifts.LocalObjectProjection,
    scope: ?PeerHandle,
    request: WithdrawRequest,
) !WithdrawOutcome {
    const borrowed_receive = request.receive;
    session.validateHandoffGiftId(borrowed_receive.signed_give.gift_id) catch {
        return .{ .settled = try preparedBreak(allocator, request.answer, "handoff gift id has invalid width") };
    };
    const gifter_session = liveGifterSession(gifter_session_resolver, borrowed_receive.signed_give) orelse
        return .{ .settled = try preparedBreak(allocator, request.answer, "gifter session is not open") };
    // Derive the receiver identity this withdraw is checked against from *this*
    // session's keys. The receive names the recipient-to-exporter session, and
    // that is the session the withdraw arrived on, so its two ends are the
    // partner key our handshake established and our own. The give's recipient
    // key is a different key: it is the one the receive is signed with, held by
    // the recipient on its connection to the gifter.
    //
    // A session with no partner key is one no signed handoff can be addressed
    // to, so there is nothing to derive and nothing to check. That is the
    // in-process substrate the test harnesses drive.
    if (!try signatures.verifyReceiveWithGifterKey(allocator, borrowed_receive, &gifter_session.key)) {
        return .{ .settled = try preparedBreak(allocator, request.answer, "invalid handoff signature") };
    }

    const expected: ?handoff_names.ExpectedReceiver = derived: {
        const partner_key = session.partnerSessionKey() orelse break :derived null;
        const names = if (session.localSessionKey()) |our_key|
            handoff_names.ExpectedReceiver.derive(partner_key, our_key)
        else
            handoff_names.ExpectedReceiver.fromPartner(partner_key);
        break :derived names catch {
            return .{ .settled = try preparedBreak(allocator, request.answer, "handoff session names a malformed key") };
        };
    };

    counters.validateWithdrawEnvelopeView(borrowed_receive, expected) catch |err| {
        return .{ .settled = try preparedBreak(allocator, request.answer, withdrawRefusalReason(err)) };
    };

    if (!gifter_session.gifts.giftLive(borrowed_receive.signed_give.gift_id)) {
        const pending = try PendingReceive.initVerified(allocator, borrowed_receive) orelse
            return .{ .settled = try preparedBreak(allocator, request.answer, "handoff session names a malformed key") };
        return .{ .awaiting_deposit = .{
            .receive = pending,
            .gifter_peer_handle = gifter_session.peer_handle,
        } };
    }

    return .{ .settled = try prepareGiftWithdraw(
        allocator,
        gifter_session.gifts,
        local_projection,
        scope,
        gifts.giftClaim(borrowed_receive),
        request.answer,
    ) };
}

/// Settle a pending withdrawal whose signatures, session names, and replay
/// count were accepted before it waited. The borrowed receive remains owned by
/// the pending row. Only the registry-owned gift key enters the commit.
pub fn resolvePendingWithdraw(
    allocator: std.mem.Allocator,
    gifter_session_resolver: ?gifts.GifterSessionResolver,
    local_projection: ?gifts.LocalObjectProjection,
    scope: ?PeerHandle,
    receive: PendingReceive,
    answer: model.AnswerName,
) !?PreparedWithdraw {
    const gifter_side = receive.gifter_side;
    const gifter_session = if (gifter_session_resolver) |resolver|
        resolver.resolve(resolver.ctx, gifter_side, receive.gifter_exporter_session[0..])
    else
        null;
    const live = gifter_session orelse return try preparedBreak(allocator, answer, "gifter session is not open");
    if (!live.gifts.giftLive(receive.gift_id)) return null;
    return try prepareGiftWithdraw(
        allocator,
        live.gifts,
        local_projection,
        scope,
        pendingGiftClaim(receive),
        answer,
    );
}

fn prepareGiftWithdraw(
    allocator: std.mem.Allocator,
    deposited: *gifts.GiftRegistry,
    local_projection: ?gifts.LocalObjectProjection,
    scope: ?PeerHandle,
    claim: gifts.WithdrawGiftClaim,
    answer: model.AnswerName,
) !PreparedWithdraw {
    deposited.validateWithdrawGiftClaim(claim) catch |err| {
        return preparedBreak(allocator, answer, withdrawRefusalReason(err));
    };

    // Consume the gift only once the object is confirmed deliverable.
    // `commitWithdraw` records the monotonic handoff-count and reclaims the
    // gift's payload, so a break returned *after* it would permanently burn a
    // legitimately-deposited gift on a recoverable condition, the recipient
    // could never retry, since a re-withdraw parks and the recorded count makes
    // a same-count retry a replay. So each arm confirms it can deliver before it
    // prepares that commit.

    // The gift is live (checked above), so its payload is present; each arm
    // decides what this session can hand back.
    switch (deposited.giftPayload(claim.gift_id).?) {
        // Project the exact target retained at deposit onto this Port. Failure
        // leaves the gift untouched. An immediately handled receive also leaves
        // its replay counter untouched; an accepted early receive has already
        // advanced that counter and can retry with a higher count.
        .local_target => |target| {
            const p = local_projection orelse return preparedBreak(allocator, answer, "gift target cannot be projected");
            const projection_scope = scope orelse return preparedBreak(allocator, answer, "gift target cannot be projected");
            const projected = p.project(p.ctx, projection_scope, target) catch return preparedBreak(allocator, answer, "gift target cannot be projected");
            var projection_live = true;
            errdefer if (projection_live) p.rollback(p.ctx, projection_scope, target, projected);
            const commit = try gifts.GiftRegistry.prepareWithdrawCommit(deposited, claim);
            const resolution: model.Resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = projected.export_position } } } };
            projection_live = false;
            return .{
                .answer = answer,
                .resolution = resolution,
                .commit = .{
                    .prepared = commit,
                    .gift_registry = deposited,
                    .projection = .{
                        .seam = p,
                        .scope = projection_scope,
                        .target = target,
                        .projected = projected,
                    },
                },
            };
        },
        // A verbatim gifted cap: `commitWithdraw` moves it out of the row after
        // the handoff count is recorded. Preparation is fallible; commit is not.
        .verbatim_cap => {
            const gifted = deposited.giftedCap(claim.gift_id).?;
            const commit = try gifts.GiftRegistry.prepareWithdrawCommit(deposited, claim);
            const resolution: model.Resolution = .{ .fulfill = .{ .reference = try model.cloneReference(allocator, gifted) } };
            return .{
                .answer = answer,
                .resolution = resolution,
                .commit = .{
                    .prepared = commit,
                    .gift_registry = deposited,
                },
            };
        },
        // Provenance-only deposit with nothing to hand back here. Leave the gift
        // live rather than consume a gift this session cannot satisfy.
        .provenance => return preparedBreak(allocator, answer, "gift not deposited"),
    }
}

/// The break reason a refused withdraw reports, keyed on the typed validation
/// error so a replayed certificate and a missing or already-consumed gift read
/// as the distinct failures they are.
fn withdrawRefusalReason(err: session_mod.Error) []const u8 {
    return switch (err) {
        session_mod.Error.HandoffReplay => "handoff-receive replayed or out-of-order handoff-count",
        session_mod.Error.InvalidGift => "gift is unknown or consumed, or names a different recipient",
        session_mod.Error.InvalidHandoffSession => "handoff-receive names the wrong receiving session or side",
        else => "invalid handoff withdraw",
    };
}
