//! Session-owned deposited-gift and handoff-count authority.
//!
//! The registry owns every retained gift row, its exact cumulative requested
//! bytes, and the replay counters that make withdrawal single-use. Bootstrap
//! orchestration verifies certificates and builds settlements; this module
//! alone admits, replaces, validates, consumes, and releases gift authority.

const std = @import("std");

const model = @import("model");
const session_mod = @import("session");
const handoff_names = @import("../handoff_names.zig");
const PeerHandle = @import("../peer_handle.zig").PeerHandle;
const counts = @import("counts.zig");

/// Adapter seam for a composition whose Ports project one local object space.
/// The engine keeps targets opaque: the composition resolves bootstrap names,
/// captures exact gifts, and projects retained targets onto another Port.
pub const LocalObjectProjection = struct {
    ctx: ?*anyopaque,
    resolve_name: *const fn (ctx: ?*anyopaque, scope: PeerHandle, swissnum: []const u8) anyerror!?model.ExportPosition,
    capture: *const fn (ctx: ?*anyopaque, scope: PeerHandle, export_position: model.ExportPosition) ?u64,
    project: *const fn (ctx: ?*anyopaque, scope: PeerHandle, target: u64) anyerror!ProjectedLocalTarget,
    rollback: *const fn (ctx: ?*anyopaque, scope: PeerHandle, target: u64, projected: ProjectedLocalTarget) void,
    /// Release the deposit-capture root on a `local_target` gift row that died
    /// (ADR-0101): consumed by withdrawal, replaced by a re-deposit, or
    /// destroyed with its session's Peer.
    release_target: *const fn (ctx: ?*anyopaque, target: u64) void,
};

pub const ProjectedLocalTarget = struct {
    export_position: model.ExportPosition,
    created: bool,
};

/// A live gifter session named by a signed give. Deposits remain owned by that
/// session's registry; the public key authenticates the give.
pub const GifterSession = struct {
    /// Node-local session identity for scheduler dependency routing. It conveys
    /// no wire authority, but every resolver must identify the live session it
    /// returned so a Node-composed receiver cannot park without a wake route.
    peer_handle: PeerHandle,
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
pub const WithdrawGiftClaim = struct {
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

/// What a deposit hands back at withdraw. A sum, not a product: provenance,
/// an exact protocol reference, or one opaque local target.
pub const GiftPayload = union(enum) {
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
/// `payload` arm holds; rows are freed precisely on overwrite, on withdraw, or
/// at `deinit`.
const GiftEntry = struct {
    payload: GiftPayload,
};

/// The gift table and the exact requested bytes its live rows retain. Most
/// sessions never deposit a gift, so `GiftRegistry` creates this owner on the
/// first successful insert and destroys it when the final row leaves.
const GiftStore = struct {
    gifts: std.StringHashMapUnmanaged(GiftEntry) = .empty,
    retained_bytes: usize = 0,
};

pub const HandoffCountCommitError = counts.CommitError;
pub const PreparedHandoffCount = counts.Prepared;

/// One CapTP session's gift and handoff-count authority. Deposits made on this
/// session live in the lazy store; receives arriving on this session use the
/// accepted count; standalone and next-profile gives redeemed through this
/// session use the emitted count. Node-composed V1 redemption supplies its
/// compatibility cursor without moving receive-side authority here.
///
/// Like the rest of the engine, the registry is externally synchronized and
/// carries no lock.
pub const GiftRegistry = struct {
    /// Deposited, not-yet-consumed gifts and their cumulative retained-byte
    /// charge. Null until the first successful deposit and null again after the
    /// last withdrawal, so a session that never carries gifts pays one pointer
    /// instead of an inline hash-map header.
    store: ?*GiftStore = null,
    /// Highest accepted `handoff_count` on this Exporter–Receiver session.
    /// Optional state retains the full `u64` count domain, including zero and
    /// `maxInt(u64)` as distinct accepted values.
    accepted_handoff_count: ?u64 = null,
    /// Next `handoff_count` emitted on this Recipient–Exporter session.
    next_emitted_handoff_count: u64 = 0,

    fn freeGiftEntry(allocator: std.mem.Allocator, projection: ?LocalObjectProjection, entry: *GiftEntry) void {
        switch (entry.payload) {
            .provenance => |recipient_key| allocator.free(recipient_key),
            .verbatim_cap => |reference| model.freeReference(allocator, reference),
            .local_target => |target| if (projection) |p| p.release_target(p.ctx, target),
        }
    }

    fn payloadRetainedBytes(payload: GiftPayload) session_mod.Error!usize {
        return switch (payload) {
            .provenance => |recipient_key| recipient_key.len,
            .verbatim_cap => |reference| model.measureReferenceOwnedBytes(reference) catch
                return session_mod.Error.DepositedGiftCapExceeded,
            .local_target => 0,
        };
    }

    fn entryRetainedBytes(gift_id: []const u8, payload: GiftPayload) session_mod.Error!usize {
        const row_bytes = @sizeOf([]const u8) + @sizeOf(GiftEntry);
        var total = std.math.add(usize, row_bytes, gift_id.len) catch
            return session_mod.Error.DepositedGiftCapExceeded;
        total = std.math.add(usize, total, try payloadRetainedBytes(payload)) catch
            return session_mod.Error.DepositedGiftCapExceeded;
        return total;
    }

    fn admittedEntryRetainedBytes(gift_id: []const u8, payload: GiftPayload) usize {
        return entryRetainedBytes(gift_id, payload) catch unreachable;
    }

    pub fn retainedBytes(self: *const GiftRegistry) usize {
        return if (self.store) |store| store.retained_bytes else 0;
    }

    pub fn acceptedHandoffCount(self: *const GiftRegistry) ?u64 {
        return self.accepted_handoff_count;
    }

    fn acceptHandoffCount(self: *GiftRegistry, count: u64) void {
        self.accepted_handoff_count = count;
    }

    pub fn deinit(self: *GiftRegistry, allocator: std.mem.Allocator, projection: ?LocalObjectProjection) void {
        const store = self.store orelse return;
        var gift_it = store.gifts.iterator();
        while (gift_it.next()) |entry| {
            store.retained_bytes -= admittedEntryRetainedBytes(entry.key_ptr.*, entry.value_ptr.payload);
            allocator.free(entry.key_ptr.*);
            freeGiftEntry(allocator, projection, entry.value_ptr);
        }
        std.debug.assert(store.retained_bytes == 0);
        store.gifts.deinit(allocator);
        allocator.destroy(store);
        self.store = null;
    }

    /// Prepare the `handoff_count` for this session's next withdrawal without
    /// consuming it. The caller commits only after its outbound queue owns the
    /// withdrawal, so malformed input, allocation failure, and backpressure do
    /// not consume a count. Queue admission is the emission boundary: teardown
    /// may discard an admitted frame, so counts are monotonic, not contiguous.
    pub fn prepareEmittedCount(self: *GiftRegistry) !PreparedHandoffCount {
        const value = self.next_emitted_handoff_count;
        if (value == std.math.maxInt(u64)) return error.HandoffCountExhausted;
        return PreparedHandoffCount.bind(self, value, commitPreparedEmittedCount);
    }

    fn commitPreparedEmittedCount(self: *GiftRegistry, prepared: u64) HandoffCountCommitError!void {
        if (self.next_emitted_handoff_count != prepared or prepared == std.math.maxInt(u64))
            return error.StaleHandoffCountPreparation;
        self.next_emitted_handoff_count = prepared + 1;
    }

    /// Deposit (or re-deposit) a gift whose capability the registry adopts. On
    /// success the registry owns `gifted`; on error the caller keeps it.
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

    /// Deposit a gift withdrawable only by `recipient_key`. The borrowed key is
    /// copied only after the whole retained row has passed admission.
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

    /// Admit and commit one complete retained row. The whole replacement charge
    /// is checked before allocation or caller-owned authority is adopted. A
    /// refused replacement therefore preserves both the live prior row and the
    /// caller's payload.
    fn putGift(
        self: *GiftRegistry,
        allocator: std.mem.Allocator,
        limits: session_mod.SessionLimits,
        projection: ?LocalObjectProjection,
        gift_id: []const u8,
        spec: GiftPayload,
    ) !void {
        if (gift_id.len == 0) return session_mod.Error.MalformedMessage;

        const store = self.store;
        const existing = if (store) |s| s.gifts.getPtr(gift_id) else null;
        const replacement_bytes = try entryRetainedBytes(gift_id, spec);
        const prior_bytes = if (existing) |entry|
            admittedEntryRetainedBytes(gift_id, entry.payload)
        else
            0;
        const without_prior = self.retainedBytes() - prior_bytes;
        if (replacement_bytes > @as(usize, limits.max_deposited_gift_bytes) -| without_prior) {
            return session_mod.Error.DepositedGiftCapExceeded;
        }

        const live_gifts = if (store) |s| s.gifts.count() else 0;
        if (existing == null and live_gifts >= @as(usize, limits.max_deposited_gifts)) {
            return session_mod.Error.DepositedGiftCapExceeded;
        }

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
            freeGiftEntry(allocator, projection, entry);
            entry.* = .{ .payload = stored };
            store.?.retained_bytes = without_prior + replacement_bytes;
            return;
        }

        const id_copy = try allocator.dupe(u8, gift_id);
        errdefer allocator.free(id_copy);
        if (store) |s| {
            const gop = try s.gifts.getOrPut(allocator, id_copy);
            std.debug.assert(!gop.found_existing);
            gop.key_ptr.* = id_copy;
            gop.value_ptr.* = .{ .payload = stored };
            s.retained_bytes = without_prior + replacement_bytes;
            return;
        }

        // Construct the first store off-registry. No authority or accounting is
        // visible until its map row and owner box both exist.
        var staged: GiftStore = .{};
        errdefer staged.gifts.deinit(allocator);
        const gop = try staged.gifts.getOrPut(allocator, id_copy);
        std.debug.assert(!gop.found_existing);
        gop.key_ptr.* = id_copy;
        gop.value_ptr.* = .{ .payload = stored };
        staged.retained_bytes = replacement_bytes;

        const owned = try allocator.create(GiftStore);
        owned.* = staged;
        self.store = owned;
    }

    pub fn giftLive(self: *const GiftRegistry, gift_id: []const u8) bool {
        const store = self.store orelse return false;
        return store.gifts.contains(gift_id);
    }

    pub fn giftedCap(self: *const GiftRegistry, gift_id: []const u8) ?model.Reference {
        const store = self.store orelse return null;
        const entry = store.gifts.get(gift_id) orelse return null;
        return switch (entry.payload) {
            .verbatim_cap => |reference| reference,
            .local_target, .provenance => null,
        };
    }

    /// Borrow the payload until this externally synchronized turn commits a
    /// withdrawal or returns. Overwrite, withdrawal, and deinit invalidate it.
    pub fn giftPayload(self: *const GiftRegistry, gift_id: []const u8) ?GiftPayload {
        const store = self.store orelse return null;
        return (store.gifts.get(gift_id) orelse return null).payload;
    }

    pub fn validateWithdraw(
        self: *const GiftRegistry,
        receive: model.HandoffReceive,
        expected: ?handoff_names.ExpectedReceiver,
    ) session_mod.Error!void {
        try self.validateWithdrawEnvelope(receive, expected);
        try self.validateWithdrawGift(receive);
    }

    pub fn validateWithdrawGift(
        self: *const GiftRegistry,
        receive: model.HandoffReceive,
    ) session_mod.Error!void {
        return self.validateWithdrawGiftClaim(ownedGiftClaim(receive));
    }

    /// Public only for the sibling bootstrap orchestrator, which has already
    /// authenticated and narrowed a borrowed or parked certificate.
    pub fn validateWithdrawGiftClaim(self: *const GiftRegistry, claim: WithdrawGiftClaim) session_mod.Error!void {
        const store = self.store orelse return session_mod.Error.InvalidGift;
        const gift = store.gifts.get(claim.gift_id) orelse return session_mod.Error.InvalidGift;
        switch (gift.payload) {
            .provenance => |recipient_key| if (!std.mem.eql(u8, recipient_key, claim.recipient_key))
                return session_mod.Error.InvalidGift,
            .verbatim_cap, .local_target => {},
        }
    }

    pub fn validateWithdrawEnvelope(
        self: *const GiftRegistry,
        receive: model.HandoffReceive,
        expected: ?handoff_names.ExpectedReceiver,
    ) session_mod.Error!void {
        return self.validateWithdrawEnvelopeClaim(ownedEnvelopeClaim(receive), expected);
    }

    /// Borrowed certificate entry for bootstrap orchestration.
    pub fn validateWithdrawEnvelopeView(
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
            if (!std.mem.eql(u8, receive.receiving_side, &names.side))
                return session_mod.Error.InvalidHandoffSession;
            if (names.session) |name| {
                if (!std.mem.eql(u8, receive.receiving_session, &name))
                    return session_mod.Error.InvalidHandoffSession;
            }
        }
        if (self.acceptedHandoffCount()) |last| {
            if (receive.gift.handoff_count <= last) return session_mod.Error.HandoffReplay;
        }
    }

    pub const PreparedWithdrawCommit = struct {
        handoff_count: u64,
        /// Registry-owned key, borrowed until the same synchronized turn
        /// commits or returns.
        gift: []const u8,
    };

    /// Public only for the sibling bootstrap orchestrator. Preparation borrows
    /// existing authority and allocates nothing; commit consumes infallibly.
    pub fn prepareWithdrawCommit(
        gifts: *GiftRegistry,
        claim: WithdrawGiftClaim,
    ) session_mod.Error!PreparedWithdrawCommit {
        const store = gifts.store orelse return session_mod.Error.InvalidGift;
        const gift = store.gifts.getKey(claim.gift_id) orelse return session_mod.Error.InvalidGift;
        return .{ .handoff_count = claim.handoff_count, .gift = gift };
    }

    pub fn acceptValidatedPendingWithdraw(self: *GiftRegistry, handoff_count: u64) void {
        std.debug.assert(self.acceptedHandoffCount() == null or handoff_count > self.acceptedHandoffCount().?);
        self.acceptHandoffCount(handoff_count);
    }

    pub fn applyWithdraw(
        self: *GiftRegistry,
        deposited: *GiftRegistry,
        allocator: std.mem.Allocator,
        projection: ?LocalObjectProjection,
        receive: model.HandoffReceive,
    ) session_mod.Error!?model.Reference {
        const prepared = try prepareWithdrawCommit(deposited, ownedGiftClaim(receive));
        return self.commitWithdraw(deposited, allocator, projection, prepared);
    }

    /// Consume one prepared gift with no allocation or failure. `self` owns the
    /// receiver-side replay counter; `deposited` owns the gifter-side row.
    pub fn commitWithdraw(
        self: *GiftRegistry,
        deposited: *GiftRegistry,
        allocator: std.mem.Allocator,
        projection: ?LocalObjectProjection,
        prepared: PreparedWithdrawCommit,
    ) ?model.Reference {
        self.acceptHandoffCount(@max(self.acceptedHandoffCount() orelse 0, prepared.handoff_count));
        const store = deposited.store orelse unreachable;
        const kv = store.gifts.fetchRemove(prepared.gift) orelse unreachable;
        store.retained_bytes -= admittedEntryRetainedBytes(kv.key, kv.value.payload);
        allocator.free(kv.key);
        var entry = kv.value;
        if (store.gifts.count() == 0) {
            std.debug.assert(store.retained_bytes == 0);
            store.gifts.deinit(allocator);
            allocator.destroy(store);
            deposited.store = null;
        }
        const moved = switch (entry.payload) {
            .verbatim_cap => |reference| reference,
            else => null,
        };
        if (moved == null) freeGiftEntry(allocator, projection, &entry);
        return moved;
    }
};
