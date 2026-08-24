//! Three-party accountability through the production Host runtime.
//!
//! Three hosts meet over loopback TCP. A fetches C's accountable affordance,
//! then returns that foreign-homed capability to B. B's ordinary call redeems
//! the resulting handoff by opening its own session to C, and invokes the
//! affordance there. C must record B's attested AID, never A's.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const driver = pancake.driver;
const net = pancake.net;
const tcp = net.tcp;

const identity = @import("identity.zig");
const said = @import("said.zig");
const accountable = @import("accountable.zig");
const affordance = @import("affordance.zig");

const opts: driver.SessionOptions = .{
    .frame_cap = affordance.frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

const Introducer = struct {
    target: driver.Capability,

    pub fn handle(self: *Introducer, turn: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        _ = turn;
        _ = args;
        if (!std.mem.eql(u8, verb, "introduce")) return error.NoSuchMethod;
        return .{ .capability = self.target };
    }
};

const ExporterArgs = struct {
    server: *driver.Server,
    store: *accountable.Store,
    served: *usize,
    last_subject: *[said.SAID_LEN]u8,
    done: *std.atomic.Value(bool),
};

/// C publishes once, then serves both A's fetch/deposit session and B's later
/// withdrawal/invocation session from the Server's one owning HostRuntime.
fn serveExporter(args: ExporterArgs) !void {
    try args.server.publishGiftable(affordance.AFFORDANCE_NAME, affordance.HostAffordance, .{
        .state = .{
            .store = args.store,
            .served = args.served,
            .last_subject = args.last_subject,
        },
    });

    var gifter = try args.server.accept();
    defer gifter.deinit();
    var recipient: ?*driver.Session = null;
    defer if (recipient) |session| session.deinit();

    while (!args.done.load(.acquire)) {
        if (recipient == null and try args.server.waitAcceptable(20))
            recipient = try args.server.accept();
        _ = gifter.stepReadable(20) catch |err| switch (err) {
            error.ConnectionClosed, error.ProtocolAbort => break,
            else => |cause| return cause,
        };
    }
}

const GifterArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    netlayers: []const net.netlayer.Netlayer,
    exporter_designator: []const u8,
    listener: net.netlayer.Listener,
    done: *std.atomic.Value(bool),
};

/// A holds C's capability on one session and publishes an introducer to B on
/// another. Returning the opaque capability is the entire handoff operation.
fn serveGifter(args: GifterArgs) !void {
    const advertised = try args.listener.localLocator(args.allocator);
    defer model.freePeerLocator(args.allocator, advertised);

    var runtime = try driver.HostRuntime.init(args.allocator, args.io, args.netlayers, .ephemeral, opts);
    defer runtime.deinit();
    try runtime.core.setAdvertisedLocator(advertised);

    var exporter_addr_buf: [tcp.designator_buf_len]u8 = undefined;
    const exporter_session = try runtime.connectLocator(tcp.locatorFromAddress(
        &exporter_addr_buf,
        try tcp.parseDesignator(args.exporter_designator),
    ), .inherit);
    const exporter = try driver.Session.adopt(&runtime, exporter_session);
    defer exporter.deinit();
    const target = try exporter.fetch(affordance.AFFORDANCE_NAME);

    const accepted = try runtime.acceptWire(args.listener, args.listener.transportName());
    const recipient = try driver.Session.adopt(&runtime, accepted);
    defer recipient.deinit();
    _ = try recipient.publish("introducer", Introducer, .{ .target = target });

    while (!args.done.load(.acquire)) {
        _ = recipient.stepReadable(20) catch |err| switch (err) {
            error.ConnectionClosed, error.ProtocolAbort => break,
            else => |cause| return cause,
        };
    }
}

fn invoke(
    session: *driver.Session,
    target: driver.Capability,
    caller: *const identity.Identity,
    arena: std.mem.Allocator,
) !driver.Reply {
    const request = "read-thermostat";
    const att = try affordance.Attestation.sign(arena, caller.current, &caller.aid, request, false);
    return session.call(target, affordance.invoke_verb, &.{
        .{ .string = caller.aidSlice() },
        .{ .string = &att.verkey },
        .{ .string = request },
        .{ .string = &att.signature },
        .{ .string = caller.kelSlice() },
    }, arena);
}

test "three-party TCP handoff: C attributes B, not introducer A" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var a_identity = try identity.Identity.incept(allocator, io);
    defer a_identity.deinit();
    var b_identity = try identity.Identity.incept(allocator, io);
    defer b_identity.deinit();
    _ = try b_identity.rotate(io);
    var c_identity = try identity.Identity.incept(allocator, io);
    defer c_identity.deinit();

    var c_store = try accountable.Store.init(
        allocator,
        io,
        &c_identity,
        ".zig-cache/pancake-accountability/three-party-tcp",
    );
    defer c_store.deinit();
    var served: usize = 0;
    var last_subject: [said.SAID_LEN]u8 = @splat(0);

    var tcp_resident = tcp.Resident{ .io = io };
    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
    var done = std.atomic.Value(bool).init(false);

    var exporter = try driver.listen(
        allocator,
        tcp_resident.netlayer(),
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        opts,
    );
    defer exporter.deinit();
    var exporter_buf: [tcp.designator_buf_len]u8 = undefined;
    const exporter_designator = try allocator.dupe(u8, try exporter.localDesignator(&exporter_buf));
    defer allocator.free(exporter_designator);

    var gifter_listen = switch (tcp_resident.netlayer().listen(
        allocator,
        .{ .designator = "127.0.0.1:0" },
    )) {
        .admitted => |result| result,
        .failed => |failure| return failure.cause,
    };
    var gifter_listener = switch (gifter_listen.requireReady()) {
        .ready => |listener| listener,
        .failed => |failure| return failure.cause,
    };
    var gifter_listener_closed = false;
    defer if (!gifter_listener_closed) {
        if (gifter_listener.close()) |failure|
            std.debug.print("accountability gifter listener cleanup failed: {s}\n", .{@errorName(failure.cause)});
    };
    const gifter_locator = try gifter_listener.localLocator(allocator);
    defer model.freePeerLocator(allocator, gifter_locator);

    var exporter_future = try io.concurrent(serveExporter, .{ExporterArgs{
        .server = exporter,
        .store = &c_store,
        .served = &served,
        .last_subject = &last_subject,
        .done = &done,
    }});
    var gifter_future = try io.concurrent(serveGifter, .{GifterArgs{
        .allocator = allocator,
        .io = io,
        .netlayers = &netlayers,
        .exporter_designator = exporter_designator,
        .listener = gifter_listener,
        .done = &done,
    }});
    var hosts_joined = false;
    defer if (!hosts_joined) {
        done.store(true, .release);
        gifter_future.await(io) catch |err|
            std.debug.print("accountability gifter cleanup failed: {s}\n", .{@errorName(err)});
        exporter_future.await(io) catch |err|
            std.debug.print("accountability exporter cleanup failed: {s}\n", .{@errorName(err)});
    };

    const recipient = try driver.connect(
        allocator,
        &netlayers,
        gifter_locator,
        .ephemeral,
        opts,
    );
    defer recipient.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const introducer = try recipient.fetch("introducer");
    const introduced = try recipient.call(introducer, "introduce", &.{}, arena);
    try std.testing.expect(introduced == .fulfilled);
    try std.testing.expect(introduced.fulfilled == .capability);

    const outcome = try invoke(recipient, introduced.fulfilled.capability, &b_identity, arena);
    try std.testing.expect(outcome == .fulfilled);
    try std.testing.expect(outcome.fulfilled == .string);
    try std.testing.expectEqualStrings("ack:read-thermostat", outcome.fulfilled.string);

    done.store(true, .release);
    try gifter_future.await(io);
    try exporter_future.await(io);
    hosts_joined = true;

    const listener_close = gifter_listener.close();
    gifter_listener_closed = true;
    if (listener_close) |failure| return failure.cause;
    if (exporter.close()) |failure| return failure.cause;

    try std.testing.expectEqual(@as(usize, 1), served);
    try std.testing.expectEqualSlices(u8, b_identity.aidSlice(), &last_subject);
    try std.testing.expect(!std.mem.eql(u8, a_identity.aidSlice(), &last_subject));
    try std.testing.expectEqual(@as(usize, 1), try c_store.auditAll());
    _ = try c_store.currentRoot();
}
