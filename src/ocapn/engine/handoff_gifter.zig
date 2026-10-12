//! Gifter-side handoff helpers (ADR-0009): building the signed
//! `desc:handoff-give`, and the Peer outbound choreography that deposits a
//! gift and resolves (or relays) it. Crypto/encoding primitives stay at the
//! top. Free functions over `*Peer` below are the same shape as
//! `inbound.zig` / `outbound.zig`.

const std = @import("std");

const codec = @import("codec");
const foundation = @import("foundation");
const crypto = foundation.crypto;
const model = @import("model");
const session = @import("session");

const engine = @import("mod.zig");
const id_route = session.id_route;
const Peer = engine.Peer;
const lower = @import("lower.zig");
const outbound = @import("outbound.zig");

pub const RecipientLocatorPolicy = struct {
    known_glowcap: bool = false,
    route_vocabulary: bool = false,
    /// The transport carrying this recipient's current session. A baseline
    /// peer advertises no outbound-provider set, so this is the only transport
    /// profile the gifter can prove it participates in. Null keeps only the
    /// Goblins-compatible floor.
    session_transport: ?[]const u8 = null,
};

pub const ExporterLocatorPolicy = struct {
    /// Whether the exporter session admitted private route vocabulary.
    route_vocabulary: bool,
    /// The exact location the exporter claimed on this session, used when a
    /// richer configured location cannot return inside a baseline withdrawal.
    session_location: []const u8,
};

/// The dialable form of a give's exporter location for a recipient whose
/// capabilities are unknown.
/// The give must equal the exporter's hello *as the receiver sees it*: the
/// pinned Goblins keys its withdrawal lookup by the full node value, hints
/// included. `id` gives lower only when its admitted bundle contains a
/// recipient-compatible baseline route. Otherwise it fails closed. Private
/// route hints (`via`) are stripped from a baseline locator instead of leaking
/// private vocabulary. On onion the
/// hello is hinted only toward a known-glowcap partner (ADR-0118), an unknown
/// receiver is always answered bare, and the pinned Goblins dial arm cannot
/// dial a hinted onion locator at all, so profile hints shed there too.
/// Bytes this walker cannot read still ship verbatim: both sources (our own
/// record encode, the partner's codec-validated hello) are already validated,
/// so the arm is unreachable rather than a policy. The decode-and-re-encode
/// is paid only when a give needs lowering or stripping. The caller owns
/// non-null bytes.
pub fn exporterLocationForRecipient(
    allocator: std.mem.Allocator,
    raw: []const u8,
    recipient: RecipientLocatorPolicy,
) !?[]u8 {
    if (recipient.route_vocabulary) return null;
    var cursor: usize = 0;
    const locator = codec.signed.readLocatorOwned(allocator, raw, &cursor) catch return null;
    defer model.freePeerLocator(allocator, locator);
    if (try compatibleRoute(allocator, locator, recipient)) |route| {
        defer model.freePeerLocator(allocator, route);
        return try codec.signed.encodeLocatorRecord(allocator, route);
    }
    if (hasPrivateRouteHint(locator)) {
        if (!routeFitsRecipient(recipient, locator.transport))
            return error.UnsupportedArgument;
        const stripped = try cloneLocatorForRecipient(allocator, locator, recipient);
        defer model.freePeerLocator(allocator, stripped);
        return try codec.signed.encodeLocatorRecord(allocator, stripped);
    }
    if (recipient.known_glowcap) return null;
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

fn compatibleRoute(
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
    recipient: RecipientLocatorPolicy,
) !?model.PeerLocator {
    if (!std.mem.eql(u8, locator.transport, model.transport.id))
        return null;
    var bundle = id_route.parseLocator(allocator, locator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnsupportedArgument,
    };
    defer bundle.deinit(allocator);
    for (bundle.paths) |path| {
        if (!routeFitsRecipient(recipient, path.transport)) continue;
        return try clonePathForRecipient(allocator, path, recipient);
    }
    return error.UnsupportedArgument;
}

fn routeFitsRecipient(recipient: RecipientLocatorPolicy, transport: []const u8) bool {
    if (recipient.session_transport) |active|
        return std.mem.eql(u8, active, transport);
    return std.mem.eql(u8, transport, model.transport.tcp) or
        std.mem.eql(u8, transport, model.transport.onion);
}

fn hasPrivateRouteHint(locator: model.PeerLocator) bool {
    for (locator.hints.entries) |entry| {
        if (std.mem.eql(u8, locator.transport, model.transport.id) and
            std.mem.eql(u8, entry.name, model.transport.hint_via)) return true;
    }
    return false;
}

fn clonePathForRecipient(
    allocator: std.mem.Allocator,
    path: model.RoutePath,
    recipient: RecipientLocatorPolicy,
) !model.PeerLocator {
    return cloneLocatorForRecipient(allocator, .{
        .transport = path.transport,
        .designator = path.designator,
        .hints = path.hints,
    }, recipient);
}

fn cloneLocatorForRecipient(
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
    recipient: RecipientLocatorPolicy,
) !model.PeerLocator {
    var kept_count: usize = 0;
    for (locator.hints.entries) |entry| {
        if (!recipient.known_glowcap and model.transport.isProfileHintName(entry.name)) continue;
        if (std.mem.eql(u8, locator.transport, model.transport.id) and
            std.mem.eql(u8, entry.name, model.transport.hint_via)) continue;
        kept_count += 1;
    }
    if (kept_count == locator.hints.entries.len)
        return model.clonePeerLocator(allocator, locator);

    const transport = try allocator.dupe(u8, locator.transport);
    errdefer allocator.free(transport);
    const designator = try allocator.dupe(u8, locator.designator);
    errdefer allocator.free(designator);
    if (kept_count == 0) {
        return .{
            .transport = transport,
            .designator = designator,
            .hints = model.Hints.emptyFalse(),
        };
    }
    const entries = try allocator.alloc(model.HintEntry, kept_count);
    errdefer allocator.free(entries);
    var write: usize = 0;
    errdefer {
        for (entries[0..write]) |entry| model.freeHintEntry(allocator, entry);
    }
    for (locator.hints.entries) |entry| {
        if (!recipient.known_glowcap and model.transport.isProfileHintName(entry.name)) continue;
        if (std.mem.eql(u8, locator.transport, model.transport.id) and
            std.mem.eql(u8, entry.name, model.transport.hint_via)) continue;
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        entries[write] = .{
            .name = name,
            .value = try model.cloneHintValue(allocator, entry.value),
        };
        write += 1;
    }
    return .{
        .transport = transport,
        .designator = designator,
        .hints = .{ .entries = entries },
    };
}

/// Mint one signed give: derive the session and side names from the
/// gifter–exporter session key (ADR-0097), pick the exporter-location form
/// the recipient can use, and sign. Signed by the gifter's key on that
/// session, so the exporter verifies it against the partner key it already
/// proved. Any other key, including the node's durable one, would not
/// verify once sessions stop sharing a key.
///
/// The location form (ADR-0118/ADR-0125): a recipient that negotiated route
/// vocabulary keeps route advice only when the exporter session admitted it
/// too. A baseline-compatible configured location remains valid. Only private
/// route vocabulary falls back to the exporter's session location. The chosen
/// source is then lowered again when the recipient is baseline.
pub fn mintGive(
    allocator: std.mem.Allocator,
    secret: crypto.SecretKey,
    gift_id: []const u8,
    recipient_key: []const u8,
    exporter_key: []const u8,
    exporter_loc: []const u8,
    recipient: RecipientLocatorPolicy,
    exporter: ExporterLocatorPolicy,
) ![]u8 {
    const gifter_side = try engine.handoff_recipient.sideName(secret.publicKey().asBytes());
    const exporter_side = try engine.handoff_recipient.sideName(exporter_key);
    const session_name = engine.handoff_recipient.sessionName(gifter_side, exporter_side);

    const accepted_by_exporter = source: {
        if (exporter.route_vocabulary) break :source exporter_loc;
        var cursor: usize = 0;
        const locator = codec.signed.readLocatorView(exporter_loc, &cursor) catch
            return error.UnsupportedArgument;
        if (cursor != exporter_loc.len) return error.UnsupportedArgument;
        const carries_routes = session.validate.carriesRouteVocabulary(locator) catch
            return error.UnsupportedArgument;
        break :source if (carries_routes) exporter.session_location else exporter_loc;
    };
    const dialable = if (recipient.route_vocabulary)
        null
    else
        try exporterLocationForRecipient(allocator, accepted_by_exporter, recipient);
    defer if (dialable) |owned| allocator.free(owned);

    return buildSignedGive(
        allocator,
        secret,
        recipient_key,
        dialable orelse accepted_by_exporter,
        &session_name,
        &gifter_side,
        gift_id,
    );
}

/// Build a signed `desc:handoff-give` the gifter returns to the recipient,
/// signed with the gifter's exporter-session key `secret`. `recipient_key` is
/// the recipient's session public key (32 bytes). `exporter_location_raw` is the
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
/// one recipient message. Adapters never receive this token. Its infallible
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
    answer: session.AnswerTarget,
    relayed: struct {
        import_position: model.ImportPosition,
        row_id: u64,
    },
};

/// Admit both local halves of one originated handoff as one sans-I/O queue
/// transaction. Every exporter-side failure is acquired before the recipient
/// queue can own `give_bytes`. After that recipient commit, the exporter queue
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
pub fn sendResolveHandoffGive(peer: *Peer, answer: session.AnswerTarget, give_bytes: []const u8) !void {
    const handoff = try decodeHandoffGive(peer.allocator, give_bytes);
    // `send` takes the boxed handoff on every outcome. The signed give is
    // already owned, so routing it through `sendCopying` would deep-clone the
    // complete tree only to free this original immediately afterward.
    try outbound.enqueueAnswerTargetResolutionOwned(
        peer,
        answer,
        .{ .fulfill = .{ .handoff = handoff } },
    );
}

/// Store a signed `desc:handoff-give` as the relayed resolution of
/// `import_position`. `give_bytes` is borrowed. Ownership of the decoded
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
/// handoff to the caller. Both recipient destinations use this ownership edge.
/// Neither needs to deep-clone an already-owned signed tree.
pub fn decodeHandoffGive(allocator: std.mem.Allocator, give_bytes: []const u8) !*model.Handoff {
    const give = try codec.signed.decodeGiveOwned(allocator, give_bytes);
    const handoff = allocator.create(model.Handoff) catch |err| {
        model.freeHandoffGive(allocator, give);
        return err;
    };
    handoff.* = .{ .give = give };
    return handoff;
}
