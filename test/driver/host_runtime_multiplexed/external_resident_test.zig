//! Foreign stream providers on a completion backend (ADR-0018): a
//! HostRuntime listens through the C TCP provider's stream table on an
//! external completion resident, a stream-netlayer client dials it, and a
//! fetch and call settle across the provider's nonblocking reads and writes.
//! A second scenario drives the backend directly through one dial.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");
const c = @import("c_abi_shared");
const tcp_provider = @import("c_abi_net_transport_tcp");
const stream_completion = @import("c_abi_driver").stream_completion;

const crypto = glowcap.foundation.crypto;
const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const net = glowcap.net;
const external = net.external_completion;

const ExternalBackend = external.CompletionBackend(net.Backend);

const ExternalResident = net.completion_resident.Resident(ExternalBackend, external.ResidentPolicy(ExternalBackend, external.PlatformRefused(net.Backend)));

const frame_cap = 4096;

const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

const Echo = struct {
    pub fn handle(_: *Echo, _: *driver.HostTurn, verb: []const u8, _: driver.Args) !driver.Value {
        if (!std.mem.eql(u8, verb, "ping")) return error.NoSuchMethod;
        return .{ .string = "pong through a foreign provider" };
    }
};

/// Fails the test on any contract violation or teardown failure.
const Recorder = struct {
    violations: usize = 0,
    teardowns: usize = 0,

    fn violation(ctx: *anyopaque, message: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        std.debug.print("provider contract violation: {s}\n", .{message});
        self.violations += 1;
    }

    fn teardown(ctx: *anyopaque, _: glowcap.foundation.FailureChain) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.teardowns += 1;
    }
};

/// The C TCP provider's stream table, adapted to the external backend.
const TcpProvider = struct {
    netlayer: ?*tcp_provider.GlowcapTcpNetlayer = null,
    stream: stream_completion.StreamProvider,
    recorder: Recorder = .{},

    fn init(self: *TcpProvider, allocator: std.mem.Allocator) !void {
        const config: tcp_provider.GlowcapTcpConfig = .{ .stream = .{ .keepalive_idle_sec = 0, .keepalive_interval_sec = 0, .keepalive_count = 0 } };
        self.netlayer = null;
        try std.testing.expectEqual(c.GLOWCAP_OK, tcp_provider.glowcap_tcp_netlayer_new(&config, &self.netlayer));
        errdefer tcp_provider.glowcap_tcp_netlayer_release(self.netlayer);
        var package: c.GlowcapTransportProvider = undefined;
        try std.testing.expectEqual(c.GLOWCAP_OK, tcp_provider.glowcap_tcp_transport_provider(self.netlayer, &package));
        const table: *const c.GlowcapStreamTransport = @ptrCast(@alignCast(package.entries.?[0].implementation.?));
        self.recorder = .{};
        self.stream = .{
            .allocator = allocator,
            .transport = model.transport.tcp,
            .table = table.*,
            .sink = .{ .ctx = &self.recorder, .violation = Recorder.violation, .teardown = Recorder.teardown },
        };
    }

    fn deinit(self: *TcpProvider) void {
        tcp_provider.glowcap_tcp_netlayer_release(self.netlayer);
    }
};

fn serve(server: *driver.Server, done: *std.atomic.Value(bool)) anyerror!void {
    var session = try server.accept();
    defer session.deinit();
    _ = try session.publish("echo", Echo, .{});
    while (!done.load(.acquire)) {
        _ = session.stepReadable(20) catch |err| switch (err) {
            error.ConnectionClosed, error.ProtocolAbort => break,
            else => |e| return e,
        };
    }
}

test "an external completion resident serves a dial through a foreign stream provider's table" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var provider: TcpProvider = undefined;
    try provider.init(allocator);
    defer provider.deinit();
    const providers = [_]external.Provider{provider.stream.provider()};

    var resident = try ExternalResident.init(allocator, try ExternalBackend.initWithPlatform(allocator, .{ .providers = &providers }, try net.Backend.init(allocator, 64, 16, frame_cap), 16, frame_cap), .{});
    defer {
        resident.closeAndDrain(2_000) catch |err| std.debug.panic("external resident drain failed: {t}", .{err});
        resident.deinit();
    }
    const registrations = [_]driver.HostRuntime.ProviderRegistration{.{
        .profile = model.transport.Known.tcp.metadata(),
        .resident = resident.resident(),
    }};
    var server = try driver.listen(allocator, io, .{ .residents = &registrations }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, opts);
    defer server.deinit();
    const designator = try allocator.dupe(u8, (try server.advertisedLocator()).designator);
    defer allocator.free(designator);

    var done = std.atomic.Value(bool).init(false);
    var server_future = try io.concurrent(serve, .{ server, &done });
    defer {
        done.store(true, .release);
        server_future.await(io) catch {};
    }
    {
        const client = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, .{
            .transport = net.tcp.transport_name,
            .designator = designator,
            .hints = model.Hints.emptyFalse(),
        }, .ephemeral, opts);
        defer client.deinit();
        const echo = try client.fetch("echo");
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        switch (try client.call(echo, "ping", &.{}, arena.allocator())) {
            .fulfilled => |arg| try std.testing.expectEqualStrings("pong through a foreign provider", arg.string),
            .broken => |reason| {
                std.debug.print("echo broke: {s}\n", .{reason});
                return error.EchoBroke;
            },
        }
    }
    try std.testing.expectEqual(@as(usize, 0), provider.recorder.violations);
}

fn echoOnce(io: std.Io, server: *std.Io.net.Server) !void {
    var stream = (try server.accept(io));
    defer stream.close(io);
    var read_buf: [64]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var bytes: [5]u8 = undefined;
    try reader.interface.readSliceAll(&bytes);
    var write_buf: [64]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(&bytes);
    try writer.interface.flush();
}

fn awaitCompletion(backend: *ExternalBackend, user_data: u64) !net.completion.Completion {
    var out: [4]net.completion.Completion = undefined;
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        const n = try backend.poll(&out, 10);
        for (out[0..n]) |comp| {
            if (comp.user_data == user_data) return comp;
            return error.UnexpectedCompletion;
        }
    }
    return error.CompletionTimedOut;
}

test "foreign-provider completion backend dials, moves bytes both ways, and closes" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try std.Io.net.IpAddress.listen(&address, io, .{ .reuse_address = true });
    defer server.deinit(io);
    var designator_buf: [32]u8 = undefined;
    const designator = try std.fmt.bufPrint(&designator_buf, "127.0.0.1:{d}", .{server.socket.address.getPort()});
    var echo_future = try io.concurrent(echoOnce, .{ io, &server });
    errdefer echo_future.cancel(io) catch {};

    var provider: TcpProvider = undefined;
    try provider.init(allocator);
    defer provider.deinit();
    const providers = [_]external.Provider{provider.stream.provider()};

    var backend = try ExternalBackend.initWithPlatform(allocator, .{ .providers = &providers }, try net.Backend.init(allocator, 64, 4, frame_cap), 4, frame_cap);
    defer backend.deinit();
    const fd = try backend.startDial(1, .{ .external = .{
        .transport = model.transport.tcp,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    } });
    try std.testing.expectEqual(@as(i32, 0), (try awaitCompletion(&backend, 1)).result);
    try backend.submitSend(2, fd, "hello");
    try std.testing.expectEqual(@as(i32, 5), (try awaitCompletion(&backend, 2)).result);
    try backend.submitRecv(3, fd);
    const received = try awaitCompletion(&backend, 3);
    defer if (received.borrowed.active()) backend.recycleBorrowed(received);
    try std.testing.expectEqualStrings("hello", received.borrowed.recvBytes() orelse "");
    try echo_future.await(io);
    try backend.submitClose(4, fd);
    try std.testing.expectEqual(@as(i32, 0), (try awaitCompletion(&backend, 4)).result);
    try std.testing.expectEqual(@as(usize, 0), provider.recorder.violations);
}
