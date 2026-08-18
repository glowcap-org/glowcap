//! Gifter-side handoff helpers (ADR-0009): building the signed
//! `desc:handoff-give`, and the Peer outbound choreography that deposits a
//! gift and resolves (or relays) it. Crypto/encoding primitives stay at the
//! top; free functions over `*Peer` below are the same shape as
//! `inbound.zig` / `outbound.zig`.

const std = @import("std");

const codec = @import("codec");
const foundation = @import("foundation");
const crypto = foundation.crypto;
const model = @import("model");
const session = @import("session");

const engine = @import("mod.zig");
const Peer = engine.Peer;
const lower = @import("lower.zig");
const outbound = @import("outbound.zig");

/// The dialable form of a give's exporter location, an onion-only rewrite.
/// The give must equal the exporter's hello *as the receiver sees it*: the
/// pinned Goblins keys its withdrawal lookup by the full node value, hints
/// included. On every transport but onion the exporter's hello is the same
/// toward everyone — profile hints stamped at configuration ride to Goblins
/// and pancake alike, which `zig build goblins-gift-hints` proves live — so
/// the verbatim bytes are already the matching form and this returns null.
/// On onion the hello is hinted only toward a known-pancake partner
/// (ADR-0118), an unknown receiver is always answered bare, and the pinned
/// Goblins dial arm cannot dial a hinted onion locator at all, so there the
/// give sheds exactly the three `pancake/*` entries, keeping routing hints a
/// receiver needs. Bytes this walker cannot read also ship verbatim,
/// today's exact contract: both sources (our own record encode, the
/// partner's codec-validated hello) are already validated, so the arm is
/// unreachable rather than a policy. The one decode-and-re-encode is paid
/// only on a give whose onion exporter stated a pancake profile; the caller
/// owns non-null bytes.
pub fn dialableExporterLocation(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    var cursor: usize = 0;
    const locator = codec.signed.readLocatorOwned(allocator, raw, &cursor) catch return null;
    defer model.freePeerLocator(allocator, locator);
    if (!std.mem.eql(u8, locator.transport, model.transport.onion)) return null;
    var stripped: usize = 0;
    for (locator.hints.entries) |entry| {
        if (model.transport.isProfileHintName(entry.name)) stripped += 1;
    }
    if (stripped == 0) return null;
    const kept = try allocator.alloc(model.HintEntry, locator.hints.entries.len - stripped);
    defer allocator.free(kept);
    var write: usize = 0;
    for (locator.hints.entries) |entry| {
        if (model.transport.isProfileHintName(entry.name)) continue;
        kept[write] = entry;
        write += 1;
    }
    return try codec.signed.encodeLocatorRecord(allocator, .{
        .transport = locator.transport,
        .designator = locator.designator,
        .hints = if (kept.len == 0) model.Hints.emptyFalse() else .{ .entries = kept },
    });
}

/// Mint one signed give: derive the session and side names from the
/// gifter–exporter session key (ADR-0097), pick the exporter-location form
/// the recipient can use, and sign. Signed by the gifter's key on that
/// session, so the exporter verifies it against the partner key it already
/// proved; any other key — including the node's durable one — would not
/// verify once sessions stop sharing a key.
///
/// The location form (ADR-0118): a known-pancake recipient keeps the
/// exporter's verbatim hello, profile hints and all, and can upgrade its
/// redeem session from them. Everyone else gets the dialable form with the
/// `pancake/*` entries stripped, because a Goblins recipient can neither
/// dial a hinted onion locator nor match a give against a hello it never
/// saw hinted — and a deferred onion exporter answers an unknown
/// recipient's hello bare, so the stripped give equals that hello.
pub fn mintGive(
    allocator: std.mem.Allocator,
    secret: crypto.SecretKey,
    gift_id: []const u8,
    recipient_key: []const u8,
    exporter_key: []const u8,
    exporter_loc: []const u8,
    recipient_known_pancake: bool,
) ![]u8 {
    const gifter_side = try engine.handoff_recipient.sideName(secret.publicKey().asBytes());
    const exporter_side = try engine.handoff_recipient.sideName(exporter_key);
    const session_name = engine.handoff_recipient.sessionName(gifter_side, exporter_side);

    const dialable = if (recipient_known_pancake)
        null
    else
        try dialableExporterLocation(allocator, exporter_loc);
    defer if (dialable) |owned| allocator.free(owned);

    return buildSignedGive(
        allocator,
        secret,
        recipient_key,
        dialable orelse exporter_loc,
        &session_name,
        &gifter_side,
        gift_id,
    );
}

/// Build a signed `desc:handoff-give` the gifter returns to the recipient,
/// signed with the gifter's exporter-session key `secret`. `recipient_key` is
/// the recipient's session public key (32 bytes); `exporter_location_raw` is the
/// exporter's verbatim `op:start-session` locator bytes, embedded exactly so a
/// peer comparing the give's exporter location to the session location matches.
/// `gifter_exporter_session` is the session name shared by the gifter and the
/// exporter, and `gifter_side` is the gifter's own side name. The caller owns the
/// returned bytes and sets them as `model.HandoffGive.raw_signed` so the encoder
/// emits them verbatim.
pub fn buildSignedGive(
    allocator: std.mem.Allocator,
    secret: crypto.SecretKey,
    recipient_key: []const u8,
    exporter_location_raw: []const u8,
    gifter_exporter_session: []const u8,
    gifter_side: []const u8,
    gift_id: []const u8,
) ![]u8 {
    const record = try codec.signed.giveRecordRawLocation(
        allocator,
        recipient_key,
        exporter_location_raw,
        gifter_exporter_session,
        gifter_side,
        gift_id,
    );
    defer allocator.free(record);
    const sig = crypto.sign(&secret, record);
    return codec.signed.wrapGive(allocator, record, &sig.bytes);
}

/// The exporter half of one engine-owned handoff transaction. Public only so
/// the sibling Node coordinator can hold several exporters while it prepares
/// one recipient message; adapters never receive this token. Its infallible
/// commit relies on no intervening exporter mutation after preparation.
pub const PreparedDepositGift = struct {
    message: model.Message,
    reservation: Peer.PendingReservation,

    pub fn abandon(self: *PreparedDepositGift, peer: *Peer) void {
        peer.cancelPendingReservation(self.reservation);
        model.freeMessage(peer.allocator, self.message);
        self.* = undefined;
    }

    pub fn commit(self: *PreparedDepositGift, peer: *Peer) void {
        // `prepareDepositGift` admitted and validated this exact message and
        // reserved every fallible exporter-table and queue resource it needs.
        // `queueOriginatedGive` excludes an aliased recipient peer, so its
        // recipient commit cannot mutate this session between those two points.
        peer.session_state.recordSend(self.message) catch unreachable;
        peer.pushPendingAssume(self.reservation, .{ .message = self.message });
        self.* = undefined;
    }
};

pub fn prepareDepositGiftInBatch(
    peer: *Peer,
    batch: *Peer.PendingBatch,
    gift_id: []const u8,
    gifted: model.Reference,
) !PreparedDepositGift {
    var message = try model.cloneMessage(peer.allocator, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(engine.BOOTSTRAP_POSITION) },
        .args = &.{ .{ .symbol = "deposit-gift" }, .{ .bytes = gift_id }, .{ .reference = gifted } },
        .answer = null,
    } });
    errdefer model.freeMessage(peer.allocator, message);

    if (peer.node_services) |services| {
        if (services.lowering_active.*) try lower.lowerMessage(services, &message);
    }
    peer.session_state.rewriteShortenedMessage(&message);
    try peer.session_state.admits(model.view.Body.fromOwned(&message));
    try session.validate.validateSend(&peer.session_state, message);
    if (message.deliver.args[2].reference == .near)
        try peer.session_state.exports.ensureUnusedCapacity(peer.allocator, 1);
    return .{
        .message = message,
        .reservation = try batch.reserve(.{ .message = message }),
    };
}

pub fn prepareDepositGift(peer: *Peer, gift_id: []const u8, gifted: model.Reference) !PreparedDepositGift {
    var batch = try peer.beginPendingBatch(1);
    return prepareDepositGiftInBatch(peer, &batch, gift_id, gifted);
}

pub fn sendDepositGift(peer: *Peer, gift_id: []const u8, gifted: model.Reference) !void {
    var prepared = try prepareDepositGift(peer, gift_id, gifted);
    prepared.commit(peer);
}

/// Where the recipient half of an originated give settles.
pub const GiveDestination = union(enum) {
    answer: model.AnswerName,
    relayed: struct {
        import_position: model.ImportPosition,
        row_id: u64,
    },
};

/// Admit both local halves of one originated handoff as one sans-I/O queue
/// transaction. Every exporter-side failure is acquired before the recipient
/// queue can own `give_bytes`; after that recipient commit, the exporter queue
/// append is infallible. Their independent transports may deliver either half
/// first, which the handoff protocol permits. The peers must be distinct: an
/// aliased recipient could mutate the prepared exporter session between those
/// commits and invalidate the transaction's premise.
pub fn queueOriginatedGive(
    exporter: *Peer,
    recipient: *Peer,
    gift_id: []const u8,
    gifted: model.Reference,
    give_bytes: []const u8,
    destination: GiveDestination,
) !void {
    if (exporter == recipient) return error.AliasedHandoffPeers;

    var deposit = try prepareDepositGift(exporter, gift_id, gifted);
    var deposit_owned = true;
    defer if (deposit_owned) deposit.abandon(exporter);

    switch (destination) {
        .answer => |answer| try sendResolveHandoffGive(recipient, answer, give_bytes),
        .relayed => |slot| try applyRelayedHandoffGive(
            recipient,
            slot.import_position,
            slot.row_id,
            give_bytes,
        ),
    }
    deposit.commit(exporter);
    deposit_owned = false;
}

/// Resolve `answer` with a signed `desc:handoff-give` decoded from `give_bytes`.
pub fn sendResolveHandoffGive(peer: *Peer, answer: model.AnswerName, give_bytes: []const u8) !void {
    const handoff = try decodeHandoffGive(peer.allocator, give_bytes);
    // `send` takes the boxed handoff on every outcome. The signed give is
    // already owned, so routing it through `sendCopying` would deep-clone the
    // complete tree only to free this original immediately afterward.
    try outbound.enqueueAnswerResolutionOwned(peer, answer, .{ .fulfill = .{ .handoff = handoff } });
}

/// Store a signed `desc:handoff-give` as the relayed resolution of
/// `import_position`. `give_bytes` is borrowed; ownership of the decoded
/// handoff passes to `applyRelayedResolution`.
pub fn applyRelayedHandoffGive(
    peer: *Peer,
    import_position: model.ImportPosition,
    row_id: u64,
    give_bytes: []const u8,
) !void {
    const boxed = try decodeHandoffGive(peer.allocator, give_bytes);
    return peer.applyRelayedResolution(import_position, row_id, .{ .fulfill = .{ .handoff = boxed } });
}

/// Decode and box one borrowed signed give, transferring the complete owned
/// handoff to the caller. Both recipient destinations use this ownership edge;
/// neither needs to deep-clone an already-owned signed tree.
pub fn decodeHandoffGive(allocator: std.mem.Allocator, give_bytes: []const u8) !*model.Handoff {
    const give = try codec.signed.decodeGiveOwned(allocator, give_bytes);
    const handoff = allocator.create(model.Handoff) catch |err| {
        model.freeHandoffGive(allocator, give);
        return err;
    };
    handoff.* = .{ .give = give };
    return handoff;
}
