//! In-process peer pairing — construct two negotiating peers and drive their
//! `op:start-session` handshake to completion, with no async, netlayer, or
//! adapter wrappers.
//!
//! Two negotiating `Peer`s exchange their `op:start-session` halves through a
//! frame shuttle: each peer steps, the outbound frames it produced are fed into
//! the partner's inbound queue, and the loop terminates when both peers reach
//! `StepOutcome.idle` with no traffic in flight. After `paired` /
//! `pairedV1_0Syrup` / `pairedWithKeys` returns, both peers sit in the canonical
//! `open` state (both handshake halves observed) with the bootstrap export
//! installed at id 0.
//!
//! Offer jobs: `paired` runs `Offer.native()` (prefers `next` / Cap'n Proto);
//! `pairedV1_0Syrup` and `pairedWithKeys` run `Offer.v1_0Syrup()` (`v1_0` / Syrup).
//! Callers that need an arbitrary intersected offer use `negotiate` then
//! `pairedNegotiated`.
//!
//! This is the no-I/O primitive the netlayer adapters wrap: an adapter delegates
//! the handshake here, then pairs the resulting sync peers with its transport glue.
//! Entropy stays at the caller — `pairedWithKeys` takes 32-byte seeds rather
//! than generating keys, keeping the engine core free of randomness (I/O).

const std = @import("std");

const codec = @import("codec");
const foundation = @import("foundation");
const model = @import("model");
const session = @import("session");
const engine = @import("mod.zig");

const crypto = foundation.crypto;
const Peer = engine.Peer;

/// Iteration cap for `shuttleUntilQuiescent`. A canonical handshake settles
/// in 2-3 iterations (send, deliver, quiesce); the generous cap surfaces a
/// non-terminating dispatcher bug as `ShuttleOutcome.iter_cap_exceeded` well
/// before any test-level wall clock fires.
const SHUTTLE_ITER_CAP: usize = 64;

pub const Error = error{
    /// The frame shuttle hit `SHUTTLE_ITER_CAP` without both peers reaching
    /// mutual quiescence — a dispatcher-bug signal.
    HandshakeDidNotQuiesce,
    /// The handshake completed without surfacing the partner's inbound
    /// `op:start-session` event for the keyed path to verify.
    MissingStartSessionEvent,
    /// The partner's `acceptable_location_sig` failed to verify against the
    /// claimed `session_pubkey` over the canonical signed bytes (ADR-0006).
    /// Keyed path only.
    InvalidStartSessionSignature,
    /// The two offers share no codec — negotiation produced no session
    /// (`engine.negotiation.negotiate` returned null).
    NoSharedCodec,
    /// The two offers share no CapTP version — negotiation produced no session
    /// (`engine.negotiation.negotiate` returned null).
    NoSharedCaptpVersion,
};

/// Outcome of `shuttleUntilQuiescent`.
pub const ShuttleOutcome = enum {
    /// Both peers reached `StepOutcome.idle` with no traffic in flight inside
    /// the iteration cap.
    quiescent,
    /// The iteration cap fired before quiescence, escalate (dispatcher bug).
    iter_cap_exceeded,
};

/// A paired peer fixture. The caller owns both peers and must `deinit` them.
pub const Pair = struct {
    p1: Peer,
    p2: Peer,

    pub fn deinit(self: *Pair) void {
        self.p1.deinit();
        self.p2.deinit();
    }
};

/// Drive two peers' frame queues to mutual quiescence.
///
/// Each iteration steps both peers and feeds every outbound frame into the
/// partner. Terminates when both report `StepOutcome.idle` and neither
/// produced traffic that iteration.
pub fn shuttleUntilQuiescent(p1: *Peer, p2: *Peer) !ShuttleOutcome {
    var i: usize = 0;
    while (i < SHUTTLE_ITER_CAP) : (i += 1) {
        const o1 = try p1.step();
        const o2 = try p2.step();
        var any_traffic = false;
        while (p1.takeOutbound()) |frame| {
            try p2.feedOwned(frame);
            any_traffic = true;
        }
        while (p2.takeOutbound()) |frame| {
            try p1.feedOwned(frame);
            any_traffic = true;
        }
        if (!any_traffic and o1 == .idle and o2 == .idle) {
            return .quiescent;
        }
    }
    return .iter_cap_exceeded;
}

/// Construct a paired pair and drive the in-process handshake with stub-zero
/// `session_pubkey` / `acceptable_location_sig` (the no-crypto fixture path).
/// Settles `Offer.native()` — typically `next` / `"pancake-next"` over Cap'n
/// Proto. V1.0-floor (`v1_0` / Syrup) fixtures use `pairedV1_0Syrup` instead. Both peers reach
/// `open` with handshake bookkeeping populated; the handshake-artifact events
/// are drained so the caller sees empty event queues.
pub fn paired(allocator: std.mem.Allocator) !Pair {
    return pairedWithOffers(allocator, engine.negotiation.Offer.native(model.FeatureSet.full()), engine.negotiation.Offer.native(model.FeatureSet.full()));
}

/// Construct a paired pair from an already-negotiated handshake outcome.
/// Both peers are built with the *same* negotiated CapTP version, codec, and
/// feature set. Callers that start from two `Offer`s run `negotiation.negotiate`
/// first (and map a null result to `Error.NoSharedCodec` /
/// `NoSharedCaptpVersion`). The no-crypto stub-key handshake path otherwise
/// matches `paired`.
pub fn pairedNegotiated(
    allocator: std.mem.Allocator,
    negotiated: engine.negotiation.Negotiated,
) !Pair {
    return pairedWithCaptpVersionCodecAndFeatures(allocator, negotiated.captp_version, negotiated.codec, negotiated.features);
}

/// Resolve two offers through `negotiation.negotiate` and pair on the result.
fn pairedWithOffers(
    allocator: std.mem.Allocator,
    local: engine.negotiation.Offer,
    remote: engine.negotiation.Offer,
) !Pair {
    const negotiated = engine.negotiation.negotiate(local, remote) orelse {
        if (offersShareCaptpVersion(local, remote)) return Error.NoSharedCodec;
        return Error.NoSharedCaptpVersion;
    };
    return pairedNegotiated(allocator, negotiated);
}

fn offersShareCaptpVersion(local: engine.negotiation.Offer, remote: engine.negotiation.Offer) bool {
    for (local.captp_versions) |lp| {
        for (remote.captp_versions) |rp| {
            if (lp == rp) return true;
        }
    }
    return false;
}

/// As `paired`, but both peers run `codec_id` under `v1_0` (full feature
/// set). Cross-codec V1.0 parity uses this so resolver-callback
/// translation stays on; native Cap'n Proto without V1.0 translation goes
/// through `paired` / `pairedWithOffers`.
pub fn pairedWithCodec(allocator: std.mem.Allocator, codec_id: model.CodecId) !Pair {
    return pairedWithCaptpVersionCodecAndFeatures(allocator, .v1_0, codec_id, model.FeatureSet.full());
}

/// V1.0-floor pairing: `Offer.v1_0Syrup()` yields authenticated `v1_0` / `"1.0"`
/// over Syrup (full feature set). Use this for fixtures and examples that must
/// match live Goblins wire shape; `paired` is the pancake-forward CapNP path.
pub fn pairedV1_0Syrup(allocator: std.mem.Allocator) !Pair {
    return pairedWithOffers(allocator, engine.negotiation.Offer.v1_0Syrup(model.FeatureSet.full()), engine.negotiation.Offer.v1_0Syrup(model.FeatureSet.full()));
}

/// Shared body for stub-key pairing on an already-chosen CapTP version, codec,
/// and feature set. Handshake and subsequent traffic ride `codec_id` through
/// the codec-dispatch boundary on `session.codec`.
fn pairedWithCaptpVersionCodecAndFeatures(
    allocator: std.mem.Allocator,
    captp_version: model.CaptpVersion,
    codec_id: model.CodecId,
    features: model.FeatureSet,
) !Pair {
    return pairedWithLimitsInternal(allocator, captp_version, codec_id, features, .{});
}

/// A pair whose sessions carry the given resource bounds.
///
/// The shipped defaults allow a million imports and a megabyte frame, which no
/// short test can approach. A test that wants to prove a bound holds needs one
/// it can actually reach, so it says which bounds it wants rather than reaching
/// into `session_state` after the fact.
pub fn pairedWithLimits(
    allocator: std.mem.Allocator,
    codec_id: model.CodecId,
    limits: session.SessionLimits,
) !Pair {
    return pairedWithLimitsInternal(allocator, .v1_0, codec_id, model.FeatureSet.full(), limits);
}

fn pairedWithLimitsInternal(
    allocator: std.mem.Allocator,
    captp_version: model.CaptpVersion,
    codec_id: model.CodecId,
    features: model.FeatureSet,
    limits: session.SessionLimits,
) !Pair {
    // The stub-key handshake below signs nothing (zero key + zero sig), so
    // partner-signature verification cannot apply here, keyed tests construct
    // verifying peers and call `sendKeyedStartSession`.
    var p1 = Peer.initNegotiatingWith(allocator, .{
        .captp_version = captp_version,
        .codec = codec_id,
        .features = features,
        .limits = limits,
        .verify_partner_handshake = false,
    });
    errdefer p1.deinit();
    var p2 = Peer.initNegotiatingWith(allocator, .{
        .captp_version = captp_version,
        .codec = codec_id,
        .features = features,
        .limits = limits,
        .verify_partner_handshake = false,
    });
    errdefer p2.deinit();

    const zero_pubkey = @as([crypto.PEER_KEY_BYTES]u8, @splat(0));
    const zero_sig = @as([crypto.SIGNATURE_BYTES]u8, @splat(0));

    try sendStartSession(&p1, defaultLocator("p1"), &zero_pubkey, &zero_sig);
    try sendStartSession(&p2, defaultLocator("p2"), &zero_pubkey, &zero_sig);

    if (try shuttleUntilQuiescent(&p1, &p2) != .quiescent) {
        return Error.HandshakeDidNotQuiesce;
    }

    drainEvents(&p1);
    drainEvents(&p2);

    return .{ .p1 = p1, .p2 = p2 };
}

/// Construct a paired pair and drive the handshake with real Ed25519 material
/// derived from the two caller-supplied seeds. Each side signs the
/// canonical `<my-location $acceptable-location>` bytes (ADR-0006). As each
/// peer's inbound `op:start-session` event is drained, the partner signature it
/// carries is verified against the *decoded* frame view (zero-copy), so what
/// gets checked is the real round-trip from encoding through the wire to
/// decoding, with no session storage. A verification failure returns
/// `Error.InvalidStartSessionSignature`.
pub fn pairedWithKeys(
    allocator: std.mem.Allocator,
    p1_seed: [crypto.SEED_BYTES]u8,
    p2_seed: [crypto.SEED_BYTES]u8,
) !Pair {
    // Keyed handshake is the authenticated `"1.0"` interop path (ADR-0006,
    // the one live Goblins interop rides): `v1_0` + Syrup. Native CapNP
    // keyed pairs go through `pairedWithOffers`
    // + `sendKeyedStartSession`.
    const negotiated = engine.negotiation.negotiate(
        engine.negotiation.Offer.v1_0Syrup(model.FeatureSet.full()),
        engine.negotiation.Offer.v1_0Syrup(model.FeatureSet.full()),
    ) orelse return Error.NoSharedCodec;
    var p1 = Peer.initNegotiatingWith(allocator, .{
        .captp_version = negotiated.captp_version,
        .codec = negotiated.codec,
        .features = negotiated.features,
    });
    errdefer p1.deinit();
    var p2 = Peer.initNegotiatingWith(allocator, .{
        .captp_version = negotiated.captp_version,
        .codec = negotiated.codec,
        .features = negotiated.features,
    });
    errdefer p2.deinit();

    const p1_secret = crypto.SecretKey.fromSeed(p1_seed);
    const p2_secret = crypto.SecretKey.fromSeed(p2_seed);
    const p1_pub = p1_secret.publicKey();
    const p2_pub = p2_secret.publicKey();

    const p1_loc = defaultLocator("p1");
    const p2_loc = defaultLocator("p2");

    var p1_hints: Peer.HelloHints = .{};
    defer p1_hints.deinit(allocator);
    const p1_advertised = try p1.advertisedLocator(p1_loc, &p1_hints);
    const p1_signed = try codec.signed.locationBytes(allocator, p1_advertised);
    defer allocator.free(p1_signed);
    var p2_hints: Peer.HelloHints = .{};
    defer p2_hints.deinit(allocator);
    const p2_advertised = try p2.advertisedLocator(p2_loc, &p2_hints);
    const p2_signed = try codec.signed.locationBytes(allocator, p2_advertised);
    defer allocator.free(p2_signed);

    const p1_sig = crypto.sign(&p1_secret, p1_signed);
    const p2_sig = crypto.sign(&p2_secret, p2_signed);

    try queueStartSession(&p1, p1_advertised, p1_pub.asBytes(), p1_sig.asBytes());
    try queueStartSession(&p2, p2_advertised, p2_pub.asBytes(), p2_sig.asBytes());

    if (try shuttleUntilQuiescent(&p1, &p2) != .quiescent) {
        return Error.HandshakeDidNotQuiesce;
    }

    try verifyAndDrainEvents(allocator, &p1);
    try verifyAndDrainEvents(allocator, &p2);

    return .{ .p1 = p1, .p2 = p2 };
}

fn sendStartSession(
    peer: *Peer,
    locator: model.PeerLocator,
    pubkey: []const u8,
    sig: []const u8,
) !void {
    var hint_storage: Peer.HelloHints = .{};
    defer hint_storage.deinit(peer.allocator);
    const advertised = try peer.advertisedLocator(locator, &hint_storage);
    return queueStartSession(peer, advertised, pubkey, sig);
}

fn queueStartSession(
    peer: *Peer,
    advertised: model.PeerLocator,
    pubkey: []const u8,
    sig: []const u8,
) !void {
    try peer.sendCopying(.{
        .start_session = .{
            // The baseline, like every hello: the preference rides the hints
            // `advertisedLocator` just stamped.
            .captp_version = model.Preference.baseline.captp_version,
            .session_pubkey = .{ .bytes = pubkey },
            .acceptable_location = advertised,
            .acceptable_location_sig = .{ .bytes = sig },
        },
    });
}

/// Drain `peer`'s events, verifying the partner signature carried by the inbound
/// `op:start-session` event against its decoded view. The view borrows the
/// event's frame, and the verification is the engine's one start-session body
/// (`engine.verifyPartnerStartSession`), so the in-process keyed pairing checks
/// exactly what a verifying peer checks, including the verbatim-capture
/// `acceptable_location_raw` signing input when the codec preserves it.
fn verifyAndDrainEvents(allocator: std.mem.Allocator, peer: *Peer) !void {
    var saw_start_session = false;
    while (peer.pollEvent()) |event| {
        var e = event;
        defer e.deinit();
        const view = try e.view();
        switch (view) {
            .start_session => |ss| {
                engine.verifyPartnerStartSession(allocator, ss) catch |err| switch (err) {
                    error.InvalidStartSessionSignature => return Error.InvalidStartSessionSignature,
                    else => |other| return other,
                };
                saw_start_session = true;
            },
            else => {},
        }
    }
    if (!saw_start_session) return Error.MissingStartSessionEvent;
}

fn defaultLocator(designator: []const u8) model.PeerLocator {
    return .{
        .transport = "memory",
        .designator = designator,
        .hints = model.Hints.emptyMap(),
    };
}

fn drainEvents(peer: *Peer) void {
    while (peer.pollEvent()) |event| {
        var e = event;
        e.deinit();
    }
}
