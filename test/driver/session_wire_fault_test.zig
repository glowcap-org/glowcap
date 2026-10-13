//! `driver.Session`'s settle-path fault mapping, pinned with no timing: a
//! `driver.connect` session over the hermetic multiplexed resident whose
//! `try_read` is scripted to deliver exact bytes and then end. A mid-frame
//! truncation closes the wire and breaks every far vow, the blocking call's
//! own among them, with the cause's name. A malformed frame is a dispatch
//! refusal: the core aborts the session, the far vows break with the abort's
//! name, and the call propagates the refusal raw.
//! Linux-only, like the resident it drives. `test/all_test.zig` gates the
//! import.

const std = @import("std");
const glowcap = @import("glowcap");
const support_actors = @import("../support/actors.zig");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const driver = glowcap.driver;
const net = glowcap.net;
const tcp = net.tcp;
const syrup = glowcap.ocapn.codec.syrup;

const fixtures = @import("host_runtime_multiplexed/residents.zig");
const FakeResident = fixtures.FakeResident;
const opts = fixtures.opts;

const ip = std.Io.net;

/// The published actor: answers `greet` with a static greeting the scripted
/// inbound then replaces.
const Greeter = support_actors.StaticReplyValueActor("greet", "hello before the fault");

/// Captures the break reason the far vows carry when the wire closes.
const BreakCapture = struct {
    broke: bool = false,
    reason: [64]u8 = undefined,
    reason_len: usize = 0,

    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *BreakCapture = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .broken => |reason| {
                self.broke = true;
                const n = @min(reason.len, self.reason.len);
                @memcpy(self.reason[0..n], reason[0..n]);
                self.reason_len = n;
            },
            else => {},
        }
    }

    fn reasonIs(self: *const BreakCapture, expected: []const u8) bool {
        return std.mem.eql(u8, self.reason[0..self.reason_len], expected);
    }
};

/// Accept one partner, publish the greeter, and serve until the client's
/// wire closes.
fn serveOnce(server: *driver.Server) anyerror!void {
    var session = try server.accept();
    defer session.deinit();
    _ = try session.publish("greeter", Greeter, .{});
    try session.serve();
}

/// A whole `op:abort` frame, encoded so a caller can take a prefix of it to
/// drive a mid-frame EOF.
fn wholeFrame(allocator: std.mem.Allocator) !std.ArrayList(u8) {
    var message = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, .{
        .abort = .{ .kind = .unauthorized, .message = "never read whole" },
    });
    defer message.deinit();
    var framed: std.ArrayList(u8) = .empty;
    errdefer framed.deinit(allocator);
    _ = try net.appendFrameBytes(&framed, allocator, message.bytes());
    return framed;
}

/// How the blocking call reports the fault: settled broken with the wire's
/// close reason, or the raw dispatch refusal.
const Expected = union(enum) {
    broken: []const u8,
    err: anyerror,
};

const Scripted = struct {
    io: std.Io,
    address: ip.IpAddress,
    allocator: std.mem.Allocator,
    script: FakeResident.ScriptedInbound,
    expected: Expected,
    expected_reason: []const u8,
};

/// Dial the real server through the fake resident, complete the handshake
/// and the fetch over the socket, then script the next reads and drive a
/// blocking call into them. A second far vow observes the break: a vow holds
/// one listener and the call registers its own.
fn callIntoScriptedInbound(scenario: Scripted) !void {
    var fake = try FakeResident.init(scenario.allocator);
    defer fake.deinit();
    const providers = [_]driver.HostRuntime.ProviderRegistration{.{
        .profile = model.transport.Known.tcp.metadata(),
        .resident = fake.multiplexedResident(),
    }};
    var buf: [64]u8 = undefined;
    const locator = tcp.locatorFromAddress(&buf, scenario.address);
    var session = try driver.connect(scenario.allocator, scenario.io, .{ .residents = &providers }, locator, .ephemeral, opts);
    defer session.deinit();

    const greeter = try session.fetch("greeter");

    const observe = try session.send(greeter, "greet", &.{});
    var capture = BreakCapture{};
    try observe.on(.{ .ctx = &capture, .func = BreakCapture.fire });

    fake.scripted_inbound = scenario.script;
    var arena = std.heap.ArenaAllocator.init(scenario.allocator);
    defer arena.deinit();
    const outcome = session.call(greeter, "greet", &.{}, arena.allocator());
    switch (scenario.expected) {
        .broken => |reason| {
            const reply = try outcome;
            try std.testing.expect(reply == .broken);
            try std.testing.expectEqualStrings(reason, reply.broken);
        },
        .err => |expected| try std.testing.expectError(expected, outcome),
    }
    try std.testing.expect(capture.broke);
    if (!capture.reasonIs(scenario.expected_reason)) {
        std.debug.print("far vow broke with {s}\n", .{capture.reason[0..capture.reason_len]});
        return error.UnexpectedBreakReason;
    }
}

fn runScripted(script: FakeResident.ScriptedInbound, expected: Expected, expected_reason: []const u8) !void {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, opts);
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    var host_future = try io.concurrent(serveOnce, .{server});
    const client_result = callIntoScriptedInbound(.{
        .io = io,
        .address = address,
        .allocator = allocator,
        .script = script,
        .expected = expected,
        .expected_reason = expected_reason,
    });
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

test "session: a transport truncation during a blocking call closes the wire and breaks every far vow with the cause" {
    const allocator = std.testing.allocator;
    // The inbound the blocking call reads: the first half of a whole frame,
    // then EOF, a mid-frame truncation. The call's own vow is one of the far
    // vows the closure breaks, so the call settles broken with the cause
    // rather than unwinding.
    var framed = try wholeFrame(allocator);
    defer framed.deinit(allocator);
    const half = framed.items[0 .. framed.items.len / 2];
    try runScripted(.{ .bytes = half, .after = .end_of_stream }, .{ .broken = "TruncatedFrame" }, "TruncatedFrame");
}

test "session: a malformed frame during a blocking call is a dispatch refusal that propagates raw" {
    // Structurally invalid bytes: a length-mismatched symbol. The core refuses
    // the frame with its own abort, the wire closes, and the refusal unwinds
    // the blocking call instead of settling it.
    const allocator = std.testing.allocator;
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(allocator);
    _ = try net.appendFrameBytes(&framed, allocator, "<7'op:foo>");
    try runScripted(.{ .bytes = framed.items, .after = .end_of_stream }, .{ .err = error.ProtocolAbort }, "ProtocolAbort");
}
