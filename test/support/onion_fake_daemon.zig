//! A fake Tor daemon: a control endpoint and a SOCKS endpoint on loopback.
//!
//! It exists so the onion transport's checks run in the ordinary suite with no Tor
//! and no network. It is deliberately not a Tor emulator. It answers the exact
//! requests pancake sends, in the exact shapes the two reference implementations
//! use, and it forwards a dial to a local address the test names.
//!
//! **What it cannot prove is that a real Tor answers the same way.** The bytes are
//! pinned against the pinned Spritely Goblins netlayer and the upstream OCapN
//! suite in `test/net/onion_socks5_test.zig` and `test/net/onion_control_test.zig`;
//! this file only replays what those tests hold. A green run here means the
//! transport agrees with those pinned bytes, never that it agrees with Tor.

const std = @import("std");

const pancake = @import("pancake");
const socks5 = pancake.net.onion.socks5;
const endpoint_mod = pancake.net.onion.endpoint;

/// A real, checksum-valid version 3 id, taken from the pinned Goblins source where
/// it is the example in `structs-urls.rkt`. Used as the id the fake control
/// endpoint reports, so a test asserting it is asserting a well-formed address
/// rather than a placeholder pancake would also accept.
pub const service_id = "wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd";

/// The key the fake reports for a freshly minted service, in the shape Tor's
/// `250-PrivateKey=` carries: a key type and a blob, which pancake passes back
/// verbatim and never parses.
pub const service_key = "ED25519-V3:c3RvcmVkLW9uaW9uLWtleS1ieXRlcw==";

/// How many control conversations one fake will hold at once.
const max_control_sessions = 4;

/// One fake daemon: two loopback listeners and the threads answering them.
pub const Daemon = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    control: std.Io.net.Server,
    socks: std.Io.net.Server,
    control_text: [48]u8 = undefined,
    control_text_len: usize = 0,
    socks_text: [48]u8 = undefined,
    socks_text_len: usize = 0,
    /// The forward target text the last `ADD_ONION` carried, so a test can point
    /// the SOCKS side at the very endpoint the listener bound.
    last_forward: [64]u8 = undefined,
    last_forward_len: usize = 0,
    control_thread: ?std.Io.Future(anyerror!void) = null,
    /// Set by `stop` so the accept loop leaves on its own. A parked `accept` is
    /// what a fake must never hold: closing the listen descriptor under it is the
    /// hazard the netlayer contract's `waitAcceptable` exists to avoid, and here it
    /// simply hangs.
    stopping: bool = false,

    pub fn start(allocator: std.mem.Allocator, io: std.Io) !*Daemon {
        const self = try allocator.create(Daemon);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .control = try std.Io.net.IpAddress.listen(
                &.{ .ip4 = std.Io.net.Ip4Address.loopback(0) },
                io,
                .{ .reuse_address = true },
            ),
            .socks = try std.Io.net.IpAddress.listen(
                &.{ .ip4 = std.Io.net.Ip4Address.loopback(0) },
                io,
                .{ .reuse_address = true },
            ),
        };
        self.control_text_len = (try std.fmt.bufPrint(
            &self.control_text,
            "{f}",
            .{self.control.socket.address},
        )).len;
        self.socks_text_len = (try std.fmt.bufPrint(
            &self.socks_text,
            "{f}",
            .{self.socks.socket.address},
        )).len;
        self.control_thread = try io.concurrent(serveControl, .{self});
        return self;
    }

    pub fn stop(self: *Daemon) void {
        // Ask the accept loop to leave, then wait for it, and only then close the
        // descriptors. Closing first would pull a listen fd out from under a
        // parked accept, which does not wake it.
        @atomicStore(bool, &self.stopping, true, .release);
        if (self.control_thread) |*f| _ = f.await(self.io) catch {};
        self.control.deinit(self.io);
        self.socks.deinit(self.io);
        self.allocator.destroy(self);
    }

    pub fn controlText(self: *const Daemon) []const u8 {
        return self.control_text[0..self.control_text_len];
    }

    pub fn socksText(self: *const Daemon) []const u8 {
        return self.socks_text[0..self.socks_text_len];
    }

    /// The forward target the last `ADD_ONION` named.
    pub fn lastForwardTarget(self: *const Daemon) []const u8 {
        return self.last_forward[0..self.last_forward_len];
    }

    /// Answer control conversations until the listener closes.
    ///
    /// Each one gets its own fiber, because pancake holds a control connection
    /// open for a listener's whole life: a second listener needs a second
    /// conversation, and a daemon that served them one at a time would park the
    /// second caller forever. Bounded, because a fake that could spawn without
    /// limit would hide a leak rather than surface it.
    fn serveControl(self: *Daemon) anyerror!void {
        var live: [max_control_sessions]?std.Io.Future(anyerror!void) = @splat(null);
        var next: usize = 0;
        defer for (&live) |*slot| {
            if (slot.*) |*f| _ = f.await(self.io) catch {};
        };
        while (next < live.len) {
            if (@atomicLoad(bool, &self.stopping, .acquire)) return;
            // Poll before accepting, so this loop is never parked in a syscall the
            // stop flag cannot interrupt.
            if (!self.acceptable()) continue;
            const stream = self.control.accept(self.io) catch return;
            live[next] = try self.io.concurrent(controlConversation, .{ self, stream });
            next += 1;
        }
    }

    /// Whether a control connection is waiting, polled with a short timeout so the
    /// accept loop keeps checking the stop flag.
    fn acceptable(self: *Daemon) bool {
        var fds = [_]std.posix.pollfd{.{
            .fd = self.control.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&fds, 20) catch return false;
        return ready != 0;
    }

    /// One control conversation: `AUTHENTICATE`, then whatever else arrives until
    /// the peer goes away.
    fn controlConversation(self: *Daemon, stream: std.Io.net.Stream) anyerror!void {
        defer stream.close(self.io);

        var read_buf: [1024]u8 = undefined;
        var write_buf: [1024]u8 = undefined;
        var reader = stream.reader(self.io, &read_buf);
        var writer = stream.writer(self.io, &write_buf);
        const r = &reader.interface;
        const w = &writer.interface;

        var line_buf: [1024]u8 = undefined;
        while (true) {
            const line = takeLine(r, &line_buf) catch return;
            if (std.mem.startsWith(u8, line, "AUTHENTICATE")) {
                try w.writeAll("250 OK\r\n");
            } else if (std.mem.startsWith(u8, line, "ADD_ONION")) {
                // Remember the forward target, the last comma-separated field of
                // the PORT= argument, so a test can reach the endpoint the
                // listener bound.
                if (std.mem.indexOf(u8, line, "PORT=")) |at| {
                    const rest = line[at + "PORT=".len ..];
                    if (std.mem.indexOfScalar(u8, rest, ',')) |ci| {
                        const target = rest[ci + 1 ..];
                        const n = @min(target.len, self.last_forward.len);
                        @memcpy(self.last_forward[0..n], target[0..n]);
                        self.last_forward_len = n;
                    }
                }
                // The three lines Tor answers with, in order.
                try w.writeAll("250-ServiceID=" ++ service_id ++ "\r\n");
                try w.writeAll("250-PrivateKey=" ++ service_key ++ "\r\n");
                try w.writeAll("250 OK\r\n");
            } else {
                // DEL_ONION and anything else this fake does not model.
                try w.writeAll("250 OK\r\n");
            }
            try w.flush();
        }
    }

    /// Splice one SOCKS dial onto the local endpoint named by the last
    /// `ADD_ONION`, as a real Tor circuit would. The two pumps must forward each
    /// available read; waiting for a full relay buffer deadlocks small CapTP
    /// handshake frames.
    pub fn spliceDial(self: *Daemon) anyerror!void {
        const client = try self.acceptDial();
        const target = self.lastForwardTarget();
        if (target.len == 0) {
            client.close(self.io);
            return error.NoForwardTarget;
        }
        const forward_ep = endpoint_mod.Endpoint.parse(target) catch |err| {
            client.close(self.io);
            return err;
        };
        const service = forward_ep.connect(self.io) catch |err| {
            client.close(self.io);
            return err;
        };

        // One fiber per direction, because a single loop would block reading one
        // side while the other had bytes waiting. The `Relay` is what makes either
        // end hanging up finish the whole splice: each pump shuts both legs down as
        // it leaves, so the opposite direction stops waiting on a socket nobody
        // will write to again, and the one guarded close runs once both have. A
        // splice that merely stopped copying would leave a served session reading a
        // stream that never reaches end-of-stream, which is a deadlock rather than
        // a slow test.
        var relay: Relay = .{ .io = self.io, .client = client, .service = service };
        defer relay.close();
        var to_service = try self.io.concurrent(pump, .{ &relay, client, service });
        pump(&relay, service, client);
        to_service.await(self.io);
    }

    /// Answer one SOCKS5 handshake and hand the raw stream back.
    ///
    /// The fake does not proxy. A real Tor splices the circuit onto the service's
    /// forward target, but a test that wanted a proxy in the middle would be
    /// testing the proxy: what the transport owes is that the stream is a
    /// transparent byte pipe positioned after the reply, so the caller becomes the
    /// far peer directly and asserts that.
    ///
    /// Returns the accepted stream, which the caller closes.
    pub fn acceptDial(self: *Daemon) anyerror!std.Io.net.Stream {
        const client = try self.socks.accept(self.io);
        errdefer client.close(self.io);

        // No read buffer: this reads exactly the request and leaves anything the
        // caller sent afterwards in the kernel, the same discipline the transport
        // side holds.
        var no_buffer: [0]u8 = undefined;
        var write_buf: [64]u8 = undefined;
        var reader = client.reader(self.io, &no_buffer);
        var writer = client.writer(self.io, &write_buf);

        var greeting: [socks5.greeting.len]u8 = undefined;
        try reader.interface.readSliceAll(&greeting);
        if (!std.mem.eql(u8, &greeting, &socks5.greeting)) return error.BadGreeting;
        try writer.interface.writeAll(&[_]u8{ 0x05, 0x00 });
        try writer.interface.flush();

        var request: [socks5.connect_request_len]u8 = undefined;
        try reader.interface.readSliceAll(&request);
        var expected: [socks5.connect_request_len]u8 = undefined;
        const want = try socks5.writeConnectRequest(&expected, service_id);
        if (!std.mem.eql(u8, want, &request)) return error.BadConnectRequest;

        // Version 5, success, reserved, IPv4, then the null bound address Tor
        // reports for an onion connect. Flushed here, because this writer's buffer
        // is a local that dies with this call: leaving the reply in it would send
        // nothing at all. The case where Tor coalesces its reply with the far
        // peer's first bytes is covered where a writer outlives the handshake, in
        // `test/net/onion_resident_test.zig`.
        try writer.interface.writeAll(&[_]u8{ 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0 });
        try writer.interface.flush();
        return client;
    }
};

const Relay = struct {
    io: std.Io,
    client: std.Io.net.Stream,
    service: std.Io.net.Stream,
    shutdown_started: std.atomic.Value(bool) = .init(false),

    fn shutdown(self: *Relay) void {
        if (self.shutdown_started.swap(true, .acq_rel)) return;
        _ = self.client.shutdown(self.io, .both) catch {};
        _ = self.service.shutdown(self.io, .both) catch {};
    }

    fn close(self: *Relay) void {
        self.client.close(self.io);
        self.service.close(self.io);
    }
};

fn pump(relay: *Relay, from: std.Io.net.Stream, to: std.Io.net.Stream) void {
    defer relay.shutdown();
    const io = relay.io;
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = from.reader(io, &read_buf);
    var writer = to.writer(io, &write_buf);
    var chunk: [4096]u8 = undefined;
    var bufs = [_][]u8{&chunk};
    while (true) {
        const n = reader.interface.readVec(&bufs) catch return;
        if (n == 0) return;
        writer.interface.writeAll(chunk[0..n]) catch return;
        writer.interface.flush() catch return;
    }
}

fn takeLine(r: *std.Io.Reader, buf: []u8) ![]const u8 {
    var len: usize = 0;
    while (true) {
        const b = try r.takeByte();
        if (b == '\n') break;
        if (b == '\r') continue;
        if (len == buf.len) return error.LineTooLong;
        buf[len] = b;
        len += 1;
    }
    return buf[0..len];
}
