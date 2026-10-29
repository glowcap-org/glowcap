//! A failed turn's send that carries a capability from another session never
//! leaves (ADR-0058): the Node withdraws the batch it staged to project the
//! capability, before any gift is deposited, and the recipient sees nothing. A
//! successful turn leaves the batch staged for the pump to complete.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../support/core_host.zig");

const model = glowcap.ocapn.model;
const session_inspect = glowcap.ocapn.session.inspect;
const actors = glowcap.actors;
const driver = glowcap.driver;
const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const Capability = driver.core.Capability;

const harness = @import("harness.zig");
const frame_cap = harness.frame_cap;
const Widget = harness.Widget;
const ParkedDial = harness.ParkedDial;
const openPair = harness.openPair;
const pumpToQuiescence = harness.pumpToQuiescence;
const CapturedRef = harness.CapturedRef;

const TakeCounter = struct {
    takes: *usize,
    pub fn handle(self: *TakeCounter, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        _ = turn;
        if (msg.is("take")) self.takes.* += 1;
        return .{ .void = {} };
    }
};

const SendThen = struct {
    host: *Host,
    session: *HostSession,
    target: Capability,
    gift: Capability,

    pub fn handle(self: *SendThen, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        _ = turn;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        _ = try self.host.queueSendValues(self.session, self.target, "take", &.{.{ .capability = self.gift }}, arena.allocator());
        if (msg.is("fail")) return error.Refused;
        return .{ .void = {} };
    }
};

fn fetch(allocator: std.mem.Allocator, host: *Host, session: *HostSession, name: []const u8, hosts: []const *Host, pairs: anytype, dials: *std.ArrayList(ParkedDial)) !Capability {
    var held = CapturedRef{};
    try host.vowOn(try host.fetch(session, name), .{ .ctx = &held, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, hosts, pairs, dials);
    return host.liftCapability(session, try held.require());
}

fn exercise(verb: []const u8) !struct { staged: usize, takes: usize } {
    const allocator = std.testing.allocator;
    var a = test_host.init(allocator, @as([32]u8, @splat(0x4a)), Host.Options.withFrameCap(frame_cap));
    defer a.deinit();
    var b = test_host.init(allocator, @as([32]u8, @splat(0x4b)), Host.Options.withFrameCap(frame_cap));
    defer b.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x4c)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const to_a = try openPair(allocator, &a, &server, "127.0.0.1:7101", &dials);
    const to_b = try openPair(allocator, &b, &server, "127.0.0.1:7102", &dials);
    var takes: usize = 0;
    _ = try a.sessionPublish(to_a.a, "sink", TakeCounter, .{ .takes = &takes });
    _ = try b.sessionPublish(to_b.a, "gift", Widget, .{});
    const hosts = [_]*Host{ &a, &b, &server };
    const pairs = [_]harness.Pair{ to_a, to_b };
    const sink = try fetch(allocator, &server, to_a.b, "sink", &hosts, &pairs, &dials);
    defer server.releaseCapability(sink, 1) catch unreachable;
    const gift = try fetch(allocator, &server, to_b.b, "gift", &hosts, &pairs, &dials);
    defer server.releaseCapability(gift, 1) catch unreachable;

    const sender = try server.vat.spawn(SendThen, .{ .host = &server, .session = to_a.b, .target = sink, .gift = gift });
    _ = server.vat.near(sender, .{ .verb = verb }) catch |err| try std.testing.expectEqual(error.Refused, err);
    const staged = server.node.inline_passable_batches.rows.count();
    if (std.mem.eql(u8, verb, "fail")) try pumpToQuiescence(allocator, &hosts, &pairs, &dials);
    return .{ .staged = staged, .takes = takes };
}

test "core host: a failed turn's cross-session send is withdrawn before it leaves" {
    const result = try exercise("fail");
    try std.testing.expectEqual(@as(usize, 0), result.staged);
    try std.testing.expectEqual(@as(usize, 0), result.takes);
}

test "core host: a successful turn's cross-session send stays staged for the pump" {
    const result = try exercise("ok");
    try std.testing.expectEqual(@as(usize, 1), result.staged);
}

const PromiseResult = struct {
    proxies: usize,
    home_pending: usize,
    home_exports: usize,
    recipient_exports: usize,
    recipient_imports: usize,
    baseline_home_pending: usize,
    baseline_home_exports: usize,
    baseline_recipient_exports: usize,
    baseline_recipient_imports: usize,
};

/// A send that carries only a promise from another session has no gift to
/// wait for, so its batch finishes while it is staged: the Node installs the
/// home listener and the recipient's promise row in the same step that queues
/// the carrier on the Peer.
fn exercisePromise(options: Host.Options, verb: []const u8) !PromiseResult {
    const allocator = std.testing.allocator;
    var a = test_host.init(allocator, @as([32]u8, @splat(0x5a)), options);
    defer a.deinit();
    var b = test_host.init(allocator, @as([32]u8, @splat(0x5b)), options);
    defer b.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x5c)), options);
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    const to_a = try openPair(allocator, &a, &server, "127.0.0.1:7111", &dials);
    const to_b = try openPair(allocator, &b, &server, "127.0.0.1:7112", &dials);
    var takes: usize = 0;
    _ = try a.sessionPublish(to_a.a, "sink", TakeCounter, .{ .takes = &takes });
    const hosts = [_]*Host{ &a, &b, &server };
    const pairs = [_]harness.Pair{ to_a, to_b };
    const sink = try fetch(allocator, &server, to_a.b, "sink", &hosts, &pairs, &dials);
    defer server.releaseCapability(sink, 1) catch unreachable;

    // The server holds an unresolved promise imported from b's session. On
    // next an imported promise also carries its shortening listener, which
    // creates the row the Node's settling listener joins. The test never pumps
    // after this, so b sees none of the setup frames.
    const source = try to_b.a.served.port.peer.session_state.allocatePromiseExport();
    const home_state = &to_b.b.served.port.peer.session_state;
    try home_state.registerImport(.from(source.int()));
    if (home_state.captp_version == .next)
        try glowcap.ocapn.engine.listen.ensureShorteningListener(to_b.b.served.port.peer, .from(source.int()));
    const promise = try server.liftCapability(to_b.b, .{ .far = model.FarRef.promise(source.int()) });
    defer server.releaseCapability(promise, 1) catch unreachable;

    const home = to_b.b.served.port.peer;
    const recipient = to_a.b.served.port.peer;
    const baseline: PromiseResult = .{
        .proxies = 0,
        .home_pending = 0,
        .home_exports = 0,
        .recipient_exports = 0,
        .recipient_imports = 0,
        .baseline_home_pending = home.pending_send.pending().len,
        .baseline_home_exports = session_inspect.exportCount(&home.session_state),
        .baseline_recipient_exports = session_inspect.exportCount(&recipient.session_state),
        .baseline_recipient_imports = session_inspect.importCount(&recipient.session_state),
    };
    const sender = try server.vat.spawn(SendThen, .{ .host = &server, .session = to_a.b, .target = sink, .gift = promise });
    _ = server.vat.near(sender, .{ .verb = verb }) catch |err| try std.testing.expectEqual(error.Refused, err);
    var result = baseline;
    result.proxies = server.node.promise_proxies.count();
    result.home_pending = home.pending_send.pending().len;
    result.home_exports = session_inspect.exportCount(&home.session_state);
    result.recipient_exports = session_inspect.exportCount(&recipient.session_state);
    result.recipient_imports = session_inspect.importCount(&recipient.session_state);
    return result;
}

test "core host: a failed turn's promise-only cross-session send leaves nothing on the home session" {
    for ([_]Host.Options{ Host.Options.withFrameCap(frame_cap), harness.nextRouteOptions() }) |options| {
        const result = try exercisePromise(options, "fail");
        try std.testing.expectEqual(@as(usize, 0), result.proxies);
        try std.testing.expectEqual(result.baseline_home_pending, result.home_pending);
        try std.testing.expectEqual(result.baseline_home_exports, result.home_exports);
        try std.testing.expectEqual(result.baseline_recipient_exports, result.recipient_exports);
        try std.testing.expectEqual(result.baseline_recipient_imports, result.recipient_imports);
    }
}

test "core host: a successful turn's promise-only cross-session send keeps its home listener" {
    for ([_]Host.Options{ Host.Options.withFrameCap(frame_cap), harness.nextRouteOptions() }) |options| {
        const result = try exercisePromise(options, "ok");
        try std.testing.expectEqual(@as(usize, 1), result.proxies);
        try std.testing.expectEqual(result.baseline_home_pending + 1, result.home_pending);
    }
}
