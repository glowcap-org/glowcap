//! Suite gifter/recipient interceptors: a `desc:handoff-give` to the
//! greeter, a sturdyref enliven to the enlivener, and the locator
//! helpers that teach the `tcp-testing-only` dialer the exporter's
//! address.
//!
//! `pancake_peer.zig` owns the bootstrap actors, the promise-resolver
//! interceptor, and Host wiring. Shared tables live in `conf_state.zig`.

const std = @import("std");
const pancake = @import("pancake");
const peer_options = @import("ocapn_peer_options");
const conf_state = @import("conf_state.zig");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const codec = pancake.ocapn.codec;
const tcp = pancake.net.tcp;
const driver = pancake.driver;

const HostSession = driver.core.HostSession;
const PeerId = engine.PeerId;
const use_onion = peer_options.use_onion;

const ConfCtx = conf_state.ConfCtx;
const Shared = conf_state.Shared;
const ConfBridge = conf_state.ConfBridge;
const GREETER = conf_state.GREETER;
const STURDYREF_ENLIVENER = conf_state.STURDYREF_ENLIVENER;
const transport_name = conf_state.transport_name;
/// The gifter fetch's settle listener: the fetched exporter object is foreign to
/// the recipient session, so claiming it (`interceptFulfilledRoute`) makes the
/// Host deposit it on the exporter and sign the give resolving the recipient's
/// enliven answer. Fires under the host callback latch, where only enqueueing
/// verbs are legal — and `interceptFulfilledRoute` only queues a `need_gift_id`.
const GifterWait = struct {
    shared: *Shared,
    recipient_peer: PeerId,
    answer: model.AnswerName,

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
                    ) catch {};
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
            .accept_give => |redeem| shared.host.acceptGive(
                redeem.session,
                redeem.answer,
                redeem.give,
                redeem.uri,
            ),
            .fetch => |fetch| runGifterFetch(
                shared,
                fetch.exporter,
                fetch.swiss,
                fetch.recipient_peer,
                fetch.answer,
            ),
            .dial => |designator| shared.bridge.dialOutbound(.{
                .transport = transport_name,
                .designator = designator,
                .hints = model.Hints.emptyFalse(),
            }),
        };
        action.deinit(shared.allocator);
        try result;
    }
    shared.deferred.clearRetainingCapacity();
}

/// When a session opens, run any gifter enliven that was waiting for this
/// exporter to become reachable.
pub fn confOnOpen(ctx: ?*anyopaque, bridge: *ConfBridge, shell: *ConfBridge.Slot) anyerror!void {
    _ = bridge;
    const shared: *Shared = @ptrCast(@alignCast(ctx.?));
    const designator = shell.session.served.port.peer.session_state.partnerDesignator() orelse return;
    var i: usize = 0;
    while (i < shared.pending.items.len) {
        const p = shared.pending.items[i];
        if (std.mem.eql(u8, p.exporter_uuid, designator)) {
            _ = shared.pending.swapRemove(i);
            defer shared.allocator.free(p.exporter_uuid);
            defer shared.allocator.free(p.swiss);
            try runGifterFetch(shared, shell.session, p.swiss, p.recipient_peer, p.answer);
            continue;
        }
        i += 1;
    }
}

/// A `desc:handoff-give` delivered to the greeter: the recipient half. Record
/// the exporter's uuid→address, then hand the give to the Host, which dials the
/// exporter and withdraws the gift (`Node.acceptGive`). The greet deliver
/// carries no answer, so a throwaway inbound answer absorbs the redeem outcome
/// the suite never reads.
pub fn tryRecipientGive(conf: *ConfCtx, event: *engine.Event) !bool {
    const peer = conf.session.served.port.peer;
    const shared = conf.shared;
    const allocator = shared.allocator;
    const body = event.view() catch return false;
    const deliver = switch (body) {
        .deliver => |d| d,
        else => return false,
    };
    const target_id = switch (deliver.target) {
        .near => |near| near.export_position.int(),
        else => return false,
    };
    const greeter_pos = peer.session_state.bootstrapLookup(GREETER) orelse return false;
    if (target_id != greeter_pos.int()) return false;
    if (std.mem.indexOf(u8, event.bytes(), "desc:handoff-give") == null) return false;

    const give_bytes = codec.syrup.spanSignedHandoffGive(event.bytes()) orelse return false;

    // The give names the exporter as a verbatim ocapn-peer locator whose address
    // lives in `host`/`port` hints. Decode it for its uuid and address, record
    // the address for the dialer, and rebuild the dialable URI for the Host.
    const uri = locatorFromGive(allocator, shared, event.bytes()) orelse return false;
    defer allocator.free(uri);

    const give_owned = try allocator.dupe(u8, give_bytes);
    const uri_owned = allocator.dupe(u8, uri) catch |err| {
        allocator.free(give_owned);
        return err;
    };
    var owns_buffers = true;
    defer if (owns_buffers) {
        allocator.free(give_owned);
        allocator.free(uri_owned);
    };
    try shared.deferred.ensureUnusedCapacity(allocator, 1);

    const answer = (peer.session_state.allocateExport() catch return false).int();
    peer.session_state.installInboundAnswer(model.AnswerPosition.from(answer)) catch return false;
    shared.deferred.appendAssumeCapacity(.{ .accept_give = .{
        .session = conf.session,
        .answer = answer,
        .give = give_owned,
        .uri = uri_owned,
    } });
    owns_buffers = false;
    return true;
}

/// A sturdyref enliven to the enlivener: the gifter half. Fetch the object on
/// the exporter session; its later settle claims the reply into a signed give
/// (`GifterWait`). If the exporter session is already open, fetch now; else dial
/// it and defer the fetch to `on_open`.
pub fn tryGifterEnliven(conf: *ConfCtx, event: *engine.Event) !bool {
    const peer = conf.session.served.port.peer;
    const shared = conf.shared;
    const allocator = shared.allocator;
    const body = event.view() catch return false;
    const deliver = switch (body) {
        .deliver => |d| d,
        else => return false,
    };
    const target_id = switch (deliver.target) {
        .near => |near| near.export_position.int(),
        else => return false,
    };
    const enlivener_pos = peer.session_state.bootstrapLookup(STURDYREF_ENLIVENER) orelse return false;
    if (target_id != enlivener_pos.int()) return false;

    const frame_bytes = event.bytes();
    const peer_start = std.mem.indexOf(u8, frame_bytes, "<10'ocapn-peer") orelse return false;
    var cursor = peer_start;
    const locator = codec.syrup.readLocatorOwned(allocator, frame_bytes, &cursor) catch return false;
    defer model.freePeerLocator(allocator, locator);
    const swiss = readSyrupBytes(frame_bytes, &cursor) catch return false;

    recordLocatorAddr(shared, locator);
    const existing = findSessionByDesignator(shared, locator.designator);

    // An answered enliven is the gifter handoff: fetch the exporter object, whose
    // settle signs the give resolving this answer. A fetch needs an open exporter
    // session — use one that exists, else dial and defer the fetch to `on_open`.
    if (enlivenAnswer(deliver, peer)) |answer| {
        if (existing) |exporter| {
            const swiss_owned = try allocator.dupe(u8, swiss);
            errdefer allocator.free(swiss_owned);
            try shared.deferred.ensureUnusedCapacity(allocator, 1);
            shared.deferred.appendAssumeCapacity(.{ .fetch = .{
                .exporter = exporter,
                .swiss = swiss_owned,
                .recipient_peer = conf.session.peer_id,
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
            .recipient_peer = conf.session.peer_id,
            .answer = answer,
        });
        shared.deferred.appendAssumeCapacity(.{ .dial = designator_owned });
        return true;
    }

    // An unanswered enliven still opens the outbound session to the exporter,
    // which is what the crossed-hellos tiebreak (Host, ADR-0030) needs on the
    // wire; there is no answer to resolve, so no fetch follows.
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
pub fn runGifterFetch(shared: *Shared, exporter: *HostSession, swiss: []const u8, recipient_peer: PeerId, answer: model.AnswerName) !void {
    const wait = try shared.allocator.create(GifterWait);
    errdefer shared.allocator.destroy(wait);
    wait.* = .{ .shared = shared, .recipient_peer = recipient_peer, .answer = answer };
    const vow = try shared.host.fetch(exporter, swiss);
    try shared.host.vowOn(vow, .{ .ctx = wait, .func = GifterWait.fire });
}

// ── Locator helpers ──────────────────────────────────────────────────────────

/// Record a `tcp-testing-only` locator's uuid → `host:port` for the dialer.
fn recordLocatorAddr(shared: *Shared, locator: model.PeerLocator) void {
    if (use_onion) return;
    const hostport = hostPortFromHints(shared.allocator, locator) orelse return;
    defer shared.allocator.free(hostport);
    if (conf_state.g_addrs) |table| table.put(locator.designator, hostport);
}

/// The `host:port` built from a locator's `host`/`port` hints, caller-owned;
/// null when either hint is missing. Falls back to the designator when the
/// locator carries no host/port hints (a plain `tcp` locator's designator is
/// already `host:port`).
fn hostPortFromHints(allocator: std.mem.Allocator, locator: model.PeerLocator) ?[]u8 {
    var dial_host: ?[]const u8 = null;
    var dial_port: ?[]const u8 = null;
    for (locator.hints.entries) |entry| {
        if (std.mem.eql(u8, entry.name, "host")) {
            if (entry.value == .string) dial_host = entry.value.string;
        } else if (std.mem.eql(u8, entry.name, "port")) {
            if (entry.value == .string) dial_port = entry.value.string;
        }
    }
    if (dial_host) |h| {
        if (dial_port) |p| {
            const port_num = std.fmt.parseInt(u16, p, 10) catch return null;
            const addr = tcp.parseHostPort(h, port_num) catch return null;
            var buf: [tcp.designator_buf_len]u8 = undefined;
            return allocator.dupe(u8, tcp.locatorFromAddress(&buf, addr).designator) catch null;
        }
    }
    return allocator.dupe(u8, locator.designator) catch null;
}

/// Decode the exporter locator embedded in a signed give, record its address,
/// and return the dialable `ocapn://…` URI (caller-owned) the Host redeems with.
fn locatorFromGive(allocator: std.mem.Allocator, shared: *Shared, give_bytes: []const u8) ?[]u8 {
    const at = std.mem.indexOf(u8, give_bytes, "<10'ocapn-peer") orelse return null;
    var cursor = at;
    const locator = codec.syrup.readLocatorOwned(allocator, give_bytes, &cursor) catch return null;
    defer model.freePeerLocator(allocator, locator);
    recordLocatorAddr(shared, locator);
    return model.uri.writePeer(allocator, locator) catch null;
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

/// The virtual inbound answer a V1.0 enliven deliver resolves through — its
/// wire answer-position, or the answer the classifier allocated for its
/// `resolve_me_desc` resolver-callback.
fn enlivenAnswer(deliver: model.view.Deliver, peer: *engine.Peer) ?model.AnswerName {
    if (deliver.answer) |a| return .fromWire(a);
    if (deliver.resolve_me_desc) |rmd| {
        const import_position = switch (rmd) {
            .far => |far| far.import_position,
            .near => |near| model.ImportPosition.from(near.export_position.int()),
            else => return null,
        };
        const answer = peer.session_state.answerForResolverImport(import_position) orelse return null;
        return answer;
    }
    return null;
}

/// Read one syrup bytestring (`N:bytes`) at `cursor`, advancing past it — the
/// one raw decode this harness does outside the codec's public surface.
fn readSyrupBytes(bytes: []const u8, cursor: *usize) ![]const u8 {
    var i = cursor.*;
    var len: usize = 0;
    var saw_digit = false;
    while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') : (i += 1) {
        saw_digit = true;
        len = try std.math.add(usize, try std.math.mul(usize, len, 10), bytes[i] - '0');
    }
    if (!saw_digit or i >= bytes.len or bytes[i] != ':') return error.BadByteString;
    i += 1;
    if (bytes.len - i < len) return error.BadByteString;
    cursor.* = i + len;
    return bytes[i .. i + len];
}
