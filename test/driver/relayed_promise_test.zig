//! Waiting on a promise a partner handed you, end to end (ADR-0095).
//!
//! Three byte-fed hosts, no socket anywhere. The exporter hosts a widget. The
//! introducer holds that widget on its own connection to the exporter and
//! answers `introduce` with it as a *promise*, so its host proxies the promise
//! onto the recipient's session (ADR-0009) instead of shipping a number that
//! means nothing there. The recipient then does the thing pancake could not do
//! before: it listens on that proxied promise, hears the settlement, and finds
//! a signed give inside it, which its own host redeems by dialing the exporter.
//! One `poke` through the redeemed token proves the capability is live.
//!
//! Host sessions negotiate V1.0, so what this pins is the choreography, not
//! the profile neutrality of the notification seam; that lives at the engine
//! tier, in `test/engine/resolver_export_test.zig` and the listen section of
//! `test/engine/relay_resolution_test.zig`, where both profiles are paired.
//!
//! Validated against an injected defect, the one it found: with the flush
//! `Node.armHomeProxy` queues for the home session removed, the home
//! `op:listen` stays enqueued on a session no verb is driving, the exporter is
//! never asked, and the recipient waits forever on a promise nobody subscribed
//! to. The test fails at the dial. A green run therefore proves the home
//! subscription actually reached the exporter.

const std = @import("std");
const pancake = @import("pancake");
const host_pair = @import("../support/host_pair.zig");
const promise_capture = @import("../support/capture.zig");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;
const engine = pancake.ocapn.engine;

const Host = driver.core.Host;
const Pair = host_pair.Pair;
const CapturedRef = promise_capture.CapturedRef;
const CapturedString = promise_capture.CapturedString;

const frame_cap = 4096;

/// The exporter's object, the capability the whole scenario is about.
const Widget = struct {
    pub fn handle(self: *Widget, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "poke")) return error.NoSuchMethod;
        return .{ .string = "poked through a relayed promise" };
    }
};

/// The exporter's vendor: hands out the widget through an ordinary reply, so
/// the introducer comes by a raw wire position rather than a fetch's token.
const Vendor = struct {
    widget: model.Reference,
    pub fn handle(self: *Vendor, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "make")) return error.NoSuchMethod;
        return .{ .reference = self.widget };
    }
};

/// The introducer's actor: answers with a promise-kind token for something
/// homed on its *other* connection. Replying with it is what sends the host
/// down the promise-proxy path.
const Introducer = struct {
    promise: model.Reference,
    pub fn handle(self: *Introducer, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "introduce")) return error.NoSuchMethod;
        return .{ .reference = self.promise };
    }
};

/// One dial the recipient's host asked for, parked for the test to execute.
const ParkedDial = struct { ticket: engine.Node.PendingId, designator: []u8 };

/// Answer every host's queued effects: gift-id entropy inline (entropy is the
/// embedder's job), dials parked for the test, and `HostAction.flush` — the
/// embedder's write signal — ignored because the shuttle drains every outbound
/// queue anyway. The flush the header's injected defect removes is a different
/// queue: `Node.Action.flush` marks the home session dirty so its `op:listen`
/// is encoded at all, and nothing here substitutes for that.
fn drainActions(allocator: std.mem.Allocator, hosts: []const *Host, dials: *std.ArrayList(ParkedDial)) !bool {
    var did_work = false;
    for (hosts) |host| {
        while (try host.nextAction()) |action| {
            switch (action) {
                .need_gift_id => |n| {
                    const gift_id = [_]u8{0x7e} ** 32;
                    try host.provideGiftId(n.ticket, &gift_id);
                    did_work = true;
                },
                .dial => |d| {
                    const view = host.pendingDial(d.ticket) orelse return error.MissingPendingDial;
                    try dials.append(allocator, .{
                        .ticket = d.ticket,
                        .designator = try allocator.dupe(u8, view.designator),
                    });
                    did_work = true;
                },
                .flush, .settled, .failed, .close => {},
            }
        }
    }
    return did_work;
}

/// Shuttle and drain until the whole network is quiescent, bounded so a
/// ping-pong bug fails loud instead of spinning.
fn pumpToQuiescence(
    allocator: std.mem.Allocator,
    hosts: []const *Host,
    pairs: []const Pair,
    dials: *std.ArrayList(ParkedDial),
) !void {
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        const moved = try host_pair.shuttleAll(pairs);
        const acted = try drainActions(allocator, hosts, dials);
        if (!moved and !acted) return;
    }
    return error.PumpDidNotQuiesce;
}

test "a recipient listens on a relayed promise and redeems the give it settles with" {
    const allocator = std.testing.allocator;
    var exporter = Host.init(allocator, [_]u8{0x2e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var introducer_host = Host.init(allocator, [_]u8{0x26} ** 32, Host.Options.withFrameCap(frame_cap));
    defer introducer_host.deinit();
    var recipient = Host.init(allocator, [_]u8{0x2c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    const hosts = [_]*Host{ &exporter, &introducer_host, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    // The introducer dials the exporter and comes by the widget through a
    // reply, so it holds the exporter's own wire position for it.
    const i_to_e = try host_pair.openPair(&introducer_host, &exporter, "127.0.0.1:7801");
    const widget = try i_to_e.b.served.publish(&i_to_e.b.host.vat, "widget", Widget, .{});
    _ = try i_to_e.b.served.publish(&i_to_e.b.host.vat, "vendor", Vendor, .{ .widget = widget.nearRef() });
    var vendor = CapturedRef{};
    try introducer_host.vowOn(
        try introducer_host.fetch(i_to_e.a, "vendor"),
        .{ .ctx = &vendor, .func = CapturedRef.record },
    );
    try pumpToQuiescence(allocator, &hosts, &.{i_to_e}, &dials);
    var made = CapturedRef{};
    try introducer_host.vowOn(
        try introducer_host.send(i_to_e.a, try vendor.require(), .{ .verb = "make", .args = &.{} }),
        .{ .ctx = &made, .func = CapturedRef.record },
    );
    try pumpToQuiescence(allocator, &hosts, &.{i_to_e}, &dials);
    const held = try made.require();

    // Enroll that position as a *promise*. The kind is the caller's to supply:
    // a far reference encodes the same whether or not it has settled, so the
    // import row knows the position and nothing else, and routing reads the
    // kind off the enrolled token. The kind is named once here, on the reference
    // handed to the verb, and read back off what the verb returns. This is the
    // C-shaped core tier, which takes the position and the kind as separate
    // arguments; `driver.Session.enroll` takes and returns a whole `FarRef`, so
    // a position and a kind that disagree are unconstructible there.
    const as_promise = model.FarRef.promise(held.far.import_position.int());
    const enrolled = try introducer_host.enrollCapability(
        i_to_e.a,
        as_promise.import_position.int(),
        as_promise.kind,
    );
    const promise_token: model.Reference = .{
        .far = .{ .import_position = .from(enrolled), .kind = as_promise.kind },
    };

    // The recipient dials the introducer and asks for the introduction. The
    // reply is a promise homed on the introducer's *other* connection, so its
    // host mints a third-party import-promise on this session and arms one home
    // listen for it on the exporter connection.
    const r_to_i = try host_pair.openPair(&recipient, &introducer_host, "127.0.0.1:7802");
    _ = try r_to_i.b.served.publish(&r_to_i.b.host.vat, "introducer", Introducer, .{ .promise = promise_token });
    var introducer_ref = CapturedRef{};
    try recipient.vowOn(
        try recipient.fetch(r_to_i.a, "introducer"),
        .{ .ctx = &introducer_ref, .func = CapturedRef.record },
    );
    try pumpToQuiescence(allocator, &hosts, &.{ i_to_e, r_to_i }, &dials);
    var introduced = CapturedRef{};
    try recipient.vowOn(
        try recipient.send(r_to_i.a, try introducer_ref.require(), .{ .verb = "introduce", .args = &.{} }),
        .{ .ctx = &introduced, .func = CapturedRef.record },
    );
    try pumpToQuiescence(allocator, &hosts, &.{ i_to_e, r_to_i }, &dials);

    // What the recipient holds is a promise, not a capability: nothing has
    // settled it yet, and before this verb existed it had no way to ask.
    const proxied = try introduced.require();
    try std.testing.expect(proxied == .far);
    try std.testing.expectEqual(model.RefKind.promise, proxied.far.kind);

    // Ask. The listen reaches the introducer, which anchors it on the proxied
    // promise; the home listen already sent to the exporter settles; the
    // settlement is a capability the recipient cannot be handed by number, so
    // the introducer's host signs a give for it and the recipient's promise
    // fires carrying that give. The recipient's host redeems it, which surfaces
    // one dial.
    var settled = CapturedRef{};
    try recipient.vowOn(
        try recipient.listenTo(r_to_i.a, proxied),
        .{ .ctx = &settled, .func = CapturedRef.record },
    );
    try pumpToQuiescence(allocator, &hosts, &.{ i_to_e, r_to_i }, &dials);

    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    const parked = dials.items[0];

    // The test is the dial executor. The exporter publishes on the redeem
    // session too: a gift resolves against the withdrawing session's own
    // registry.
    const e_accepts_r = try host_pair.publishAndOpenAccepted(&exporter, "tcp", "127.0.0.1:7801", &.{});
    _ = try e_accepts_r.served.publish(&e_accepts_r.host.vat, "widget", Widget, .{});
    const redeem_view = recipient.pendingDial(parked.ticket) orelse return error.MissingPendingDial;
    const r_to_e = try recipient.openDialedLocator(.{
        .transport = redeem_view.transport,
        .designator = redeem_view.designator,
        .hints = model.Hints.emptyFalse(),
    });
    const redeem_pair = Pair{ .ah = &recipient, .a = r_to_e, .bh = &exporter, .b = e_accepts_r };
    const all_pairs = [_]Pair{ i_to_e, r_to_i, redeem_pair };
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expect(r_to_e.sessionOpen());
    try recipient.exporterDialed(parked.ticket, r_to_e);
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);

    // The listen settled with a routable token, and the token reaches the
    // exporter's object over the recipient's own connection.
    const token = try settled.require();
    try std.testing.expect(token == .far);
    var poked = CapturedString{};
    try recipient.vowOn(
        try recipient.send(r_to_i.a, token, .{ .verb = "poke", .args = &.{} }),
        .{ .ctx = &poked, .func = CapturedString.record },
    );
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expectEqualStrings("poked through a relayed promise", poked.text());

    try recipient.releaseSession(r_to_e);
    try exporter.releaseSession(e_accepts_r);
    try recipient.releaseSession(r_to_i.a);
    try introducer_host.releaseSession(r_to_i.b);
    try introducer_host.releaseSession(i_to_e.a);
    try exporter.releaseSession(i_to_e.b);
}
