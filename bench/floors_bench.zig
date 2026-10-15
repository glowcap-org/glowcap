//! The floors: what one primitive costs alone, with nothing of glowcap around
//! it. `bench/README.md` pairs each product path with the floors it pays and
//! records the ratio, so a path's cost is judged against the machine and
//! the primitives, never only against its own last run.
//!
//! Each row is one primitive timed in a tight loop: an Ed25519 signature and
//! its verification, one Noise XK handshake with both roles in this process,
//! one sealed record each way, a frame-sized copy, one thread waking another
//! and being woken back, and one 64-byte ping and pong over a loopback
//! socket, once with both sides parked in a blocking read and once with both
//! sides spinning on a nonblocking one. The wake row is the kernel's own
//! hand-off between two parked threads, and the loopback rows are its own
//! socket round trip with and without a park, each with no completion loop
//! above it.
//!
//! Run `zig build bench-floors -Doptimize=ReleaseFast` for absolute figures,
//! with `--pin=A,B` to keep the timed thread on core A and its partner on B.
//! `--smoke` (used by `zig build check`) runs a few iterations of each row to
//! prove the bench still runs. Nothing here gates: a floor is a property of
//! the machine, and `bench/README.md` records which machine.

const std = @import("std");
const glowcap = @import("glowcap");

const affinity = @import("support/affinity.zig");

const crypto = glowcap.foundation.crypto;
const noise = glowcap.foundation.noise;
const socket_tcp = glowcap.net.socket_tcp;

const IpAddress = std.Io.net.IpAddress;

const payload_bytes = 64;
const record_bytes = 1024;
const ping_bytes = 64;
const prologue = "noise-tcp\x00designator";

fn nowNs(io: std.Io) i128 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn report(name: []const u8, elapsed_ns: i128, iterations: usize) void {
    std.debug.print("floor name={s} iterations={d} ns_per_op={d}\n", .{
        name, iterations, @divTrunc(elapsed_ns, @as(i128, @intCast(iterations))),
    });
}

fn floorEd25519(io: std.Io, iterations: usize) !void {
    const identity = crypto.SecretKey.fromSeed(@splat(0xC3));
    const public = identity.publicKey();
    var payload: [payload_bytes]u8 = @splat(0x5A);

    var checksum: u8 = 0;
    const sign_start = nowNs(io);
    for (0..iterations) |i| {
        payload[0] = @truncate(i);
        const sig = crypto.sign(&identity, &payload);
        checksum +%= sig.bytes[0];
    }
    const sign_elapsed = nowNs(io) - sign_start;
    std.mem.doNotOptimizeAway(checksum);
    report("ed25519_sign", sign_elapsed, iterations);

    payload[0] = 0;
    const sig = crypto.sign(&identity, &payload);
    const verify_start = nowNs(io);
    for (0..iterations) |_| {
        try crypto.verify(public, &payload, sig);
    }
    report("ed25519_verify", nowNs(io) - verify_start, iterations);
}

/// One full XK handshake: three messages written and read in this process,
/// then `split` on both sides. Each iteration derives fresh ephemerals from
/// a seeded generator, so the row includes the two public-key derivations
/// a real dial and accept pay.
fn floorNoiseHandshake(io: std.Io, iterations: usize) !void {
    const dialer_identity = crypto.SecretKey.fromSeed(@splat(0xC3));
    const answerer_identity = crypto.SecretKey.fromSeed(@splat(0xD4));
    const dialer_static = crypto.x25519FromSecretKey(&dialer_identity).?;
    const answerer_static = crypto.x25519FromSecretKey(&answerer_identity).?;
    const answerer_point = crypto.x25519FromPeerKey(answerer_identity.publicKey()).?;
    const dialer_key = dialer_identity.publicKey();

    var prng = std.Random.DefaultPrng.init(0x515EEDED);
    const random = prng.random();
    var a_to_b: [256]u8 = undefined;
    var b_to_a: [256]u8 = undefined;
    var scratch: [256]u8 = undefined;
    var checksum: u8 = 0;

    const start = nowNs(io);
    for (0..iterations) |_| {
        var dialer_seed: [32]u8 = undefined;
        var answerer_seed: [32]u8 = undefined;
        random.bytes(&dialer_seed);
        random.bytes(&answerer_seed);
        const dialer_ephemeral = crypto.X25519KeyMaterial.fromSecret(dialer_seed);
        const answerer_ephemeral = crypto.X25519KeyMaterial.fromSecret(answerer_seed);

        var dialer = noise.HandshakeState.initInitiator(&dialer_static, answerer_point, &dialer_ephemeral, prologue);
        var answerer = noise.HandshakeState.initResponder(&answerer_static, &answerer_ephemeral, prologue);
        _ = try answerer.readMessage(try dialer.writeMessage("", &a_to_b), &scratch);
        _ = try dialer.readMessage(try answerer.writeMessage("", &b_to_a), &scratch);
        const identity_payload = try answerer.readMessage(try dialer.writeMessage(dialer_key.asBytes(), &a_to_b), &scratch);
        checksum +%= identity_payload[0];

        var dialer_keys = try dialer.split();
        var answerer_keys = try answerer.split();
        checksum +%= dialer_keys.send.k[0] ^ answerer_keys.recv.k[0];
        dialer_keys.send.deinit();
        dialer_keys.recv.deinit();
        answerer_keys.send.deinit();
        answerer_keys.recv.deinit();
    }
    const elapsed = nowNs(io) - start;
    std.mem.doNotOptimizeAway(checksum);
    report("noise_xk_handshake", elapsed, iterations);
}

fn floorNoiseRecord(io: std.Io, iterations: usize) !void {
    var sealer = noise.CipherState.init(@splat(0x11));
    var opener = noise.CipherState.init(@splat(0x11));
    defer sealer.deinit();
    defer opener.deinit();
    const plaintext: [record_bytes]u8 = @splat(0x42);
    var wire: [record_bytes + noise.RECORD_HEADER_BYTES + noise.TAG_BYTES]u8 = undefined;
    var out: [record_bytes]u8 = undefined;
    var checksum: u8 = 0;

    const seal_start = nowNs(io);
    for (0..iterations) |_| {
        const sealed = try noise.sealRecord(&sealer, &plaintext, &wire);
        checksum +%= sealed[sealed.len - 1];
    }
    report("noise_record_seal_1k", nowNs(io) - seal_start, iterations);

    // Reseal once from a fresh nonce so every open below reads a record the
    // opener's nonce sequence accepts, then open that one record each turn.
    var fresh = noise.CipherState.init(@splat(0x11));
    defer fresh.deinit();
    const sealed = try noise.sealRecord(&fresh, &plaintext, &wire);
    const body = sealed[noise.RECORD_HEADER_BYTES..];
    const open_start = nowNs(io);
    for (0..iterations) |_| {
        opener = noise.CipherState.init(@splat(0x11));
        const opened = try noise.openRecord(&opener, body, &out);
        checksum +%= opened[0];
    }
    const open_elapsed = nowNs(io) - open_start;
    std.mem.doNotOptimizeAway(checksum);
    report("noise_record_open_1k", open_elapsed, iterations);
}

fn floorMemcpy(io: std.Io, comptime bytes: usize, name: []const u8, iterations: usize) void {
    var src: [bytes]u8 = @splat(0x33);
    var dst: [bytes]u8 = undefined;
    var checksum: u8 = 0;
    const start = nowNs(io);
    for (0..iterations) |i| {
        src[0] = @truncate(i);
        @memcpy(&dst, &src);
        std.mem.doNotOptimizeAway(&dst);
        checksum +%= dst[bytes - 1];
    }
    const elapsed = nowNs(io) - start;
    std.mem.doNotOptimizeAway(checksum);
    report(name, elapsed, iterations);
}

/// A pair of one-shot events, one per direction, for the wake round trip.
const WakePair = struct {
    to_server: std.Io.Event = .unset,
    to_client: std.Io.Event = .unset,
};

/// Answer `iterations` wakes: park, be woken, wake the client back.
fn wakeBack(io: std.Io, pair: *WakePair, iterations: usize) void {
    pinPartner();
    for (0..iterations) |_| {
        pair.to_server.waitUncancelable(io);
        pair.to_server.reset();
        pair.to_client.set(io);
    }
}

/// One thread wakes a parked partner and parks until the partner wakes it
/// back: the kernel's hand-off between two threads of this process, which an
/// in-process transport pays once per direction.
fn floorThreadWake(io: std.Io, iterations: usize) !void {
    var pair = WakePair{};
    var answering = try io.concurrent(wakeBack, .{ io, &pair, iterations });
    const start = nowNs(io);
    for (0..iterations) |_| {
        pair.to_server.set(io);
        pair.to_client.waitUncancelable(io);
        pair.to_client.reset();
    }
    const elapsed = nowNs(io) - start;
    answering.await(io);
    report("thread_wake_round_trip", elapsed, iterations);
}

/// Accept one connection and echo `iterations` pings of `ping_bytes` each.
fn echo(io: std.Io, server: *std.Io.net.Server, iterations: usize) !void {
    pinPartner();
    const stream = try server.accept(io);
    defer stream.close(io);
    var read_buf: [ping_bytes]u8 = undefined;
    var write_buf: [ping_bytes]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    var ping: [ping_bytes]u8 = undefined;
    for (0..iterations) |_| {
        try reader.interface.readSliceAll(&ping);
        try writer.interface.writeAll(&ping);
        try writer.interface.flush();
    }
}

/// One 64-byte ping and its pong over a blocking loopback socket: the kernel's
/// round trip between two threads of this process, with no loop above it.
fn floorLoopback(io: std.Io, iterations: usize) !void {
    const bind = try IpAddress.parse("127.0.0.1", 0);
    var server = try bind.listen(io, .{});
    defer server.deinit(io);
    var echoing = try io.concurrent(echo, .{ io, &server, iterations });

    const stream = try server.socket.address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var read_buf: [ping_bytes]u8 = undefined;
    var write_buf: [ping_bytes]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    var ping: [ping_bytes]u8 = @splat(0x77);
    var pong: [ping_bytes]u8 = undefined;
    var checksum: u8 = 0;

    const start = nowNs(io);
    for (0..iterations) |i| {
        ping[0] = @truncate(i);
        try writer.interface.writeAll(&ping);
        try writer.interface.flush();
        try reader.interface.readSliceAll(&pong);
        checksum +%= pong[0];
    }
    const elapsed = nowNs(io) - start;
    try echoing.await(io);
    std.mem.doNotOptimizeAway(checksum);
    report("loopback_round_trip_64b", elapsed, iterations);
}

/// Receive exactly `buf.len` bytes on a nonblocking socket, spinning
/// between partial reads.
fn receiveSpinning(fd: i32, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = socket_tcp.receiveNonblocking(fd, buf[got..]) catch |err| switch (err) {
            error.WouldBlock => {
                std.atomic.spinLoopHint();
                continue;
            },
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        got += n;
    }
}

/// Send all of `bytes` on a nonblocking socket, spinning while the kernel's
/// send buffer is full.
fn sendSpinning(fd: i32, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        sent += socket_tcp.sendNonblocking(fd, bytes[sent..]) catch |err| switch (err) {
            error.WouldBlock => {
                std.atomic.spinLoopHint();
                continue;
            },
            else => return err,
        };
    }
}

/// Accept one connection and echo `iterations` pings without ever parking.
fn echoSpinning(io: std.Io, server: *std.Io.net.Server, iterations: usize) !void {
    pinPartner();
    const stream = try server.accept(io);
    defer stream.close(io);
    const fd: i32 = @intCast(stream.socket.handle);
    if (!socket_tcp.setNonblocking(fd)) return error.SetNonblockingFailed;
    var ping: [ping_bytes]u8 = undefined;
    for (0..iterations) |_| {
        try receiveSpinning(fd, &ping);
        try sendSpinning(fd, &ping);
    }
}

/// The loopback round trip with neither side parking: both sockets are
/// nonblocking and each side spins on its receive. This is the socket cost a
/// busy-polling runtime pays, with the wake taken out.
fn floorLoopbackSpinning(io: std.Io, iterations: usize) !void {
    const bind = try IpAddress.parse("127.0.0.1", 0);
    var server = try bind.listen(io, .{});
    defer server.deinit(io);
    var echoing = try io.concurrent(echoSpinning, .{ io, &server, iterations });

    const stream = try server.socket.address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    const fd: i32 = @intCast(stream.socket.handle);
    if (!socket_tcp.setNonblocking(fd)) return error.SetNonblockingFailed;
    var ping: [ping_bytes]u8 = @splat(0x77);
    var pong: [ping_bytes]u8 = undefined;
    var checksum: u8 = 0;

    const start = nowNs(io);
    for (0..iterations) |i| {
        ping[0] = @truncate(i);
        try sendSpinning(fd, &ping);
        try receiveSpinning(fd, &pong);
        checksum +%= pong[0];
    }
    const elapsed = nowNs(io) - start;
    try echoing.await(io);
    std.mem.doNotOptimizeAway(checksum);
    report("loopback_round_trip_64b_spinning", elapsed, iterations);
}

/// The cores `--pin=` named, or null to let the scheduler place the threads.
var pin: ?affinity.Pair = null;

/// Pin a partner thread to the second core of `--pin=`, when one was named.
fn pinPartner() void {
    // best-effort: a pin that fails leaves the row unpinned, which the
    // scheduler placement makes visible as a slower, noisier figure.
    if (pin) |cores| affinity.pinThread(cores[1]) catch {};
}

pub fn main(init: std.process.Init) !void {
    var smoke = false;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) {
            smoke = true;
        } else if (std.mem.startsWith(u8, arg, "--pin=")) {
            pin = try affinity.parsePair(arg["--pin=".len..]);
        } else {
            return error.UnknownArgument;
        }
    }
    if (pin) |cores| try affinity.pinThread(cores[0]);
    const io = init.io;
    const crypto_iterations: usize = if (smoke) 4 else 2_000;
    const byte_iterations: usize = if (smoke) 4 else 200_000;
    const socket_iterations: usize = if (smoke) 4 else 20_000;

    std.debug.print("floors mode={s} payload_bytes={d} record_bytes={d} ping_bytes={d} pin={s}\n", .{
        @tagName(@import("builtin").mode), payload_bytes, record_bytes, ping_bytes, if (pin != null) "yes" else "no",
    });
    try floorEd25519(io, crypto_iterations);
    try floorNoiseHandshake(io, crypto_iterations);
    try floorNoiseRecord(io, byte_iterations);
    floorMemcpy(io, 1024, "memcpy_1k", byte_iterations);
    floorMemcpy(io, 16 * 1024, "memcpy_16k", byte_iterations);
    try floorThreadWake(io, socket_iterations);
    try floorLoopback(io, socket_iterations);
    try floorLoopbackSpinning(io, socket_iterations);
}
