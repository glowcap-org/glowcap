//! Minimal server-side WebSocket relay for the keyed-relay loopback tests.
//!
//! Test support (not a production module): the in-process stand-in for the
//! reference relay's rendezvous contract (ADR-0086/0088). It accepts WebSocket
//! clients on a loopback TCP socket, performs the RFC 6455 server upgrade,
//! routes by request target (`/register?id=` holds the socket;
//! `/relay?rendezvous=` bridges onto it), and pumps frames between the two
//! legs — unmasking each client frame and re-framing it unmasked, the
//! byte-transparent shape `bindings/ts/relay/serve.ts` ships. The production
//! client side under test is `net.relay`; everything here exists so that
//! client meets a spec-shaped far end without Deno.

const std = @import("std");
const glowcap = @import("glowcap");

const keyed_relay = glowcap.net.relay;
const Io = std.Io;
const ip = Io.net;

/// The relay never re-frames more than this per frame; a test frame larger
/// than the cap is a test bug, refused loudly.
pub const max_frame_payload = 64 * 1024;

/// One upgraded server-side leg: the accepted stream plus its reader/writer
/// stores, pinned by value inside the test's frame.
pub const Leg = struct {
    stream: Io.net.Stream,
    io: Io,
    read_store: [4096]u8 = undefined,
    write_store: [4096]u8 = undefined,
    reader: Io.net.Stream.Reader = undefined,
    writer: Io.net.Stream.Writer = undefined,
    target: []const u8 = &.{},
    target_store: [512]u8 = undefined,

    /// Wire the reader/writer over the stores. Call once the Leg has its final
    /// address (the interfaces are recovered by field offset).
    pub fn wire(leg: *Leg) void {
        leg.reader = leg.stream.reader(leg.io, &leg.read_store);
        leg.writer = leg.stream.writer(leg.io, &leg.write_store);
    }

    pub fn close(leg: *Leg) void {
        leg.stream.close(leg.io);
    }
};

/// Read the client's upgrade request off `leg`, answer the 101 with the
/// correct `Sec-WebSocket-Accept`, and record the request target (path plus
/// query) on the leg for routing.
pub fn serveUpgrade(leg: *Leg) !void {
    const r = &leg.reader.interface;
    var line: [512]u8 = undefined;
    var line_len: usize = 0;
    var first = true;
    var key: [64]u8 = undefined;
    var key_len: usize = 0;
    while (true) {
        const b = try r.takeByte();
        if (b != '\n') {
            if (line_len < line.len) {
                line[line_len] = b;
                line_len += 1;
            }
            continue;
        }
        var l = line[0..line_len];
        if (l.len > 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];
        line_len = 0;
        if (first) {
            // "GET <target> HTTP/1.1"
            var it = std.mem.splitScalar(u8, l, ' ');
            _ = it.next() orelse return error.BadRequest;
            const target = it.next() orelse return error.BadRequest;
            if (target.len > leg.target_store.len) return error.BadRequest;
            @memcpy(leg.target_store[0..target.len], target);
            leg.target = leg.target_store[0..target.len];
            first = false;
        } else if (l.len == 0) {
            break;
        } else if (std.mem.indexOfScalar(u8, l, ':')) |colon| {
            if (std.ascii.eqlIgnoreCase(l[0..colon], "sec-websocket-key")) {
                const value = std.mem.trim(u8, l[colon + 1 ..], " \t");
                if (value.len > key.len) return error.BadRequest;
                @memcpy(key[0..value.len], value);
                key_len = value.len;
            }
        }
    }
    if (key_len == 0) return error.BadRequest;
    var accept: [28]u8 = undefined;
    keyed_relay.acceptKey(&accept, key[0..key_len]);
    const w = &leg.writer.interface;
    try w.print(
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n",
        .{accept[0..]},
    );
    try w.flush();
}

/// One frame read off a client leg, unmasked into `payload_buf`.
pub const ClientFrame = struct {
    opcode: keyed_relay.Opcode,
    payload: []const u8,
};

/// Read one frame from a client leg, requiring the client mask RFC 6455
/// demands, and unmask its payload into `payload_buf`.
pub fn readClientFrame(leg: *Leg, payload_buf: []u8) !ClientFrame {
    const r = &leg.reader.interface;
    const b0 = try r.takeByte();
    const b1 = try r.takeByte();
    if (b1 & 0x80 == 0) return error.ClientFrameUnmasked;
    var len: u64 = b1 & 0x7f;
    if (len == 126) {
        var ext: [2]u8 = undefined;
        try r.readSliceAll(&ext);
        len = std.mem.readInt(u16, &ext, .big);
    } else if (len == 127) {
        var ext: [8]u8 = undefined;
        try r.readSliceAll(&ext);
        len = std.mem.readInt(u64, &ext, .big);
    }
    if (len > payload_buf.len) return error.FrameTooLarge;
    var mask: [4]u8 = undefined;
    try r.readSliceAll(&mask);
    const payload = payload_buf[0..@intCast(len)];
    try r.readSliceAll(payload);
    for (payload, 0..) |*b, i| b.* ^= mask[i % 4];
    return .{
        .opcode = @fromBackingInt(@intCast(@as(u4, @truncate(b0 & 0x0f)))),
        .payload = payload,
    };
}

/// Stage one unmasked server frame without flushing the carrier. Tests use this
/// to prove several WebSocket frames delivered by one socket write.
pub fn stageServerFrame(leg: *Leg, opcode: keyed_relay.Opcode, payload: []const u8) !void {
    const w = &leg.writer.interface;
    var header: [10]u8 = undefined;
    header[0] = 0x80 | @as(u8, @backingInt(opcode));
    var at: usize = 2;
    if (payload.len < 126) {
        header[1] = @intCast(payload.len);
    } else if (payload.len <= std.math.maxInt(u16)) {
        header[1] = 126;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        at = 4;
    } else {
        header[1] = 127;
        std.mem.writeInt(u64, header[2..10], payload.len, .big);
        at = 10;
    }
    try w.writeAll(header[0..at]);
    try w.writeAll(payload);
}

/// Write one unmasked server frame to a leg.
pub fn writeServerFrame(leg: *Leg, opcode: keyed_relay.Opcode, payload: []const u8) !void {
    try stageServerFrame(leg, opcode, payload);
    const w = &leg.writer.interface;
    try w.flush();
}

/// Pump frames from `src` to `dst` until `src` closes (a close frame or EOF),
/// then close-frame `dst`. Data frames re-frame unmasked and are followed by a
/// ping, exercising the client's byte-stream behavior across buffered control
/// frames. Pings from `src` are answered in place, as the relay runtime would.
const PlaintextProbe = struct {
    needle: []const u8,
    found: *std.atomic.Value(bool),
};

fn bridgeDirectionObserved(
    src: *Leg,
    dst: *Leg,
    allocator: std.mem.Allocator,
    probe: ?PlaintextProbe,
) !void {
    const payload_buf = try allocator.alloc(u8, max_frame_payload);
    defer allocator.free(payload_buf);
    while (true) {
        const frame = readClientFrame(src, payload_buf) catch break;
        switch (frame.opcode) {
            .binary, .continuation => {
                if (probe) |p| {
                    if (std.mem.indexOf(u8, frame.payload, p.needle) != null)
                        p.found.store(true, .release);
                }
                writeServerFrame(dst, .binary, frame.payload) catch break;
                writeServerFrame(dst, .ping, "hb") catch break;
            },
            .ping => writeServerFrame(src, .pong, frame.payload) catch break,
            .pong => {},
            .close => break,
            else => break,
        }
    }
    writeServerFrame(dst, .close, &.{}) catch {};
}

/// Accept one registration leg and one rendezvous leg, assert they name the
/// same key, then bridge bytes between them until either side closes.
pub fn bridgeOneRendezvous(io: Io, server: *ip.Server, allocator: std.mem.Allocator) !void {
    return bridgeOneRendezvousObserved(io, server, allocator, null);
}

pub const Probe = struct {
    /// Scanned for at the relay's plaintext payload position.
    needle: []const u8 = &.{},
    found: ?*std.atomic.Value(bool) = null,
    /// Set once the parked registration answered the relay's ping, so a
    /// test can dial knowing the registration is the first leg accepted.
    registered: ?*std.atomic.Value(bool) = null,
};

/// The rendezvous bridge with an optional scanner at the relay's plaintext
/// payload position. A sealed-channel test passes a needle and proves the far
/// peer received it while this scanner did not.
pub fn bridgeOneRendezvousObserved(
    io: Io,
    server: *ip.Server,
    allocator: std.mem.Allocator,
    probe: ?Probe,
) !void {
    var reg: Leg = .{ .stream = try server.accept(io), .io = io };
    reg.wire();
    defer reg.close();
    try serveUpgrade(&reg);
    try std.testing.expect(std.mem.startsWith(u8, reg.target, "/register?id="));
    const reg_id = reg.target["/register?id=".len..];

    // Ping the parked registration; a proper keyed-relay listener answers
    // control frames while waiting for a dialer's bytes.
    try writeServerFrame(&reg, .ping, "hb");
    var pong_buf: [16]u8 = undefined;
    const pong = try readClientFrame(&reg, &pong_buf);
    try std.testing.expectEqual(keyed_relay.Opcode.pong, pong.opcode);
    try std.testing.expectEqualStrings("hb", pong.payload);
    if (probe) |p| if (p.registered) |registered| registered.store(true, .release);

    var dial: Leg = .{ .stream = try server.accept(io), .io = io };
    dial.wire();
    defer dial.close();
    try serveUpgrade(&dial);
    try std.testing.expect(std.mem.startsWith(u8, dial.target, "/relay?rendezvous="));
    try std.testing.expectEqualStrings(reg_id, dial.target["/relay?rendezvous=".len..]);

    const internal_probe: ?PlaintextProbe = if (probe) |p| if (p.found) |found| .{
        .needle = p.needle,
        .found = found,
    } else null else null;
    var to_reg = try io.concurrent(bridgeDirectionObserved, .{ &dial, &reg, allocator, internal_probe });
    var to_dial = try io.concurrent(bridgeDirectionObserved, .{ &reg, &dial, allocator, internal_probe });
    to_reg.await(io) catch {};
    to_dial.await(io) catch {};
}
