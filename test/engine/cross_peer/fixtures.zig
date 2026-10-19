//! The signed-handoff fixtures the cross-peer suite shares: deterministic
//! keys and sides, give and receive builders, scripted verifiers, and the
//! real-signature helper.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const crypto = glowcap.foundation.crypto;
const syrup = glowcap.ocapn.codec.syrup;
const cross_peer = @import("../../support/cross_peer.zig");

pub fn repeated(comptime n: usize, byte: u8) [n]u8 {
    return @splat(byte);
}

pub const recipient_key = repeated(32, 0x42);

pub const gifter_session = repeated(32, 0xcc);

pub const gifter_side = repeated(32, 0x11);

pub const receiving_session = repeated(32, 0xdd);

/// The recipient's side name is not free bytes: the exporter derives it from the
/// give's recipient key and refuses a receive that names anything else, so the
/// fixture derives it the same way rather than picking a constant.
pub const receiving_side = blk: {
    @setEvalBranchQuota(100_000);
    break :blk engine.handoff_names.sideName(recipient_key[0..]) catch unreachable;
};

pub const give_signature = repeated(64, 0xaa);

pub const receive_signature = repeated(64, 0xbb);

pub const gift_id_a = repeated(32, 0x01);

pub const gift_id_b = repeated(32, 0x02);

/// The side name the exporter derives from a give's recipient key. A receive
/// must name exactly this, so a fixture holding its own recipient key derives it
/// the same way instead of inventing bytes.
pub fn sideOf(key: crypto.PeerKey) [32]u8 {
    return engine.handoff_names.sideName(key.asBytes()) catch unreachable;
}

pub const GifterSessionFixture = struct {
    peer_handle: engine.PeerHandle = .from(0),
    side: [32]u8,
    session_name: [32]u8,
    key: [32]u8,
    gifts: *engine.bootstrap.gifts.GiftRegistry,
    resolve_calls: usize = 0,

    pub fn resolve(ctx: ?*anyopaque, side: [32]u8, session_name: []const u8) ?engine.bootstrap.gifts.GifterSession {
        const self: *GifterSessionFixture = @ptrCast(@alignCast(ctx.?));
        self.resolve_calls += 1;
        if (!std.mem.eql(u8, &self.side, &side)) return null;
        if (!std.mem.eql(u8, &self.session_name, session_name)) return null;
        return .{ .peer_handle = self.peer_handle, .key = self.key, .gifts = self.gifts };
    }

    pub fn resolver(self: *GifterSessionFixture) engine.bootstrap.gifts.GifterSessionResolver {
        return .{ .ctx = self, .resolve = resolve };
    }
};

/// A permissive resolver: it returns a live gifter session no
/// matter what side or session name the give carried. The resolver seam is
/// application-supplied, so the engine must not trust it to have established
/// the fixed widths production resolution guarantees.
pub const PermissiveGifterSessionFixture = struct {
    peer_handle: engine.PeerHandle = .from(0),
    key: [32]u8,
    gifts: *engine.bootstrap.gifts.GiftRegistry,
    resolve_calls: usize = 0,

    pub fn resolve(ctx: ?*anyopaque, side: [32]u8, session_name: []const u8) ?engine.bootstrap.gifts.GifterSession {
        _ = side;
        _ = session_name;
        const self: *PermissiveGifterSessionFixture = @ptrCast(@alignCast(ctx.?));
        self.resolve_calls += 1;
        return .{ .peer_handle = self.peer_handle, .key = self.key, .gifts = self.gifts };
    }

    pub fn resolver(self: *PermissiveGifterSessionFixture) engine.bootstrap.gifts.GifterSessionResolver {
        return .{ .ctx = self, .resolve = resolve };
    }
};

pub fn giveWith(gift_id: []const u8) model.HandoffGive {
    return .{
        .recipient_key = recipient_key[0..],
        .exporter = .{ .transport = "memory", .designator = "exporter" },
        .gifter_exporter_session = gifter_session[0..],
        .gifter_side = gifter_side[0..],
        .gift_id = gift_id,
        .signature = give_signature[0..],
    };
}

pub fn receiveWith(gift_id: []const u8, count: u64, signature: []const u8) model.HandoffReceive {
    return .{
        .receiving_session = receiving_session[0..],
        .receiving_side = receiving_side[0..],
        .handoff_count = count,
        .signed_give = giveWith(gift_id),
        .signature = signature,
    };
}

pub const RejectingVerifier = struct {
    pub fn verify(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
        return false;
    }

    pub fn make() cross_peer.SignatureVerifier {
        return .{ .context = null, .verify_fn = verify };
    }
};

/// A real Ed25519 verifier that routes each handoff certificate to the right key,
/// the production shape ADR-0039 describes. A `desc:handoff-receive` payload is
/// verified with the recipient key. Any other (`desc:handoff-give`) with the
/// gifter's session key. It distinguishes them by the leading record label, since
/// a receive record carries its own label before the give it embeds.
pub const RoutingVerifier = struct {
    gifter_key: crypto.PeerKey,
    recipient_key: crypto.PeerKey,

    pub fn verify(ctx: ?*anyopaque, payload: []const u8, signature: []const u8) bool {
        const self: *RoutingVerifier = @ptrCast(@alignCast(ctx.?));
        const label_at = std.mem.indexOf(u8, payload, "desc:handoff-") orelse return false;
        const key = if (std.mem.startsWith(u8, payload[label_at..], "desc:handoff-receive"))
            self.recipient_key
        else
            self.gifter_key;
        if (signature.len != crypto.signature_bytes) return false;
        const sig = crypto.Signature.fromBytes(signature[0..crypto.signature_bytes].*);
        crypto.verify(key, payload, sig) catch return false;
        return true;
    }

    pub fn make(self: *RoutingVerifier) cross_peer.SignatureVerifier {
        return .{ .context = self, .verify_fn = verify };
    }
};

/// A give signed by `gifter_secret` over its canonical bytes, naming `recipient`
/// as its recipient. The returned give borrows the caller-owned key/signature
/// slices, so they must outlive it.
pub fn signedGive(
    gift_id: []const u8,
    recipient: []const u8,
    gifter_secret: *const crypto.SecretKey,
    out_signed: *[]u8,
    out_sig: *crypto.Signature,
    allocator: std.mem.Allocator,
) !model.HandoffGive {
    var give: model.HandoffGive = .{
        .recipient_key = recipient,
        .exporter = .{ .transport = "memory", .designator = "exporter" },
        .gifter_exporter_session = gifter_session[0..],
        .gifter_side = gifter_side[0..],
        .gift_id = gift_id,
        .signature = "",
    };
    out_signed.* = try syrup.canonicalHandoffGiveSignedBytes(allocator, give);
    out_sig.* = crypto.sign(gifter_secret, out_signed.*);
    give.signature = out_sig.asBytes();
    return give;
}
