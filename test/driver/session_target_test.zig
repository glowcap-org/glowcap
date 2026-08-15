//! Eventual-send target refusal on the owning `driver.Session`: `call` /
//! `send` / `tell` admit only an _object_ capability. A promise-kind
//! capability (an unresolved import promise) must be refused with
//! `Error.UncallableTarget`, not silently coerced into an object turn:
//! pipelining rides the returned Promise (`Promise.send`), never a promise-kind
//! target. The shapes that are not capabilities at all — a promise-kind local
//! export, a bare answer-promise — cannot even be lifted into the opaque
//! surface: the Host refuses them at the lift, so the facade has nothing to
//! gate.
//!
//! Driven over TCP loopback — the owning tier multiplexes its blocking waits
//! with poll, so it binds fd-backed transports only (ADR-0090). The positive
//! control is a genuine far object that still calls and settles. That shows
//! the gate refuses on _kind_, not by over-rejecting every capability.

const std = @import("std");
const pancake = @import("pancake");
const support_actors = @import("../support/actors.zig");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;
const tcp = net.tcp;
const ip = std.Io.net;

const frame_cap = 4096;

/// Session options for a real loopback dial. The budgets are finite on purpose:
/// an unbounded CapTP wait against a partner that goes quiet does not fail the
/// suite, it wedges the test binary, which reads as a hang rather than a bug.
const dial_opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

/// The published actor the positive control calls.
const Greeter = support_actors.StaticReplyValueActor("greet", "hello over loopback");

const DropServingSession = struct {
    owned: *?*driver.Session,
    dropped: *std.atomic.Value(bool),

    pub fn handle(self: *DropServingSession, ht: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        _ = .{ ht, args };
        if (!std.mem.eql(u8, verb, "drop")) return error.NoSuchMethod;
        const session = self.owned.* orelse return error.SessionAlreadyDropped;
        self.owned.* = null;
        session.deinit();
        self.dropped.store(true, .release);
        return .{ .string = "closing" };
    }
};

const SettlementFlag = struct {
    done: bool = false,

    fn fire(ctx: ?*anyopaque, _: actors.Resolution) void {
        const self: *SettlementFlag = @ptrCast(@alignCast(ctx.?));
        self.done = true;
    }
};

const CountLocal = struct {
    hits: *usize,

    pub fn handle(self: *CountLocal, _: *driver.HostTurn, verb: []const u8, _: []const driver.Value) !driver.Value {
        if (!std.mem.eql(u8, verb, "count")) return error.NoSuchMethod;
        self.hits.* += 1;
        return .{ .void = {} };
    }
};

/// Accept one partner over the bound listener, publish the greeter, and serve
/// until the client leaves. Mirrors the owning `Server` accept the bindings ride.
fn hostOnce(server: *driver.Server) anyerror!void {
    const session = try server.accept();
    defer session.deinit();
    _ = try session.publish("greeter", Greeter, .{});
    try session.serve();
}

test "session capability targets: promise-kind is refused, an object still calls" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(
        allocator,
        tcp_resident.netlayer(),
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        dial_opts,
    );
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    var host_future = try io.concurrent(hostOnce, .{server});

    const client_result = clientAsserts(allocator, io, address);

    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

fn hostDropsServingSession(server: *driver.Server, dropped: *std.atomic.Value(bool)) anyerror!void {
    var owned: ?*driver.Session = try server.accept();
    errdefer if (owned) |session| session.deinit();
    const session = owned.?;
    _ = try session.publish("dropper", DropServingSession, .{ .owned = &owned, .dropped = dropped });
    session.serve() catch |err| switch (err) {
        error.ConnectionClosed, error.ProtocolAbort => {},
        else => return err,
    };
    try std.testing.expect(owned == null);
    try std.testing.expect(dropped.load(.acquire));
}

test "Session.deinit inside its hosted callback releases at the public method boundary" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(
        allocator,
        tcp_resident.netlayer(),
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        dial_opts,
    );
    defer server.deinit();
    var address_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&address_buf));
    var dropped = std.atomic.Value(bool).init(false);
    var host_future = try io.concurrent(hostDropsServingSession, .{ server, &dropped });

    var client_resident = tcp.Resident{ .io = io };
    const netlayers = [_]net.netlayer.Netlayer{client_resident.netlayer()};
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const client = try driver.connect(
        allocator,
        &netlayers,
        tcp.locatorFromAddress(&designator_buf, address),
        .ephemeral,
        dial_opts,
    );
    defer client.deinit();
    const dropper = try client.fetch("dropper");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = client.call(dropper, "drop", &.{}, arena.allocator()) catch |err| switch (err) {
        error.ConnectionClosed, error.ProtocolAbort => {},
        else => return err,
    };

    try host_future.await(io);
    try std.testing.expect(dropped.load(.acquire));
}

test "Session.close keeps its session alive through callback-deferred release" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(
        allocator,
        tcp_resident.netlayer(),
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        dial_opts,
    );
    defer server.deinit();
    var address_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&address_buf));
    var host_future = try io.concurrent(hostOnce, .{server});

    var client_resident = tcp.Resident{ .io = io };
    const netlayers = [_]net.netlayer.Netlayer{client_resident.netlayer()};
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    var owned: ?*driver.Session = try driver.connect(
        allocator,
        &netlayers,
        tcp.locatorFromAddress(&designator_buf, address),
        .ephemeral,
        dial_opts,
    );
    errdefer if (owned) |session| session.deinit();
    const session = owned.?;
    var dropped = std.atomic.Value(bool).init(false);
    const dropper = try session.spawn(DropServingSession, .{ .owned = &owned, .dropped = &dropped });
    const promise = try session.send(dropper, "drop", &.{});
    var settled = SettlementFlag{};
    try promise.on(.{ .ctx = &settled, .func = SettlementFlag.fire });

    // Finish drives the already-observed local promise. Its behavior drops
    // this same Session; the wrapper release must remain deferred until the
    // blocking close has stopped reading the core session pointer.
    try session.close(.{ .finish = .unbounded });

    try std.testing.expect(owned == null);
    try std.testing.expect(dropped.load(.acquire));
    try std.testing.expect(settled.done);
    try host_future.await(io);
}

test "Session finish drives an ignored Promise admitted before close" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    const server = try driver.listen(
        allocator,
        tcp_resident.netlayer(),
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        dial_opts,
    );
    defer server.deinit();
    var address_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&address_buf));
    var host_future = try io.concurrent(hostOnce, .{server});

    var client_resident = tcp.Resident{ .io = io };
    const netlayers = [_]net.netlayer.Netlayer{client_resident.netlayer()};
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const session = try driver.connect(
        allocator,
        &netlayers,
        tcp.locatorFromAddress(&designator_buf, address),
        .ephemeral,
        dial_opts,
    );
    defer session.deinit();

    var hits: usize = 0;
    const counter = try session.spawn(CountLocal, .{ .hits = &hits });
    _ = try session.send(counter, "count", &.{});
    try session.close(.{ .finish = .unbounded });

    try std.testing.expectEqual(@as(usize, 1), hits);
    try host_future.await(io);
}

test "Session finish waits for an admitted beginSendNamed chain" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    const server = try driver.listen(
        allocator,
        tcp_resident.netlayer(),
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        dial_opts,
    );
    defer server.deinit();
    var address_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&address_buf));
    var host_future = try io.concurrent(hostOnce, .{server});

    var client_resident = tcp.Resident{ .io = io };
    const netlayers = [_]net.netlayer.Netlayer{client_resident.netlayer()};
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const session = try driver.connect(
        allocator,
        &netlayers,
        tcp.locatorFromAddress(&designator_buf, address),
        .ephemeral,
        dial_opts,
    );
    defer session.deinit();

    var pending: driver.PendingSend = undefined;
    defer pending.deinit();
    var settled = SettlementFlag{};
    try session.beginSendNamed(
        &pending,
        "greeter",
        "greet",
        &.{},
        .{ .ctx = &settled, .func = SettlementFlag.fire },
    );
    try session.close(.{ .finish = .unbounded });

    try std.testing.expect(settled.done);
    try host_future.await(io);
}

fn clientAsserts(allocator: std.mem.Allocator, io: std.Io, address: ip.IpAddress) !void {
    var tcp_resident = tcp.Resident{ .io = io };
    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
    var designator_buf: [net.tcp.plain.designator_buf_len]u8 = undefined;
    const client = try driver.connect(
        allocator,
        &netlayers,
        tcp.locatorFromAddress(&designator_buf, address),
        .ephemeral,
        dial_opts,
    );
    defer client.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Positive control: a genuine far object fetched from the partner calls
    // and settles. The gate refuses on kind, not by rejecting every capability.
    const greeter = try client.fetch("greeter");
    const settled = try client.call(greeter, "greet", &.{}, arena.allocator());
    try std.testing.expect(settled == .fulfilled and settled.fulfilled == .string);
    try std.testing.expectEqualStrings("hello over loopback", settled.fulfilled.string);

    // The promise-kind twin of the object import cannot even become a
    // capability: the import row's identity already names the object kind,
    // and the lift refuses the mismatch outright.
    const import_position = blk: {
        const wire = try client.runtime.core.lowerCapability(client.hs, greeter);
        break :blk wire.far.import_position;
    };
    try std.testing.expectError(error.ImportKindConflict, client.runtime.core.liftCapability(
        client.hs,
        .{ .far = .{ .import_position = import_position, .kind = .promise } },
    ));

    // A genuine promise-kind capability (a fresh promise import, lifted
    // through the core escape — the opaque surface itself never mints one
    // from a send): every eventual-send verb must refuse it, never coerce it
    // into an object turn.
    const fresh_promise_position: u64 = 40;
    try client.peer().importObject(fresh_promise_position);
    const far_promise = try client.runtime.core.liftCapability(
        client.hs,
        .{ .far = .{ .import_position = model.ImportPosition.from(fresh_promise_position), .kind = .promise } },
    );
    try std.testing.expectError(error.UncallableTarget, client.call(far_promise, "greet", &.{}, arena.allocator()));
    try std.testing.expectError(error.UncallableTarget, client.send(far_promise, "greet", &.{}));
    try std.testing.expectError(error.UncallableTarget, client.tell(far_promise, "greet", &.{}));

    // The shapes that are not capabilities cannot even enter the opaque
    // surface: a promise-kind local export and a bare answer-promise are
    // refused at the lift itself.
    const near_promise = model.Reference{ .near = .{ .export_position = model.ExportPosition.from(1), .kind = .promise } };
    try std.testing.expectError(error.UncallableTarget, client.runtime.core.liftCapability(client.hs, near_promise));
    const bare_promise = model.Reference{ .promise = .{ .answer_position = model.AnswerPosition.from(1) } };
    try std.testing.expectError(error.UncallableTarget, client.runtime.core.liftCapability(client.hs, bare_promise));
}
