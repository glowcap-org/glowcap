//! Thin conformance host: canonical swiss-nums over `tcp-testing-only`, served
//! by one `driver.core.Host` behind a `driver.Bridge` over a completion loop,
//! the single-thread, many-session host tier (ADR-0076), not a thread per
//! connection.
//!
//! The Host owns every protocol-policy seam the suite exercises through the
//! library rather than this file: crossed-hellos tiebreak (`Host.CrossedHellos`,
//! ADR-0030), one node identity reused as every session's signing key, and a
//! shared gift registry. What stays here is what the Host cannot know: the
//! conformance actors, and the three suite-specific interceptors the harness
//! requires on the serve path:
//!
//!   * the promise-resolver bootstrap object (a `fulfill`/`break` to a minted
//!     resolver export becomes an `op:resolve` on its paired answer);
//!   * a `desc:handoff-give` delivered to the greeter (the recipient half):
//!     the Host redeems it (`Node.acceptGive`) by dialing the named exporter
//!     and withdrawing the gift;
//!   * a sturdyref enliven to the enlivener (the gifter half): fetch the object
//!     on the exporter session, then claim the reply
//!     (`Node.interceptFulfilledRef`) so the Host deposits it and signs the give.
//!
//! The `tcp-testing-only` transport carries the exporter's address in locator
//! hints (`host`/`port`), not in its designator (a bare uuid), so the loop's
//! dialer resolves it through a conformance `Locator` backed by a uuid-to-address
//! table this file fills as it sees each locator. That is the one transport
//! seam the standard `tcp.DialResolver` does not cover.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const crypto = pancake.foundation.crypto;
const net = pancake.net;
const driver = pancake.driver;
const codec = pancake.ocapn.codec;
const tcp = net.tcp;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const PeerId = engine.PeerId;

/// The transport symbol the suite dials pancake on. Its designator is a bare
/// uuid; the dialable address lives in the locator's `host`/`port` hints.
const transport_name = "tcp-testing-only";

const host_ip = "127.0.0.1";
/// The suite dials this fixed port; `--port=N` (threaded by
/// `run-against-pancake.sh` from `zig build ocapn-conformance -Dport=N`)
/// moves it when 22055 is taken.
const default_port: u16 = 22055;
const frame_cap: usize = 1 << 16;

const CAR_FACTORY_BUILDER = "JadQ0++RzsD4M+40uLxTWVaVqM10DcBJ";
const ECHO = "IO58l1laTyhcrgDKbEzFOO32MDd6zE5w";
const GREETER = "VMDDd1voKWarCe2GvgLbxbVFysNzRPzx";
const PROMISE_RESOLVER = "IokCxYmMj04nos2JN1TDoY1bT8dXh6Lr";
const STURDYREF_ENLIVENER = "gi02I1qghIwPiKGKleCQAOhpy3ZtYRpB";

// ── The conformance dial resolver ────────────────────────────────────────────

/// uuid → `host:port`, filled on the loop thread whenever a give or sturdyref
/// names a `tcp-testing-only` exporter, read when the Host's redeem or gifter
/// dial resolves that locator. Single loop thread owns it, so no lock.
const AddrTable = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged([]u8) = .{},

    fn put(self: *AddrTable, uuid: []const u8, hostport: []const u8) void {
        const gop = self.entries.getOrPut(self.allocator, uuid) catch return;
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = self.allocator.dupe(u8, uuid) catch {
                _ = self.entries.remove(uuid);
                return;
            };
        }
        gop.value_ptr.* = self.allocator.dupe(u8, hostport) catch "";
    }

    fn get(self: *const AddrTable, uuid: []const u8) ?[]const u8 {
        return self.entries.get(uuid);
    }

    fn deinit(self: *AddrTable) void {
        var it = self.entries.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.entries.deinit(self.allocator);
    }
};

/// Process-global address table. The conformance peer is one Host on one loop
/// in one process, and the loop's `Locator.resolve` is a free function with no
/// context slot, so the table it consults lives here. `main` owns its storage.
var g_addrs: ?*AddrTable = null;

/// The loop's OCapN-locator → dial-target resolver. `tcp-testing-only` resolves
/// through the address table (the designator is a uuid, the address a hint we
/// recorded); every other transport defers to the standard `tcp.DialResolver`.
const ConformanceLocator = struct {
    pub fn resolve(
        transport: []const u8,
        designator: []const u8,
        direct_addresses_hint: []const u8,
    ) !std.Io.net.IpAddress {
        if (std.mem.eql(u8, transport, transport_name)) {
            const table = g_addrs orelse return error.InvalidAddress;
            const hostport = table.get(designator) orelse return error.InvalidAddress;
            return tcp.parseDesignator(hostport);
        }
        return tcp.DialResolver.resolve(transport, designator, direct_addresses_hint);
    }
};

const ConfLoop = net.completion.Loop(net.Backend, ConformanceLocator);
const ConfBridge = driver.Bridge(ConfLoop);

// ── Conformance actors ───────────────────────────────────────────────────────

const Echo = struct {
    pub fn handle(self: *Echo, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        return .{ .list = msg.args };
    }
};

const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        if (msg.args.len < 1) return error.BadGreet;
        const target: actors.Ref = switch (try msg.arg(0)) {
            .reference => |reference| switch (reference) {
                .far => |far_ref| .{ .far = far_ref },
                else => return error.BadGreet,
            },
            else => return error.BadGreet,
        };
        _ = try turn.send(target, .{ .verb = "", .args = &.{.{ .string = "Hello" }} });
        return .{ .void = {} };
    }
};

const CarFactoryBuilder = struct {
    pub fn handle(self: *CarFactoryBuilder, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = msg;
        const factory = try turn.spawn(CarFactory, .{});
        const export_position = try publishLocal(turn, factory);
        return .{ .reference = .{ .near = model.NearRef.object(export_position) } };
    }
};

const CarFactory = struct {
    pub fn handle(self: *CarFactory, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        if (msg.args.len < 1) return error.BadArgs;
        const items = switch (try msg.arg(0)) {
            .list => |l| l,
            else => return error.BadArgs,
        };
        if (items.len < 2) return error.BadArgs;
        const color = switch (items[0]) {
            .symbol => |s| s,
            .string => |s| s,
            else => return error.BadArgs,
        };
        const name = switch (items[1]) {
            .symbol => |s| s,
            .string => |s| s,
            else => return error.BadArgs,
        };
        const response = std.fmt.allocPrint(turn.vat.allocator, "Vroom! I am a {s} {s} car!", .{ color, name }) catch return error.OutOfMemory;
        const car = try turn.spawn(Car, .{ .response = response });
        const export_position = try publishLocal(turn, car);
        return .{ .reference = .{ .near = model.NearRef.object(export_position) } };
    }
};

const Car = struct {
    response: []const u8,
    pub fn handle(self: *Car, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        _ = msg;
        return .{ .string = self.response };
    }
    pub fn deinit(self: *Car, allocator: std.mem.Allocator) void {
        allocator.free(self.response);
    }
};

/// The promise-resolver bootstrap object: a deliver mints a fresh answer and a
/// resolver export, returns the `(vow, resolver)` pair, and records the
/// resolver→answer link in this session's map so a later `fulfill`/`break` to
/// the resolver resolves the vow (`tryPromiseResolve`).
const PromiseResolver = struct {
    conf: *ConfCtx,

    pub fn handle(self: *PromiseResolver, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = msg;
        const peer = turn.vat.peer orelse return error.NotConnected;
        const answer_position = model.AnswerPosition.from((try peer.session_state.allocateExport()).int());
        try peer.session_state.installInboundAnswer(answer_position);
        const resolver_export = try peer.session_state.allocateExport();
        try peer.session_state.registerExport(resolver_export);
        try self.conf.resolver_map.put(turn.vat.allocator, resolver_export.int(), answer_position.int());
        const pair = try turn.vat.allocator.alloc(model.Argument, 2);
        pair[0] = .{ .reference = .{ .near = model.NearRef.promise(answer_position.int()) } };
        pair[1] = .{ .reference = .{ .near = model.NearRef.object(resolver_export.int()) } };
        return .{ .list = pair };
    }
};

const Unimplemented = struct {
    pub fn handle(self: *Unimplemented, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        _ = msg;
        return error.NotImplemented;
    }
};

fn publishLocal(turn: *actors.Turn, ref: actors.Ref) !u64 {
    const peer = turn.vat.peer orelse return error.NotConnected;
    const export_position = try peer.session_state.allocateExport();
    try turn.vat.bindExport(ref, export_position.int());
    return export_position.int();
}

// ── Per-session and shared state ─────────────────────────────────────────────

/// Per-accepted-session conformance state: the resolver→answer map the promise
/// resolver fills and the serve interceptor reads. Allocated at adoption
/// (`publishConf`), freed at close (`confFreeConnCtx`).
const ConfCtx = struct {
    shared: *Shared,
    session: *HostSession,
    resolver_map: std.AutoHashMapUnmanaged(u64, u64) = .{},
};

/// A gifter enliven waiting for an exporter session to open before its fetch
/// can go out — the no-prior-connection gifter path. Bounded by concurrent
/// enlivens; `runGifterFetch` consumes one when its exporter opens.
const PendingEnliven = struct {
    exporter_uuid: []u8,
    swiss: []u8,
    recipient_peer: PeerId,
    answer: u64,
};

const Shared = struct {
    allocator: std.mem.Allocator,
    host: *Host,
    bridge: *ConfBridge,
    /// Per-session conformance state, keyed by session. Only accepted sessions
    /// (desks) register here; dialed exporter/redeem legs never do.
    confs: std.AutoHashMapUnmanaged(PeerId, *ConfCtx) = .{},
    /// Gifter enlivens whose exporter session was not yet open when the enliven
    /// arrived; drained in `on_open`.
    pending: std.ArrayListUnmanaged(PendingEnliven) = .empty,

    fn deinit(self: *Shared) void {
        var it = self.confs.valueIterator();
        while (it.next()) |c| {
            c.*.resolver_map.deinit(self.allocator);
            self.allocator.destroy(c.*);
        }
        self.confs.deinit(self.allocator);
        for (self.pending.items) |p| {
            self.allocator.free(p.exporter_uuid);
            self.allocator.free(p.swiss);
        }
        self.pending.deinit(self.allocator);
    }
};

/// The gifter fetch's settle listener: the fetched exporter object is foreign to
/// the recipient session, so claiming it (`interceptFulfilledRef`) makes the
/// Host deposit it on the exporter and sign the give resolving the recipient's
/// enliven answer. Fires under the host callback latch, where only enqueueing
/// verbs are legal — and `interceptFulfilledRef` only queues a `need_gift_id`.
const GifterWait = struct {
    shared: *Shared,
    recipient_peer: PeerId,
    answer: u64,

    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *GifterWait = @ptrCast(@alignCast(ctx.?));
        defer self.shared.allocator.destroy(self);
        switch (resolution) {
            .fulfilled => |value| {
                if (value == .reference and value.reference == .far) {
                    _ = self.shared.host.node.interceptFulfilledRef(
                        self.recipient_peer,
                        self.answer,
                        value.reference.far.import_position.int(),
                    ) catch {};
                }
            },
            else => {},
        }
    }
};

// ── Bridge hooks ─────────────────────────────────────────────────────────────

/// Publish the five bootstrap actors on every accepted session and allocate its
/// conformance state. Runs at adoption, before any inbound frame is served, so
/// a partner's first fetch cannot race the registration.
fn publishConf(ctx: ?*anyopaque, served: *driver.Served) anyerror!void {
    const shared: *Shared = @ptrCast(@alignCast(ctx.?));
    const session: *HostSession = @fieldParentPtr("served", served);

    const conf = try shared.allocator.create(ConfCtx);
    errdefer shared.allocator.destroy(conf);
    conf.* = .{ .shared = shared, .session = session };
    try shared.confs.put(shared.allocator, session.peer_id, conf);

    // The suite's GC modules expect wire-delta drops for every reference an actor
    // consumed and did not retain. The Host wires its own before-serve hook at
    // enroll; flip stateless GC on without disturbing it.
    served.serve_options.gc_stateless = true;

    _ = try served.publish(ECHO, Echo, .{});
    _ = try served.publish(GREETER, Greeter, .{});
    _ = try served.publish(CAR_FACTORY_BUILDER, CarFactoryBuilder, .{});
    _ = try served.publish(PROMISE_RESOLVER, PromiseResolver, .{ .conf = conf });
    _ = try served.publish(STURDYREF_ENLIVENER, Unimplemented, .{});
}

fn confFreeConnCtx(ctx: ?*anyopaque, conn_ctx: ?*anyopaque) void {
    const bridge: *ConfBridge = @ptrCast(@alignCast(ctx.?));
    const shell: *ConfBridge.Slot = @ptrCast(@alignCast(conn_ctx orelse return));
    const shared: *Shared = @ptrCast(@alignCast(bridge.publish_ctx.?));
    if (shared.confs.fetchRemove(shell.session.peer_id)) |kv| {
        kv.value.resolver_map.deinit(shared.allocator);
        shared.allocator.destroy(kv.value);
    }
    ConfBridge.freeConnCtx(ctx, conn_ctx);
}

/// The loop's serve hook: try the three conformance interceptors first (each
/// consumes the event and never serves it into the vat), else the bridge's
/// ordinary serve.
fn confServe(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
    const shell: *ConfBridge.Slot = @ptrCast(@alignCast(conn_ctx.?));
    const bridge = shell.bridge;
    const shared: *Shared = @ptrCast(@alignCast(bridge.publish_ctx.?));

    if (event.kind() == .deliver) {
        if (shared.confs.get(shell.session.peer_id)) |conf| {
            if (try tryPromiseResolve(conf, event)) {
                try bridge.drainActions();
                return;
            }
            if (try tryRecipientGive(conf, event)) {
                try bridge.drainActions();
                return;
            }
            if (try tryGifterEnliven(conf, event)) {
                try bridge.drainActions();
                return;
            }
        }
    }
    try ConfBridge.serve(conn_ctx, peer, event);
}

/// When a session opens, run any gifter enliven that was waiting for this
/// exporter to become reachable.
fn confOnOpen(ctx: ?*anyopaque, bridge: *ConfBridge, shell: *ConfBridge.Slot) anyerror!void {
    _ = bridge;
    const shared: *Shared = @ptrCast(@alignCast(ctx.?));
    const designator = shell.session.served.peer.session_state.partnerDesignator() orelse return;
    var i: usize = 0;
    while (i < shared.pending.items.len) {
        const p = shared.pending.items[i];
        if (std.mem.eql(u8, p.exporter_uuid, designator)) {
            runGifterFetch(shared, shell.session, p.swiss, p.recipient_peer, p.answer) catch {};
            shared.allocator.free(p.exporter_uuid);
            shared.allocator.free(p.swiss);
            _ = shared.pending.swapRemove(i);
            continue;
        }
        i += 1;
    }
}

// ── Interceptors ─────────────────────────────────────────────────────────────

/// A `fulfill`/`break` deliver to a resolver export minted by the promise
/// resolver: push the matching `op:resolve` on its paired answer. Returns false
/// for any deliver to a target that is not a live resolver.
fn tryPromiseResolve(conf: *ConfCtx, event: *engine.Event) !bool {
    const peer = conf.session.served.peer;
    const allocator = conf.shared.allocator;
    const body = event.view() catch return false;
    const deliver = switch (body) {
        .deliver => |d| d,
        else => return false,
    };
    const target_id = switch (deliver.target) {
        .near => |near| near.export_position.int(),
        else => return false,
    };
    const answer_position = conf.resolver_map.get(target_id) orelse return false;
    const arg_count = deliver.args.len() catch return false;
    if (arg_count < 2) return false;
    const verb = switch (deliver.args.at(0) catch return false) {
        .symbol => |sym| sym,
        else => return false,
    };
    const value = deliver.args.at(1) catch return false;
    const owned_value = value.toOwned(allocator) catch return false;
    const resolution: model.Resolution = if (std.mem.eql(u8, verb, "fulfill"))
        .{ .fulfill = owned_value }
    else if (std.mem.eql(u8, verb, "break"))
        .{ .@"break" = switch (owned_value) {
            .@"error" => |e| e,
            .symbol => |sym| .{ .message = sym },
            .string => |str| .{ .message = str },
            else => .{ .message = "broken" },
        } }
    else
        return false;
    peer.sendCopying(.{ .resolve = .{ .answer = model.AnswerPosition.from(answer_position), .resolution = resolution } }) catch return false;
    return true;
}

/// A `desc:handoff-give` delivered to the greeter: the recipient half. Record
/// the exporter's uuid→address, then hand the give to the Host, which dials the
/// exporter and withdraws the gift (`Node.acceptGive`). The greet deliver
/// carries no answer, so a throwaway inbound answer absorbs the redeem outcome
/// the suite never reads.
fn tryRecipientGive(conf: *ConfCtx, event: *engine.Event) !bool {
    const peer = conf.session.served.peer;
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

    const answer = (peer.session_state.allocateExport() catch return false).int();
    peer.session_state.installInboundAnswer(model.AnswerPosition.from(answer)) catch return false;
    shared.host.acceptGive(conf.session, answer, give_bytes, uri) catch return true;
    return true;
}

/// A sturdyref enliven to the enlivener: the gifter half. Fetch the object on
/// the exporter session; its later settle claims the reply into a signed give
/// (`GifterWait`). If the exporter session is already open, fetch now; else dial
/// it and defer the fetch to `on_open`.
fn tryGifterEnliven(conf: *ConfCtx, event: *engine.Event) !bool {
    const peer = conf.session.served.peer;
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
            const swiss_owned = allocator.dupe(u8, swiss) catch return true;
            defer allocator.free(swiss_owned);
            runGifterFetch(shared, exporter, swiss_owned, conf.session.peer_id, answer) catch return true;
            return true;
        }
        const swiss_owned = allocator.dupe(u8, swiss) catch return true;
        const uuid_owned = allocator.dupe(u8, locator.designator) catch {
            allocator.free(swiss_owned);
            return true;
        };
        shared.pending.append(allocator, .{
            .exporter_uuid = uuid_owned,
            .swiss = swiss_owned,
            .recipient_peer = conf.session.peer_id,
            .answer = answer,
        }) catch {
            allocator.free(uuid_owned);
            allocator.free(swiss_owned);
            return true;
        };
        shared.bridge.dialOutbound(transport_name, locator.designator, "") catch {};
        return true;
    }

    // An unanswered enliven still opens the outbound session to the exporter,
    // which is what the crossed-hellos tiebreak (Host, ADR-0030) needs on the
    // wire; there is no answer to resolve, so no fetch follows.
    if (existing == null) {
        shared.bridge.dialOutbound(transport_name, locator.designator, "") catch {};
    }
    return true;
}

/// Fetch `swiss` on the exporter session and arm a `GifterWait` on the vow so
/// the fulfilled foreign object is claimed into a signed give for the recipient.
fn runGifterFetch(shared: *Shared, exporter: *HostSession, swiss: []const u8, recipient_peer: PeerId, answer: u64) !void {
    const wait = try shared.allocator.create(GifterWait);
    errdefer shared.allocator.destroy(wait);
    wait.* = .{ .shared = shared, .recipient_peer = recipient_peer, .answer = answer };
    const vow = try shared.host.fetch(exporter, swiss);
    try shared.host.vowOn(vow, .{ .ctx = wait, .func = GifterWait.fire });
    try shared.bridge.drainActions();
}

// ── Locator helpers ──────────────────────────────────────────────────────────

/// Record a `tcp-testing-only` locator's uuid → `host:port` for the dialer.
fn recordLocatorAddr(shared: *Shared, locator: model.PeerLocator) void {
    const hostport = hostPortFromHints(shared.allocator, locator) orelse return;
    defer shared.allocator.free(hostport);
    if (g_addrs) |table| table.put(locator.designator, hostport);
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
            return allocator.dupe(u8, tcp.locator(&buf, addr).designator) catch null;
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
        const partner = session.served.peer.session_state.partnerDesignator() orelse continue;
        if (std.mem.eql(u8, partner, designator)) return session;
    }
    return null;
}

/// The virtual inbound answer a V1.0 enliven deliver resolves through — its
/// wire answer-position, or the answer the classifier allocated for its
/// `resolve_me_desc` resolver-callback.
fn enlivenAnswer(deliver: model.view.Deliver, peer: *engine.Peer) ?u64 {
    if (deliver.answer) |a| return a.int();
    if (deliver.resolve_me_desc) |rmd| {
        const import_position = switch (rmd) {
            .far => |far| far.import_position,
            .near => |near| model.ImportPosition.from(near.export_position.int()),
            else => return null,
        };
        const answer = peer.session_state.answerForResolverImport(import_position) orelse return null;
        return answer.int();
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

// ── Entry point ──────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // program name
    var port: u16 = default_port;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--port=")) {
            port = std.fmt.parseInt(u16, arg["--port=".len..], 10) catch {
                std.debug.print("pancake-ocapn-peer: --port must be an integer in 1..65535\n", .{});
                return error.BadPort;
            };
        } else {
            std.debug.print("pancake-ocapn-peer: unknown argument '{s}'\n", .{arg});
            return error.BadArgument;
        }
    }

    var addrs = AddrTable{ .allocator = allocator };
    defer addrs.deinit();
    g_addrs = &addrs;
    defer g_addrs = null;

    var seed: [crypto.SEED_BYTES]u8 = undefined;
    try io.randomSecure(&seed);

    var host = Host.init(allocator, seed, blk: {
        var o = Host.Options.withFrameCap(frame_cap);
        o.local_turn_budget = 64;
        break :blk o;
    });
    defer host.deinit();

    var shared = Shared{ .allocator = allocator, .host = &host, .bridge = undefined };
    defer shared.deinit();

    var loop: ConfLoop = undefined;
    var bridge = ConfBridge.init(allocator, &host, io, &loop, .{
        .publish = publishConf,
        .publish_ctx = &shared,
        .on_open = confOnOpen,
        .on_open_ctx = &shared,
    });
    defer bridge.deinit();
    shared.bridge = &bridge;

    loop = try ConfLoop.init(allocator, ConfBridge.makePeer, @ptrCast(&bridge), .{
        .frame_cap = frame_cap,
        .max_conns = 256,
        .listen = port,
        .make_conn_ctx = ConfBridge.makeConnCtx,
        .serve = confServe,
        .free_conn_ctx = confFreeConnCtx,
        .on_close = ConfBridge.onClose,
    });
    defer loop.deinit();

    const bound_port = loop.port.?;
    // The suite's `tcp-testing-only` designator is a bare uuid; pancake advertises
    // the reused CAR_FACTORY_BUILDER swiss as its own, and its address lives in
    // the banner's `host`/`port` the suite parses.
    try bridge.attach(transport_name, CAR_FACTORY_BUILDER, "");

    std.debug.print(
        "PANCAKE-OCAPN-PEER-READY ocapn://{s}.tcp-testing-only?host={s}&port={d}\n",
        .{ CAR_FACTORY_BUILDER, host_ip, bound_port },
    );

    try loop.run(.forever);
}
