//! Sync in-process paired-peer factories — pair construction and the
//! `op:start-session` handshake without async, netlayer, or adapter wrappers.
//!
//! Two negotiating [`Peer`]s exchange their `op:start-session` halves through a
//! frame shuttle: each peer steps, the outbound frames it produced are fed into
//! the partner's inbound queue, and the loop terminates when both peers reach
//! [`StepOutcome.idle`](runtime.StepOutcome) with no traffic in flight. After
//! [`paired`] / [`pairedWithKeys`] returns, both peers sit in the canonical
//! `open` state (both handshake halves observed) with the bootstrap export
//! installed at id 0.
//!
//! This is the no-I/O primitive the async / netlayer adapters wrap (per the
//! canonical runtime's `factories` module): the adapters delegate the handshake
//! here, then pair the resulting sync peers with their own transport glue.
//! Entropy stays at the caller — [`pairedWithKeys`] takes 32-byte seeds rather
//! than generating keys, keeping the runtime core free of randomness (I/O).

const std = @import("std");

const codec = @import("../codec/mod.zig");
const foundation = @import("../foundation/mod.zig");
const model = @import("../model/mod.zig");
const runtime = @import("mod.zig");

const crypto = foundation.crypto;
const Peer = runtime.Peer;

/// Iteration cap for [`shuttleUntilQuiescent`]. A canonical handshake settles
/// in 2-3 iterations (send → deliver → quiesce); the generous cap surfaces a
/// non-terminating dispatcher bug as [`ShuttleOutcome.iter_cap_exceeded`] well
/// before any test-level wall clock fires.
const SHUTTLE_ITER_CAP: usize = 64;

pub const Error = error{
    /// The frame shuttle hit [`SHUTTLE_ITER_CAP`] without both peers reaching
    /// mutual quiescence — a dispatcher-bug signal.
    HandshakeDidNotQuiesce,
    /// The handshake completed without surfacing the partner's inbound
    /// `op:start-session` event for the keyed path to verify.
    MissingStartSessionEvent,
    /// The partner's `acceptable_location_sig` failed to verify against the
    /// claimed `session_pubkey` over the canonical signed bytes (ADR-0015).
    /// Keyed path only.
    InvalidStartSessionSignature,
    /// The two offers share no codec — negotiation produced no session
    /// ([`runtime.negotiation.negotiate`] returned null).
    NoSharedCodec,
};

/// Outcome of [`shuttleUntilQuiescent`].
pub const ShuttleOutcome = enum {
    /// Both peers reached [`StepOutcome.idle`](runtime.StepOutcome) with no
    /// traffic in flight inside the iteration cap.
    quiescent,
    /// The iteration cap fired before quiescence — escalate (dispatcher bug).
    iter_cap_exceeded,
};

/// A paired peer fixture. The caller owns both peers and must
/// [`deinit`](Pair.deinit) them.
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
/// partner. Terminates when both report [`StepOutcome.idle`](runtime.StepOutcome)
/// and neither produced traffic that iteration.
pub fn shuttleUntilQuiescent(p1: *Peer, p2: *Peer) !ShuttleOutcome {
    var i: usize = 0;
    while (i < SHUTTLE_ITER_CAP) : (i += 1) {
        const o1 = try p1.step();
        const o2 = try p2.step();
        var any_traffic = false;
        while (p1.takeOutbound()) |frame| {
            var f = frame;
            p2.feedInbound(f) catch |err| {
                f.deinit();
                return err;
            };
            any_traffic = true;
        }
        while (p2.takeOutbound()) |frame| {
            var f = frame;
            p1.feedInbound(f) catch |err| {
                f.deinit();
                return err;
            };
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
/// Both peers reach `open` with handshake bookkeeping populated; the
/// handshake-artifact events are drained so the caller sees empty event queues.
pub fn paired(allocator: std.mem.Allocator) !Pair {
    return pairedWithFeatures(allocator, model.FeatureSet.full());
}

/// Construct a paired pair whose sessions carry the handshake-negotiated feature
/// set — the intersection of the two [`Offer`](runtime.negotiation.Offer)s
/// ([`runtime.negotiation.negotiate`]). Returns [`Error.NoSharedCodec`] when the
/// offers share no codec. Both peers are built with the *same* negotiated set,
/// so a capability one side withholds (e.g. `handoff = false`) is exercised by
/// neither. The no-crypto stub-key handshake path otherwise matches [`paired`].
pub fn pairedWithOffers(
    allocator: std.mem.Allocator,
    local: runtime.negotiation.Offer,
    remote: runtime.negotiation.Offer,
) !Pair {
    const negotiated = runtime.negotiation.negotiate(local, remote) orelse
        return Error.NoSharedCodec;
    return pairedWithCodecAndFeatures(allocator, negotiated.chosen, negotiated.features);
}

/// As [`paired`], but both peers run `codec_id` (full feature set). The whole
/// handshake and all subsequent traffic ride that codec through the
/// codec-dispatch seam on `session.codec` — the entry point a cross-codec
/// conformance parity run uses to drive one scenario over each codec and assert
/// the semantic traces match (Invariant 8's two-codec requirement).
pub fn pairedWithCodec(allocator: std.mem.Allocator, codec_id: model.CodecId) !Pair {
    return pairedWithCodecAndFeatures(allocator, codec_id, model.FeatureSet.full());
}

/// Shared body of [`paired`] / [`pairedWithOffers`]: build two negotiating peers
/// carrying `features`, drive the stub-key in-process handshake to quiescence,
/// and drain the handshake-artifact events. Defaults to the Syrup codec.
fn pairedWithFeatures(allocator: std.mem.Allocator, features: model.FeatureSet) !Pair {
    return pairedWithCodecAndFeatures(allocator, .syrup, features);
}

/// As [`pairedWithFeatures`], building both peers on the negotiated
/// [`model.CodecId`] (Invariant 4). The whole handshake and all subsequent
/// traffic ride that codec, since the peers' send/recv route through the
/// codec-dispatch seam on `session.codec`.
fn pairedWithCodecAndFeatures(
    allocator: std.mem.Allocator,
    codec_id: model.CodecId,
    features: model.FeatureSet,
) !Pair {
    var p1 = Peer.initNegotiatingWithCodecAndFeatures(allocator, codec_id, features);
    errdefer p1.deinit();
    var p2 = Peer.initNegotiatingWithCodecAndFeatures(allocator, codec_id, features);
    errdefer p2.deinit();

    const zero_pubkey = [_]u8{0} ** crypto.PEER_KEY_BYTES;
    const zero_sig = [_]u8{0} ** crypto.SIGNATURE_BYTES;

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
/// derived from the two caller-supplied seeds (P1 crypto). Each side signs the
/// canonical `<my-location $acceptable-location>` bytes (ADR-0015). As each
/// peer's inbound `op:start-session` event is drained, the partner signature it
/// carries is verified — against the *decoded* frame view (zero-copy), so the
/// real encode → wire → decode round-trip is what gets checked, with no session
/// storage. A verification failure returns [`Error.InvalidStartSessionSignature`].
pub fn pairedWithKeys(
    allocator: std.mem.Allocator,
    p1_seed: [crypto.SEED_BYTES]u8,
    p2_seed: [crypto.SEED_BYTES]u8,
) !Pair {
    var p1 = Peer.initNegotiating(allocator);
    errdefer p1.deinit();
    var p2 = Peer.initNegotiating(allocator);
    errdefer p2.deinit();

    const p1_secret = try crypto.SecretKey.fromSeed(p1_seed);
    const p2_secret = try crypto.SecretKey.fromSeed(p2_seed);
    const p1_pub = p1_secret.publicKey();
    const p2_pub = p2_secret.publicKey();

    const p1_loc = defaultLocator("p1");
    const p2_loc = defaultLocator("p2");

    const p1_signed = try codec.syrup.canonicalLocationSignedBytes(allocator, p1_loc);
    defer allocator.free(p1_signed);
    const p2_signed = try codec.syrup.canonicalLocationSignedBytes(allocator, p2_loc);
    defer allocator.free(p2_signed);

    const p1_sig = crypto.sign(&p1_secret, p1_signed);
    const p2_sig = crypto.sign(&p2_secret, p2_signed);

    try sendStartSession(&p1, p1_loc, p1_pub.asBytes(), p1_sig.asBytes());
    try sendStartSession(&p2, p2_loc, p2_pub.asBytes(), p2_sig.asBytes());

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
    try peer.sendCopying(.{
        .start_session = .{
            .captp_version = peer.session_state.wire_profile.captp_version,
            .session_pubkey = .{ .bytes = pubkey },
            .acceptable_location = locator,
            .acceptable_location_sig = .{ .bytes = sig },
        },
    });
}

/// Drain `peer`'s events, verifying the partner signature carried by the inbound
/// `op:start-session` event against its decoded view. The view borrows the
/// event's frame; only the canonical signed bytes are materialized (to verify
/// against), and the fixed-width key/signature boundary is the one in
/// [`crypto.PeerKey.fromSlice`] / [`crypto.Signature.fromParts`].
fn verifyAndDrainEvents(allocator: std.mem.Allocator, peer: *Peer) !void {
    var saw_start_session = false;
    while (peer.pollEvent()) |event| {
        var e = event;
        defer e.deinit();
        const view = try e.view();
        switch (view) {
            .start_session => |ss| {
                const pubkey = crypto.PeerKey.fromSlice(ss.session_pubkey) catch
                    return Error.InvalidStartSessionSignature;
                const sig = sig: {
                    switch (ss.acceptable_location_sig) {
                        .halves => |h| break :sig crypto.Signature.fromParts(h.r, h.s) catch
                            return Error.InvalidStartSessionSignature,
                        .raw => |raw| {
                            if (raw.len != crypto.SIGNATURE_BYTES) return Error.InvalidStartSessionSignature;
                            break :sig crypto.Signature.fromBytes(raw[0..crypto.SIGNATURE_BYTES].*);
                        },
                    }
                };
                const signed = try codec.syrup.canonicalLocationSignedBytes(allocator, .{
                    .transport = ss.acceptable_location.transport,
                    .designator = ss.acceptable_location.designator,
                    .hints = ss.acceptable_location.hints,
                });
                defer allocator.free(signed);
                crypto.verify(pubkey, signed, sig) catch
                    return Error.InvalidStartSessionSignature;
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
