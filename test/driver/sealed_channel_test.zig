//! ADR-0041's sealed byte channel on the byte-fed host core, with no socket
//! anywhere: sealed sessions are wired by moving the wire bytes
//! `HostSession.takeOutbound` drains into the partner's `Host.feedBytes`
//! verbatim, so the tests stand exactly where a byte-owning embedder stands.
//! The scenarios are the record's own evidence items at this tier: a sealed
//! pair reports `authenticated_transport` where the cleartext keyed pair
//! reports `unauthenticated`, a recorded handshake replayed onto a fresh
//! responder is refused, a responder holding a different key than the one
//! dialed is refused, and the wire between the peers carries no plaintext
//! CapTP.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../support/core_host.zig");
const host_pair = @import("../support/host_pair.zig");
const promise_capture = @import("../support/capture.zig");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const driver = glowcap.driver;
const crypto = glowcap.foundation.crypto;
const noise = glowcap.foundation.noise;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const sealed = glowcap.foundation.sealed;
const noise_tcp = model.transport.noise_tcp;

const frame_cap = 4096;

const sealed_pair = @import("../support/sealed_pair.zig");
const keyedDesignator = sealed_pair.keyedDesignator;
const noiseLocator = sealed_pair.noiseLocator;
const moveSealedWire = sealed_pair.moveSealedWire;
const drainSealedActions = sealed_pair.drainSealedActions;
const SealedPair = sealed_pair.SealedPair;
const pumpSealedPair = sealed_pair.pumpSealedPair;
const openSealedPair = sealed_pair.openSealedPair;

fn sealedHost(allocator: std.mem.Allocator, durable_seed: [crypto.seed_bytes]u8, root_byte: u8) Host {
    return sealed_pair.sealedHost(allocator, durable_seed, root_byte, Host.Options.withFrameCap(frame_cap));
}

const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        _ = self;
        _ = turn;
        if (!msg.is("greet")) return error.NoSuchMethod;
        return .{ .string = "sealed hello" };
    }
};

test "sealed channel: a noise-tcp pair opens over fed bytes and both legs report the channel proof" {
    const allocator = std.testing.allocator;
    const seed_a = @as([32]u8, @splat(0x61));
    const seed_b = @as([32]u8, @splat(0x62));
    var a = sealedHost(allocator, seed_a, 0xa1);
    defer a.deinit();
    var b = sealedHost(allocator, seed_b, 0xb1);
    defer b.deinit();

    var log_ab: std.ArrayList(u8) = .empty;
    defer log_ab.deinit(allocator);
    var log_ba: std.ArrayList(u8) = .empty;
    defer log_ba.deinit(allocator);
    const pair = try openSealedPair(allocator, &a, seed_a, &b, seed_b, &log_ab, &log_ba);
    try std.testing.expect(pair.a.sessionOpen());
    try std.testing.expect(pair.b.sessionOpen());

    // The realizer is the channel itself: both legs report the proof with no
    // embedder testimony anywhere in this test.
    const dialer_view = try a.partnerIdentity(pair.a);
    try std.testing.expectEqual(driver.core.DurableProvenance.authenticated_transport, dialer_view.provenance);
    const acceptor_view = try b.partnerIdentity(pair.b);
    try std.testing.expectEqual(driver.core.DurableProvenance.authenticated_transport, acceptor_view.provenance);

    // CapTP itself runs through the records: a publish on one end settles a
    // fetch on the other.
    _ = try pair.b.served.publish(&b.vat, "greeter", Greeter, .{});
    var fetched = promise_capture.CapturedRef{};
    try a.vowOn(try a.fetch(pair.a, "greeter"), .{ .ctx = &fetched, .func = promise_capture.CapturedRef.record });
    try pumpSealedPair(allocator, pair, &log_ab, &log_ba);
    _ = try fetched.require();

    // What crossed the wire: message one leads the dialing side, and neither
    // direction ever carries the hello's plaintext. Sixteen ciphertext bytes
    // matching a chosen ASCII string is beyond chance, so a hit here means
    // plaintext actually leaked.
    try std.testing.expect(log_ab.items.len >= sealed.msg1_wire_bytes);
    try std.testing.expect(std.mem.indexOf(u8, log_ab.items, "start-session") == null);
    try std.testing.expect(std.mem.indexOf(u8, log_ba.items, "start-session") == null);
    try std.testing.expect(std.mem.indexOf(u8, log_ab.items, "greeter") == null);
    try std.testing.expect(std.mem.indexOf(u8, log_ba.items, "sealed hello") == null);
}

test "sealed host consumes a coalesced read larger than one Noise record" {
    const allocator = std.testing.allocator;
    const seed_a = @as([32]u8, @splat(0x41));
    const seed_b = @as([32]u8, @splat(0x42));
    var options_a = Host.Options.withFrameCap(frame_cap);
    options_a.limits.max_frame_bytes = 100_000;
    var a = test_host.initWithRoot(allocator, seed_a, @as([32]u8, @splat(0xa2)), options_a);
    defer a.deinit();
    var options_b = Host.Options.withFrameCap(frame_cap);
    options_b.limits.max_frame_bytes = 100_000;
    var b = test_host.initWithRoot(allocator, seed_b, @as([32]u8, @splat(0xb2)), options_b);
    defer b.deinit();
    const pair = try openSealedPair(allocator, &a, seed_a, &b, seed_b, null, null);

    // A valid but incomplete outer frame keeps codec semantics out of this
    // ingestion test. Its plaintext crosses two Noise records, and both records
    // arrive in one borrowed Host.feedBytes call.
    const declared_len = 90_000;
    const body_len = noise.max_record_plaintext_bytes + 137;
    var plaintext: std.ArrayList(u8) = .empty;
    defer plaintext.deinit(allocator);
    var prefix_buf: [32]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "{d}:", .{declared_len});
    try plaintext.appendSlice(allocator, prefix);
    try plaintext.appendNTimes(allocator, 0x61, body_len);

    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(allocator);
    try pair.a.sealed.?.sealBytes(allocator, &wire, plaintext.items);
    try std.testing.expect(wire.items.len > noise.record_header_bytes + noise.max_record_bytes);

    try b.feedBytes(pair.b, wire.items);
    try std.testing.expectEqual(plaintext.items.len, pair.b.feed_tail.len);
    try std.testing.expectEqual(@as(usize, 0), pair.b.sealed.?.staged.len);
}

test "sealed channel: the same pair over keyed-tcp reports unauthenticated" {
    // Evidence item two's second row: the identical topology minus the
    // channel. The keyed dial demands the same durable key, yet nothing on a status-allow: pending state or quoted runtime label
    // cleartext socket proves it, so the honest report stays unauthenticated.
    const allocator = std.testing.allocator;
    const seed_c = @as([32]u8, @splat(0x63));
    const seed_d = @as([32]u8, @splat(0x64));
    var c = test_host.init(allocator, seed_c, Host.Options.withFrameCap(frame_cap));
    defer c.deinit();
    var d = test_host.init(allocator, seed_d, Host.Options.withFrameCap(frame_cap));
    defer d.deinit();

    const acceptor_designator = keyedDesignator(seed_d);
    const accepted = try host_pair.publishAndOpenAccepted(&d, "keyed-tcp", &acceptor_designator, "127.0.0.1:7501");
    try c.ensureAdvertisedLocator("keyed-tcp");
    const dialed = try c.openDialedLocator(.{
        .transport = "keyed-tcp",
        .designator = &acceptor_designator,
        .hints = model.Hints.emptyFalse(),
    });
    const pair = host_pair.Pair{ .ah = &c, .a = dialed, .bh = &d, .b = accepted };
    try host_pair.pumpToQuiescence(&.{pair});
    try std.testing.expect(dialed.sessionOpen());

    const dialer_view = try c.partnerIdentity(dialed);
    try std.testing.expectEqual(driver.core.DurableProvenance.unauthenticated, dialer_view.provenance);
    const acceptor_view = try d.partnerIdentity(accepted);
    try std.testing.expectEqual(driver.core.DurableProvenance.unauthenticated, acceptor_view.provenance);
}

test "sealed channel: a recorded handshake replayed onto a fresh responder is refused" {
    const allocator = std.testing.allocator;
    const seed_a = @as([32]u8, @splat(0x65));
    const seed_b = @as([32]u8, @splat(0x66));

    // Record the dialing side's wire, frame by frame, from a completed run.
    var recorded: std.ArrayList([]u8) = .empty;
    defer {
        for (recorded.items) |bytes| allocator.free(bytes);
        recorded.deinit(allocator);
    }
    {
        var a = sealedHost(allocator, seed_a, 0xa3);
        defer a.deinit();
        var b = sealedHost(allocator, seed_b, 0xb3);
        defer b.deinit();
        const acceptor_designator = keyedDesignator(seed_b);
        try b.setAdvertisedLocator(noiseLocator(&acceptor_designator));
        const accepted = try b.openAcceptedAdvertised(noise_tcp);
        try a.setAdvertisedLocator(noiseLocator(&keyedDesignator(seed_a)));
        const dialed = try a.openDialedLocator(noiseLocator(&acceptor_designator));
        var rounds: usize = 0;
        while (rounds < 16) : (rounds += 1) {
            var moved = false;
            while (try dialed.takeOutbound()) |frame_value| {
                var frame = frame_value;
                defer frame.deinit();
                try recorded.append(allocator, try allocator.dupe(u8, frame.bytes()));
                try b.feedBytes(accepted, frame.bytes());
                moved = true;
            }
            if (try moveSealedWire(allocator, accepted, &a, dialed, null)) moved = true;
            if (try drainSealedActions(&.{ &a, &b }, null)) moved = true;
            if (!moved) break;
        }
        try std.testing.expect(dialed.sessionOpen());
        try std.testing.expect(accepted.sessionOpen());
        // The recording holds at least message one, message three, and the
        // sealed hello behind it.
        try std.testing.expect(recorded.items.len >= 3);
    }

    // Replay against a fresh responder holding the same durable identity.
    // Message one still verifies. It is encrypted to the durable static,
    // but the fresh responder's ephemeral makes every later key differ, so
    // message three cannot.
    var b2 = sealedHost(allocator, seed_b, 0xb4);
    defer b2.deinit();
    const acceptor_designator = keyedDesignator(seed_b);
    try b2.setAdvertisedLocator(noiseLocator(&acceptor_designator));
    const accepted = try b2.openAcceptedAdvertised(noise_tcp);
    try b2.feedBytes(accepted, recorded.items[0]);
    // The responder answered with its own message two; the recorder has no
    // matching state, so the answer goes nowhere.
    var answer = (try accepted.takeOutbound()) orelse return error.MissingMessageTwo;
    answer.deinit();
    try std.testing.expectError(error.DecryptFailed, b2.feedBytes(accepted, recorded.items[1]));
    try std.testing.expect(!accepted.sessionOpen());
    // The session is condemned without a CapTP session ever existing, and
    // the embedder is told to close the transport.
    try std.testing.expectError(
        driver.core.HostError.SessionCondemned,
        b2.feedBytes(accepted, recorded.items[2]),
    );
    var closes: usize = 0;
    _ = try drainSealedActions(&.{&b2}, &closes);
    try std.testing.expectEqual(@as(usize, 1), closes);
    try b2.releaseSession(accepted);
}

test "sealed channel: a responder that holds a different key than the one dialed is refused" {
    // Evidence item four: the party in the middle answers with its own
    // static. Message one is encrypted to the key the dialer named, so the
    // substitute cannot even read it, and no session it could read exists.
    const allocator = std.testing.allocator;
    const seed_a = @as([32]u8, @splat(0x67));
    const seed_b = @as([32]u8, @splat(0x68));
    const seed_m = @as([32]u8, @splat(0x69));
    var a = sealedHost(allocator, seed_a, 0xa4);
    defer a.deinit();
    var mitm = sealedHost(allocator, seed_m, 0xc4);
    defer mitm.deinit();

    const mitm_designator = keyedDesignator(seed_m);
    try mitm.setAdvertisedLocator(noiseLocator(&mitm_designator));
    const accepted = try mitm.openAcceptedAdvertised(noise_tcp);
    try a.setAdvertisedLocator(noiseLocator(&keyedDesignator(seed_a)));
    // The dial names B's key; the wire lands at M.
    const dialed = try a.openDialedLocator(noiseLocator(&keyedDesignator(seed_b)));

    var msg1 = (try dialed.takeOutbound()) orelse return error.MissingMessageOne;
    defer msg1.deinit();
    try std.testing.expectError(error.DecryptFailed, mitm.feedBytes(accepted, msg1.bytes()));
    try std.testing.expect(!accepted.sessionOpen());
    try std.testing.expect(!dialed.sessionOpen());
    var closes: usize = 0;
    _ = try drainSealedActions(&.{ &a, &mitm }, &closes);
    try std.testing.expectEqual(@as(usize, 1), closes);
    try mitm.releaseSession(accepted);
    try a.releaseSession(dialed);
}

test "sealed channel: an Ed25519 sign-bit alias cannot claim the initiator static" {
    const allocator = std.testing.allocator;
    const initiator_identity = crypto.SecretKey.fromSeed(@as([32]u8, @splat(0x6d)));
    const responder_identity = crypto.SecretKey.fromSeed(@as([32]u8, @splat(0x6e)));
    const initiator_static = crypto.x25519FromSecretKey(&initiator_identity).?;
    const responder_static = crypto.x25519FromSecretKey(&responder_identity).?;
    const initiator_ephemeral = crypto.X25519KeyMaterial.fromSecret(@as([32]u8, @splat(0x6f)));

    const responder_designator = responder_identity.publicKey().toDesignator();
    var prologue_buf: [96]u8 = undefined;
    @memcpy(prologue_buf[0..noise_tcp.len], noise_tcp);
    prologue_buf[noise_tcp.len] = 0;
    @memcpy(
        prologue_buf[noise_tcp.len + 1 ..][0..responder_designator.len],
        &responder_designator,
    );
    const prologue = prologue_buf[0 .. noise_tcp.len + 1 + responder_designator.len];

    var other_hs = noise.HandshakeState.initInitiator(
        &initiator_static,
        responder_static.public,
        &initiator_ephemeral,
        prologue,
    );
    defer other_hs.deinit();
    var responder = try glowcap.foundation.sealed.SealedChannel.initResponder(
        &responder_identity,
        @as([32]u8, @splat(0x70)),
        noise_tcp,
    );
    defer responder.deinit(allocator);

    var wire: [glowcap.foundation.sealed.msg3_wire_bytes]u8 = undefined;
    var payload: [crypto.peer_key_bytes + crypto.signature_bytes]u8 = undefined;
    const msg1 = try other_hs.writeMessage(&.{}, &wire);
    const first = try responder.ingest(allocator, msg1);
    try std.testing.expectEqual(msg1.len, first.consumed);
    try std.testing.expectEqual(
        glowcap.foundation.sealed.SealedChannel.Event.handshake,
        first.event,
    );
    var msg2_frame = (try responder.takeWire(allocator)) orelse return error.MissingMessageTwo;
    defer msg2_frame.deinit();
    _ = try other_hs.readMessage(msg2_frame.bytes(), &payload);

    const actual = initiator_identity.publicKey();
    var alias = actual;
    alias.bytes[crypto.peer_key_bytes - 1] ^= 0x80;
    try std.testing.expect(!actual.eql(alias));
    try std.testing.expectEqualSlices(
        u8,
        &crypto.x25519FromPeerKey(actual).?,
        &crypto.x25519FromPeerKey(alias).?,
    );
    payload = @splat(0);
    payload[0..crypto.peer_key_bytes].* = alias.bytes;
    const msg3 = try other_hs.writeMessage(&payload, &wire);
    try std.testing.expectError(error.IdentityMismatch, responder.ingest(allocator, msg3));
    try std.testing.expect(!responder.isOpen());
}

test "sealed channel: a whole plaintext frame cannot bypass the channel" {
    const allocator = std.testing.allocator;
    const seed_a = @as([32]u8, @splat(0x6a));
    var a = sealedHost(allocator, seed_a, 0xa5);
    defer a.deinit();
    try a.setAdvertisedLocator(noiseLocator(&keyedDesignator(seed_a)));
    const accepted = try a.openAcceptedAdvertised(noise_tcp);
    const bytes = "not a sealed byte stream";
    try std.testing.expectError(
        driver.core.HostError.SealedSessionBytesOnly,
        a.feed(accepted, .{ .bytes = bytes, .shape = .byte }),
    );
    try a.releaseSession(accepted);
}

test "sealed channel: a frame larger than one record spans records intact" {
    // The channel alone, no host: a frame past one record's plaintext
    // capacity crosses as several records whose reassembled plaintext is the
    // outer-framed original.
    const allocator = std.testing.allocator;
    const secret_a = crypto.SecretKey.fromSeed(@as([32]u8, @splat(0x71)));
    const secret_b = crypto.SecretKey.fromSeed(@as([32]u8, @splat(0x72)));
    var initiator = try sealed.SealedChannel.initInitiator(
        &secret_a,
        secret_b.publicKey(),
        @as([32]u8, @splat(0x73)),
        noise_tcp,
    );
    defer initiator.deinit(allocator);
    var responder = try sealed.SealedChannel.initResponder(
        &secret_b,
        @as([32]u8, @splat(0x74)),
        noise_tcp,
    );
    defer responder.deinit(allocator);

    // Drive the handshake by carrying each side's pending wire across.
    var initiator_done = false;
    var responder_done = false;
    var rounds: usize = 0;
    while ((!initiator_done or !responder_done) and rounds < 8) : (rounds += 1) {
        if (try initiator.takeWire(allocator)) |frame_value| {
            var frame = frame_value;
            defer frame.deinit();
            const step = try responder.ingest(allocator, frame.bytes());
            try std.testing.expectEqual(frame.bytes().len, step.consumed);
            switch (step.event) {
                .need_input => return error.IncompleteHandshakeMessage,
                .handshake => {},
                .completed => |remote| {
                    try std.testing.expect(remote.eql(secret_a.publicKey()));
                    responder_done = true;
                },
                .plaintext => return error.UnexpectedPlaintext,
            }
        }
        if (try responder.takeWire(allocator)) |frame_value| {
            var frame = frame_value;
            defer frame.deinit();
            const step = try initiator.ingest(allocator, frame.bytes());
            try std.testing.expectEqual(frame.bytes().len, step.consumed);
            switch (step.event) {
                .need_input => return error.IncompleteHandshakeMessage,
                .handshake => {},
                .completed => |remote| {
                    try std.testing.expect(remote.eql(secret_b.publicKey()));
                    initiator_done = true;
                },
                .plaintext => return error.UnexpectedPlaintext,
            }
        }
    }
    try std.testing.expect(initiator_done and responder_done);
    // The initiator's message three is still pending; a real embedder writes
    // it ahead of the first sealed frame.
    if (try initiator.takeWire(allocator)) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        const step = try responder.ingest(allocator, frame.bytes());
        try std.testing.expectEqual(frame.bytes().len, step.consumed);
        switch (step.event) {
            .need_input, .handshake => return error.IncompleteHandshake,
            .completed => |remote| {
                try std.testing.expect(remote.eql(secret_a.publicKey()));
                responder_done = true;
            },
            .plaintext => return error.UnexpectedPlaintext,
        }
    }
    try std.testing.expect(responder.isOpen());
    try std.testing.expect(initiator.isOpen());

    const big_len = noise.max_record_plaintext_bytes + 4321;
    const big = try allocator.alloc(u8, big_len);
    defer allocator.free(big);
    for (big, 0..) |*byte, i| byte.* = @truncate(i *% 31);

    var wire = try initiator.sealFrame(allocator, big);
    defer wire.deinit();
    var reassembled: std.ArrayList(u8) = .empty;
    defer reassembled.deinit(allocator);
    var wire_at: usize = 0;
    while (wire_at < wire.bytes().len) {
        const step = try responder.ingest(allocator, wire.bytes()[wire_at..]);
        wire_at += step.consumed;
        switch (step.event) {
            .need_input => return error.IncompleteSealedRecord,
            .handshake => return error.UnexpectedHandshake,
            .completed => return error.UnexpectedCompletion,
            .plaintext => |plain| {
                try reassembled.appendSlice(allocator, plain);
                responder.releasePlaintext();
            },
        }
    }
    const outer = glowcap.foundation.stream_framing.parsePrefix(reassembled.items, big_len);
    try std.testing.expect(outer == .decoded);
    try std.testing.expectEqualSlices(u8, big, outer.decoded.body);
    try std.testing.expectEqual(reassembled.items.len, outer.decoded.consumed);
}

test "sealed channel: a split handshake retains only the consumed prefix" {
    const allocator = std.testing.allocator;
    const identity = crypto.SecretKey.fromSeed(@as([32]u8, @splat(0x75)));
    var channel = try sealed.SealedChannel.initResponder(
        &identity,
        @as([32]u8, @splat(0x76)),
        noise_tcp,
    );
    defer channel.deinit(allocator);

    const partial = [_]u8{0};
    const step = try channel.ingest(allocator, &partial);
    try std.testing.expectEqual(@as(usize, 1), step.consumed);
    try std.testing.expectEqual(glowcap.foundation.sealed.SealedChannel.Event.need_input, step.event);
    // Handshake staging is bounded by the fixed message expected;
    // arbitrary caller chunk sizes are consumed by prefix, not rejected or
    // copied wholesale.
    try std.testing.expectEqual(@as(usize, 1), channel.staged.len);
}

test "sealed channel: allocation failure after a split record header consumes no retry bytes" {
    const allocator = std.testing.allocator;
    const seed_a = @as([32]u8, @splat(0x77));
    const seed_b = @as([32]u8, @splat(0x78));
    var a = sealedHost(allocator, seed_a, 0xa6);
    defer a.deinit();
    var b = sealedHost(allocator, seed_b, 0xb6);
    defer b.deinit();
    const pair = try openSealedPair(allocator, &a, seed_a, &b, seed_b, null, null);

    var plaintext: [4097]u8 = undefined;
    for (&plaintext, 0..) |*byte, i| byte.* = @truncate(i *% 29);
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(allocator);
    try pair.a.sealed.?.sealBytes(allocator, &wire, &plaintext);

    const first = try pair.b.sealed.?.ingest(allocator, wire.items[0..1]);
    try std.testing.expectEqual(@as(usize, 1), first.consumed);
    try std.testing.expectEqual(sealed.SealedChannel.Event.need_input, first.event);
    try std.testing.expectEqual(@as(usize, 1), pair.b.sealed.?.staged.len);

    // The staged-buffer capacity growth succeeds; plaintext-scratch capacity
    // growth fails. The remaining borrowed slice must still be retryable in
    // full.
    var failing = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = 0,
        .resize_fail_index = 1,
    });
    try std.testing.expectError(
        error.OutOfMemory,
        pair.b.sealed.?.ingest(failing.allocator(), wire.items[1..]),
    );
    try std.testing.expectEqual(@as(usize, 1), pair.b.sealed.?.staged.len);

    const retried = try pair.b.sealed.?.ingest(allocator, wire.items[1..]);
    try std.testing.expectEqual(wire.items.len - 1, retried.consumed);
    switch (retried.event) {
        .plaintext => |opened| try std.testing.expectEqualSlices(u8, &plaintext, opened),
        else => return error.ExpectedPlaintext,
    }
    pair.b.sealed.?.releasePlaintext();
}
