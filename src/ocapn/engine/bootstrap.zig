//! Bootstrap-object methods the engine answers automatically (ADR-0006 / ADR-0009).
//!
//! `fetch` resolves a swissnum to a local export. `deposit-gift` / `withdraw-gift`
//! are the exporter-side handoff bootstrap methods. Gift and handoff-count
//! authority lives in the vat-scoped `GiftRegistry` here (ADR-0056); the session
//! spine still validates frame well-formedness, while the verified responders in
//! this module consult the registry before any gift moves.

const std = @import("std");

const model = @import("model");
const codec = @import("codec");
const crypto = @import("foundation").crypto;
const session_mod = @import("session");

/// A recognized inbound bootstrap-fetch.
pub const FetchRequest = struct {
    swissnum: []const u8,
    answer: model.AnswerId,
};

/// A recognized inbound `deposit-gift` bootstrap call.
pub const DepositRequest = struct {
    gift_id: []const u8,
    gifted: model.view.Reference,
    answer: ?model.AnswerId,
};

/// A recognized inbound `withdraw-gift` bootstrap call.
pub const WithdrawRequest = struct {
    receive: model.view.HandoffReceive,
    answer: model.AnswerId,
};

pub const Action = union(enum) {
    fetch: FetchRequest,
    deposit_gift: DepositRequest,
    withdraw_gift: WithdrawRequest,
};

/// One deposited gift awaiting withdrawal. The registry owns every slice and the
/// optional gifted reference; rows are freed precisely, on overwrite or at
/// `deinit`.
const GiftEntry = struct {
    /// The recipient session key the gifter named at deposit, or empty when the
    /// deposit carried none (a bootstrap `deposit-gift` names no recipient — the
    /// signed give names one at withdraw time, and the signature check binds it).
    recipient_key: []const u8,
    /// The depositing gifter's session public key, recorded as opaque provenance
    /// so a withdrawal can verify the gifter's `desc:handoff-give` signature
    /// against the key the exporter learned at deposit (ADR-0009). Empty only
    /// for a gift deposited without a known gifter key.
    gifter_key: []const u8,
    withdrawn: bool,
    /// The capability the gifter deposited, returned on a successful withdraw.
    /// Null when the deposit recorded only provenance (the cross-peer give
    /// routing path, where no capability rides with the deposit).
    gifted: ?model.Reference,
    /// The vat-scoped swissnum the gifted object is published under, captured
    /// when the deposit named a local bootstrap export (ADR-0009 exporter half).
    /// A cross-session withdraw re-resolves this against the *withdrawing*
    /// session — the gifted near is only meaningful on the deposit session, so a
    /// node serving the recipient on a different session hands back a fresh near
    /// for the same object. Empty when the gift names no node-local swiss cap, in
    /// which case the stored `gifted` reference is returned verbatim.
    gifted_swiss: []const u8,
};

/// The vat-scoped gift and handoff-count authority (ADR-0056). A gifter deposits
/// on its session while the recipient withdraws on a different session, so this
/// table lives outside any single `session_mod.Session`: every `Peer` owns a
/// private registry, and a host serving several direct sessions to one vat
/// points its peers at one shared registry instead.
///
/// Like the rest of the engine, the registry is externally synchronized: it
/// carries no lock. A host that shares one registry across OS threads owns the
/// locking around every operation that can touch it — the conformance host
/// wraps its shared-registry dispatch in a host-owned blocking mutex.
pub const GiftRegistry = struct {
    gifts: std.StringHashMapUnmanaged(GiftEntry) = .empty,
    /// Highest accepted `handoff_count` per receiving session id — the monotonic
    /// replay guard. Vat-scoped on purpose: a receiving session's counter is
    /// per gifter/recipient pair regardless of which direct session carries the
    /// withdraw.
    handoff_counts: std.StringHashMapUnmanaged(u64) = .empty,
    /// Next `handoff_count` this node will emit when it withdraws from a given
    /// receiving session id — the recipient-side mirror of `handoff_counts`.
    /// Lives here, not in the adapter, so every binding and a native Zig caller
    /// share one monotonic source across reconnects to the same exporter
    /// (ADR-0025/ADR-0056). Keyed by the same vat-scoped receiving session id the
    /// exporter checks, so a count this node mints is the count that exporter
    /// expects.
    emitted_handoff_counts: std.StringHashMapUnmanaged(u64) = .empty,

    pub fn deinit(self: *GiftRegistry, allocator: std.mem.Allocator) void {
        var gift_it = self.gifts.iterator();
        while (gift_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.recipient_key);
            allocator.free(entry.value_ptr.gifter_key);
            allocator.free(entry.value_ptr.gifted_swiss);
            if (entry.value_ptr.gifted) |gifted| model.freeReference(allocator, gifted);
        }
        self.gifts.deinit(allocator);

        var count_it = self.handoff_counts.iterator();
        while (count_it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.handoff_counts.deinit(allocator);

        var emitted_it = self.emitted_handoff_counts.iterator();
        while (emitted_it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.emitted_handoff_counts.deinit(allocator);
    }

    /// Mint the `handoff_count` for this node's next withdrawal from
    /// `receiving_session` and advance the stored counter. Returns 0 for the
    /// first withdrawal from a session and a strictly increasing value after,
    /// exactly what the exporter's `validateWithdraw` replay guard requires. The
    /// table is bounded by `max_seen_handoff_counts` like its accepted-side
    /// mirror, so an unbounded fan-out of exporters cannot grow it without limit.
    pub fn nextEmittedCount(
        self: *GiftRegistry,
        allocator: std.mem.Allocator,
        limits: session_mod.SessionLimits,
        receiving_session: []const u8,
    ) !u64 {
        if (self.emitted_handoff_counts.getPtr(receiving_session)) |next| {
            const value = next.*;
            next.* = value + 1;
            return value;
        }
        if (self.emitted_handoff_counts.count() >= limits.max_seen_handoff_counts) {
            return session_mod.Error.HandoffCountCapExceeded;
        }
        const copy = try allocator.dupe(u8, receiving_session);
        errdefer allocator.free(copy);
        const gop = try self.emitted_handoff_counts.getOrPut(allocator, copy);
        gop.key_ptr.* = copy;
        gop.value_ptr.* = 1;
        return 0;
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
        gift_id: []const u8,
        gifted: model.Reference,
        gifter_key: []const u8,
    ) !void {
        try self.putGift(allocator, limits, gift_id, "", gifter_key, gifted, "");
    }

    /// Deposit a gift whose capability the registry adopts *and* whose gifted
    /// object is a node-local bootstrap cap named by `gifted_swiss` (ADR-0009
    /// exporter half). A withdraw arriving on a different session re-resolves the
    /// swiss against that session and hands back a fresh near, so the recipient
    /// can reach the object over its own connection. On success the registry owns
    /// `gifted` and a copy of `gifted_swiss`; on error the caller keeps `gifted`.
    pub fn depositOwnedNamed(
        self: *GiftRegistry,
        allocator: std.mem.Allocator,
        limits: session_mod.SessionLimits,
        gift_id: []const u8,
        gifted: model.Reference,
        gifter_key: []const u8,
        gifted_swiss: []const u8,
    ) !void {
        try self.putGift(allocator, limits, gift_id, "", gifter_key, gifted, gifted_swiss);
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
        gift_id: []const u8,
        recipient_key: []const u8,
        gifter_key: []const u8,
    ) !void {
        if (recipient_key.len == 0) return session_mod.Error.MalformedMessage;
        try self.putGift(allocator, limits, gift_id, recipient_key, gifter_key, null, "");
    }

    fn putGift(
        self: *GiftRegistry,
        allocator: std.mem.Allocator,
        limits: session_mod.SessionLimits,
        gift_id: []const u8,
        recipient_key: []const u8,
        gifter_key: []const u8,
        gifted: ?model.Reference,
        gifted_swiss: []const u8,
    ) !void {
        if (gift_id.len == 0) return session_mod.Error.MalformedMessage;
        if (self.gifts.getPtr(gift_id)) |entry| {
            const recipient_copy = try allocator.dupe(u8, recipient_key);
            errdefer allocator.free(recipient_copy);
            const gifter_copy = try allocator.dupe(u8, gifter_key);
            errdefer allocator.free(gifter_copy);
            const swiss_copy = try allocator.dupe(u8, gifted_swiss);
            allocator.free(entry.recipient_key);
            allocator.free(entry.gifter_key);
            allocator.free(entry.gifted_swiss);
            if (entry.gifted) |old| model.freeReference(allocator, old);
            entry.* = .{
                .recipient_key = recipient_copy,
                .gifter_key = gifter_copy,
                .withdrawn = false,
                .gifted = gifted,
                .gifted_swiss = swiss_copy,
            };
            return;
        }
        if (self.gifts.count() >= limits.max_deposited_gifts) {
            return session_mod.Error.DepositedGiftCapExceeded;
        }

        const id_copy = try allocator.dupe(u8, gift_id);
        errdefer allocator.free(id_copy);
        const recipient_copy = try allocator.dupe(u8, recipient_key);
        errdefer allocator.free(recipient_copy);
        const gifter_copy = try allocator.dupe(u8, gifter_key);
        errdefer allocator.free(gifter_copy);
        const swiss_copy = try allocator.dupe(u8, gifted_swiss);
        errdefer allocator.free(swiss_copy);
        const gop = try self.gifts.getOrPut(allocator, id_copy);
        gop.key_ptr.* = id_copy;
        gop.value_ptr.* = .{
            .recipient_key = recipient_copy,
            .gifter_key = gifter_copy,
            .withdrawn = false,
            .gifted = gifted,
            .gifted_swiss = swiss_copy,
        };
    }

    pub fn giftDeposited(self: *const GiftRegistry, gift_id: []const u8) bool {
        return self.gifts.contains(gift_id);
    }

    pub fn giftWithdrawn(self: *const GiftRegistry, gift_id: []const u8) bool {
        const entry = self.gifts.get(gift_id) orelse return false;
        return entry.withdrawn;
    }

    /// Whether `gift_id` names a deposited, not-yet-consumed gift, the only
    /// rows a withdraw can take. A consumed row reads as not live, so an early
    /// or repeated `withdraw-gift` parks awaiting a (re-)deposit instead of
    /// verifying against a stale row's key.
    pub fn giftLive(self: *const GiftRegistry, gift_id: []const u8) bool {
        const entry = self.gifts.get(gift_id) orelse return false;
        return !entry.withdrawn;
    }

    /// The session public key the depositing gifter signed its `desc:handoff-give`
    /// with, recorded at deposit. A withdrawal verifies the give certificate
    /// against it; null if the gift is unknown, empty if it was deposited without
    /// a key.
    pub fn giftGifterKey(self: *const GiftRegistry, gift_id: []const u8) ?[]const u8 {
        const entry = self.gifts.get(gift_id) orelse return null;
        return entry.gifter_key;
    }

    /// The gifted reference for `gift_id` *regardless of withdrawn status*. The
    /// withdraw path reads this only after `applyWithdraw` has marked the gift —
    /// exactly when the capability must still be delivered — so it is not
    /// filtered by the withdrawn flag.
    pub fn giftedCap(self: *const GiftRegistry, gift_id: []const u8) ?model.Reference {
        const entry = self.gifts.get(gift_id) orelse return null;
        return entry.gifted;
    }

    /// The vat-scoped swissnum the gifted object is published under, or empty if
    /// the deposit named no node-local bootstrap cap. The cross-session withdraw
    /// path re-resolves a non-empty swiss against the withdrawing session; null
    /// if the gift is unknown.
    fn giftedSwiss(self: *const GiftRegistry, gift_id: []const u8) ?[]const u8 {
        const entry = self.gifts.get(gift_id) orelse return null;
        return entry.gifted_swiss;
    }

    /// The withdrawal authority check: gift existence, not-yet-withdrawn,
    /// recipient match when the deposit named a recipient, and monotonic
    /// handoff-count replay rejection. Validate before `applyWithdraw`; the two
    /// stay split so a refusal never mutates state.
    pub fn validateWithdraw(self: *const GiftRegistry, receive: model.HandoffReceive) session_mod.Error!void {
        const gift = self.gifts.get(receive.signed_give.gift_id) orelse return session_mod.Error.InvalidGift;
        if (gift.withdrawn) return session_mod.Error.InvalidGift;
        if (gift.recipient_key.len > 0 and
            !std.mem.eql(u8, gift.recipient_key, receive.signed_give.recipient_key))
        {
            return session_mod.Error.InvalidGift;
        }
        if (self.handoff_counts.get(receive.receiving_session)) |last| {
            if (receive.handoff_count <= last) return session_mod.Error.HandoffReplay;
        }
    }

    pub fn applyWithdraw(
        self: *GiftRegistry,
        allocator: std.mem.Allocator,
        limits: session_mod.SessionLimits,
        receive: model.HandoffReceive,
    ) !void {
        // Record the count first (the only fallible step); marking the gift
        // withdrawn afterwards cannot fail, so the apply stays atomic.
        try self.recordHandoffCount(allocator, limits, receive.receiving_session, receive.handoff_count);
        if (self.gifts.getPtr(receive.signed_give.gift_id)) |gift| {
            gift.withdrawn = true;
        }
    }

    fn recordHandoffCount(
        self: *GiftRegistry,
        allocator: std.mem.Allocator,
        limits: session_mod.SessionLimits,
        session_id: []const u8,
        count: u64,
    ) !void {
        if (self.handoff_counts.getPtr(session_id)) |last_count| {
            last_count.* = count;
            return;
        }
        if (self.handoff_counts.count() >= limits.max_seen_handoff_counts) {
            return session_mod.Error.HandoffCountCapExceeded;
        }
        const copy = try allocator.dupe(u8, session_id);
        errdefer allocator.free(copy);
        const gop = try self.handoff_counts.getOrPut(allocator, copy);
        gop.key_ptr.* = copy;
        gop.value_ptr.* = count;
    }
};

/// Recognize an inbound bootstrap `op:deliver`, or null when the deliver is not a
/// bootstrap method this peer auto-answers. The bootstrap object is one of *our*
/// exports, so only a `.near` target can name it (`exportPosition`); a `.far`
/// target whose partner-named import id happens to be 0 falls through to
/// ordinary handling instead of being auto-served.
pub fn pendingBootstrapAction(deliver: model.view.Deliver, session: *const session_mod.Session) model.view.ProjectError!?Action {
    const target_export = deliver.target.exportPosition() orelse return null;
    if (target_export.int() != session_mod.BOOTSTRAP_POSITION) return null;

    const argc = try deliver.args.len();
    if (argc < 2) return null;

    const method = switch (try deliver.args.at(0)) {
        .symbol => |symbol| symbol,
        else => return null,
    };

    if (std.mem.eql(u8, method, "deposit-gift")) {
        if (argc != 3) return null;
        const gift_id = switch (try deliver.args.at(1)) {
            .bytes => |bytes| bytes,
            else => return null,
        };
        const gifted = switch (try deliver.args.at(2)) {
            .reference => |reference| reference,
            else => return null,
        };
        const answer = answerForDeliver(deliver, session);
        return .{ .deposit_gift = .{ .gift_id = gift_id, .gifted = gifted, .answer = answer } };
    }

    const answer = answerForDeliver(deliver, session) orelse return null;

    if (std.mem.eql(u8, method, "fetch")) {
        if (argc != 2) return null;
        const swissnum = switch (try deliver.args.at(1)) {
            .bytes => |bytes| bytes,
            else => return null,
        };
        return .{ .fetch = .{ .swissnum = swissnum, .answer = answer } };
    }

    if (std.mem.eql(u8, method, "withdraw-gift")) {
        if (argc != 2) return null;
        const handoff = switch (try deliver.args.at(1)) {
            .handoff => |h| h,
            else => return null,
        };
        const receive = switch (handoff) {
            .receive => |receive| receive,
            .give => return null,
        };
        return .{ .withdraw_gift = .{ .receive = receive, .answer = answer } };
    }

    return null;
}

fn answerForDeliver(deliver: model.view.Deliver, session: *const session_mod.Session) ?model.AnswerId {
    return deliver.answer orelse blk: {
        if (deliver.resolve_me_desc) |rmd| {
            if (rmd.position()) |import_position| {
                break :blk session.answerForResolverImport(model.ImportId.from(import_position));
            }
        }
        break :blk null;
    };
}

pub fn resolveForSwissnum(session: *const session_mod.Session, request: FetchRequest) model.Message {
    if (session.bootstrapLookup(request.swissnum)) |export_position| {
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
    request: DepositRequest,
) !?model.Message {
    const gifted = try request.gifted.toOwned(session.allocator);
    var transferred = false;
    errdefer if (!transferred) model.freeReference(session.allocator, gifted);
    const gifter_key = session.partnerSessionKey() orelse "";
    // A gifted near naming one of our bootstrap caps carries a vat-scoped
    // identity (its swissnum); recording it lets a withdraw on a different
    // session re-resolve the object there instead of returning this session's
    // near. Any other shape (a far import, a near with no swiss) deposits
    // verbatim, preserving the cross-peer give-routing contract.
    const gifted_swiss: []const u8 = switch (gifted) {
        .near => |near| session.bootstrapSwissForExport(near.export_position) orelse "",
        else => "",
    };
    try registry.depositOwnedNamed(session.allocator, session.limits, request.gift_id, gifted, gifter_key, gifted_swiss);
    transferred = true;
    const answer = request.answer orelse return null;
    return .{ .resolve = .{
        .answer = answer,
        .resolution = .{ .fulfill = .{ .void = {} } },
    } };
}

/// The withdraw responder's verdict.
pub const WithdrawOutcome = union(enum) {
    /// The withdraw settled: a fulfill carrying the gifted capability, or a
    /// typed break refusal.
    settled: model.Message,
    /// The gift id names no *live* deposit — the gift is unknown, or its prior
    /// row is already consumed and awaits a re-deposit. `deposit-gift` and
    /// `withdraw-gift` travel on different sessions, so the withdraw can
    /// legitimately arrive first, and the protocol expects the exporter to
    /// answer once the deposit lands rather than refuse (the upstream OCapN
    /// suite pins this). The caller parks the withdraw; `Peer.step` retries
    /// parked withdraws, and one whose deposit never arrives stays parked until
    /// session teardown — deadlines belong to the application, above pancake.
    awaiting_deposit,
};

pub fn resolveForWithdraw(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    registry: *GiftRegistry,
    request: WithdrawRequest,
) !WithdrawOutcome {
    const handoff_owned = try (model.view.Handoff{ .receive = request.receive }).toOwned(allocator);
    // `receive` only borrows `handoff_owned` for this call, and a fulfilled
    // resolution returns an independent `cloneReference`, so the owned copy is
    // freed on every path, not just on error.
    defer model.freeHandoff(allocator, handoff_owned);
    const receive = handoff_owned.receive;

    // Only a live row can satisfy a withdraw; a missing or consumed row parks
    // it, so verification never runs against a stale row's gifter key.
    if (!registry.giftLive(receive.signed_give.gift_id)) return .awaiting_deposit;
    const gifter_key_bytes = registry.giftGifterKey(receive.signed_give.gift_id).?;
    if (!verifyHandoffReceiveWithGifterKey(allocator, receive, gifter_key_bytes)) {
        return .{ .settled = .{ .resolve = .{
            .answer = request.answer,
            .resolution = .{ .@"break" = .{ .message = "invalid handoff signature" } },
        } } };
    }

    registry.validateWithdraw(receive) catch |err| {
        return .{ .settled = .{ .resolve = .{
            .answer = request.answer,
            .resolution = .{ .@"break" = .{ .message = withdrawRefusalReason(err) } },
        } } };
    };
    try registry.applyWithdraw(allocator, session.limits, receive);

    // A gift that named a node-local bootstrap cap is re-resolved against *this*
    // (the withdrawing) session: the deposit-session near is meaningless here, so
    // hand back a fresh near for the same swissnum, the export the recipient can
    // reach over its own connection. This is the exporter half of a three-party
    // handoff across two sessions; the gift's deposit session and this withdraw
    // session differ, so a verbatim near would point at nothing on the wire.
    const gifted_swiss = registry.giftedSwiss(receive.signed_give.gift_id) orelse "";
    if (gifted_swiss.len > 0) {
        if (session.bootstrapLookup(gifted_swiss)) |export_position| {
            return .{ .settled = .{ .resolve = .{
                .answer = request.answer,
                .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = export_position } } } },
            } } };
        }
        // The object is not published on this session: the node owns the gift's
        // identity but has not exported it here. Refuse rather than hand back a
        // dangling deposit-session near.
        return .{ .settled = .{ .resolve = .{
            .answer = request.answer,
            .resolution = .{ .@"break" = .{ .message = "gift object not hosted on this session" } },
        } } };
    }

    // Read the unfiltered gifted cap: `applyWithdraw` above just marked the gift
    // withdrawn, and a withdraw is exactly when we deliver the gifted reference.
    const gifted = registry.giftedCap(receive.signed_give.gift_id) orelse {
        return .{ .settled = .{ .resolve = .{
            .answer = request.answer,
            .resolution = .{ .@"break" = .{ .message = "gift not deposited" } },
        } } };
    };
    const gifted_copy = try model.cloneReference(allocator, gifted);
    return .{ .settled = .{ .resolve = .{
        .answer = request.answer,
        .resolution = .{ .fulfill = .{ .reference = gifted_copy } },
    } } };
}

/// The break reason a refused withdraw reports, keyed on the typed validation
/// error so a replayed certificate and a missing or already-consumed gift read
/// as the distinct failures they are.
fn withdrawRefusalReason(err: session_mod.Error) []const u8 {
    return switch (err) {
        session_mod.Error.HandoffReplay => "handoff-receive replayed or out-of-order handoff-count",
        session_mod.Error.InvalidGift => "gift is unknown, already withdrawn, or names a different recipient",
        else => "invalid handoff withdraw",
    };
}

fn verifyHandoffReceiveWithGifterKey(
    allocator: std.mem.Allocator,
    receive: model.HandoffReceive,
    gifter_key_bytes: []const u8,
) bool {
    const give = receive.signed_give;
    const give_signed = codec.syrup.canonicalHandoffGiveSignedBytes(allocator, give) catch return false;
    defer allocator.free(give_signed);

    const gifter_key = crypto.PeerKey.fromSlice(gifter_key_bytes) catch return false;
    const give_sig = crypto.Signature.fromSlice(give.signature) catch return false;
    crypto.verify(gifter_key, give_signed, give_sig) catch return false;

    const receive_signed = codec.syrup.canonicalHandoffReceiveSignedBytes(allocator, receive) catch return false;
    defer allocator.free(receive_signed);

    const recipient_key = crypto.PeerKey.fromSlice(give.recipient_key) catch return false;
    const receive_sig = crypto.Signature.fromSlice(receive.signature) catch return false;
    crypto.verify(recipient_key, receive_signed, receive_sig) catch return false;

    return true;
}
