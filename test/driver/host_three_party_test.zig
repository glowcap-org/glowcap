//! The native three-party handoff, hermetic: three `driver.Host`s — an
//! exporter, a gifter, and a recipient — run the complete gifter-and-recipient
//! choreography over real loopback TCP sockets, no hand-built wire messages.
//! The gifter's published introducer simply *returns* the foreign capability
//! it fetched; the host's resolve interceptor turns that reply into a signed
//! give (deposit on the exporter leg, give to the caller), the recipient's
//! call settles as the typed `.give`, `Host.redeem` dials the exporter and
//! withdraws, and the routed call reaches the object directly. The exporter
//! serves both of its connections from one thread with `stepReadable`: a
//! withdraw that beats its deposit parks on the peer and settles when the
//! deposit lands (ADR-0056), which is what makes single-owner round-robin
//! serving correct. The live twins are `zig build goblins-handoff` (recipient
//! half against real Goblins) and `zig build deno-gifter-handoff` (all three
//! parties in the Deno binding).

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;
const tcp = net.tcp;

const frame_cap = 4096;

/// The gifted object, published by the exporter on every connection.
const Widget = struct {
    pub fn handle(self: *Widget, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "poke")) return error.NoSuchMethod;
        return .{ .string = "poked directly at the exporter" };
    }
};

/// The gifter's introducer: replies with the foreign capability it holds. The
/// host's interceptor is what turns this ordinary-looking reply into a give.
const Introducer = struct {
    widget: actors.Ref,
    pub fn handle(self: *Introducer, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "introduce")) return error.NoSuchMethod;
        return .{ .reference = .{ .far = self.widget.far } };
    }
};

/// One published bound address, written once by its listener's task and
/// spin-read by the task that dials it.
const Addr = struct {
    buf: [64]u8 = undefined,
    len: std.atomic.Value(usize) = .init(0),

    fn publish(self: *Addr, designator: []const u8) void {
        @memcpy(self.buf[0..designator.len], designator);
        self.len.store(designator.len, .release);
    }
    fn await_(self: *Addr, io: std.Io) []const u8 {
        while (true) {
            const n = self.len.load(.acquire);
            if (n != 0) return self.buf[0..n];
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .real) catch {};
        }
    }
};

const Shared = struct {
    exporter_addr: Addr = .{},
    gifter_addr: Addr = .{},
    gifter_fetched: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
};

/// The exporter: publish the widget on each accepted connection, serve the
/// gifter's leg until its fetch landed, then accept the recipient's redeem
/// dial and round-robin both legs — the deposit (gifter leg) and the parked
/// withdraw (recipient leg) settle in whichever order they arrive.
fn exporterTask(allocator: std.mem.Allocator, shared: *Shared) anyerror!void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var resident = tcp.Resident{ .io = io };
    var host = driver.Host.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x0e} ** 32, .{ .frame_cap = frame_cap });
    defer host.deinit();
    var server = try host.listen(resident.netlayer(), .{ .designator = "127.0.0.1:0" });
    defer server.close();
    var addr_buf: [64]u8 = undefined;
    shared.exporter_addr.publish(server.localDesignator(&addr_buf));
    const to_gifter = try server.accept();
    _ = try to_gifter.publish("widget", Widget, .{});
    while (!shared.gifter_fetched.load(.acquire)) {
        _ = try to_gifter.stepReadable(10);
    }
    const to_recipient = try server.accept();
    _ = try to_recipient.publish("widget", Widget, .{});
    while (!shared.done.load(.acquire)) {
        _ = try to_gifter.stepReadable(5);
        _ = try to_recipient.stepReadable(5);
    }
}

/// The gifter: fetch the widget from the exporter (its foreign home is
/// recorded by `fetch`), publish the introducer that hands it back, and serve
/// the recipient. The origination fires inside the serve, in the interceptor.
fn gifterTask(allocator: std.mem.Allocator, shared: *Shared) anyerror!void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var resident = tcp.Resident{ .io = io };
    var host = driver.Host.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x06} ** 32, .{ .frame_cap = frame_cap });
    defer host.deinit();

    const to_exporter = try host.dial(.{
        .transport = tcp.transport_name,
        .designator = shared.exporter_addr.await_(io),
        .hints = model.Hints.emptyFalse(),
    });
    const widget = try to_exporter.fetch("widget");
    shared.gifter_fetched.store(true, .release);

    var server = try host.listen(resident.netlayer(), .{ .designator = "127.0.0.1:0" });
    defer server.close();
    var addr_buf: [64]u8 = undefined;
    shared.gifter_addr.publish(server.localDesignator(&addr_buf));
    const to_recipient = try server.accept();
    _ = try to_recipient.publish("introducer", Introducer, .{ .widget = widget });
    while (!shared.done.load(.acquire)) {
        _ = try to_recipient.stepReadable(5);
        // The deposit leg the interceptor flushed needs its socket serviced
        // too, so the exporter's ack and any parked traffic keep moving.
        _ = try to_exporter.stepReadable(5);
    }
}

test "three hosts run the full three-party handoff hermetically: originate, give, redeem, direct call" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var shared = Shared{};
    var exporter_future = try io.concurrent(exporterTask, .{ allocator, &shared });
    var gifter_future = try io.concurrent(gifterTask, .{ allocator, &shared });
    // Whatever happens, unblock the serving tasks before awaiting them.
    defer {
        shared.done.store(true, .release);
        const e = exporter_future.await(io);
        const g = gifter_future.await(io);
        e catch |err| std.debug.print("exporter task: {s}\n", .{@errorName(err)});
        g catch |err| std.debug.print("gifter task: {s}\n", .{@errorName(err)});
    }

    var resident = tcp.Resident{ .io = io };
    var host = driver.Host.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x0c} ** 32, .{ .frame_cap = frame_cap });
    defer host.deinit();
    const to_gifter = try host.dial(.{
        .transport = tcp.transport_name,
        .designator = shared.gifter_addr.await_(io),
        .hints = model.Hints.emptyFalse(),
    });
    const introducer = try to_gifter.fetch("introducer");

    // The introduction: an ordinary call whose answer settles as the typed
    // third outcome, carrying the verbatim signed give.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const settled = try to_gifter.call(introducer, .{ .verb = "introduce", .args = &.{} }, arena.allocator());
    const give = switch (settled) {
        .give => |g| g,
        .fulfilled => return error.ExpectedGive,
        .broken => |reason| {
            std.debug.print("introduce broke: {s}\n", .{reason});
            return error.ExpectedGive;
        },
    };
    try std.testing.expect(give.give_bytes.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, give.exporter_locator_uri, "127.0.0.1") != null);

    // Redeem dials the exporter directly and withdraws; the returned ref
    // routes through the node to the fresh exporter connection.
    const widget = try host.redeem(to_gifter, give);
    const reply = try to_gifter.call(widget, .{ .verb = "poke", .args = &.{} }, arena.allocator());
    switch (reply) {
        .fulfilled => |arg| try std.testing.expectEqualStrings("poked directly at the exporter", arg.string),
        .broken => |reason| {
            std.debug.print("poke broke: {s}\n", .{reason});
            return error.PokeBroke;
        },
        .give => return error.ExpectedValue,
    }
}

// A crossed-hellos collision, staged deterministically: host B has an
// outbound dial to A in flight (registered, bytes not yet moving) when A's
// dial arrives at B's listener. B's accepted connection compares the two
// public identifiers (ADR-0030): the not-lower side aborts its inbound, the
// strictly lower side marks its outbound lost, so exactly one of the pair
// survives whichever way the keys order.
test "two hosts dialing each other collapse crossed hellos to one session" {
    const crypto = pancake.foundation.crypto;
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var resident = tcp.Resident{ .io = io };

    const seed_a = [_]u8{0x0a} ** 32;
    const seed_b = [_]u8{0x0b} ** 32;
    var host_a = driver.Host.initSeeded(allocator, io, &.{resident.netlayer()}, seed_a, .{ .frame_cap = frame_cap });
    defer host_a.deinit();
    var host_b = driver.Host.initSeeded(allocator, io, &.{resident.netlayer()}, seed_b, .{ .frame_cap = frame_cap });
    defer host_b.deinit();

    // Both hosts listen: each signs its real bound address into its dials,
    // which is the key the partner's registry compares against.
    var server_a = try host_a.listen(resident.netlayer(), .{ .designator = "127.0.0.1:0" });
    defer server_a.close();
    var server_b = try host_b.listen(resident.netlayer(), .{ .designator = "127.0.0.1:0" });
    defer server_b.close();
    var a_addr_buf: [64]u8 = undefined;
    const a_designator = server_a.localDesignator(&a_addr_buf);
    var b_addr_buf: [64]u8 = undefined;
    const b_designator = server_b.localDesignator(&b_addr_buf);

    // B's outbound to A is in flight: registered before its bytes move, the
    // window a crossed inbound must land in.
    const b_pid = crypto.derivePublicIdentifier(crypto.SecretKey.fromSeed(seed_b).publicKey());
    try host_b.hellos.registerOutbound(io, allocator, a_designator, b_pid);
    defer host_b.hellos.unregister(io, allocator, a_designator);

    // A dials B; A's start-session names A's bound address.
    var accept_future = try io.concurrent(acceptOne, .{&server_b});
    const a_to_b = try host_a.dial(.{
        .transport = tcp.transport_name,
        .designator = b_designator,
        .hints = pancake.ocapn.model.Hints.emptyFalse(),
    });
    const accepted = try accept_future.await(io);
    _ = a_to_b;
    // The handshake completed inside accept, but the queued start-session
    // event reaches the inbound hook on the first drain.
    try accepted.cv.flush();

    // Exactly one half of the pair lost, decided by the byte order of the two
    // public identifiers, computed here the same way the registry computes it.
    const a_pid = crypto.derivePublicIdentifier(crypto.SecretKey.fromSeed(seed_a).publicKey());
    const b_is_lower = std.mem.order(u8, &b_pid.bytes, &a_pid.bytes) == .lt;
    try std.testing.expectEqual(b_is_lower, host_b.hellos.shouldAbortOutbound(io, a_designator));
}

fn acceptOne(server: *driver.host.HostServer) anyerror!*driver.HostConnection {
    return server.accept();
}
