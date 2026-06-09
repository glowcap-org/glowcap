//! Bootstrap-object methods the engine answers automatically (ADR-0006 / ADR-0009).
//!
//! `fetch` resolves a swissnum to a local export. `deposit-gift` / `withdraw-gift`
//! are the exporter-side handoff bootstrap methods — gift authority stays in the
//! session; this module only recognizes the wire shapes and synthesizes the
//! matching `Resolve`.

const std = @import("std");

const model = @import("../model/mod.zig");
const codec = @import("../codec/mod.zig");
const crypto = @import("../foundation/crypto.zig");
const session_mod = @import("../session/mod.zig");

/// A recognized inbound bootstrap-fetch.
pub const FetchRequest = struct {
    swissnum: []const u8,
    answer: u64,
};

/// A recognized inbound `deposit-gift` bootstrap call.
pub const DepositRequest = struct {
    gift_id: []const u8,
    gifted: model.view.Reference,
    answer: ?u64,
};

/// A recognized inbound `withdraw-gift` bootstrap call.
pub const WithdrawRequest = struct {
    receive: model.view.HandoffReceive,
    answer: u64,
};

pub const Action = union(enum) {
    fetch: FetchRequest,
    deposit_gift: DepositRequest,
    withdraw_gift: WithdrawRequest,
};

const GiftEntry = struct {
    gifter_key: []const u8,
    withdrawn: bool,
    gifted: model.Reference,
};

/// Exporter-scoped handoff gifts shared by all direct sessions to the same local
/// vat. A gifter deposits on its session, while the recipient withdraws on a
/// different session; keeping this table outside a single [`session_mod.Session`]
/// is what makes that cross-session handoff possible.
pub const GiftRegistry = struct {
    gifts: std.StringHashMapUnmanaged(GiftEntry) = .empty,
    handoff_counts: std.StringHashMapUnmanaged(u64) = .empty,
    /// A host may serve the gifter's and the recipient's connections to one vat
    /// on separate OS threads (the conformance host serves each connection on its
    /// own thread), so a deposit and a withdraw can touch this table at once. The
    /// withdraw and deposit critical sections take this lock so the maps are never
    /// mutated concurrently and a borrowed gift never escapes a re-deposit that
    /// frees it. The unmanaged tables themselves stay lock-free primitives; the
    /// resolve functions that own each operation hold the lock around the whole
    /// sequence.
    mutex: std.atomic.Mutex = .unlocked,

    /// Acquire the table lock, spinning until it is free. `std.atomic.Mutex` is the
    /// only blocking-free mutex a sans-I/O core layer can use; the I/O layer's
    /// futex-backed blocking mutex would pull host I/O into the engine, which the
    /// architecture gate forbids a core layer from importing. So this is a
    /// deliberate spin, not a workaround. The critical section is bounded by
    /// one deposit or one withdraw: a deposit is a map insert plus a dupe; a
    /// withdraw is a map lookup, two Ed25519 verifications, and a reference clone,
    /// held as one unit because the gifter key and deposited capability are
    /// borrowed from the gift row and a concurrent re-deposit must not free them
    /// mid-withdraw (see `resolveForWithdrawWithRegistry`). It is bounded work, not
    /// allocation-free work.
    pub fn lock(self: *GiftRegistry) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *GiftRegistry) void {
        self.mutex.unlock();
    }

    pub fn deinit(self: *GiftRegistry, allocator: std.mem.Allocator) void {
        var gift_it = self.gifts.iterator();
        while (gift_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.gifter_key);
            model.freeReference(allocator, entry.value_ptr.gifted);
        }
        self.gifts.deinit(allocator);

        var count_it = self.handoff_counts.iterator();
        while (count_it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.handoff_counts.deinit(allocator);
    }

    pub fn depositOwned(
        self: *GiftRegistry,
        allocator: std.mem.Allocator,
        limits: session_mod.SessionLimits,
        gift_id: []const u8,
        gifted: model.Reference,
        gifter_key: []const u8,
    ) !void {
        if (gift_id.len == 0) return session_mod.Error.MalformedMessage;
        if (self.gifts.getPtr(gift_id)) |entry| {
            const gifter_copy = try allocator.dupe(u8, gifter_key);
            errdefer allocator.free(gifter_copy);
            allocator.free(entry.gifter_key);
            model.freeReference(allocator, entry.gifted);
            entry.* = .{
                .gifter_key = gifter_copy,
                .withdrawn = false,
                .gifted = gifted,
            };
            return;
        }
        if (self.gifts.count() >= limits.max_deposited_gifts) {
            return session_mod.Error.DepositedGiftCapExceeded;
        }

        const id_copy = try allocator.dupe(u8, gift_id);
        errdefer allocator.free(id_copy);
        const gifter_copy = try allocator.dupe(u8, gifter_key);
        errdefer allocator.free(gifter_copy);
        const gop = try self.gifts.getOrPut(allocator, id_copy);
        gop.key_ptr.* = id_copy;
        gop.value_ptr.* = .{
            .gifter_key = gifter_copy,
            .withdrawn = false,
            .gifted = gifted,
        };
    }

    pub fn giftGifterKey(self: *const GiftRegistry, gift_id: []const u8) ?[]const u8 {
        const entry = self.gifts.get(gift_id) orelse return null;
        return entry.gifter_key;
    }

    pub fn giftedCap(self: *const GiftRegistry, gift_id: []const u8) ?model.Reference {
        const entry = self.gifts.get(gift_id) orelse return null;
        return entry.gifted;
    }

    pub fn validateWithdraw(self: *const GiftRegistry, receive: model.HandoffReceive) session_mod.Error!void {
        const gift = self.gifts.get(receive.signed_give.gift_id) orelse return session_mod.Error.InvalidGift;
        if (gift.withdrawn) return session_mod.Error.InvalidGift;
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
/// bootstrap method this peer auto-answers.
pub fn pendingBootstrapAction(deliver: model.view.Deliver, session: *const session_mod.Session) model.view.ProjectError!?Action {
    if (referencePosition(deliver.target) != session_mod.BOOTSTRAP_EXPORT_ID) return null;

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

fn answerForDeliver(deliver: model.view.Deliver, session: *const session_mod.Session) ?u64 {
    return deliver.answer orelse blk: {
        if (deliver.resolve_me_desc) |rmd| {
            if (referencePosition(rmd)) |import_id| {
                break :blk session.answerForResolverImport(import_id);
            }
        }
        break :blk null;
    };
}

/// Back-compat alias for fetch-only callers.
pub const Request = FetchRequest;
pub fn pendingBootstrapRequest(deliver: model.view.Deliver, session: *const session_mod.Session) model.view.ProjectError!?FetchRequest {
    const action = try pendingBootstrapAction(deliver, session);
    return if (action) |a| switch (a) {
        .fetch => |req| req,
        else => null,
    } else null;
}

pub fn resolveForSwissnum(session: *const session_mod.Session, request: FetchRequest) model.Message {
    if (session.bootstrapLookup(request.swissnum)) |export_id| {
        return .{ .resolve = .{
            .answer = request.answer,
            .resolution = .{ .fulfill = .{ .reference = .{ .near = model.NearRef.object(export_id) } } },
        } };
    }
    return .{ .resolve = .{
        .answer = request.answer,
        .resolution = .{ .break_ = .{ .message = "unknown swissnum" } },
    } };
}

pub fn resolveForDeposit(
    session: *session_mod.Session,
    request: DepositRequest,
) !?model.Message {
    const gifted = try request.gifted.toOwned(session.allocator);
    errdefer model.freeReference(session.allocator, gifted);
    const gifter_key = session.partnerSessionKey() orelse "";
    try session.depositGiftCap(request.gift_id, gifted, gifter_key);
    const answer = request.answer orelse return null;
    return .{ .resolve = .{
        .answer = answer,
        .resolution = .{ .fulfill = .{ .void = {} } },
    } };
}

pub fn resolveForDepositWithRegistry(
    session: *session_mod.Session,
    registry: *GiftRegistry,
    request: DepositRequest,
) !?model.Message {
    const gifted = try request.gifted.toOwned(session.allocator);
    var transferred = false;
    errdefer if (!transferred) model.freeReference(session.allocator, gifted);
    const gifter_key = session.partnerSessionKey() orelse "";
    {
        registry.lock();
        defer registry.unlock();
        try registry.depositOwned(session.allocator, session.limits, request.gift_id, gifted, gifter_key);
    }
    transferred = true;
    const answer = request.answer orelse return null;
    return .{ .resolve = .{
        .answer = answer,
        .resolution = .{ .fulfill = .{ .void = {} } },
    } };
}

pub fn resolveForWithdraw(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    request: WithdrawRequest,
) !model.Message {
    const handoff_owned = try (model.view.Handoff{ .receive = request.receive }).toOwned(allocator);
    errdefer model.freeHandoff(allocator, handoff_owned);
    const receive = handoff_owned.receive;

    if (!verifyHandoffReceive(allocator, session, receive)) {
        return .{ .resolve = .{
            .answer = request.answer,
            .resolution = .{ .break_ = .{ .message = "invalid handoff signature" } },
        } };
    }

    session.validateInboundWithdraw(receive) catch {
        return .{ .resolve = .{
            .answer = request.answer,
            .resolution = .{ .break_ = .{ .message = "invalid handoff withdraw" } },
        } };
    };
    try session.applyInboundWithdraw(receive);

    const gifted = session.giftedCap(receive.signed_give.gift_id) orelse {
        return .{ .resolve = .{
            .answer = request.answer,
            .resolution = .{ .break_ = .{ .message = "gift not deposited" } },
        } };
    };
    const gifted_copy = try model.cloneReference(allocator, gifted);
    return .{ .resolve = .{
        .answer = request.answer,
        .resolution = .{ .fulfill = .{ .reference = gifted_copy } },
    } };
}

pub fn resolveForWithdrawWithRegistry(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    registry: *GiftRegistry,
    request: WithdrawRequest,
) !model.Message {
    const handoff_owned = try (model.view.Handoff{ .receive = request.receive }).toOwned(allocator);
    errdefer model.freeHandoff(allocator, handoff_owned);
    const receive = handoff_owned.receive;

    // Hold the registry lock across the whole withdraw: the gifter key and the
    // deposited capability are borrowed from the gift row, so a concurrent
    // re-deposit on another thread must not free them between the lookup, the
    // signature check, and the clone. Validate and consume stay indivisible too.
    registry.lock();
    defer registry.unlock();

    const gifter_key_bytes = registry.giftGifterKey(receive.signed_give.gift_id) orelse {
        return .{ .resolve = .{
            .answer = request.answer,
            .resolution = .{ .break_ = .{ .message = "invalid handoff withdraw" } },
        } };
    };
    if (!verifyHandoffReceiveWithGifterKey(allocator, receive, gifter_key_bytes)) {
        return .{ .resolve = .{
            .answer = request.answer,
            .resolution = .{ .break_ = .{ .message = "invalid handoff signature" } },
        } };
    }

    registry.validateWithdraw(receive) catch {
        return .{ .resolve = .{
            .answer = request.answer,
            .resolution = .{ .break_ = .{ .message = "invalid handoff withdraw" } },
        } };
    };
    try registry.applyWithdraw(allocator, session.limits, receive);

    const gifted = registry.giftedCap(receive.signed_give.gift_id) orelse {
        return .{ .resolve = .{
            .answer = request.answer,
            .resolution = .{ .break_ = .{ .message = "gift not deposited" } },
        } };
    };
    const gifted_copy = try model.cloneReference(allocator, gifted);
    return .{ .resolve = .{
        .answer = request.answer,
        .resolution = .{ .fulfill = .{ .reference = gifted_copy } },
    } };
}

fn verifyHandoffReceive(allocator: std.mem.Allocator, session: *session_mod.Session, receive: model.HandoffReceive) bool {
    const give = receive.signed_give;
    const gifter_key_bytes = session.giftGifterKey(give.gift_id) orelse session.partnerSessionKey() orelse return false;
    return verifyHandoffReceiveWithGifterKey(allocator, receive, gifter_key_bytes);
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
    if (give.signature.len != crypto.SIGNATURE_BYTES) return false;
    const give_sig = crypto.Signature.fromBytes(give.signature[0..crypto.SIGNATURE_BYTES].*);
    crypto.verify(gifter_key, give_signed, give_sig) catch return false;

    const receive_signed = codec.syrup.canonicalHandoffReceiveSignedBytes(allocator, receive) catch return false;
    defer allocator.free(receive_signed);

    const recipient_key = crypto.PeerKey.fromSlice(give.recipient_key) catch return false;
    if (receive.signature.len != crypto.SIGNATURE_BYTES) return false;
    const receive_sig = crypto.Signature.fromBytes(receive.signature[0..crypto.SIGNATURE_BYTES].*);
    crypto.verify(recipient_key, receive_signed, receive_sig) catch return false;

    return true;
}

fn referencePosition(reference: model.view.Reference) ?u64 {
    return switch (reference) {
        .near => |near| near.export_id,
        .far => |far| far.import_id,
        .promise, .sturdy, .broken => null,
    };
}
