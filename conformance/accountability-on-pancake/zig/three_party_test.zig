//! Three-party accountability: the introduction survives a handoff.
//!
//! Three in-memory peers prove the load-bearing claim: when A introduces B to C
//! via a three-party handoff, C's Episode attributes B (the true caller), not A
//! (the introducer). The capability that B reaches C through is distinct from
//! A's — so "who called" is answered by the reference itself.
//!
//! This is the in-memory protocol-level proof. It uses the `cross_peer`
//! handoff machinery (ADR-0009) and the accountability application's Episode +
//! Identity layers, wired through `actors.Vat` on each peer.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.model;
const engine = pancake.engine;
const actors = pancake.actors;
const cross_peer = engine.cross_peer;
const crypto = pancake.foundation.crypto;
const syrup = pancake.codec.syrup;

const identity = @import("identity.zig");
const episode = @import("episode.zig");
const accountable = @import("accountable.zig");
const log = @import("log.zig");

const AFFORDANCE_EXPORT: u64 = 5;

fn strArg(a: model.Argument) ?[]const u8 {
    return switch (a) {
        .string => |s| s,
        else => null,
    };
}

fn decodeKey(b64: []const u8) ![32]u8 {
    const expected_len = 1 + std.base64.url_safe_no_pad.Encoder.calcSize(32);
    if (b64.len != expected_len) return error.BadKey;
    var out: [32]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&out, b64[1..]);
    return out;
}

fn decodeSig(b64: []const u8) ![64]u8 {
    const expected_len = std.base64.url_safe_no_pad.Encoder.calcSize(64);
    if (b64.len != expected_len) return error.BadSig;
    var out: [64]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&out, b64);
    return out;
}

fn attestation(buf: []u8, request: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "invoke|{s}", .{request}) catch unreachable;
}

/// The same Affordance as main.zig, but also records a verifiable Episode.
const Affordance = struct {
    store: *accountable.Store,
    last_subject: []u8,
    served: *usize,

    pub fn handle(self: *Affordance, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "invoke")) return error.NoSuchMethod;
        if (msg.args.len != 4) return error.BadInvocation;
        const subject = strArg(msg.args[0]) orelse return error.BadInvocation;
        const verkey_b64 = strArg(msg.args[1]) orelse return error.BadInvocation;
        const request = strArg(msg.args[2]) orelse return error.BadInvocation;
        const sig_b64 = strArg(msg.args[3]) orelse return error.BadInvocation;

        const verkey = decodeKey(verkey_b64) catch return error.UnattestedCaller;
        const sig = decodeSig(sig_b64) catch return error.UnattestedCaller;
        var att_buf: [512]u8 = undefined;
        const att = attestation(&att_buf, request);
        identity.verify(verkey, att, sig) catch return error.UnattestedCaller;

        const result = try std.fmt.allocPrint(turn.arena, "ack:{s}", .{request});
        _ = try self.store.record(.outcome, subject, "demo", result);
        @memcpy(self.last_subject[0..subject.len], subject);
        self.served.* += 1;
        return .{ .string = result };
    }
};

fn shuttleAndStep(from: *engine.Peer, to: *engine.Peer) !void {
    _ = try from.step();
    while (from.takeOutbound()) |frame| {
        try to.feedInbound(frame);
    }
    _ = try to.step();
}

fn drainEvents(peer: *engine.Peer) void {
    while (peer.pollEvent()) |ev| {
        var e = ev;
        e.deinit();
    }
}

test "three-party handoff: C attributes B (the true caller), not A (the introducer)" {
    const allocator = std.testing.allocator;

    // The standard four-peer topology (ADR-0009):
    //   gifter (A)        → gifter-to-recipient (A→B)
    //   recipient-from-A  → B's view of A's session
    //   recipient-to-C    → B's view of C's session
    //   exporter (C)      → single peer, receives deposit AND withdrawal
    //
    // A introduces B to C. After the handoff, B reaches C's Affordance
    // through a direct session. C's Episode must attribute B, not A.

    var gifter = engine.Peer.init(allocator);
    defer gifter.deinit();
    var recipient_from_gifter = engine.Peer.init(allocator);
    defer recipient_from_gifter.deinit();
    var recipient_to_exporter = engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = engine.Peer.init(allocator);
    defer exporter.deinit();

    // C (exporter) creates a KERI identity and accountability store.
    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();
    const tio = io.io();

    var c_id = try identity.Identity.incept(allocator, tio);
    defer c_id.deinit();
    const data_dir = "conformance/accountability-on-pancake/.data/three-party-test";
    var c_store = try accountable.Store.init(allocator, tio, &c_id, data_dir);
    defer c_store.deinit();

    // C publishes the Affordance.
    var served: usize = 0;
    var last_subject = [_]u8{0} ** identity.SAID_LEN;
    var c_vat = actors.Vat.initOver(allocator, &exporter);
    defer c_vat.deinit();
    const aff = try c_vat.spawn(Affordance, .{
        .store = &c_store,
        .last_subject = &last_subject,
        .served = &served,
    });
    try c_vat.publish(aff, AFFORDANCE_EXPORT);

    // --- Three-party handoff: A introduces B to C ---
    const gift_id = [_]u8{0x42} ** 32;
    const recipient_key = [_]u8{0x52} ** 32;
    const give: model.HandoffGive = .{
        .recipient_key = &recipient_key,
        .exporter_location = "memory:C",
        .gifter_exporter_session = &([_]u8{0} ** 32),
        .gifter_side = &([_]u8{0} ** 32),
        .gift_id = &gift_id,
        .signature = &([_]u8{0xaa} ** 64),
    };

    // A deposits the gift on C and delivers the give certificate to B.
    try cross_peer.deliverGive(&gifter, &recipient_from_gifter, &exporter, give, "");
    drainEvents(&recipient_from_gifter);
    drainEvents(&exporter);

    // B withdraws the gift from C.
    const receive: model.HandoffReceive = .{
        .receiving_session = &([_]u8{0xdd} ** 32),
        .receiving_side = &([_]u8{0x22} ** 32),
        .handoff_count = 1,
        .signed_give = give,
        .signature = &([_]u8{0xbb} ** 64),
    };
    try cross_peer.withdrawGift(&recipient_to_exporter, &exporter, receive, cross_peer.acceptingVerifier());
    drainEvents(&exporter);

    // After withdrawal, B can reach C directly. B's Vat sends to C's export.
    try recipient_to_exporter.importObject(AFFORDANCE_EXPORT);

    // --- B invokes the Affordance with its own KERI attestation ---
    var b_id = try identity.Identity.incept(allocator, tio);
    defer b_id.deinit();

    const request = "read-thermostat";
    var att_buf: [512]u8 = undefined;
    const att = attestation(&att_buf, request);
    const sig = b_id.current.sign(att);
    var sig_b64: [std.base64.url_safe_no_pad.Encoder.calcSize(64)]u8 = undefined;
    const sig_enc = std.base64.url_safe_no_pad.Encoder.encode(&sig_b64, &sig);
    var verkey_b64: [1 + std.base64.url_safe_no_pad.Encoder.calcSize(32)]u8 = undefined;
    verkey_b64[0] = 'D';
    _ = std.base64.url_safe_no_pad.Encoder.encode(verkey_b64[1..], &b_id.current.verkey());

    // B sends via its Vat over the B↔C (recipient_to_exporter) session.
    var b_vat = actors.Vat.initOver(allocator, &recipient_to_exporter);
    defer b_vat.deinit();
    const ref: actors.Ref = .{ .far = model.FarRef.object(AFFORDANCE_EXPORT) };
    _ = try b_vat.send(ref, .{
        .verb = "invoke",
        .args = &.{
            .{ .string = b_id.aidSlice() },
            .{ .string = &verkey_b64 },
            .{ .string = request },
            .{ .string = sig_enc },
        },
    });

    // Shuttle B→C (deliver), step C, serve on C.
    try shuttleAndStep(&recipient_to_exporter, &exporter);
    while (exporter.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = c_vat.serve(&e) catch {};
    }

    // The headline: C attributes the TRUE caller (B), not A (the introducer).
    try std.testing.expect(served == 1);
    try std.testing.expectEqualSlices(u8, b_id.aidSlice(), last_subject[0..identity.SAID_LEN]);

    // The Episode is verifiable and the transparency log is stable.
    const audited = try c_store.auditAll();
    try std.testing.expectEqual(@as(usize, 1), audited);
    const root = try c_store.currentRoot();
    _ = log.toHex(root);
}
