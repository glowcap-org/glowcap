//! Recipient-side handoff helpers (ADR-0009): session/side naming, signed
//! `desc:handoff-receive` construction, and the Peer outbound choreography
//! that withdraws a gift. Crypto/session primitives stay at the top; the
//! withdraw free function over `*Peer` is the same shape as `inbound.zig` /
//! `outbound.zig`.

const std = @import("std");

const model = @import("model");
const codec = @import("codec");
const foundation = @import("foundation");
const crypto = foundation.crypto;
const handoff_names = @import("handoff_names.zig");

const engine = @import("mod.zig");
const Peer = engine.Peer;

const CountIssuer = union(enum) {
    session: *engine.bootstrap.gifts.GiftRegistry,
    node_v1: engine.NodeServices,

    fn prepare(self: CountIssuer) !engine.bootstrap.gifts.PreparedHandoffCount {
        return switch (self) {
            .session => |registry| registry.prepareEmittedCount(),
            .node_v1 => |services| services.prepareV1EmittedHandoffCount(),
        };
    }
};

/// The side and session naming both handoff ends derive from session keys. The
/// exporter checks an inbound receive against the same derivation, so they live
/// in `handoff_names.zig` and are re-exported here for the recipient's callers.
pub const sideName = handoff_names.sideName;
pub const sessionName = handoff_names.sessionName;

/// A signed `desc:handoff-receive` that owns its derived bytes, including the
/// gifter's give it parsed from `give_bytes` (`give` carries both `raw_signed`,
/// for a Syrup session's verbatim fast path, and the typed fields a Cap'n Proto
/// session encodes instead — so the receive rides *this* session's codec, not
/// just Syrup's). The session and side names and the signature live inline, so
/// the `model.HandoffReceive` that `message` projects borrows only this value,
/// no dangling stack references once the builder returns. The caller holds the
/// `SignedReceive` until the withdraw it carries has been encoded, then
/// releases it with `deinit`.
pub const SignedReceive = struct {
    receiving_session: [32]u8,
    receiving_side: [32]u8,
    signature: [crypto.SIGNATURE_BYTES]u8,
    give: model.HandoffGive,
    handoff_count: u64,

    /// Project the borrowed wire `desc:handoff-receive`. The returned value
    /// borrows `self`, so `self` must outlive every use of it.
    pub fn message(self: *const SignedReceive) model.HandoffReceive {
        return .{
            .receiving_session = &self.receiving_session,
            .receiving_side = &self.receiving_side,
            .handoff_count = self.handoff_count,
            .signed_give = self.give,
            .signature = &self.signature,
        };
    }

    /// Release the give `signedReceiveFromGiveBytes` parsed and owns. Safe to
    /// call once the withdraw `message()` projected has been encoded —
    /// `sendCopying` deep-copies before it returns, so the caller's one send
    /// call always finishes first.
    pub fn deinit(self: *const SignedReceive, allocator: std.mem.Allocator) void {
        model.freeHandoffGive(allocator, self.give);
    }
};

/// Build a signed `desc:handoff-receive` embedding the gifter's give, returning
/// a self-contained `SignedReceive` the caller keeps alive while it encodes the
/// withdraw, then releases with `SignedReceive.deinit`. `give_bytes` is the
/// Syrup-encoded `<desc:sig-envelope …>` a gifter returned (or a binding's
/// `glowcap_build_handoff_give` built); it is parsed once here into a typed,
/// codec-neutral give. `secret` is the recipient's session key — the one the
/// gifter named as the give's recipient key — so the exporter verifies the
/// receive against it. `handoff_count` is supplied by the owner of issuance.
/// Ordinary peers mint it from their recipient-to-exporter session registry. A
/// Node's V1 compatibility path may supply its host-lifetime cursor for Goblins
/// reconnect interop; this changes emitted values, never replay authority.
pub fn signedReceiveFromGiveBytes(
    allocator: std.mem.Allocator,
    handoff_count: u64,
    secret: crypto.SecretKey,
    our_pubkey: crypto.PeerKey,
    exporter_partner_key: []const u8,
    give_bytes: []const u8,
) !SignedReceive {
    const give = try codec.signed.decodeGiveOwned(allocator, give_bytes);
    errdefer model.freeHandoffGive(allocator, give);
    const our_side = try sideName(our_pubkey.asBytes());
    const exporter_side = try sideName(exporter_partner_key);
    const receiving_session = sessionName(our_side, exporter_side);
    var result: SignedReceive = .{
        .receiving_session = receiving_session,
        .receiving_side = our_side,
        .signature = @as([crypto.SIGNATURE_BYTES]u8, @splat(0)),
        .give = give,
        .handoff_count = handoff_count,
    };
    const receive_signed = try codec.signed.receiveBytes(allocator, result.message());
    defer allocator.free(receive_signed);
    result.signature = crypto.sign(&secret, receive_signed).bytes;
    return result;
}

/// Rebuild a Syrup `<desc:sig-envelope <desc:handoff-give …> …>` from typed
/// Cap'n Proto (or other non-Syrup) give fields so Host / C ABI redeem can
/// relay the signing domain when the frame has no Syrup envelope span.
/// Caller owns the returned bytes.
fn reconstructSignedHandoffGive(
    allocator: std.mem.Allocator,
    give: model.view.HandoffGive,
) ![]u8 {
    const owned = try give.toOwned(allocator);
    defer model.freeHandoffGive(allocator, owned);
    const record = try codec.signed.giveBytes(allocator, owned);
    defer allocator.free(record);
    return codec.signed.wrapGive(allocator, record, owned.signature);
}

/// Project a give's exporter peer into the dialable `ocapn://…` URI a
/// recipient hands its dialer, through the one core URI grammar. Materialize
/// hints only when the lazy arm requires it; transport/designator stay
/// borrowed for `writePeer`. The caller owns the returned bytes.
pub const LocatorUriError = error{ OutOfMemory, MalformedLocatorRecord };
pub fn exporterLocatorUri(
    allocator: std.mem.Allocator,
    location: model.view.PeerLocator,
) LocatorUriError![]u8 {
    var owned_hints: ?model.Hints = null;
    defer if (owned_hints) |h| model.freeHints(allocator, h);
    const hints: model.Hints = if (location.hints.stackUriHints()) |h| h else blk: {
        owned_hints = location.hints.toOwned(allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedView => return error.MalformedLocatorRecord,
        };
        break :blk owned_hints.?;
    };
    const peer: model.PeerLocator = .{
        .transport = location.transport,
        .designator = location.designator,
        .hints = hints,
    };

    return model.uri.writePeer(allocator, peer) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedLocatorRecord,
    };
}

/// Signed give + dial URI for a fulfill that carries a handoff give.
/// Soft failures leave `give` as `.absent` or `locator` as `.absent` /
/// `.malformed`; only OOM errors out. Caller frees via `deinit`.
pub const ProjectedRedeemGive = struct {
    give: union(enum) {
        borrowed: []const u8,
        owned: []u8,
        absent,
    } = .absent,
    locator: union(enum) {
        uri: []u8,
        absent,
        malformed,
    } = .absent,

    /// Give octets when present; `null` when reconstruct/span failed (`.absent`).
    /// Callers must branch on this instead of treating an empty slice as absent.
    pub fn bytes(self: ProjectedRedeemGive) ?[]const u8 {
        return switch (self.give) {
            .borrowed => |b| b,
            .owned => |o| o,
            .absent => null,
        };
    }

    pub fn deinit(self: *ProjectedRedeemGive, allocator: std.mem.Allocator) void {
        if (self.give == .owned) allocator.free(self.give.owned);
        if (self.locator == .uri) allocator.free(self.locator.uri);
        self.* = .{};
    }
};

/// One redeem-projection spine for Host / Vat / C ABI: span or reconstruct the
/// signed give, then project the exporter dial URI.
pub fn projectGiveForRedeem(
    allocator: std.mem.Allocator,
    give: model.view.HandoffGive,
) error{OutOfMemory}!ProjectedRedeemGive {
    var result: ProjectedRedeemGive = .{};
    errdefer result.deinit(allocator);

    // The Syrup parser already recorded the envelope's exact span while it read
    // the give, so use that rather than scanning the frame for the label. A scan
    // finds the *first* occurrence of `desc:sig-envelope`, and those bytes can
    // appear earlier inside any byte-string argument a partner controls, which
    // would relay a span disagreeing with the typed view beside it. A non-Syrup
    // session records no span and reconstructs below.
    if (give.raw_signed) |span| {
        result.give = .{ .borrowed = span };
    } else {
        result.give = if (reconstructSignedHandoffGive(allocator, give)) |owned|
            .{ .owned = owned }
        else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => .absent,
        };
    }

    result.locator = if (exporterLocatorUri(allocator, give.exporter)) |uri|
        .{ .uri = uri }
    else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MalformedLocatorRecord => .malformed,
    };
    return result;
}

/// Queue the recipient half of a three-party handoff: sign a
/// `desc:handoff-receive` over `give_bytes` keyed by `secret`, mint the
/// monotonic handoff-count from this session or its Node's V1 compatibility
/// issuer, and queue `withdraw-gift` to the exporter's bootstrap under
/// `answer`. The exporter session must be open — its partner key names the
/// receive's session — or this fails with `error.NoExporterKey`. This is the
/// one definition of the withdraw deliver shape; the `Node` redeem path and
/// the C ABI both drive it. `give_bytes` is borrowed for the call.
pub fn sendWithdrawGift(
    peer: *Peer,
    secret: foundation.crypto.SecretKey,
    give_bytes: []const u8,
    answer: model.AnswerPosition,
) !void {
    const exporter_key = peer.session_state.partnerSessionKey() orelse return error.NoExporterKey;
    // Two different keys, deliberately (ADR-0097).
    //
    // `secret` signs, and it is the key of the session the *give arrived
    // on*, because that is the identity the give named as its
    // `recipient_key` and the exporter verifies this receive against that
    // name. The side and session names below are this session's — the
    // recipient–exporter one — because they name where the withdrawal is
    // happening. Goblins draws the same distinction: its receive is signed
    // by the coordinator that received the give while its names come from
    // the exporter session's coordinator. Conflating them works only while
    // one key serves every session.
    const local_key = peer.session_state.localSessionKey() orelse
        return error.NoLocalSessionKey;
    const our_side_key = foundation.crypto.PeerKey.fromSlice(local_key) catch
        return error.NoLocalSessionKey;
    const issuer: CountIssuer = if (peer.session_state.captp_version == .v1_0)
        if (peer.node_services) |services|
            .{ .node_v1 = services }
        else
            .{ .session = peer.giftRegistry() }
    else
        .{ .session = peer.giftRegistry() };
    const prepared_count = try issuer.prepare();
    const signed = try signedReceiveFromGiveBytes(
        peer.allocator,
        prepared_count.count,
        secret,
        our_side_key,
        exporter_key,
        give_bytes,
    );
    defer signed.deinit(peer.allocator);
    // `signed.message()` borrows `signed`; both outlive `sendCopying`, which
    // deep-copies the deliver before this returns.
    var handoff = model.Handoff{ .receive = signed.message() };
    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(engine.BOOTSTRAP_POSITION) },
        .args = &.{ .{ .symbol = "withdraw-gift" }, .{ .handoff = &handoff } },
        .answer = answer,
    } });
    try prepared_count.commit();
}
