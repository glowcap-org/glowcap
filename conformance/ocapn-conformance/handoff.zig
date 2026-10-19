//! Suite gifter/recipient interceptors: a `desc:handoff-give` to the
//! greeter, a sturdyref enliven to the enlivener, and the locator
//! helpers that teach the `tcp-testing-only` dialer the exporter's
//! address.
//!
//! `glowcap_peer.zig` owns the bootstrap actors, the promise-resolver
//! interceptor, and Host wiring. Shared tables live in `conf_state.zig`.

const std = @import("std");
const glowcap = @import("glowcap");
const peer_options = @import("ocapn_peer_options");
const conf_state = @import("conf_state.zig");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const actors = glowcap.actors;
const tcp = glowcap.net.tcp;
const driver = glowcap.driver;

const HostSession = driver.core.HostSession;
const PeerHandle = engine.PeerHandle;
const use_onion = peer_options.use_onion;

const ConfCtx = conf_state.ConfCtx;
const Shared = conf_state.Shared;
const GREETER = conf_state.GREETER;
const STURDYREF_ENLIVENER = conf_state.STURDYREF_ENLIVENER;
const transport_name = conf_state.transport_name;
/// The gifter fetch's settle listener: the fetched exporter object is foreign to
/// the recipient session, so claiming it (`interceptFulfilledRoute`) makes the
/// Host deposit it on the exporter and sign the give resolving the recipient's
/// enliven answer. Fires under the host callback latch, where only enqueueing
/// verbs are legal, and `interceptFulfilledRoute` only queues a `need_gift_id`.
const GifterWait = struct {
    shared: *Shared,
    recipient_peer: PeerHandle,
    answer: engine.AnswerTarget,

    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *GifterWait = @ptrCast(@alignCast(ctx.?));
        defer self.shared.allocator.destroy(self);
        switch (resolution) {
            .fulfilled => |value| {
                if (value == .reference and value.reference == .routed) {
                    _ = self.shared.host.node.interceptFulfilledRouteNamed(
                        self.recipient_peer,
                        self.answer,
                        value.reference.routed.id,
                    ) catch |err| self.shared.noteCallbackErr(err);
                }
            },
            else => {},
        }
    }
};

pub fn discardDeferred(shared: *Shared) void {
    for (shared.deferred.items) |action| action.deinit(shared.allocator);
    shared.deferred.clearRetainingCapacity();
}

pub fn drainDeferred(shared: *Shared) !void {
    var index: usize = 0;
    errdefer {
        for (shared.deferred.items[index..]) |action| action.deinit(shared.allocator);
        shared.deferred.clearRetainingCapacity();
    }
    while (index < shared.deferred.items.len) {
        const action = shared.deferred.items[index];
        index += 1;
        const result = switch (action) {
            .accept_give => |redeem| runRecipientGive(shared, redeem.session, redeem.give),
            .fetch => |fetch| runGifterFetch(
                shared,
                fetch.exporter,
                fetch.swiss,
                fetch.recipient_peer,
                fetch.answer,
            ),
            .dial => |designator| shared.runtime.startDial(.{
                .transport = transport_name,
                .designator = designator,
                .hints = model.Hints.emptyFalse(),
            }, .inherit, 0, dialObserver(shared)),
        };
        action.deinit(shared.allocator);
        try result;
    }
    shared.deferred.clearRetainingCapacity();
}

/// A gifter dial's outcome. The open is queued, because the observer runs
/// inside the runtime step where top-level Host verbs are refused.
fn dialObserver(shared: *Shared) driver.HostRuntime.SessionOpenObserver {
    return .{ .ctx = shared, .opened = dialOpened, .failed = dialFailed };
}

fn dialOpened(ctx: *anyopaque, _: u64, session: *HostSession) anyerror!void {
    const shared: *Shared = @ptrCast(@alignCast(ctx));
    try shared.owned.ensureUnusedCapacity(shared.allocator, 1);
    try shared.dialed.append(shared.allocator, session);
    shared.owned.appendAssumeCapacity(session);
}

fn dialFailed(_: *anyopaque, _: u64, failure: driver.OperationFailure) void {
    std.debug.print("glowcap-ocapn-peer: gifter dial failed: {s}\n", .{failure.chain.primaryName()});
}

/// When a gifter dial opens, run any enliven that was waiting for this
/// exporter to become reachable.
pub fn runPendingEnlivens(shared: *Shared, session: *HostSession) !void {
    const designator = session.served.port.peer.session_state.partnerDesignator() orelse return;
    var i: usize = 0;
    while (i < shared.pending.items.len) {
        const p = shared.pending.items[i];
        if (std.mem.eql(u8, p.exporter_uuid, designator)) {
            _ = shared.pending.swapRemove(i);
            defer shared.allocator.free(p.exporter_uuid);
            defer shared.allocator.free(p.swiss);
            try runGifterFetch(shared, session, p.swiss, p.recipient_peer, p.answer);
            continue;
        }
        i += 1;
    }
}

/// A typed `desc:handoff-give` delivered to the greeter: the recipient half.
/// Record the exporter's uuid→address, then hand the give to the Host, which
/// dials the exporter and withdraws the gift. The suite does not read the
/// redeemed capability, so `runRecipientGive` releases its Host identity while
/// the Host-owned deferred completion remains the terminal-result authority.
pub fn tryRecipientGive(conf: *ConfCtx, event: *engine.Event) !bool {
    const peer = conf.session.served.port.peer;
    const shared = conf.shared;
    const allocator = shared.allocator;
    const body = event.view();
    const deliver = switch (body.*) {
        .deliver => |d| d,
        else => return false,
    };
    const target_id = switch (deliver.target) {
        .near => |near| near.export_position.int(),
        else => return false,
    };
    const greeter_pos = peer.session_state.bootstrapLookup(GREETER) orelse return false;
    if (target_id != greeter_pos.int()) return false;
    if ((deliver.args.len() catch return false) != 1) return false;
    const argument = deliver.args.at(0) catch return false;
    const argument_handoff = switch (argument) {
        .handoff => |value| value,
        else => return false,
    };
    const give = switch (argument_handoff.project() catch return false) {
        .give => |value| value,
        .receive => return false,
    };

    // The parsed argument is the authority for both the signed envelope span
    // and exporter locator. Untrusted byte strings elsewhere in the
    // frame cannot impersonate either value.
    try recordLocatorAddr(shared, give.exporter);
    const give_owned = try give.toOwned(allocator);
    errdefer model.freeHandoffGive(allocator, give_owned);
    try shared.deferred.ensureUnusedCapacity(allocator, 1);
    shared.deferred.appendAssumeCapacity(.{ .accept_give = .{
        .session = conf.session,
        .give = give_owned,
    } });
    return true;
}

fn runRecipientGive(shared: *Shared, session: *HostSession, give: model.HandoffGive) !void {
    const capability_ref = try shared.host.acceptInlineGive(session, give);
    errdefer shared.host.releaseCapabilityTerminal(capability_ref, null);
    try shared.host.releaseCapability(capability_ref, 1);
}

/// A sturdyref enliven to the enlivener: the gifter half. Fetch the object on
/// the exporter session. Its later settle claims the reply into a signed give
/// (`GifterWait`). If the exporter session is already open, fetch now. Else dial
/// it and defer the fetch to `on_open`.
pub fn tryGifterEnliven(conf: *ConfCtx, event: *engine.Event) !bool {
    const peer = conf.session.served.port.peer;
    const shared = conf.shared;
    const allocator = shared.allocator;
    const body = event.view();
    const deliver = switch (body.*) {
        .deliver => |d| d,
        else => return false,
    };
    const target_id = switch (deliver.target) {
        .near => |near| near.export_position.int(),
        else => return false,
    };
    const enlivener_pos = peer.session_state.bootstrapLookup(STURDYREF_ENLIVENER) orelse return false;
    if (target_id != enlivener_pos.int()) return false;

    if ((deliver.args.len() catch return false) != 1) return false;
    const argument = deliver.args.at(0) catch return false;
    const sturdy = switch (argument) {
        .reference => |reference| switch (reference) {
            .sturdy => |value| value.project() catch return false,
            else => return false,
        },
        else => return false,
    };
    const locator = sturdy.peer;
    const swiss = sturdy.swissnum;

    try recordLocatorAddr(shared, locator);
    const existing = findSessionByDesignator(shared, locator.designator);

    // An answered enliven is the gifter handoff: fetch the exporter object, whose
    // settle signs the give resolving this answer. A fetch needs an open exporter
    // session, use one that exists, else dial and defer the fetch to `on_open`.
    if (event.deliverAnswerTarget()) |answer| {
        if (existing) |exporter| {
            const swiss_owned = try allocator.dupe(u8, swiss);
            errdefer allocator.free(swiss_owned);
            try shared.deferred.ensureUnusedCapacity(allocator, 1);
            shared.deferred.appendAssumeCapacity(.{ .fetch = .{
                .exporter = exporter,
                .swiss = swiss_owned,
                .recipient_peer = conf.session.peer_handle,
                .answer = answer,
            } });
            return true;
        }
        const swiss_owned = try allocator.dupe(u8, swiss);
        errdefer allocator.free(swiss_owned);
        const uuid_owned = try allocator.dupe(u8, locator.designator);
        errdefer allocator.free(uuid_owned);
        const designator_owned = try allocator.dupe(u8, locator.designator);
        errdefer allocator.free(designator_owned);
        try shared.pending.ensureUnusedCapacity(allocator, 1);
        try shared.deferred.ensureUnusedCapacity(allocator, 1);
        shared.pending.appendAssumeCapacity(.{
            .exporter_uuid = uuid_owned,
            .swiss = swiss_owned,
            .recipient_peer = conf.session.peer_handle,
            .answer = answer,
        });
        shared.deferred.appendAssumeCapacity(.{ .dial = designator_owned });
        return true;
    }

    // An unanswered enliven still opens the outbound session to the exporter,
    // and the crossed-hellos tiebreak (Host, ADR-0012) needs exactly that on
    // the wire; there is no answer to resolve, so no fetch follows.
    if (existing == null) {
        const designator_owned = try allocator.dupe(u8, locator.designator);
        errdefer allocator.free(designator_owned);
        try shared.deferred.ensureUnusedCapacity(allocator, 1);
        shared.deferred.appendAssumeCapacity(.{ .dial = designator_owned });
    }
    return true;
}

/// Fetch `swiss` on the exporter session and arm a `GifterWait` on the vow so
/// the fulfilled foreign object is claimed into a signed give for the recipient.
pub fn runGifterFetch(shared: *Shared, exporter: *HostSession, swiss: []const u8, recipient_peer: PeerHandle, answer: engine.AnswerTarget) !void {
    const wait = try shared.allocator.create(GifterWait);
    errdefer shared.allocator.destroy(wait);
    wait.* = .{ .shared = shared, .recipient_peer = recipient_peer, .answer = answer };
    const vow = try shared.host.fetch(exporter, swiss);
    try shared.host.vowOn(vow, .{ .ctx = wait, .func = GifterWait.fire });
}

// ── Locator helpers ──────────────────────────────────────────────────────────

/// Record a `tcp-testing-only` locator's uuid → `host:port` for the dialer.
fn recordLocatorAddr(shared: *Shared, locator: model.view.PeerLocator) !void {
    if (use_onion) return;
    const hostport = try hostPortFromHints(shared.allocator, locator) orelse return;
    defer shared.allocator.free(hostport);
    if (conf_state.g_addrs) |table| try table.put(locator.designator, hostport);
}

/// The `host:port` built from a locator's `host`/`port` hints, caller-owned,
/// or null when the peer's hints do not parse. Falls back to the designator
/// when the locator carries no host/port hints (a plain `tcp` locator's
/// designator is already `host:port`).
fn hostPortFromHints(allocator: std.mem.Allocator, locator: model.view.PeerLocator) !?[]u8 {
    const host_hint = locator.hints.findNamed("host") catch return null;
    const port_hint = locator.hints.findNamed("port") catch return null;
    const dial_host: ?[]const u8 = if (host_hint) |value|
        if (value == .string) value.string else null
    else
        null;
    const dial_port: ?[]const u8 = if (port_hint) |value|
        if (value == .string) value.string else null
    else
        null;
    if (dial_host) |h| {
        if (dial_port) |p| {
            const port_num = std.fmt.parseInt(u16, p, 10) catch return null;
            const addr = tcp.parseHostPort(h, port_num) catch return null;
            var buf: [tcp.designator_buf_len]u8 = undefined;
            return try allocator.dupe(u8, tcp.locatorFromAddress(&buf, addr).designator);
        }
    }
    return try allocator.dupe(u8, locator.designator);
}

/// The accepted session whose partner advertised `designator`, or null.
fn findSessionByDesignator(shared: *Shared, designator: []const u8) ?*HostSession {
    var it = shared.confs.valueIterator();
    while (it.next()) |conf| {
        const session = conf.*.session;
        if (!session.sessionOpen()) continue;
        const partner = session.served.port.peer.session_state.partnerDesignator() orelse continue;
        if (std.mem.eql(u8, partner, designator)) return session;
    }
    return null;
}
