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
const handoff_names = @import("handoff_names.zig");

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

/// What a deposit hands back at withdraw, as the three disjoint deposit modes
/// (ADR-0009). A sum, not a product: the mode is a tag, so a gift can never be
/// both provenance-only and capability-bearing, and a swissnum can never ride
/// without a capability. The registry owns every slice and reference each arm
/// holds.
const GiftPayload = union(enum) {
    /// Provenance-only: no capability rode the deposit (the cross-peer give
    /// routing path). Withdrawable by the recipient named here, whom the
    /// withdrawal's signed give must match — a bootstrap `deposit-gift` names no
    /// recipient at deposit, so the signed give names one at withdraw and the
    /// signature check binds it. Never empty: `deposit` refuses an empty key.
    provenance: []const u8,
    /// The gifter deposited the capability itself; it is returned verbatim on a
    /// successful withdraw.
    verbatim_cap: model.Reference,
    /// The gifted object is a node-local bootstrap cap, named by its swissnum
    /// (ADR-0009 exporter half). A cross-session withdraw re-resolves the
    /// swissnum against the *withdrawing* session — the deposited near is only
    /// meaningful on the deposit session, so a node serving the recipient on a
    /// different session hands back a fresh near for the same object.
    named_cap: struct { reference: model.Reference, swiss: []const u8 },
};

/// One deposited, not-yet-consumed gift. The registry owns `gifter_key` and
/// everything the `payload` arm holds; rows are freed precisely, on overwrite,
/// on withdraw (a consumed gift's whole row is removed — replay stays blocked by
/// the monotonic `handoff_counts`, so no spent marker accrues), or at `deinit`.
const GiftEntry = struct {
    /// The depositing gifter's session public key, recorded as opaque provenance
    /// so a withdrawal can verify the gifter's `desc:handoff-give` signature
    /// against the key the exporter learned at deposit (ADR-0009). Common to all
    /// three modes; empty only for a gift deposited without a known gifter key.
    gifter_key: []const u8,
    /// The deposit mode and what it hands back at withdraw.
    payload: GiftPayload,
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
    /// Deposited, not-yet-consumed gifts. A consumed gift's whole row is removed
    /// at withdraw, so the row count _is_ the live-gift count, and
    /// `max_deposited_gifts` bounds it directly: a process-lifetime registry that
    /// has served many completed handoffs keeps accepting new deposits.
    gifts: std.StringHashMapUnmanaged(GiftEntry) = .empty,
    /// Highest accepted `handoff_count` per recipient, the monotonic replay
    /// guard. Vat-scoped on purpose: a recipient's counter is the same counter
    /// regardless of which direct session carries the withdraw. Keyed by the
    /// side name the exporter *derives* from the gifter-signed give, never by a
    /// name the withdrawing peer supplies, because this table is shared across
    /// every session on the host and a peer-chosen key would reach rows that are
    /// not its own.
    handoff_counts: std.StringHashMapUnmanaged(u64) = .empty,
    /// Next `handoff_count` this node will emit when it withdraws from a given
    /// receiving session id — the recipient-side mirror of `handoff_counts`.
    /// Lives here, not in the adapter, so every binding and a native Zig caller
    /// share one monotonic source across reconnects to the same exporter
    /// (ADR-0025/ADR-0056). Keyed by the same vat-scoped receiving session id the
    /// exporter checks, so a count this node mints is the count that exporter
    /// expects.
    emitted_handoff_counts: std.StringHashMapUnmanaged(u64) = .empty,
    /// Monotonic count of accepted deposits. A withdraw parked on one session
    /// awaits a deposit that lands on another (`deposit`/`withdraw` travel on
    /// different sessions); a shared-registry owner watches this to know a new
    /// deposit arrived and re-drive parked withdraws, without a per-frame sweep.
    /// Bumped on every accepted deposit, including a re-deposit that overwrites
    /// a live row, since a re-deposit is exactly what a replayed withdraw awaits.
    deposits: u64 = 0,

    /// Free everything a gift row owns. Used at deinit, on re-deposit overwrite,
    /// and on the removed row a withdraw pulls out of the map.
    fn freeGiftEntry(allocator: std.mem.Allocator, entry: *GiftEntry) void {
        allocator.free(entry.gifter_key);
        switch (entry.payload) {
            .provenance => |recipient_key| allocator.free(recipient_key),
            .verbatim_cap => |reference| model.freeReference(allocator, reference),
            .named_cap => |named| {
                model.freeReference(allocator, named.reference);
                allocator.free(named.swiss);
            },
        }
    }

    pub fn deinit(self: *GiftRegistry, allocator: std.mem.Allocator) void {
        var gift_it = self.gifts.iterator();
        while (gift_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            freeGiftEntry(allocator, entry.value_ptr);
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
        try self.putGift(allocator, limits, gift_id, gifter_key, .{ .verbatim_cap = gifted });
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
        // The swissnum decides the mode: a named node-local cap re-resolves at
        // withdraw, while a gifted reference with no swissnum (any shape that is
        // not one of our bootstrap exports) is returned verbatim. Deciding it
        // here keeps `named_cap.swiss` always non-empty, so the withdraw switch
        // never re-resolves an empty swissnum.
        const spec: GiftPayload = if (gifted_swiss.len > 0)
            .{ .named_cap = .{ .reference = gifted, .swiss = gifted_swiss } }
        else
            .{ .verbatim_cap = gifted };
        try self.putGift(allocator, limits, gift_id, gifter_key, spec);
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
        try self.putGift(allocator, limits, gift_id, gifter_key, .{ .provenance = recipient_key });
    }

    /// Commit a deposit. `spec`'s byte fields (`provenance` recipient key,
    /// `named_cap` swiss) are *borrowed*: `putGift` dupes them into
    /// registry-owned storage. `spec`'s reference (`verbatim_cap`,
    /// `named_cap.reference`) is *adopted on success* and *left to the caller on
    /// error* — the error paths free only the dup'd bytes, never the reference —
    /// which is the contract the deposit constructors' callers rely on.
    fn putGift(
        self: *GiftRegistry,
        allocator: std.mem.Allocator,
        limits: session_mod.SessionLimits,
        gift_id: []const u8,
        gifter_key: []const u8,
        spec: GiftPayload,
    ) !void {
        if (gift_id.len == 0) return session_mod.Error.MalformedMessage;

        const gifter_copy = try allocator.dupe(u8, gifter_key);
        errdefer allocator.free(gifter_copy);

        // Dupe the borrowed byte fields into the stored payload; the reference
        // arms carry the caller's reference by value, adopted on success. The
        // errdefer frees only those dup'd bytes, so an error below leaves the
        // reference with the caller.
        const stored: GiftPayload = switch (spec) {
            .provenance => |recipient_key| .{ .provenance = try allocator.dupe(u8, recipient_key) },
            .verbatim_cap => |reference| .{ .verbatim_cap = reference },
            .named_cap => |named| .{ .named_cap = .{
                .reference = named.reference,
                .swiss = try allocator.dupe(u8, named.swiss),
            } },
        };
        errdefer switch (stored) {
            .provenance => |recipient_key| allocator.free(recipient_key),
            .verbatim_cap => {},
            .named_cap => |named| allocator.free(named.swiss),
        };

        if (self.gifts.getPtr(gift_id)) |entry| {
            // A live row is being re-deposited (a consumed gift's row is removed
            // at withdraw, so a hit is always live): replace it in place, the
            // live count is unchanged.
            freeGiftEntry(allocator, entry);
            entry.* = .{ .gifter_key = gifter_copy, .payload = stored };
            self.deposits +%= 1;
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
        gop.value_ptr.* = .{ .gifter_key = gifter_copy, .payload = stored };
        self.deposits +%= 1;
    }

    /// Whether `gift_id` names a live, not-yet-consumed gift — equivalently,
    /// whether a row is present, since a consumed gift's row is removed. It is the
    /// only kind of gift a withdraw can take: a missing row (consumed or never
    /// deposited) reads as not live, so an early or repeated `withdraw-gift` parks
    /// awaiting a (re-)deposit rather than verifying against a stale row's key.
    pub fn giftLive(self: *const GiftRegistry, gift_id: []const u8) bool {
        return self.gifts.contains(gift_id);
    }

    /// The session public key the depositing gifter signed its `desc:handoff-give`
    /// with, recorded at deposit. A withdrawal verifies the give certificate
    /// against it; null if the gift is unknown, empty if it was deposited without
    /// a key.
    pub fn giftGifterKey(self: *const GiftRegistry, gift_id: []const u8) ?[]const u8 {
        const entry = self.gifts.get(gift_id) orelse return null;
        return entry.gifter_key;
    }

    /// The gifted reference for `gift_id`, or null when the deposit recorded only
    /// provenance. A consumed gift holds no row to read.
    pub fn giftedCap(self: *const GiftRegistry, gift_id: []const u8) ?model.Reference {
        const entry = self.gifts.get(gift_id) orelse return null;
        return switch (entry.payload) {
            .verbatim_cap => |reference| reference,
            .named_cap => |named| named.reference,
            .provenance => null,
        };
    }

    /// The deposit mode and payload for `gift_id`, or null if the gift is
    /// unknown. The returned slices and reference alias the registry-owned row,
    /// valid until the row is removed (`applyWithdraw`, overwrite, or `deinit`).
    fn giftPayload(self: *const GiftRegistry, gift_id: []const u8) ?GiftPayload {
        const entry = self.gifts.get(gift_id) orelse return null;
        return entry.payload;
    }

    /// The withdrawal authority check: gift existence (a consumed gift's row is
    /// gone, so it reads as unknown), recipient match when the deposit named a
    /// recipient, the receive naming the parties it actually came from, and
    /// monotonic handoff-count replay rejection. Validate before
    /// `applyWithdraw`; the two stay split so a refusal never mutates state.
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
        const gift = self.gifts.get(receive.signed_give.gift_id) orelse return session_mod.Error.InvalidGift;
        // Only a provenance-only deposit binds a recipient at deposit time; a
        // capability-bearing deposit named none, so it admits any recipient the
        // signed give carries (the give's own signature is the authority there).
        switch (gift.payload) {
            .provenance => |recipient_key| {
                if (!std.mem.eql(u8, recipient_key, receive.signed_give.recipient_key)) {
                    return session_mod.Error.InvalidGift;
                }
            },
            .verbatim_cap, .named_cap => {},
        }
        if (self.handoff_counts.get(counterKey(receive, &expected))) |last| {
            if (receive.handoff_count <= last) return session_mod.Error.HandoffReplay;
        }
    }

    /// What the replay counter is keyed by.
    ///
    /// The derived side when this session has one: the registry is shared by
    /// every session on the host, so a peer-chosen key would let one peer reach
    /// another pair's counter, and a derived name also fixes the key at 32
    /// bytes where a wire-supplied one is bounded only by the frame cap while
    /// `max_seen_handoff_counts` counts rows rather than bytes. An unkeyed
    /// session has nothing to derive from, and no signed handoff can be
    /// addressed to one, so the receive's own name stands in there.
    /// Taken by pointer, not by value: the returned slice borrows the derived
    /// name in place, and a by-value parameter's copy dies at the return.
    fn counterKey(
        receive: model.HandoffReceive,
        expected: *const ?handoff_names.ExpectedReceiver,
    ) []const u8 {
        if (expected.*) |*names| return &names.side;
        return receive.receiving_session;
    }

    /// Record the handoff count and remove the consumed gift row. Returns the
    /// moved verbatim gifted reference when the deposit mode was `.verbatim_cap`;
    /// otherwise frees the payload and returns null. Atomic: it records the
    /// count, then removes the gift row, then transfers or frees the payload.
    pub fn applyWithdraw(
        self: *GiftRegistry,
        allocator: std.mem.Allocator,
        limits: session_mod.SessionLimits,
        receive: model.HandoffReceive,
        expected: ?handoff_names.ExpectedReceiver,
    ) !?model.Reference {
        // Record the count first (the only fallible step); removing the gift
        // afterwards cannot fail, so the apply stays atomic. Keyed by the same
        // derived side `validateWithdraw` read, or the guard would check one row
        // and the write would land in another.
        try self.recordHandoffCount(allocator, limits, counterKey(receive, &expected), receive.handoff_count);
        // Remove the whole row the moment the gift is consumed: no spent marker
        // accrues, so a process-lifetime registry pins neither a capability nor a
        // row per handoff it ever served, and the live count cannot be driven
        // past its cap by re-arming a marker. Replay stays blocked by the
        // monotonic handoff-count above, and a legitimate re-deposit simply
        // creates a fresh row.
        if (self.gifts.fetchRemove(receive.signed_give.gift_id)) |kv| {
            allocator.free(kv.key);
            var entry = kv.value;
            const moved = switch (entry.payload) {
                .verbatim_cap => |reference| reference,
                else => null,
            };
            if (moved == null) {
                freeGiftEntry(allocator, &entry);
            } else {
                allocator.free(entry.gifter_key);
            }
            return moved;
        }
        return null;
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
    /// typed break refusal. The message is borrowed except for one arm: a
    /// verbatim gifted capability is moved out of the gift row into the fulfill,
    /// so the caller sends with `sendCopying` and then reclaims that one owned
    /// arm with `freeSettledWithdrawOwned`.
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
    // `receive` only borrows `handoff_owned` for this call; the owned copy is
    // freed on every path, not just on error.
    defer model.freeHandoff(allocator, handoff_owned);
    const receive = handoff_owned.receive;

    // Only a live row can satisfy a withdraw; a missing or consumed row parks
    // it, so verification never runs against a stale row's gifter key.
    if (!registry.giftLive(receive.signed_give.gift_id)) return .awaiting_deposit;
    const gifter_key_bytes = registry.giftGifterKey(receive.signed_give.gift_id).?;
    if (!try verifyHandoffReceiveWithGifterKey(allocator, receive, gifter_key_bytes)) {
        return .{ .settled = .{ .resolve = .{
            .answer = request.answer,
            .resolution = .{ .@"break" = .{ .message = "invalid handoff signature" } },
        } } };
    }

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
    const expected: ?handoff_names.ExpectedReceiver = derived: {
        const partner_key = session.partnerSessionKey() orelse break :derived null;
        const names = if (session.localSessionKey()) |our_key|
            handoff_names.ExpectedReceiver.derive(partner_key, our_key)
        else
            handoff_names.ExpectedReceiver.fromPartner(partner_key);
        break :derived names catch {
            return .{ .settled = .{ .resolve = .{
                .answer = request.answer,
                .resolution = .{ .@"break" = .{ .message = "handoff session names a malformed key" } },
            } } };
        };
    };

    registry.validateWithdraw(receive, expected) catch |err| {
        return .{ .settled = .{ .resolve = .{
            .answer = request.answer,
            .resolution = .{ .@"break" = .{ .message = withdrawRefusalReason(err) } },
        } } };
    };

    // Consume the gift only once the object is confirmed deliverable.
    // `applyWithdraw` records the monotonic handoff-count and reclaims the
    // gift's payload, so a break returned *after* it would permanently burn a
    // legitimately-deposited gift on a recoverable condition — the recipient
    // could never retry, since a re-withdraw parks and the recorded count makes
    // a same-count retry a replay. So each arm confirms it can deliver before it
    // calls `applyWithdraw`.

    // The gift is live (checked above), so its payload is present; each arm
    // decides what this session can hand back.
    switch (registry.giftPayload(receive.signed_give.gift_id).?) {
        // A gift that named a node-local bootstrap cap is re-resolved against
        // *this* (the withdrawing) session: the deposit-session near is
        // meaningless here, so hand back a fresh near for the same swissnum, the
        // export the recipient can reach over its own connection. This is the
        // exporter half of a three-party handoff across two sessions; the
        // deposit and withdraw sessions differ, so a verbatim near would point
        // at nothing on the wire.
        .named_cap => |named| {
            const export_position = session.bootstrapLookup(named.swiss) orelse {
                // The object is not published on this session yet: the node owns
                // the gift's identity but has not exported it here. Leave the
                // gift live and its handoff-count unrecorded so a later publish
                // plus retry can succeed, rather than burning it on a recoverable
                // condition.
                return .{ .settled = .{ .resolve = .{
                    .answer = request.answer,
                    .resolution = .{ .@"break" = .{ .message = "gift object not hosted on this session" } },
                } } };
            };
            _ = try registry.applyWithdraw(allocator, session.limits, receive, expected);
            return .{ .settled = .{ .resolve = .{
                .answer = request.answer,
                .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = export_position } } } },
            } } };
        },
        // A verbatim gifted cap: `applyWithdraw` moves it out of the row after
        // the handoff count is recorded (fallible only before the move).
        .verbatim_cap => {
            const gifted = try registry.applyWithdraw(allocator, session.limits, receive, expected) orelse unreachable;
            return .{ .settled = .{ .resolve = .{
                .answer = request.answer,
                .resolution = .{ .fulfill = .{ .reference = gifted } },
            } } };
        },
        // Provenance-only deposit with nothing to hand back here. Leave the gift
        // live rather than consume a gift this session cannot satisfy.
        .provenance => return .{ .settled = .{ .resolve = .{
            .answer = request.answer,
            .resolution = .{ .@"break" = .{ .message = "gift not deposited" } },
        } } },
    }
}

/// Reclaim the one owned arm a `WithdrawOutcome.settled` message may carry.
/// `resolveForWithdraw` moves a verbatim gifted capability into the fulfill
/// arm; once the message has been copied onto the wire (`Peer.sendCopying`)
/// that owned reference is freed here. The re-exported-near arm carries a POD
/// reference and the break arms carry static reasons, so `freeArgument` on a
/// non-owned fulfill is a no-op and this is safe to call for every settled
/// withdraw outcome.
pub fn freeSettledWithdrawOwned(allocator: std.mem.Allocator, msg: model.Message) void {
    if (msg == .resolve and msg.resolve.resolution == .fulfill) {
        model.freeArgument(allocator, msg.resolve.resolution.fulfill);
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
    receive: model.HandoffReceive,
    gifter_key_bytes: []const u8,
) error{OutOfMemory}!bool {
    const give = receive.signed_give;
    const give_signed = codec.syrup.canonicalHandoffGiveSignedBytes(allocator, give) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return false;
    };
    defer allocator.free(give_signed);

    const gifter_key = crypto.PeerKey.fromSlice(gifter_key_bytes) catch return false;
    const give_sig = crypto.Signature.fromSlice(give.signature) catch return false;
    crypto.verify(gifter_key, give_signed, give_sig) catch return false;

    const receive_signed = codec.syrup.canonicalHandoffReceiveSignedBytes(allocator, receive) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return false;
    };
    defer allocator.free(receive_signed);

    const recipient_key = crypto.PeerKey.fromSlice(give.recipient_key) catch return false;
    const receive_sig = crypto.Signature.fromSlice(receive.signature) catch return false;
    crypto.verify(recipient_key, receive_signed, receive_sig) catch return false;

    return true;
}
