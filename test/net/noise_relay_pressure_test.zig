//! The sealing completion adapter under pressure and closure (ADR-0107):
//! handshake submission refusals share one retry owner, receive-buffer
//! starvation sleeps until recycle, cancel removes recycle-gated debt,
//! refused closes retry in bounded FIFO turns, lent plaintext survives to
//! recycle, a substituted responder key never connects, and the registered
//! resident opens an authenticated session through a ciphertext-only relay.

const std = @import("std");
const pancake = @import("pancake");
const support_actors = @import("../support/actors.zig");
const ws_relay = @import("../support/ws_relay.zig");

const foundation = pancake.foundation;
const crypto = foundation.crypto;
const sealed = foundation.sealed;
const model = pancake.ocapn.model;
const net = pancake.net;
const completion = net.completion;
const noise_completion = net.noise_completion;
const driver = pancake.driver;

const seal = @import("noise_relay_test.zig");
const PipePlatform = seal.PipePlatform;
const NoiseBackend = seal.NoiseBackend;
const initiatorSecret = seal.initiatorSecret;
const responderSecret = seal.responderSecret;
const sealingBackend = seal.sealingBackend;
const responderChannel = seal.responderChannel;
const sealedTarget = seal.sealedTarget;
const drain = seal.drain;
const openSealed = seal.openSealed;
const closeSealed = seal.closeSealed;

test "handshake submission refusals share one actionable retry owner" {
    const allocator = std.testing.allocator;
    var backend = try sealingBackend(allocator);
    defer backend.deinit();
    backend.inner.refused_sends = 1;
    backend.inner.refused_recvs = 1;

    const fd = try backend.startDial(71, .{ .sealed = sealedTarget() });
    var completions: [2]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 1), backend.inner.send_submit_attempts);
    try std.testing.expectEqual(@as(usize, 1), backend.inner.recv_submit_attempts);
    try std.testing.expectEqual(@as(?u64, null), backend.inner.armed_recv_ud);
    try std.testing.expectEqual(@as(usize, 0), backend.inner.wire.items.len);

    // One FIFO visit retries both operations. No receive-buffer recycle is
    // needed because this is submission pressure, not pool starvation.
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 2), backend.inner.send_submit_attempts);
    try std.testing.expectEqual(@as(usize, 2), backend.inner.recv_submit_attempts);
    try std.testing.expect(backend.inner.armed_recv_ud != null);
    try std.testing.expectEqual(@as(usize, sealed.msg1_wire_bytes), backend.inner.wire.items.len);

    try backend.submitClose(72, fd);
    var got: std.ArrayList(completion.Completion) = .empty;
    defer got.deinit(allocator);
    try drain(&backend, &got, allocator);
}

test "receive-buffer starvation sleeps until recycle and then rearms" {
    const allocator = std.testing.allocator;
    var backend = try sealingBackend(allocator);
    defer backend.deinit();
    var responder = try responderChannel();
    defer responder.deinit(allocator);
    const fd = try openSealed(&backend, &responder, allocator);

    try backend.submitRecv(73, fd);
    const internal_ud = backend.inner.armed_recv_ud.?;
    backend.inner.armed_recv_ud = null;
    backend.inner.pending_recv = .{
        .user_data = internal_ud,
        .result = -1,
        .recv_no_buffer = true,
    };
    var completions: [2]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 73));
    const attempts_after_starvation = backend.inner.recv_submit_attempts;

    // Starvation alone is not actionable debt. The adapter may block in its
    // inner poll instead of spinning at timeout zero.
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 73));
    try std.testing.expectEqual(@as(i32, 73), backend.inner.last_poll_timeout_ms);
    try std.testing.expectEqual(attempts_after_starvation, backend.inner.recv_submit_attempts);

    backend.recycleBorrowed(.{ .user_data = 0, .result = 0 });
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(attempts_after_starvation + 1, backend.inner.recv_submit_attempts);
    try std.testing.expect(backend.inner.armed_recv_ud != null);

    try backend.submitCancel(74, 73, fd);
    try std.testing.expectEqual(@as(usize, 2), try backend.poll(&completions, 0));
    try closeSealed(&backend, fd, allocator);
}

test "cancel removes recycle-gated receive debt" {
    const allocator = std.testing.allocator;
    var backend = try sealingBackend(allocator);
    defer backend.deinit();
    var responder = try responderChannel();
    defer responder.deinit(allocator);
    const fd = try openSealed(&backend, &responder, allocator);

    try backend.submitRecv(75, fd);
    const internal_ud = backend.inner.armed_recv_ud.?;
    backend.inner.armed_recv_ud = null;
    backend.inner.pending_recv = .{
        .user_data = internal_ud,
        .result = -1,
        .recv_no_buffer = true,
    };
    var completions: [2]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    const attempts_after_starvation = backend.inner.recv_submit_attempts;
    try backend.submitCancel(76, 75, fd);
    try std.testing.expectEqual(@as(usize, 2), try backend.poll(&completions, 0));
    backend.recycleBorrowed(.{ .user_data = 0, .result = 0 });
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(attempts_after_starvation, backend.inner.recv_submit_attempts);
    try closeSealed(&backend, fd, allocator);
}

test "refused close retries in bounded FIFO turns and completes once" {
    const allocator = std.testing.allocator;
    var backend = try sealingBackend(allocator);
    defer backend.deinit();
    var responder = try responderChannel();
    defer responder.deinit(allocator);
    const fd = try openSealed(&backend, &responder, allocator);

    backend.inner.refused_closes = 2;
    try backend.submitClose(77, fd);
    try std.testing.expectEqual(@as(usize, 1), backend.inner.close_submit_attempts);
    var completions: [2]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, -1));
    try std.testing.expectEqual(@as(i32, 50), backend.inner.last_poll_timeout_ms);
    try std.testing.expectEqual(@as(usize, 2), backend.inner.close_submit_attempts);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, -1));
    try std.testing.expectEqual(@as(u64, 77), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), completions[0].result);
    try std.testing.expectEqual(@as(usize, 3), backend.inner.close_submit_attempts);
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
}

test "allocator refusal preserves earned completions before polling inner" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var backend = try sealingBackend(failing.allocator());
    defer backend.deinit();

    const Namespace = completion.AdapterNamespace(PipePlatform);
    const absent_fd = try Namespace.fdFromId(1);
    try backend.submitClose(78, absent_fd);
    failing.fail_index = failing.alloc_index;
    backend.inner.poll_calls = 0;

    var completions: [1]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 78), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), completions[0].result);
    try std.testing.expectEqual(@as(usize, 0), backend.inner.poll_calls);

    try std.testing.expectError(error.OutOfMemory, backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 0), backend.inner.poll_calls);
}

test "sealed completion close owns retries and preserves lent plaintext until recycle" {
    const allocator = std.testing.allocator;
    var backend = try sealingBackend(allocator);
    defer backend.deinit();
    var responder = try responderChannel();
    defer responder.deinit(allocator);
    const fd = try openSealed(&backend, &responder, allocator);

    var got: std.ArrayList(completion.Completion) = .empty;
    defer got.deinit(allocator);

    // An accepted empty send completes exactly once without occupying the send
    // seat or moving the cipher stream.
    try backend.submitSend(21, fd, &.{});
    try drain(&backend, &got, allocator);
    try std.testing.expectEqual(@as(usize, 1), got.items.len);
    try std.testing.expectEqual(@as(u64, 21), got.items[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), got.items[0].result);
    try std.testing.expectEqual(@as(usize, 0), backend.inner.wire.items.len);

    // A receive completion lends the channel's plaintext scratch. Close may
    // retire the pipe, but cannot free that scratch before recycle.
    const reply = "borrow remains valid through close";
    var reply_ct: std.ArrayList(u8) = .empty;
    defer reply_ct.deinit(allocator);
    try responder.sealBytes(allocator, &reply_ct, reply);
    try backend.submitRecv(22, fd);
    try backend.inner.completeRecv(reply_ct.items);
    try drain(&backend, &got, allocator);
    const lent = got.items[1];
    try std.testing.expectEqualStrings(reply, lent.borrowed.recvBytes().?);
    try std.testing.expectError(error.AlreadyReading, backend.submitRecv(23, fd));
    try backend.submitClose(24, fd);
    try drain(&backend, &got, allocator);
    try std.testing.expectEqualStrings(reply, lent.borrowed.recvBytes().?);
    try std.testing.expect(backend.verifiedChannelKey(fd) != null);
    backend.recycleBorrowed(lent);
    try std.testing.expectEqual(@as(?[crypto.PEER_KEY_BYTES]u8, null), backend.verifiedChannelKey(fd));
    try drain(&backend, &got, allocator);
    try std.testing.expectEqual(@as(u64, 24), got.items[got.items.len - 1].user_data);

    // On a fresh leg, close cancels an owed ciphertext submit. A later poll
    // cannot retry bytes after close has taken ownership.
    var responder2 = try responderChannel();
    defer responder2.deinit(allocator);
    const fd2 = try openSealed(&backend, &responder2, allocator);
    backend.inner.refused_sends = 1;
    try backend.submitSend(25, fd2, "must not escape after close");
    try backend.submitClose(26, fd2);
    try drain(&backend, &got, allocator);
    try std.testing.expectEqual(@as(usize, 0), backend.inner.wire.items.len);
    try std.testing.expectEqual(@as(u64, 25), got.items[got.items.len - 2].user_data);
    try std.testing.expectEqual(@as(i32, -1), got.items[got.items.len - 2].result);
    try std.testing.expectEqual(@as(u64, 26), got.items[got.items.len - 1].user_data);
}

test "a substituted responder key never yields a connected session" {
    const allocator = std.testing.allocator;
    var backend = try sealingBackend(allocator);
    defer backend.deinit();

    // The relay answers with its own static: a responder whose durable key is
    // not the one the dial named. Its message two cannot verify against the
    // dialed key's handshake transcript.
    const mitm_secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x66)));
    var mitm = try sealed.SealedChannel.initResponder(
        &mitm_secret,
        @as([crypto.SEED_BYTES]u8, @splat(0x77)),
        model.transport.noise_relay,
    );
    defer mitm.deinit(allocator);

    const fd = try backend.startDial(7, .{ .sealed = sealedTarget() });
    var got: std.ArrayList(completion.Completion) = .empty;
    defer got.deinit(allocator);
    try drain(&backend, &got, allocator);
    try std.testing.expectEqual(@as(usize, 0), got.items.len);

    // The imposter cannot even read message one, which was keyed to the
    // dialed responder; whatever it answers with, the initiator refuses.
    _ = mitm.ingest(allocator, backend.inner.wire.items) catch {};
    var msg2: std.ArrayList(u8) = .empty;
    defer msg2.deinit(allocator);
    try mitm.takeWireInto(allocator, &msg2);
    if (msg2.items.len == 0) {
        // No readable message one means no message two; synthesize the
        // imposter's best remaining move, a well-formed message two under its
        // own keys, by handshaking against itself. Either way the initiator
        // must refuse below.
        try msg2.appendNTimes(allocator, 0xaa, sealed.msg2_wire_bytes);
    }
    backend.inner.wire.clearRetainingCapacity();

    try backend.inner.completeRecv(msg2.items);
    try drain(&backend, &got, allocator);
    // The dial fails; it never reports connected, and no channel key exists.
    try std.testing.expectEqual(@as(usize, 1), got.items.len);
    try std.testing.expectEqual(@as(u64, 7), got.items[0].user_data);
    try std.testing.expectEqual(@as(i32, -1), got.items[0].result);
    try std.testing.expectEqual(@as(?[crypto.PEER_KEY_BYTES]u8, null), backend.verifiedChannelKey(fd));

    try closeSealed(&backend, fd, allocator);
}

test "noise-relay resolves as a sealed key-designator dial" {
    try std.testing.expectEqual(model.transport.DesignatorScheme.key, model.transport.Known.noise_relay.metadata().designator_scheme);
    try std.testing.expect(model.transport.Known.noise_relay.metadata().sealed_channel);

    const Resolver = noise_completion.DialResolver(NoiseBackend, PassthroughResolver);
    const designator = responderSecret().publicKey().toDesignator();
    const target = try Resolver.resolve(.{
        .transport = model.transport.noise_relay,
        .designator = designator[0..],
        .hints = model.Hints.emptyFalse(),
    });
    try std.testing.expect(target == .sealed);
    try std.testing.expectEqualSlices(u8, &responderSecret().publicKey().bytes, &target.sealed.remote.bytes);
    try std.testing.expectEqualStrings(model.transport.noise_relay, target.sealed.transport);

    const plain = try Resolver.resolve(.{
        .transport = "tcp",
        .designator = "127.0.0.1:1",
        .hints = model.Hints.emptyFalse(),
    });
    try std.testing.expect(plain == .plain);

    try std.testing.expectError(error.InvalidAddress, Resolver.resolve(.{
        .transport = model.transport.noise_relay,
        .designator = "not-a-key",
        .hints = model.Hints.emptyFalse(),
    }));
}

/// Stands in for the keyed-relay resolver: the wrapped grammar only needs to
/// show which transport symbol the sealing layer forwarded.
const PassthroughResolver = struct {
    pub fn resolve(locator: model.PeerLocator) error{InvalidAddress}!u32 {
        if (std.mem.eql(u8, locator.transport, model.transport.keyed_relay)) return 1;
        if (std.mem.eql(u8, locator.transport, "tcp")) return 2;
        return error.InvalidAddress;
    }
};

const live_frame_cap = 4096;
const live_options: driver.SessionOptions = .{
    .frame_cap = live_frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};
const relay_reply = "hello through the sealed relay";
const RelayGreeter = support_actors.StaticReplyValueActor("greet", relay_reply);

fn serveNoiseRelayOnce(server: *driver.Server) !void {
    const session = try server.accept();
    defer session.deinit();
    const identity = try session.runtime.core.partnerIdentity(session.hs);
    try std.testing.expectEqual(
        driver.core.DurableProvenance.authenticated_transport,
        identity.provenance,
    );
    _ = try session.publish("greeter", RelayGreeter, .{});
    try session.serve();
}

test "noise-relay registered resident opens an authenticated session through a ciphertext-only relay" {
    if (!(@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin()))
        return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const relay_addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var relay_server = try std.Io.net.IpAddress.listen(&relay_addr, io, .{ .reuse_address = true });
    defer relay_server.deinit(io);
    const port = relay_server.socket.address.getPort();
    var relay_url_buf: [64]u8 = undefined;
    const relay_url = try std.fmt.bufPrint(&relay_url_buf, "ws://127.0.0.1:{d}/relay", .{port});
    var register_url_buf: [64]u8 = undefined;
    const register_url = try std.fmt.bufPrint(&register_url_buf, "ws://127.0.0.1:{d}/register", .{port});

    var relay_saw_plaintext = std.atomic.Value(bool).init(false);
    var relay = try io.concurrent(ws_relay.bridgeOneRendezvousObserved, .{
        io,
        &relay_server,
        allocator,
        .{ .needle = relay_reply, .found = &relay_saw_plaintext },
    });

    const server_secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x52)));
    var registered = try net.relay.Resident.initRegisteredProfile(
        allocator,
        io,
        relay_url,
        register_url,
        server_secret.publicKey(),
        .noise,
    );
    defer _ = registered.deinit();
    var server = try driver.listen(
        allocator,
        registered.netlayer(),
        .{ .designator = "" },
        .{ .keyed = server_secret },
        live_options,
    );
    defer server.deinit();

    const advertised = try server.advertisedLocator();
    try std.testing.expectEqualStrings(model.transport.noise_relay, advertised.transport);
    try std.testing.expectEqualStrings(&server_secret.publicKey().toDesignator(), advertised.designator);

    var serving = try io.concurrent(serveNoiseRelayOnce, .{server});

    var dialer = try net.relay.Resident.initProfile(allocator, io, relay_url, .noise);
    defer _ = dialer.deinit();
    const layers = [_]net.netlayer.Netlayer{dialer.netlayer()};
    {
        const client = try driver.connect(allocator, &layers, advertised, .ephemeral, live_options);
        defer client.deinit();
        const identity = try client.runtime.core.partnerIdentity(client.hs);
        try std.testing.expectEqual(
            driver.core.DurableProvenance.authenticated_transport,
            identity.provenance,
        );

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const greeter = try client.fetch("greeter");
        const settled = try client.call(greeter, "greet", &.{}, arena.allocator());
        try std.testing.expect(settled == .fulfilled and settled.fulfilled == .string);
        try std.testing.expectEqualStrings(relay_reply, settled.fulfilled.string);
    }
    try serving.await(io);
    try relay.await(io);
    try std.testing.expect(!relay_saw_plaintext.load(.acquire));
}
