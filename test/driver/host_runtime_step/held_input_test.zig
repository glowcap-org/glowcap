//! A stepped Host posts its readiness wake after a step only when the next
//! step's sweep can move input it holds (ADR-0024). Input that cannot move
//! until more bytes arrive leaves the descriptor quiet, because those bytes
//! raise it themselves. Three scenarios drive a raw TCP partner whose writes
//! the test cuts, and the fourth scripts a resident's reads.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const net = glowcap.net;
const tcp = net.tcp;

const harness = @import("harness.zig");
const residents = @import("../host_runtime_multiplexed/residents.zig");
const raw_partner = @import("raw_partner.zig");
const RawPartner = raw_partner.RawPartner;
const Treasure = harness.Treasure;
const DialRecorder = harness.DialRecorder;

const max_rounds = 200;

/// A stepped server with one accepted raw partner whose hello crossed. The
/// partner's session is open and its hello is queued behind `extra_fetches`
/// fetches that go out in the same write.
const Accepted = struct {
    server: *driver.Server,
    partner: RawPartner,
    session: *driver.Session,
    ready_fd: i32,

    fn init(allocator: std.mem.Allocator, io: std.Io, extra_fetches: usize) !Accepted {
        const server = try driver.listen(
            allocator,
            io,
            .{ .symbols = &.{.tcp} },
            model.transport.tcp,
            .{ .designator = "127.0.0.1:0" },
            .ephemeral,
            harness.steppedQuiet(),
        );
        errdefer server.deinit();
        try server.publish("treasure", Treasure, .{});
        var designator_buf: [64]u8 = undefined;
        const designator = try server.localDesignator(&designator_buf);
        const addr = try tcp.parseDesignator(designator);
        const stream = try std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
        var partner = try RawPartner.init(allocator, io, stream, .dialer, "tcp", null, designator);
        errdefer partner.deinit();

        // The server's hello leaves on accept. The partner opens on it, then
        // answers with its own hello and any fetches in one write.
        var rounds: usize = 0;
        while (!partner.session.sessionOpen()) : (rounds += 1) {
            if (rounds == max_rounds) return error.ServerHelloNeverArrived;
            _ = try server.waitAcceptable(1);
            if (try partner.readSome(1) != 0) try partner.feedInbox();
        }
        for (0..extra_fetches) |_| _ = try partner.host.fetch(partner.session, "treasure");
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(allocator);
        try partner.takeWire(&wire);
        try partner.writeAll(wire.items);

        rounds = 0;
        while (!try server.waitAcceptable(10)) : (rounds += 1) {
            if (rounds == max_rounds) return error.NeverAcceptable;
        }
        return .{
            .server = server,
            .partner = partner,
            .session = try server.accept(),
            .ready_fd = try server.runtime.readinessDescriptor(),
        };
    }

    fn deinit(self: *Accepted) void {
        self.session.deinit();
        self.partner.deinit();
        self.server.deinit();
    }

    /// Step until the descriptor is quiet, so a leftover wake cannot fake
    /// the proof.
    fn settle(self: *Accepted) !void {
        for (0..max_rounds) |_| {
            if (!try raw_partner.readable(self.ready_fd)) return;
            _ = try self.server.runtime.stepAny(0);
        }
        return error.NeverQuiet;
    }

    /// Step on the descriptor until the partner has heard from the server.
    fn stepUntilReply(self: *Accepted) !void {
        for (0..max_rounds) |_| {
            _ = try raw_partner.becomesReadable(self.ready_fd, 10);
            _ = try self.server.runtime.stepAny(0);
            if (try self.partner.readSome(0) != 0) return;
        }
        return error.NoReply;
    }
};

fn fetchWire(partner: *RawPartner, out: *std.ArrayList(u8)) !void {
    _ = try partner.host.fetch(partner.session, "treasure");
    try partner.takeWire(out);
}

test "a stepped Host is quiet while a partner's frame is incomplete, and the rest of it wakes the descriptor and dispatches" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var rig = try Accepted.init(allocator, threaded.io(), 0);
    defer rig.deinit();
    try rig.session.attend();
    try rig.settle();

    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(allocator);
    try fetchWire(&rig.partner, &wire);

    // Two bytes of the frame's length prefix reach the Host.
    try rig.partner.writeAll(wire.items[0..2]);
    for (0..max_rounds) |_| {
        if (rig.session.hs.feed_tail.len == 2) break;
        try std.testing.expect(try raw_partner.becomesReadable(rig.ready_fd, 10_000));
        _ = try rig.server.runtime.stepAny(0);
    } else return error.PrefixNeverRead;
    // Nothing a resume can move is held, and the missing bytes raise the
    // descriptor themselves, so the descriptor goes quiet and a parked
    // embedder stays parked.
    try rig.settle();
    try std.testing.expectEqual(@as(usize, 2), rig.session.hs.feed_tail.len);

    // The rest of the frame crosses the kernel, wakes the descriptor, and
    // the next step dispatches the frame.
    try rig.partner.writeAll(wire.items[2..]);
    try std.testing.expect(try raw_partner.becomesReadable(rig.ready_fd, 10_000));
    try rig.stepUntilReply();
    try std.testing.expectEqual(@as(usize, 0), rig.session.hs.feed_tail.len);
}

test "a stepped Host stays quiet for whole frames held behind an unattended session's hello, and attending wakes it" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var rig = try Accepted.init(allocator, threaded.io(), 2);
    defer rig.deinit();

    // The frames coalesced behind the hello wait in the tail. The embedder
    // has not served the session, so the sweep skips it, and its own attend
    // is the wake.
    try std.testing.expect(rig.session.hs.feed_tail.len != 0);
    try rig.settle();
    try std.testing.expect(rig.session.hs.feed_tail.len != 0);

    try rig.session.attend();
    try std.testing.expect(try raw_partner.readable(rig.ready_fd));
    // The sweep dispatches the held frames, and the step reports that as
    // progress although no source was ready.
    try std.testing.expect(try rig.server.runtime.stepAny(0) != null);
    try rig.stepUntilReply();
}

test "a stepped Host wakes its embedder for whole frames held behind the hello that opened a dialed session" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var listener = try std.Io.net.IpAddress.listen(&address, io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var designator_buf: [32]u8 = undefined;
    const designator = try std.mem.print(&designator_buf, "127.0.0.1:{d}", .{listener.socket.address.getPort()});

    var dials = DialRecorder{};
    var runtime = try driver.HostRuntime.init(allocator, io, .{ .symbols = &.{.tcp} }, .ephemeral, harness.steppedQuiet());
    defer runtime.deinit();
    try runtime.publish("treasure", Treasure, .{});
    const ready_fd = try runtime.readinessDescriptor();
    var locator_buf: [tcp.designator_buf_len]u8 = undefined;
    try runtime.startDial(tcp.locatorFromAddress(&locator_buf, listener.socket.address), .inherit, 5, .{
        .ctx = &dials,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });

    var accepting: usize = 0;
    while (!try raw_partner.becomesReadable(listener.socket.handle, 0)) : (accepting += 1) {
        if (accepting == max_rounds) return error.DialNeverConnected;
        _ = try runtime.stepAny(1);
    }
    var partner = try RawPartner.init(allocator, io, try listener.accept(io), .acceptor, "tcp", null, designator);
    defer partner.deinit();

    // The partner opens on the dialer's hello, then answers with its own
    // hello and two fetches in one write.
    var rounds: usize = 0;
    while (!partner.session.sessionOpen()) : (rounds += 1) {
        if (rounds == max_rounds) return error.DialerHelloNeverArrived;
        _ = try runtime.stepAny(1);
        if (try partner.readSome(1) != 0) try partner.feedInbox();
    }
    for (0..2) |_| _ = try partner.host.fetch(partner.session, "treasure");
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(allocator);
    try partner.takeWire(&wire);
    try partner.writeAll(wire.items);

    rounds = 0;
    while (dials.opened_session == null) : (rounds += 1) {
        if (rounds == max_rounds) return error.DialNeverOpened;
        _ = try runtime.stepAny(10);
    }
    const session = dials.opened_session.?;
    // The step that opened the session read the frames behind the hello and
    // left them in the tail. No poll will report bytes that left the kernel,
    // so the descriptor stays readable until the next step resumes them.
    try std.testing.expect(session.feed_tail.len != 0);
    try std.testing.expect(try raw_partner.readable(ready_fd));
    // The sweep dispatches them, and the step reports that as progress
    // although no source was ready.
    try std.testing.expect(try runtime.stepAny(0) != null);
    try std.testing.expectEqual(@as(usize, 0), session.feed_tail.len);
    for (0..max_rounds) |_| {
        _ = try runtime.stepAny(0);
        if (try partner.readSome(0) != 0) break;
    } else return error.NoReply;
    try std.testing.expectEqual(@as(usize, 0), session.feed_tail.len);
    try runtime.releaseWire(session);
}

test "a stepped Host wakes its embedder when a read stopped at the opening hello left bytes in the resident" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    const Fixture = residents.ExternalAdoptionResident;
    var resident = Fixture{
        .wake = try net.wake_channel.WakeChannel.open(),
        .read_result = net.multiplexed_resident.would_block,
    };
    defer resident.wake.deinit();
    var observed = residents.ObservedOpen{};
    var runtime = try driver.HostRuntime.init(allocator, threaded.io(), .{}, .ephemeral, observed.steppedOpts());
    defer runtime.deinit();
    const profile: model.transport.Metadata = .{
        .symbol = Fixture.transport,
        .designator_scheme = .key,
        .wire_framing = .byte_stream,
        .max_packet_bytes = residents.frame_cap + 2048,
    };
    _ = try runtime.addResident(profile, resident.multiplexedResident());
    try runtime.core.ensureAdvertisedLocator(Fixture.transport);
    const designator = runtime.core.advertisedLocator(Fixture.transport).?.designator;
    try runtime.publish("treasure", Treasure, .{});

    // The partner's hello is one read of the connection, and the bytes of a
    // frame the partner has not finished are the next.
    var partner = try RawPartner.init(allocator, threaded.io(), null, .dialer, Fixture.transport, profile, designator);
    defer partner.deinit();
    var hello: std.ArrayList(u8) = .empty;
    defer hello.deinit(allocator);
    try partner.takeWire(&hello);
    const reads = [_][]const u8{ hello.items, "3:" };
    try runtime.startAdoptExternal(Fixture.transport, Fixture.conn_id, .accepted, 7, .{
        .ctx = &observed,
        .reserve = residents.ObservedOpen.reserve,
        .release = residents.ObservedOpen.release,
        .opened = residents.ObservedOpen.opened,
        .failed = residents.ObservedOpen.failed,
    });
    resident.inbound = &reads;
    _ = try resident.wake.nudge();
    const ready_fd = try runtime.readinessDescriptor();
    _ = try runtime.stepAny(0);

    // The read stopped at the frame that opened the session. The resident
    // reported its record once and will not report the second read again, so
    // the runtime owes the embedder a step that finishes it.
    try std.testing.expect(observed.did_open);
    try std.testing.expectEqual(@as(usize, 1), resident.inbound.len);
    try std.testing.expect(try raw_partner.readable(ready_fd));
    try std.testing.expect(try runtime.stepAny(0) != null);
    try std.testing.expectEqual(@as(usize, 0), resident.inbound.len);
}
