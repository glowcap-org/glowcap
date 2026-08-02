//! Bootstrap-object methods the engine answers automatically (ADR-0006 / ADR-0009).
//!
//! `fetch` resolves a swissnum to a local export. `deposit-gift` / `withdraw-gift`
//! are the exporter-side handoff bootstrap methods. Each Peer owns its session's
//! `GiftRegistry` (ADR-0100); the session spine still validates frame
//! well-formedness, while the verified responders in this module resolve the
//! required live sessions before any gift moves.

const std = @import("std");

const model = @import("model");
const codec = @import("codec");
const crypto = @import("foundation").crypto;
const session_mod = @import("session");
const handoff_names = @import("handoff_names.zig");
const PeerId = @import("peer_id.zig").PeerId;

/// A recognized inbound bootstrap-fetch.
pub const FetchRequest = struct {
    swissnum: []const u8,
    answer: model.AnswerPosition,
};

/// A recognized inbound `deposit-gift` bootstrap call.
pub const DepositRequest = struct {
    gift_id: []const u8,
    gifted: model.view.Reference,
    answer: ?model.AnswerPosition,
};

/// A recognized inbound `withdraw-gift` bootstrap call.
pub const WithdrawRequest = struct {
    receive: model.view.HandoffReceive,
    answer: model.AnswerPosition,
};

pub const Request = union(enum) {
    fetch: FetchRequest,
    deposit_gift: DepositRequest,
    withdraw_gift: WithdrawRequest,
};

/// Adapter seam for a composition whose Ports project one local object space.
/// The engine keeps targets opaque: the composition resolves bootstrap names,
/// captures exact gifts, and projects retained targets onto another Port.
pub const LocalObjectProjection = struct {
    ctx: ?*anyopaque,
    resolve_name: *const fn (ctx: ?*anyopaque, scope: PeerId, swissnum: []const u8) anyerror!?model.ExportPosition,
    capture: *const fn (ctx: ?*anyopaque, scope: PeerId, export_position: model.ExportPosition) ?u64,
    project: *const fn (ctx: ?*anyopaque, scope: PeerId, target: u64) anyerror!ProjectedLocalTarget,
    rollback: *const fn (ctx: ?*anyopaque, scope: PeerId, target: u64, projected: ProjectedLocalTarget) void,
    /// Release the deposit-capture root on a `local_target` gift row that died
    /// (ADR-0101): consumed by withdrawal, replaced by a re-deposit, or
    /// destroyed with its session's Peer.
    release_target: *const fn (ctx: ?*anyopaque, target: u64) void,
};

/// A live gifter session named by a signed give. Deposits remain owned by that
/// session's registry; the public key authenticates the give.
pub const GifterSession = struct {
    /// Node-local session identity for scheduler dependency routing. It conveys
    /// no wire authority, but every resolver must identify the live session it
    /// returned so a Node-composed receiver cannot park without a wake route.
    peer_id: PeerId,
    key: [32]u8,
    gifts: *GiftRegistry,
};

/// Resolve the verified gifter session named by a signed give. OCapN requires
/// that session to remain live while a missing gift waits.
pub const GifterSessionResolver = struct {
    ctx: ?*anyopaque,
    resolve: *const fn (ctx: ?*anyopaque, gifter_side: [32]u8, session_name: []const u8) ?GifterSession,
};

/// The authority fields consulted after signature verification. This is a
/// narrow internal view, not a second wire model: owned, borrowed, and parked
/// representations each project into it at the call boundary.
const WithdrawGiftClaim = struct {
    handoff_count: u64,
    gift_id: []const u8,
    recipient_key: []const u8,
};

const WithdrawEnvelopeClaim = struct {
    gift: WithdrawGiftClaim,
    receiving_session: []const u8,
    receiving_side: []const u8,
};

fn ownedGiftClaim(receive: model.HandoffReceive) WithdrawGiftClaim {
    return .{
        .handoff_count = receive.handoff_count,
        .gift_id = receive.signed_give.gift_id,
        .recipient_key = receive.signed_give.recipient_key,
    };
}

fn ownedEnvelopeClaim(receive: model.HandoffReceive) WithdrawEnvelopeClaim {
    return .{
        .gift = ownedGiftClaim(receive),
        .receiving_session = receive.receiving_session,
        .receiving_side = receive.receiving_side,
    };
}

fn borrowedGiftClaim(receive: model.view.HandoffReceive) WithdrawGiftClaim {
    return .{
        .handoff_count = receive.handoff_count,
        .gift_id = receive.signed_give.gift_id,
        .recipient_key = receive.signed_give.recipient_key,
    };
}

fn borrowedEnvelopeClaim(receive: model.view.HandoffReceive) WithdrawEnvelopeClaim {
    return .{
        .gift = borrowedGiftClaim(receive),
        .receiving_session = receive.receiving_session,
        .receiving_side = receive.receiving_side,
    };
}

fn pendingGiftClaim(receive: PendingReceive) WithdrawGiftClaim {
    return .{
        .handoff_count = receive.handoff_count,
        .gift_id = receive.gift_id,
        .recipient_key = &receive.recipient_key,
    };
}

/// Match a give's side and session name against one already-authenticated
/// gifter session. The caller owns authentication and session lookup; this
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

pub const ProjectedLocalTarget = struct {
    export_position: model.ExportPosition,
    created: bool,
};

/// What a deposit hands back at withdraw. A sum, not a product: provenance,
/// an exact protocol reference, or one opaque local target.
const GiftPayload = union(enum) {
    /// Provenance-only: no capability rode the deposit (the cross-peer give
    /// routing path). Withdrawable by the recipient named here, whom the
    /// withdrawal's signed give must match — a bootstrap `deposit-gift` names no
    /// recipient at deposit, so the signed give names one at withdraw and the
    /// signature check binds it. Never empty: `deposit` refuses an empty key.
    provenance: []const u8,
    /// The gifter deposited a session-independent protocol reference; it is
    /// returned verbatim on a successful withdraw.
    verbatim_cap: model.Reference,
    /// Stable identity supplied by the local-object composition. No swiss name
    /// is retained or consulted after deposit.
    local_target: u64,
};

/// One deposited, not-yet-consumed gift. The registry owns everything the
/// `payload` arm holds; rows are freed precisely, on overwrite,
/// on withdraw (a consumed gift's whole row is removed — replay stays blocked by
/// the session's monotonic accepted count, so no spent marker accrues), or at
/// `deinit`.
const GiftEntry = struct {
    /// The deposit mode and what it hands back at withdraw.
    payload: GiftPayload,
};

/// One CapTP session's gift and handoff-count authority. Deposits made on this
/// session live in `gifts`; receives arriving on this session use the accepted
/// count; gives redeemed through this session use the emitted count.
/// Cross-session withdrawal reaches the gifter's
/// registry only through a live `GifterSessionResolver` result.
///
/// Like the rest of the engine, the registry is externally synchronized and
/// carries no lock.
pub const GiftRegistry = struct {
    /// Deposited, not-yet-consumed gifts. A consumed gift's whole row is removed
    /// at withdraw, so the row count _is_ the live-gift count, and
    /// `max_deposited_gifts` bounds it directly: a long-lived session registry that
    /// has served many completed handoffs keeps accepting new deposits.
    gifts: std.StringHashMapUnmanaged(GiftEntry) = .empty,
    /// Highest accepted `handoff_count` on this Exporter–Receiver session.
    accepted_handoff_count: ?u64 = null,
    /// Next `handoff_count` emitted on this Recipient–Exporter session.
    next_emitted_handoff_count: u64 = 0,
    /// Free everything a gift row owns. Used at deinit, on re-deposit overwrite,
    /// and on the removed row a withdraw pulls out of the map. An exact
    /// `local_target` row also releases the deposit-capture actor root through
    /// `projection` (ADR-0101); a null projection is the substrate with no
    /// local-object composition, which never minted the root either.
    fn freeGiftEntry(allocator: std.mem.Allocator, projection: ?LocalObjectProjection, entry: *GiftEntry) void {
        switch (entry.payload) {
            .provenance => |recipient_key| allocator.free(recipient_key),
            .verbatim_cap => |reference| model.freeReference(allocator, reference),
            .local_target => |target| if (projection) |p| p.release_target(p.ctx, target),
        }
    }

    pub fn deinit(self: *GiftRegistry, allocator: std.mem.Allocator, projection: ?LocalObjectProjection) void {
        var gift_it = self.gifts.iterator();
        while (gift_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            freeGiftEntry(allocator, projection, entry.value_ptr);
        }
        self.gifts.deinit(allocator);
    }

    /// Mint the `handoff_count` for this session's next withdrawal and advance
    /// the stored counter. Returns 0 for the
    /// first withdrawal from a session and a strictly increasing value after,
    /// exactly what the exporter's `validateWithdraw` replay guard requires.
    pub fn nextEmittedCount(self: *GiftRegistry) !u64 {
        const value = self.next_emitted_handoff_count;
        if (value == std.math.maxInt(u64)) return error.HandoffCountExhausted;
        self.next_emitted_handoff_count = value + 1;
        return value;
    }

    /// Deposit (or re-deposit) a gift whose capability the registry adopts. On
    /// success the registry owns `gifted`; on error the caller keeps it.
    /// Re-depositing an existing `gift_id` is intentional — a gifter
    /// re-authorizing the same gift replaces the prior row (its keys and
    /// capability are freed) — and is safe because replay is blocked by the
    /// monotonic `handoff_count` checked at withdraw, not by rejecting a repeat
    /// deposit.
    pub fn depositOwned(
        self: *GiftRegistry,
        allocator: std.mem.Allocator,
        limits: session_mod.SessionLimits,
        projection: ?LocalObjectProjection,
        gift_id: []const u8,
        gifted: model.Reference,
    ) !void {
        try self.putGift(allocator, limits, projection, gift_id, .{ .verbatim_cap = gifted });
    }

    /// Deposit one exact node-local target. The id is opaque to the engine and
    /// is projected only by the local-object composition at withdrawal.
    pub fn depositLocalTarget(
        self: *GiftRegistry,
        allocator: std.mem.Allocator,
        limits: session_mod.SessionLimits,
        projection: ?LocalObjectProjection,
        gift_id: []const u8,
        target: u64,
    ) !void {
        try self.putGift(allocator, limits, projection, gift_id, .{ .local_target = target });
    }

    /// Deposit (or re-deposit) a gift withdrawable only by the recipient named in
    /// `recipient_key`, checked against the signed give at withdraw time. No
    /// capability is recorded, a host routing the give across sessions
    /// deposits provenance only. Use `depositOwned` when the deposit itself
    /// carries the capability.
    pub fn deposit(
        self: *GiftRegistry,
        allocator: std.mem.Allocator,
        limits: session_mod.SessionLimits,
        projection: ?LocalObjectProjection,
        gift_id: []const u8,
        recipient_key: []const u8,
    ) !void {
        if (recipient_key.len == 0) return session_mod.Error.MalformedMessage;
        try self.putGift(allocator, limits, projection, gift_id, .{ .provenance = recipient_key });
    }

    /// Commit a deposit. A provenance key is copied; a verbatim reference is
    /// adopted on success and left to the caller on error.
    fn putGift(
        self: *GiftRegistry,
        allocator: std.mem.Allocator,
        limits: session_mod.SessionLimits,
        projection: ?LocalObjectProjection,
        gift_id: []const u8,
        spec: GiftPayload,
    ) !void {
        if (gift_id.len == 0) return session_mod.Error.MalformedMessage;

        // Looked up once, before the dupes below, so the replace path does not
        // pay a second probe.
        const existing = self.gifts.getPtr(gift_id);

        // Dupe the borrowed byte field; a reference is adopted on success.
        const stored: GiftPayload = switch (spec) {
            .provenance => |recipient_key| .{ .provenance = try allocator.dupe(u8, recipient_key) },
            .verbatim_cap => |reference| .{ .verbatim_cap = reference },
            .local_target => |target| .{ .local_target = target },
        };
        errdefer switch (stored) {
            .provenance => |recipient_key| allocator.free(recipient_key),
            .verbatim_cap, .local_target => {},
        };

        if (existing) |entry| {
            // Re-depositing this session's id (a consumed gift's row is
            // removed at withdraw, so a hit is always live): replace it in
            // place; the live count is unchanged. Another gifter owns another
            // session registry and never reaches this row.
            freeGiftEntry(allocator, projection, entry);
            entry.* = .{ .payload = stored };
            return;
        }
        // A consumed gift's row is removed, so the row count is the live count.
        if (self.gifts.count() >= limits.max_deposited_gifts) {
            return session_mod.Error.DepositedGiftCapExceeded;
        }

        const id_copy = try allocator.dupe(u8, gift_id);
        errdefer allocator.free(id_copy);
        const gop = try self.gifts.getOrPut(allocator, id_copy);
        gop.key_ptr.* = id_copy;
        gop.value_ptr.* = .{ .payload = stored };
    }

    /// Whether `gift_id` names a live, not-yet-consumed gift — equivalently,
    /// whether a row is present, since a consumed gift's row is removed. It is the
    /// only kind of gift a withdraw can take: a missing row (consumed or never
    /// deposited) reads as not live, so an early or repeated `withdraw-gift` parks
    /// awaiting a (re-)deposit rather than verifying against a stale row's key.
    pub fn giftLive(self: *const GiftRegistry, gift_id: []const u8) bool {
        return self.gifts.contains(gift_id);
    }

    /// The gifted reference for `gift_id`, or null when the deposit recorded only
    /// provenance. A consumed gift holds no row to read.
    pub fn giftedCap(self: *const GiftRegistry, gift_id: []const u8) ?model.Reference {
        const entry = self.gifts.get(gift_id) orelse return null;
        return switch (entry.payload) {
            .verbatim_cap => |reference| reference,
            .local_target, .provenance => null,
        };
    }

    /// The deposit mode and payload for `gift_id`, or null if the gift is
    /// unknown. The returned slices and reference alias the registry-owned row,
    /// valid until the row is removed (`commitWithdraw`, overwrite, or `deinit`).
    fn giftPayload(self: *const GiftRegistry, gift_id: []const u8) ?GiftPayload {
        const entry = self.gifts.get(gift_id) orelse return null;
        return entry.payload;
    }

    /// The withdrawal authority check: gift existence (a consumed gift's row is
    /// gone, so it reads as unknown), recipient match when the deposit named a
    /// recipient, the receive naming the parties it actually came from, and
    /// monotonic handoff-count replay rejection. Validate before preparing and
    /// committing a withdrawal; the phases stay split so a refusal never
    /// mutates state.
    ///
    /// `expected` is derived by the caller from the give's recipient key, never
    /// read from the receive. It is a parameter rather than something this
    /// function digs out for itself so a caller cannot reach the replay guard
    /// without having derived it.
    pub fn validateWithdraw(
        self: *const GiftRegistry,
        receive: model.HandoffReceive,
        expected: ?handoff_names.ExpectedReceiver,
    ) session_mod.Error!void {
        try self.validateWithdrawEnvelope(receive, expected);
        try self.validateWithdrawGift(receive);
    }

    /// Validate the deposited row after a certificate was already accepted.
    /// Pending withdrawals use this when their gift arrives: replay authority
    /// was committed before they waited, so checking it again would reject the
    /// same certificate as its own replay.
    pub fn validateWithdrawGift(
        self: *const GiftRegistry,
        receive: model.HandoffReceive,
    ) session_mod.Error!void {
        return self.validateWithdrawGiftClaim(ownedGiftClaim(receive));
    }

    fn validateWithdrawGiftClaim(self: *const GiftRegistry, claim: WithdrawGiftClaim) session_mod.Error!void {
        const gift = self.gifts.get(claim.gift_id) orelse return session_mod.Error.InvalidGift;
        // Only a provenance-only deposit binds a recipient at deposit time; a
        // capability-bearing deposit named none, so it admits any recipient the
        // signed give carries (the give's own signature is the authority there).
        switch (gift.payload) {
            .provenance => |recipient_key| {
                if (!std.mem.eql(u8, recipient_key, claim.recipient_key)) {
                    return session_mod.Error.InvalidGift;
                }
            },
            .verbatim_cap, .local_target => {},
        }
    }

    /// Validate everything that does not require the deposit row. This runs
    /// before a missing gift is admitted to the pending table.
    pub fn validateWithdrawEnvelope(
        self: *const GiftRegistry,
        receive: model.HandoffReceive,
        expected: ?handoff_names.ExpectedReceiver,
    ) session_mod.Error!void {
        return self.validateWithdrawEnvelopeClaim(ownedEnvelopeClaim(receive), expected);
    }

    fn validateWithdrawEnvelopeView(
        self: *const GiftRegistry,
        receive: model.view.HandoffReceive,
        expected: ?handoff_names.ExpectedReceiver,
    ) session_mod.Error!void {
        return self.validateWithdrawEnvelopeClaim(borrowedEnvelopeClaim(receive), expected);
    }

    fn validateWithdrawEnvelopeClaim(
        self: *const GiftRegistry,
        receive: WithdrawEnvelopeClaim,
        expected: ?handoff_names.ExpectedReceiver,
    ) session_mod.Error!void {
        if (expected) |names| {
            if (!std.mem.eql(u8, receive.receiving_side, &names.side)) {
                return session_mod.Error.InvalidHandoffSession;
            }
            if (names.session) |name| {
                if (!std.mem.eql(u8, receive.receiving_session, &name)) {
                    return session_mod.Error.InvalidHandoffSession;
                }
            }
        }
        if (self.accepted_handoff_count) |last| {
            if (receive.gift.handoff_count <= last) return session_mod.Error.HandoffReplay;
        }
    }

    pub const PreparedWithdrawCommit = struct {
        handoff_count: u64,
        /// Registry-owned key; valid until this commit removes or a new deposit
        /// replaces the row. Preparation and commit run in one externally
        /// synchronized engine turn, with no callback between them.
        gift: []const u8,
    };

    /// Reserve every resource needed to consume a verified gift. The matching
    /// commit is infallible, so a caller can first make its outbound settlement
    /// durable and then consume the gift without opening a queue/OOM gap.
    fn prepareWithdrawCommit(
        gifts: *GiftRegistry,
        claim: WithdrawGiftClaim,
    ) !PreparedWithdrawCommit {
        const gift = gifts.gifts.getKey(claim.gift_id) orelse return session_mod.Error.InvalidGift;
        return .{ .handoff_count = claim.handoff_count, .gift = gift };
    }

    /// Accept a verified certificate before waiting for an out-of-order gift.
    /// This advances replay authority immediately, matching Goblins's
    /// verify-then-wait order. The pending receive itself retains the accepted
    /// count; no second representation can drift from it.
    pub fn acceptValidatedPendingWithdraw(self: *GiftRegistry, handoff_count: u64) void {
        std.debug.assert(self.accepted_handoff_count == null or handoff_count > self.accepted_handoff_count.?);
        self.accepted_handoff_count = handoff_count;
    }

    /// Record the handoff count and remove the consumed gift row. Returns the
    /// moved verbatim gifted reference when the deposit mode was `.verbatim_cap`;
    /// otherwise frees the payload and returns null. Atomic: it records the
    /// count, then removes the gift row, then transfers or frees the payload.
    pub fn applyWithdraw(
        self: *GiftRegistry,
        gifts: *GiftRegistry,
        allocator: std.mem.Allocator,
        projection: ?LocalObjectProjection,
        receive: model.HandoffReceive,
    ) !?model.Reference {
        const prepared = try prepareWithdrawCommit(gifts, ownedGiftClaim(receive));
        return self.commitWithdraw(gifts, allocator, projection, prepared);
    }

    /// Consume a gift after `prepareWithdrawCommit`. No allocation and no
    /// failure: the caller may safely run this after queueing the resolution.
    pub fn commitWithdraw(
        self: *GiftRegistry,
        gifts: *GiftRegistry,
        allocator: std.mem.Allocator,
        projection: ?LocalObjectProjection,
        prepared: PreparedWithdrawCommit,
    ) ?model.Reference {
        self.accepted_handoff_count = @max(self.accepted_handoff_count orelse 0, prepared.handoff_count);
        // Remove the whole row the moment the gift is consumed: no spent marker
        // accrues, so a long-lived session registry pins neither a capability nor a
        // row per handoff it ever served, and the live count cannot be driven
        // past its cap by re-arming a marker. Replay stays blocked by the
        // monotonic handoff-count above, and a legitimate re-deposit simply
        // creates a fresh row.
        if (gifts.gifts.fetchRemove(prepared.gift)) |kv| {
            allocator.free(kv.key);
            var entry = kv.value;
            const moved = switch (entry.payload) {
                .verbatim_cap => |reference| reference,
                else => null,
            };
            if (moved == null) freeGiftEntry(allocator, projection, &entry);
            return moved;
        }
        return null;
    }
};

/// Recognize an inbound bootstrap `op:deliver`, or null when the deliver is not a
/// bootstrap method this peer auto-answers. The bootstrap object is one of *our*
/// exports, so only a `.near` target can name it (`exportPosition`); a `.far`
/// target whose partner-named import position happens to be 0 falls through to
/// ordinary handling instead of being auto-served.
pub fn pendingBootstrapAction(deliver: model.view.Deliver, session: *const session_mod.Session) model.view.ProjectError!?Request {
    const target_export = deliver.target.exportPosition() orelse return null;
    if (target_export.int() != session_mod.BOOTSTRAP_POSITION) return null;

    // Forward peel: one linear pass over the arg region, matching validate.zig —
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
        const answer = answerForDeliver(deliver, session);
        return .{ .deposit_gift = .{ .gift_id = gift_id, .gifted = gifted, .answer = answer } };
    }

    const answer = answerForDeliver(deliver, session) orelse return null;

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
pub fn answerForDeliver(deliver: anytype, session: *const session_mod.Session) ?model.AnswerPosition {
    return deliver.answer orelse blk: {
        if (deliver.resolve_me_desc) |rmd| {
            if (rmd.position()) |import_position| {
                break :blk session.answerForResolverImport(model.ImportPosition.from(import_position));
            }
        }
        break :blk null;
    };
}

pub fn resolveForSwissnum(
    session: *const session_mod.Session,
    local_projection: ?LocalObjectProjection,
    scope: ?PeerId,
    request: FetchRequest,
) !model.Message {
    const projected = if (local_projection) |p|
        (try p.resolve_name(p.ctx, scope orelse return session_mod.Error.InvalidGift, request.swissnum)) orelse
            session.bootstrapLookup(request.swissnum)
    else
        session.bootstrapLookup(request.swissnum);
    if (projected) |export_position| {
        return .{ .resolve = .{
            .answer = request.answer,
            .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = export_position } } } },
        } };
    }
    return .{ .resolve = .{
        .answer = request.answer,
        .resolution = .{ .@"break" = .{ .message = "unknown swissnum" } },
    } };
}

pub fn resolveForDeposit(
    session: *session_mod.Session,
    registry: *GiftRegistry,
    local_projection: ?LocalObjectProjection,
    scope: ?PeerId,
    request: DepositRequest,
) !?model.Message {
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
            const answer = request.answer orelse return null;
            return .{ .resolve = .{
                .answer = answer,
                .resolution = .{ .fulfill = .{ .void = {} } },
            } };
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
    // also covers the in-process `GiftRegistry.depositOwned`), and by then the
    // party that earned the refusal is no longer the party that pays it.
    if (gifted == .far) return session_mod.Error.InvalidGift;
    // This registry belongs to the depositing session. The give's signed
    // session name selects it at withdrawal, so no peer-supplied namespace key
    // is retained beside the gift id.
    try registry.depositOwned(session.allocator, session.limits, local_projection, request.gift_id, gifted);
    transferred = true;
    const answer = request.answer orelse return null;
    return .{ .resolve = .{
        .answer = answer,
        .resolution = .{ .fulfill = .{ .void = {} } },
    } };
}

/// The withdraw responder's verdict.
pub const WithdrawOutcome = union(enum) {
    /// The withdraw settled: an owned outbound message plus, on success, an
    /// infallible gift commit. The caller queues the message before applying
    /// the commit, so allocation failure leaves the gift retryable.
    settled: PreparedWithdraw,
    /// The gift id names no *live* deposit — the gift is unknown, or its prior
    /// row is already consumed and awaits a re-deposit. `deposit-gift` and
    /// `withdraw-gift` travel on different sessions, so the withdraw can
    /// legitimately arrive first, and the protocol expects the exporter to
    /// answer once the deposit lands rather than refuse (the upstream OCapN
    /// suite pins this). The caller parks the withdraw; `Peer.step` retries
    /// parked withdraws, and one whose deposit never arrives stays parked until
    /// session teardown — deadlines belong to the application, above pancake.
    awaiting_deposit: struct {
        receive: PendingReceive,
        gifter_peer_id: PeerId,
    },
};

/// The verified subset a withdrawal needs after its deposit was absent. The
/// signatures, locator, receiving names, and verbatim signed envelope have
/// already done their work and are not retained. Only `gift_id` is variable
/// attacker-sized storage; the authenticated keys/session name are fixed-width.
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

pub const PreparedWithdraw = struct {
    message: ?model.Message,
    commit: ?GiftRegistry.PreparedWithdrawCommit = null,
    gift_registry: ?*GiftRegistry = null,
    projection: ?struct {
        seam: LocalObjectProjection,
        scope: PeerId,
        target: u64,
        projected: ProjectedLocalTarget,
    } = null,

    pub fn deinit(self: *PreparedWithdraw, allocator: std.mem.Allocator) void {
        if (self.message) |message| model.freeMessage(allocator, message);
        self.message = null;
        if (self.projection) |projection| {
            projection.seam.rollback(
                projection.seam.ctx,
                projection.scope,
                projection.target,
                projection.projected,
            );
        }
        self.projection = null;
        self.gift_registry = null;
    }

    pub fn takeMessage(self: *PreparedWithdraw) model.Message {
        const message = self.message orelse unreachable;
        self.message = null;
        return message;
    }

    /// Finish a successfully queued withdrawal. Every fallible resource was
    /// reserved by `resolveForWithdraw`; this consumes the gift infallibly and
    /// preserves a newly shared Port projection.
    pub fn apply(self: *PreparedWithdraw, allocator: std.mem.Allocator, projection: ?LocalObjectProjection, counters: *GiftRegistry) void {
        const prepared = self.commit orelse return;
        const gifts = self.gift_registry orelse unreachable;
        if (counters.commitWithdraw(gifts, allocator, projection, prepared)) |moved|
            model.freeReference(allocator, moved);
        self.commit = null;
        self.gift_registry = null;
        self.projection = null;
    }
};

fn preparedBreak(allocator: std.mem.Allocator, answer: model.AnswerPosition, reason: []const u8) !PreparedWithdraw {
    return .{ .message = try model.cloneMessage(allocator, .{ .resolve = .{
        .answer = answer,
        .resolution = .{ .@"break" = .{ .message = reason } },
    } }) };
}

/// The gifter side a signed give names, fixed-width for the session resolver.
/// A give whose side name is not 32 bytes never verified; a zero side matches
/// no deposited row, so it falls through to `InvalidGift`.
fn giveGifterSide(give: model.view.HandoffGive) [32]u8 {
    var gifter: [32]u8 = undefined;
    if (give.gifter_side.len == gifter.len) {
        @memcpy(&gifter, give.gifter_side);
    } else {
        gifter = [_]u8{0} ** 32;
    }
    return gifter;
}

/// Resolve a borrowed give to the still-open Gifter–Exporter session it names.
/// This performs no allocation or signature work, so admission checks can run
/// before materializing attacker-controlled handoff data.
pub fn liveGifterSession(resolver: ?GifterSessionResolver, give: model.view.HandoffGive) ?GifterSession {
    const r = resolver orelse return null;
    return r.resolve(r.ctx, giveGifterSide(give), give.gifter_exporter_session);
}

pub fn resolveForWithdraw(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    counters: *GiftRegistry,
    gifter_session_resolver: ?GifterSessionResolver,
    local_projection: ?LocalObjectProjection,
    scope: ?PeerId,
    request: WithdrawRequest,
) !WithdrawOutcome {
    const borrowed_receive = request.receive;
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
    if (!try verifyHandoffReceiveWithGifterKey(allocator, borrowed_receive, &gifter_session.key)) {
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
            .gifter_peer_id = gifter_session.peer_id,
        } };
    }

    return .{ .settled = try prepareGiftWithdraw(
        allocator,
        gifter_session.gifts,
        local_projection,
        scope,
        borrowedGiftClaim(borrowed_receive),
        request.answer,
    ) };
}

/// Settle a pending withdrawal whose signatures, session names, and replay
/// count were accepted before it waited. The borrowed receive remains owned by
/// the pending row; only the registry-owned gift key enters the commit.
pub fn resolvePendingWithdraw(
    allocator: std.mem.Allocator,
    gifter_session_resolver: ?GifterSessionResolver,
    local_projection: ?LocalObjectProjection,
    scope: ?PeerId,
    receive: PendingReceive,
    answer: model.AnswerPosition,
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
    gifts: *GiftRegistry,
    local_projection: ?LocalObjectProjection,
    scope: ?PeerId,
    claim: WithdrawGiftClaim,
    answer: model.AnswerPosition,
) !PreparedWithdraw {
    gifts.validateWithdrawGiftClaim(claim) catch |err| {
        return preparedBreak(allocator, answer, withdrawRefusalReason(err));
    };

    // Consume the gift only once the object is confirmed deliverable.
    // `commitWithdraw` records the monotonic handoff-count and reclaims the
    // gift's payload, so a break returned *after* it would permanently burn a
    // legitimately-deposited gift on a recoverable condition — the recipient
    // could never retry, since a re-withdraw parks and the recorded count makes
    // a same-count retry a replay. So each arm confirms it can deliver before it
    // prepares that commit.

    // The gift is live (checked above), so its payload is present; each arm
    // decides what this session can hand back.
    switch (gifts.giftPayload(claim.gift_id).?) {
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
            const commit = try GiftRegistry.prepareWithdrawCommit(gifts, claim);
            const message = try model.cloneMessage(allocator, .{ .resolve = .{
                .answer = answer,
                .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = projected.export_position } } } },
            } });
            projection_live = false;
            return .{
                .message = message,
                .commit = commit,
                .gift_registry = gifts,
                .projection = .{
                    .seam = p,
                    .scope = projection_scope,
                    .target = target,
                    .projected = projected,
                },
            };
        },
        // A verbatim gifted cap: `commitWithdraw` moves it out of the row after
        // the handoff count is recorded. Preparation is fallible; commit is not.
        .verbatim_cap => {
            const gifted = gifts.giftedCap(claim.gift_id).?;
            const commit = try GiftRegistry.prepareWithdrawCommit(gifts, claim);
            const message = try model.cloneMessage(allocator, .{ .resolve = .{
                .answer = answer,
                .resolution = .{ .fulfill = .{ .reference = gifted } },
            } });
            return .{
                .message = message,
                .commit = commit,
                .gift_registry = gifts,
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

/// Whether both handoff signatures verify. An `OutOfMemory` building the
/// canonical signing bytes is a host failure and propagates as itself, never
/// folded into `false` — a `false` here becomes a permanent "invalid handoff
/// signature" break, and disguising a transient host condition as a partner
/// protocol violation is exactly the doctrine `gc.zig` states in this layer.
/// Malformed `raw_signed` bytes and every crypto parse/verify failure stay
/// `false`: those are attacker-controlled and a genuine signature refusal.
fn verifyHandoffReceiveWithGifterKey(
    allocator: std.mem.Allocator,
    receive: model.view.HandoffReceive,
    gifter_key_bytes: []const u8,
) error{OutOfMemory}!bool {
    const give = receive.signed_give;
    const give_signed = codec.signed.giveViewBytes(allocator, give) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return false;
    };
    defer allocator.free(give_signed);

    const gifter_key = crypto.PeerKey.fromSlice(gifter_key_bytes) catch return false;
    const give_sig = parseBorrowedSignature(give.signature) orelse return false;
    crypto.verify(gifter_key, give_signed, give_sig) catch return false;

    const receive_signed = codec.signed.receiveViewBytes(allocator, receive) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return false;
    };
    defer allocator.free(receive_signed);

    const recipient_key = crypto.PeerKey.fromSlice(give.recipient_key) catch return false;
    const receive_sig = parseBorrowedSignature(receive.signature) orelse return false;
    crypto.verify(recipient_key, receive_signed, receive_sig) catch return false;

    return true;
}

fn parseBorrowedSignature(signature: model.view.Signature) ?crypto.Signature {
    return switch (signature) {
        .raw => |raw| crypto.Signature.fromSlice(raw) catch null,
        .halves => |halves| crypto.Signature.fromParts(halves.r, halves.s) catch null,
    };
}
