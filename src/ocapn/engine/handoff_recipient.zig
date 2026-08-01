//! Recipient-side handoff helpers (ADR-0009): session/side naming and signed
//! `desc:handoff-receive` construction. I/O-bound withdraw choreography stays in
//! the adapter; these are the crypto/session primitives any host needs.

const std = @import("std");

const model = @import("model");
const codec = @import("codec");
const crypto = @import("foundation").crypto;
const session_mod = @import("session");
const bootstrap = @import("bootstrap.zig");
const handoff_names = @import("handoff_names.zig");

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
/// `pancake_build_handoff_give` built); it is parsed once here into a typed,
/// codec-neutral give. `secret` is the recipient's session key — the one the
/// gifter named as the give's recipient key — so the exporter verifies the
/// receive against it. The `handoff_count` is minted from this
/// recipient-to-exporter session's `registry`, so its monotonic replay counter
/// dies with the session (ADR-0100).
pub fn signedReceiveFromGiveBytes(
    allocator: std.mem.Allocator,
    limits: session_mod.SessionLimits,
    registry: *bootstrap.GiftRegistry,
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
    _ = limits;
    const handoff_count = try registry.nextEmittedCount();
    var result: SignedReceive = .{
        .receiving_session = receiving_session,
        .receiving_side = our_side,
        .signature = [_]u8{0} ** crypto.SIGNATURE_BYTES,
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

    /// Take ownership of reconstructed give bytes, or null when borrowed/absent.
    pub fn takeOwned(self: *ProjectedRedeemGive) ?[]u8 {
        return switch (self.give) {
            .owned => |o| blk: {
                self.give = .absent;
                break :blk o;
            },
            .borrowed, .absent => null,
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
