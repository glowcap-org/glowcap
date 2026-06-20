//! Thin conformance host: canonical swiss-nums over `tcp-testing-only`.
//!
//! Protocol policy (crossed-hellos, stateless GC, bootstrap handoff) lives in the
//! library `driver` and `engine` layers. This file owns only the conformance
//! actors and the small interceptors the suite requires (promise-resolver,
//! sturdyref enlivener).

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
const Stream = std.Io.net.Stream;

const host = "127.0.0.1";
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

const SharedState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    listener: *tcp.Listener,
    /// The `host:port` this peer signs its own locator with — runtime state
    /// because `--port` can move the listening port off `default_port`.
    local_designator: []const u8,
    registry: driver.crossed_hellos.Registry = .{},
    /// One gift registry shared by every accepted connection's peer, so a gift
    /// deposited on the gifter's session is withdrawable on the recipient's.
    handoff_gifts: engine.bootstrap.GiftRegistry = .{},
    /// The registry carries no lock (the engine is externally synchronized), and
    /// this host serves each connection on its own thread — so every pump that
    /// can dispatch a `deposit-gift` / `withdraw-gift` on a peer sharing
    /// `handoff_gifts` runs under this mutex. The host owns the threads and may
    /// block, so the blocking io-aware `std.Io.Mutex` is the right tool here.
    gift_mutex: std.Io.Mutex = .init,
    gifter: GifterHub = .{},
};

// ── Gifter handoff orchestration across two connections ──────────────────────
//
// When pancake is the gifter, the recipient's enliven arrives on one connection
// while the exporter pancake must fetch from and deposit the gift with is a
// *different* connection. Each connection runs on its own thread, so the two
// coordinate through this hub: the recipient thread posts a request to the
// exporter connection's slot (matched by the exporter's session designator), the
// exporter thread runs the fetch/deposit and signs the give, and the recipient
// thread resolves the enliven once the give is back. Only serializable data
// crosses the hub, each thread still touches only its own peer.

/// The signed handoff-give the exporter thread produces, polled by the recipient
/// thread. Every field is read and written only under the hub mutex, so the two
/// threads never race. `recipient_gone` lets a recipient that tears down before
/// its give arrives hand ownership of this result (and the give bytes) to
/// whichever thread finishes last, so it is freed exactly once on every path.
const GifterResult = struct {
    give_bytes: ?[]u8 = null,
    failed: bool = false,
    done: bool = false,
    recipient_gone: bool = false,
};

/// A gifter request the recipient thread routes to an exporter connection.
const GifterRequest = struct {
    swiss: []u8,
    exporter_location_raw: []u8,
    recipient_key: [32]u8,
    result: *GifterResult,
};

/// One connection's registration in the hub: its partner designator (for routing)
/// and a slot for a pending request the exporter thread should serve.
const ExporterSlot = struct {
    designator: []u8,
    request: ?GifterRequest = null,
};

const GifterHub = struct {
    mutex: std.atomic.Mutex = .unlocked,
    slots: std.ArrayList(*ExporterSlot) = .empty,

    fn lock(self: *GifterHub) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *GifterHub) void {
        self.mutex.unlock();
    }

    /// Register a connection by its partner designator. Returns a caller-owned
    /// slot the connection polls for inbound gifter requests and unregisters on
    /// exit. Null on allocation failure.
    fn register(self: *GifterHub, allocator: std.mem.Allocator, designator: []const u8) ?*ExporterSlot {
        const slot = allocator.create(ExporterSlot) catch return null;
        slot.* = .{ .designator = allocator.dupe(u8, designator) catch {
            allocator.destroy(slot);
            return null;
        } };
        self.lock();
        defer self.unlock();
        self.slots.append(allocator, slot) catch {
            allocator.free(slot.designator);
            allocator.destroy(slot);
            return null;
        };
        return slot;
    }

    fn unregister(self: *GifterHub, allocator: std.mem.Allocator, slot: *ExporterSlot) void {
        self.lock();
        for (self.slots.items, 0..) |s, i| {
            if (s == slot) {
                _ = self.slots.swapRemove(i);
                break;
            }
        }
        // An exporter connection that closes with a request still parked in its
        // slot must not strand the recipient waiting on it: take the orphan out
        // and report failure so the recipient's enliven settles broken. The
        // recipient still owns its `result`, so `complete(..., null)` (not a free)
        // is the right hand-off.
        const orphan = slot.request;
        slot.request = null;
        self.unlock();
        if (orphan) |req| {
            allocator.free(req.swiss);
            allocator.free(req.exporter_location_raw);
            self.complete(allocator, req.result, null);
        }
        allocator.free(slot.designator);
        allocator.destroy(slot);
    }

    /// Route `request` to the connection whose partner designator matches
    /// `exporter_designator`. Returns true if a slot accepted it. An empty
    /// designator never routes: two unkeyed connections would both sit under ""
    /// and a request would claim whichever was free first, cross-routing between
    /// unrelated exporter sessions. Real peers always carry a host:port designator.
    fn postRequest(self: *GifterHub, exporter_designator: []const u8, request: GifterRequest) bool {
        if (exporter_designator.len == 0) return false;
        self.lock();
        defer self.unlock();
        for (self.slots.items) |slot| {
            if (slot.designator.len == 0) continue;
            if (std.mem.eql(u8, slot.designator, exporter_designator) and slot.request == null) {
                slot.request = request;
                return true;
            }
        }
        return false;
    }

    /// The exporter thread claims any request waiting in its slot.
    fn takeRequest(self: *GifterHub, slot: *ExporterSlot) ?GifterRequest {
        self.lock();
        defer self.unlock();
        const req = slot.request;
        slot.request = null;
        return req;
    }

    /// The exporter thread hands a finished give (or a failure) back to the
    /// recipient thread's result. If the recipient already tore down
    /// (`recipient_gone`), no one will consume the result, so the caller frees the
    /// give bytes and the result here; it is the last thread out. `allocator` is
    /// the shared process allocator every result and give was built with.
    fn complete(self: *GifterHub, allocator: std.mem.Allocator, result: *GifterResult, give_bytes: ?[]u8) void {
        self.lock();
        const gone = result.recipient_gone;
        if (!gone) {
            result.give_bytes = give_bytes;
            result.failed = give_bytes == null;
            result.done = true;
        }
        self.unlock();
        if (gone) {
            if (give_bytes) |b| allocator.free(b);
            allocator.destroy(result);
        }
    }

    /// The recipient connection is tearing down before consuming its give. Free
    /// the result safely against the exporter thread, which may be mid-flight:
    ///   * if an un-taken request still references it, reclaim that request (the
    ///     exporter will never run) and free the result outright;
    ///   * if the exporter already completed, consume and free what it left;
    ///   * otherwise mark `recipient_gone` and let the exporter's `complete` free
    ///     it when it finishes.
    /// All decisions are made under the lock, so the exporter and recipient never
    /// both free.
    fn cancelPendingRecipient(self: *GifterHub, allocator: std.mem.Allocator, result: *GifterResult) void {
        self.lock();
        for (self.slots.items) |slot| {
            if (slot.request) |req| {
                if (req.result == result) {
                    allocator.free(req.swiss);
                    allocator.free(req.exporter_location_raw);
                    slot.request = null;
                    self.unlock();
                    allocator.destroy(result);
                    return;
                }
            }
        }
        if (result.done) {
            self.unlock();
            if (result.give_bytes) |b| allocator.free(b);
            allocator.destroy(result);
            return;
        }
        result.recipient_gone = true;
        self.unlock();
    }

    fn isDone(self: *GifterHub, result: *GifterResult) bool {
        self.lock();
        defer self.unlock();
        return result.done;
    }
};

// ── Conformance actors ──────────────────────────────────────────────────────

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
        const target: actors.Ref = switch (msg.arg(0)) {
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
        const items = switch (msg.arg(0)) {
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

const PromiseResolver = struct {
    resolver_map: *std.AutoHashMapUnmanaged(u64, u64),

    pub fn handle(self: *PromiseResolver, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = msg;
        const peer = turn.vat.peer orelse return error.NotConnected;
        const answer_position = try peer.session_state.allocateExport();
        try peer.session_state.installInboundAnswer(answer_position);
        const resolver_export = try peer.session_state.allocateExport();
        try peer.session_state.registerExport(resolver_export);
        try self.resolver_map.put(turn.vat.allocator, resolver_export, answer_position);
        const pair = try turn.vat.allocator.alloc(model.Argument, 2);
        pair[0] = .{ .reference = .{ .near = model.NearRef.promise(answer_position) } };
        pair[1] = .{ .reference = .{ .near = model.NearRef.object(resolver_export) } };
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
    try turn.vat.bindExport(ref, export_position);
    return export_position;
}

// ── Entry point ─────────────────────────────────────────────────────────────

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

    const listen_addr = try tcp.parseHostPort(host, port);
    var listener = try tcp.Listener.bind(io, listen_addr);
    defer listener.deinit();

    var designator_buf: [32]u8 = undefined;
    const local_designator = try std.fmt.bufPrint(&designator_buf, "{s}:{d}", .{ host, port });
    var shared = SharedState{ .allocator = allocator, .io = io, .listener = &listener, .local_designator = local_designator };
    defer shared.registry.deinit(io, allocator);
    defer shared.handoff_gifts.deinit(allocator);
    defer shared.gifter.slots.deinit(allocator);

    std.debug.print(
        "PANCAKE-OCAPN-PEER-READY ocapn://{s}.tcp-testing-only?host={s}&port={d}\n",
        .{ CAR_FACTORY_BUILDER, host, port },
    );

    var accept_future = try io.concurrent(acceptLoop, .{ &shared, io });
    accept_future.await(io);
}

fn acceptLoop(shared: *SharedState, io: std.Io) void {
    var group: std.Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = shared.listener.server.accept(io) catch return;
        group.concurrent(io, serveOneConnection, .{ shared, io, stream }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                var s = stream;
                s.close(io);
                continue;
            },
        };
    }
}

fn serveOneConnection(shared: *SharedState, io: std.Io, stream_in: Stream) void {
    var enliven_group: std.Io.Group = .init;
    defer enliven_group.cancel(io);

    const allocator = shared.allocator;
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    peer.session_state.next_export_position = 1;

    _ = peer.registerBootstrapCap(ECHO) catch return;
    _ = peer.registerBootstrapCap(CAR_FACTORY_BUILDER) catch return;
    _ = peer.registerBootstrapCap(GREETER) catch return;
    _ = peer.registerBootstrapCap(PROMISE_RESOLVER) catch return;
    _ = peer.registerBootstrapCap(STURDYREF_ENLIVENER) catch return;

    const read_buf = allocator.alloc(u8, frame_cap) catch return;
    defer allocator.free(read_buf);
    const write_buf = allocator.alloc(u8, frame_cap) catch return;
    defer allocator.free(write_buf);

    var conn = net.tcp.connectionOver(io, &peer, stream_in, read_buf, write_buf) catch return;
    defer conn.deinit();

    var resolver_map: std.AutoHashMapUnmanaged(u64, u64) = .{};
    defer resolver_map.deinit(allocator);

    var cv = driver.ConnectedVat.over(allocator, &peer, conn);
    cv.serve_options = .{
        .crossed_hellos = &shared.registry,
        .gc_stateless = true,
    };

    const echo_id = peer.session_state.bootstrapLookup(ECHO) orelse 0;
    const cfb_id = peer.session_state.bootstrapLookup(CAR_FACTORY_BUILDER) orelse 0;
    const greeter_id = peer.session_state.bootstrapLookup(GREETER) orelse 0;
    const resolver_id = peer.session_state.bootstrapLookup(PROMISE_RESOLVER) orelse 0;
    const enlivener_id = peer.session_state.bootstrapLookup(STURDYREF_ENLIVENER) orelse 0;

    cv.vat.bindExport(cv.vat.spawn(Echo, .{}) catch return, echo_id) catch return;
    cv.vat.bindExport(cv.vat.spawn(Greeter, .{}) catch return, greeter_id) catch return;
    cv.vat.bindExport(cv.vat.spawn(CarFactoryBuilder, .{}) catch return, cfb_id) catch return;
    cv.vat.bindExport(cv.vat.spawn(PromiseResolver, .{ .resolver_map = &resolver_map }) catch return, resolver_id) catch return;
    cv.vat.bindExport(cv.vat.spawn(Unimplemented, .{}) catch return, enlivener_id) catch return;

    // One session identity for this whole connection. A three-party handoff where
    // pancake is the recipient signs its `desc:handoff-receive` with this key,
    // because the gifter named pancake's session public key as the give's
    // recipient key, so the handshake and the later withdraw must use the same
    // secret.
    var session_seed: [crypto.SEED_BYTES]u8 = undefined;
    io.randomSecure(&session_seed) catch return;
    const session_secret = crypto.SecretKey.fromSeed(session_seed);

    const local_designator = shared.local_designator;
    // The handshake pump must not hold the gift mutex: it blocks until the
    // partner's hello arrives, which can be never (a crossed-hellos abort), and
    // an unbounded hold would stall every other connection's dispatch. The peer
    // therefore runs the handshake on its private registry and joins the shared
    // one just below, before any bootstrap deliver can dispatch, non-handshake
    // traffic is refused until the session is open.
    cv.startKeyedSessionWithSecret(.{
        .transport = "tcp-testing-only",
        .designator = local_designator,
        .hints = model.Hints.emptyFalse(),
    }, session_secret) catch return;
    peer.shared_gift_registry = &shared.handoff_gifts;

    // Register this connection in the gifter hub under its partner's designator,
    // so a gifter enliven arriving on another connection can route a fetch/deposit
    // request here when this is the exporter it names.
    const slot = shared.gifter.register(allocator, peer.session_state.partnerDesignator() orelse "") orelse return;
    defer shared.gifter.unregister(allocator, slot);

    var hook_ctx = HookCtx{
        .shared = shared,
        .resolver_map = &resolver_map,
        .enliven_group = &enliven_group,
        .io = io,
        .handoff_secret = session_secret,
        .greeter_export = greeter_id,
        .enlivener_export = enlivener_id,
        .exporter_slot = slot,
    };
    cv.serve_options.hook_ctx = &hook_ctx;
    cv.serve_options.before_serve = beforeServe;
    // If this connection closes while it is still waiting on a gifter give it
    // routed to an exporter, hand the pending result off safely so it is freed on
    // every exit path and never stranded. `resolvePendingRecipient` clears
    // `pending_recipient` once it consumes the give, so this is a no-op on the
    // normal path.
    defer if (hook_ctx.pending_recipient) |pending| {
        shared.gifter.cancelPendingRecipient(allocator, pending.result);
    };

    while (true) {
        // Wait for readability *without* the gift mutex: an idle connection
        // parked in its poll must never starve another connection's dispatch.
        if (!cv.conn.hasBufferedInbound()) {
            if (cv.conn.socketHandle()) |handle| {
                var fds = [_]std.posix.pollfd{.{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 }};
                _ = std.posix.poll(&fds, 20) catch return;
            }
        }
        // The step can dispatch a deposit-gift / withdraw-gift against the
        // shared registry, so the dispatch runs under the host's gift mutex; the
        // zero timeout means the lock is held for work, never for waiting.
        const progress = blk: {
            shared.gift_mutex.lockUncancelable(shared.io);
            defer shared.gift_mutex.unlock(shared.io);
            break :blk cv.stepReadable(0) catch return;
        };
        if (progress) |p| {
            if (p == .closed) return;
        }
        // Between reads, advance any cross-connection gifter work: serve an
        // inbound gifter request as the exporter, and resolve our own enliven once
        // its give is back.
        serveGifterExport(&cv, &hook_ctx) catch return;
        resolvePendingRecipient(&cv, &hook_ctx) catch return;
    }
}

/// If this connection is the exporter for a pending gifter handoff, run it: fetch
/// the gifted object, deposit it as a gift, sign the `desc:handoff-give`, and hand
/// the give back to the recipient thread. Each step drives only this connection.
fn serveGifterExport(cv: *driver.ConnectedVat, hook: *HookCtx) !void {
    const request = hook.shared.gifter.takeRequest(hook.exporter_slot) orelse return;
    const allocator = hook.shared.allocator;
    defer {
        allocator.free(request.swiss);
        allocator.free(request.exporter_location_raw);
    }
    const give = gifterExportGive(cv, hook, request) catch |err| {
        std.debug.print("pancake-peer: gifter export failed: {s}\n", .{@errorName(err)});
        hook.shared.gifter.complete(allocator, request.result, null);
        return;
    };
    hook.shared.gifter.complete(allocator, request.result, give);
}

/// The exporter half of a gifter handoff over this connection: fetch the swiss,
/// deposit it under a fresh gift id, and return the signed give bytes (caller, via
/// the hub, owns them).
fn gifterExportGive(cv: *driver.ConnectedVat, hook: *HookCtx, request: GifterRequest) ![]u8 {
    const allocator = hook.shared.allocator;
    const peer = cv.peer;

    // 1. Fetch the gifted object from the exporter over this connection.
    const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &peer.session_state, request.swiss);
    try peer.send(prepared.message);
    var gifted: ?model.Reference = null;
    errdefer if (gifted) |g| model.freeReference(allocator, g);
    while (gifted == null) {
        // This pump dispatches inbound frames on a peer sharing the registry,
        // so it holds the gift mutex like the serve loop's step.
        const progress = blk: {
            hook.shared.gift_mutex.lockUncancelable(hook.shared.io);
            defer hook.shared.gift_mutex.unlock(hook.shared.io);
            break :blk try cv.conn.pump();
        };
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const owned = event.decodeOwned(allocator) catch continue;
            const match = engine.fetch.tryMatchFetchOutcome(allocator, prepared.resolver_export, prepared.answer_position, owned) catch continue;
            switch (match) {
                .settled => |outcome| switch (outcome) {
                    .fulfilled => |reference| gifted = reference,
                    .broken => |reason| {
                        allocator.free(reason);
                        return error.GifterFetchBroke;
                    },
                    .malformed => return error.GifterFetchMalformed,
                },
                .unrelated => |msg| model.freeMessage(allocator, msg),
            }
        }
        if (progress == .closed) return error.GifterConnectionClosed;
    }
    const obj = gifted.?;
    defer model.freeReference(allocator, obj);

    // 2. Deposit it as a gift under a fresh id (derived from the swiss so it is
    //    stable for this exchange). The exporter expects no answer.
    const gift_id = engine.handoff_recipient.sha256d(request.swiss);
    var deposit_args = [_]model.Argument{
        .{ .symbol = "deposit-gift" },
        .{ .bytes = gift_id[0..] },
        .{ .reference = obj },
    };
    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(0) },
        .args = &deposit_args,
        .answer = null,
    } });
    try cv.conn.flush();

    // 3. Sign a desc:handoff-give that names this exporter session and the gift.
    const our_pubkey = hook.handoff_secret.publicKey();
    const exporter_key = peer.session_state.partnerSessionKey() orelse return error.GifterNoExporterKey;
    const our_side = try engine.handoff_gifter.sideName(our_pubkey.asBytes());
    const exporter_side = try engine.handoff_gifter.sideName(exporter_key);
    const session = engine.handoff_gifter.sessionName(our_side, exporter_side);
    return engine.handoff_gifter.buildSignedGive(
        allocator,
        hook.handoff_secret,
        request.recipient_key[0..],
        request.exporter_location_raw,
        session[0..],
        our_side[0..],
        gift_id[0..],
    );
}

/// If this connection's enliven is awaiting a give from the exporter thread,
/// resolve it once the give is back: fulfill the enliven answer with the signed
/// `desc:handoff-give`.
fn resolvePendingRecipient(cv: *driver.ConnectedVat, hook: *HookCtx) !void {
    const pending = hook.pending_recipient orelse return;
    if (!hook.shared.gifter.isDone(pending.result)) return;
    const allocator = hook.shared.allocator;
    hook.pending_recipient = null;
    defer allocator.destroy(pending.result);

    const give_bytes = pending.result.give_bytes orelse {
        cv.peer.sendCopying(.{ .resolve = .{
            .answer = pending.answer,
            .resolution = .{ .@"break" = .{ .message = "gifter handoff failed" } },
        } }) catch {};
        try cv.flush();
        return;
    };
    defer allocator.free(give_bytes);

    var handoff = model.Handoff{ .give = .{
        .recipient_key = "",
        .exporter_location = "",
        .gifter_exporter_session = "",
        .gifter_side = "",
        .gift_id = "",
        .signature = "",
        .raw_signed = give_bytes,
    } };
    cv.peer.sendCopying(.{ .resolve = .{
        .answer = pending.answer,
        .resolution = .{ .fulfill = .{ .handoff = &handoff } },
    } }) catch {};
    try cv.flush();
}

const HookCtx = struct {
    shared: *SharedState,
    resolver_map: *std.AutoHashMapUnmanaged(u64, u64),
    enliven_group: *std.Io.Group,
    io: std.Io,
    handoff_secret: crypto.SecretKey,
    greeter_export: u64,
    enlivener_export: u64,
    /// This connection's hub slot, an exporter thread polls it for gifter work.
    exporter_slot: *ExporterSlot,
    /// Set when this connection is a gifter's recipient awaiting a give: the
    /// pending result and the enliven answer to resolve once it arrives.
    pending_recipient: ?PendingRecipient = null,
};

const PendingRecipient = struct {
    result: *GifterResult,
    answer: u64,
};

fn beforeServe(ctx: ?*anyopaque, cv: *driver.ConnectedVat, event: *engine.Event) !bool {
    const hook: *HookCtx = @ptrCast(@alignCast(ctx.?));
    const allocator = hook.shared.allocator;

    if (event.kind() == .deliver) {
        if (tryHandoffGiveFromEvent(hook, event)) return true;
        if (tryResolveFromEvent(allocator, cv.peer, hook.resolver_map, event)) return true;
        if (tryGifterEnliven(hook, cv, event)) return true;
        if (tryEnlivenFromEvent(hook, cv.peer, event)) return true;
    }
    return false;
}

/// Recognize a recipient's enliven of a sturdyref hosted by an exporter pancake
/// already has a session with: route a fetch/deposit request to that exporter
/// connection's thread (the gifter's exporter half), and remember the enliven
/// answer so the give it produces resolves it. Returns false — falling through to
/// the dialing enliven path — when no such exporter session is registered.
fn tryGifterEnliven(hook: *HookCtx, cv: *driver.ConnectedVat, event: *engine.Event) bool {
    const body = event.view() catch return false;
    const deliver = switch (body) {
        .deliver => |d| d,
        else => return false,
    };
    const target_id = switch (deliver.target) {
        .near => |near| near.export_position,
        else => return false,
    };
    if (target_id != hook.enlivener_export) return false;

    const allocator = hook.shared.allocator;
    const frame_bytes = event.frame.bytes();

    // The sturdyref names the exporter as a verbatim `ocapn-peer` locator followed
    // by the swiss-num bytes. Decode the locator (for its designator) and keep its
    // exact bytes (for the give's exporter location).
    const peer_start = std.mem.indexOf(u8, frame_bytes, "<10'ocapn-peer") orelse return false;
    var cursor = peer_start;
    const locator = codec.syrup.readLocatorOwned(allocator, frame_bytes, &cursor) catch return false;
    defer model.freePeerLocator(allocator, locator);
    const exporter_loc_raw = frame_bytes[peer_start..cursor];
    const swiss = codec.syrup.readBytes(frame_bytes, &cursor) catch return false;

    const answer = enlivenAnswer(deliver, &cv.peer.session_state) orelse return false;
    const recipient_key = cv.peer.session_state.partnerSessionKey() orelse return false;
    if (recipient_key.len != 32) return false;

    const swiss_owned = allocator.dupe(u8, swiss) catch return false;
    const loc_owned = allocator.dupe(u8, exporter_loc_raw) catch {
        allocator.free(swiss_owned);
        return false;
    };
    const result = allocator.create(GifterResult) catch {
        allocator.free(swiss_owned);
        allocator.free(loc_owned);
        return false;
    };
    result.* = .{};
    var request = GifterRequest{
        .swiss = swiss_owned,
        .exporter_location_raw = loc_owned,
        .recipient_key = undefined,
        .result = result,
    };
    @memcpy(&request.recipient_key, recipient_key[0..32]);

    var posted = false;
    for (0..20) |attempt| {
        if (hook.shared.gifter.postRequest(locator.designator, request)) {
            posted = true;
            break;
        }
        if (attempt != 19) {
            std.Io.sleep(hook.io, std.Io.Duration.fromMilliseconds(5), .real) catch break;
        }
    }
    if (!posted) {
        allocator.free(swiss_owned);
        allocator.free(loc_owned);
        allocator.destroy(result);
        return false;
    }
    hook.pending_recipient = .{ .result = result, .answer = answer };
    return true;
}

/// The virtual answer the engine installed for a V1.0 enliven deliver (no wire
/// answer, only a `resolve_me_desc`), or null when neither is present.
fn enlivenAnswer(deliver: model.view.Deliver, session: *const pancake.ocapn.session.Session) ?u64 {
    if (deliver.answer) |a| return a;
    if (deliver.resolve_me_desc) |rmd| {
        const import_position = switch (rmd) {
            .far => |far| far.import_position,
            .near => |near| near.export_position,
            else => return null,
        };
        return session.answerForResolverImport(import_position);
    }
    return null;
}

fn tryHandoffGiveFromEvent(hook: *HookCtx, event: *engine.Event) bool {
    const body = event.view() catch return false;
    const deliver = switch (body) {
        .deliver => |d| d,
        else => return false,
    };
    const target_id = switch (deliver.target) {
        .near => |near| near.export_position,
        else => return false,
    };
    if (target_id != hook.greeter_export) return false;
    if (std.mem.indexOf(u8, event.frame.bytes(), "desc:handoff-give") == null) return false;

    const give_bytes = codec.syrup.spanSignedHandoffGive(event.frame.bytes()) orelse return false;
    const owned_give = hook.shared.allocator.dupe(u8, give_bytes) catch return false;
    // The give names the exporter as a full `ocapn-peer` locator whose host and
    // port live in its hints, not in the designator (the `tcp-testing-only`
    // designator is just a uuid). Decode that locator the same way the enliven
    // path does and build the `host:port` the recipient dials.
    const owned_loc = exporterDialTarget(hook.shared.allocator, owned_give) orelse {
        hook.shared.allocator.free(owned_give);
        return false;
    };
    hook.enliven_group.concurrent(hook.io, handoffWithdrawTask, .{ hook.shared, hook.handoff_secret, owned_give, owned_loc }) catch {
        hook.shared.allocator.free(owned_give);
        hook.shared.allocator.free(owned_loc);
        return false;
    };
    return true;
}

/// Find the exporter's `ocapn-peer` locator in the signed give bytes, decode it
/// (hints included), and return an allocated `host:port` the recipient can dial.
/// Falls back to the locator designator when it has no host/port hints (a Goblins
/// `tcp` locator already carries `host:port` there).
fn exporterDialTarget(allocator: std.mem.Allocator, give_bytes: []const u8) ?[]u8 {
    const marker = "<10'ocapn-peer";
    const at = std.mem.indexOf(u8, give_bytes, marker) orelse return null;
    var cursor = at;
    const locator = codec.syrup.readLocatorOwned(allocator, give_bytes, &cursor) catch return null;
    defer model.freePeerLocator(allocator, locator);

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
        if (dial_port) |p| return std.fmt.allocPrint(allocator, "{s}:{s}", .{ h, p }) catch null;
    }
    // Goblins `tcp` locators carry `host:port` directly in the designator.
    return allocator.dupe(u8, locator.designator) catch null;
}

fn tryResolveFromEvent(
    allocator: std.mem.Allocator,
    peer: *engine.Peer,
    resolver_map: *std.AutoHashMapUnmanaged(u64, u64),
    event: *engine.Event,
) bool {
    const body = event.view() catch return false;
    const deliver = switch (body) {
        .deliver => |d| d,
        else => return false,
    };
    const target_id = switch (deliver.target) {
        .near => |near| near.export_position,
        else => return false,
    };
    const answer_position = resolver_map.get(target_id) orelse return false;
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
    peer.sendCopying(.{ .resolve = .{ .answer = answer_position, .resolution = resolution } }) catch return false;
    return true;
}

fn tryEnlivenFromEvent(hook: *HookCtx, peer: *engine.Peer, event: *engine.Event) bool {
    const body = event.view() catch return false;
    const deliver = switch (body) {
        .deliver => |d| d,
        else => return false,
    };
    const target_id = switch (deliver.target) {
        .near => |near| near.export_position,
        else => return false,
    };
    const enlivener_id = peer.session_state.bootstrapLookup(STURDYREF_ENLIVENER) orelse return false;
    if (target_id != enlivener_id) return false;

    const frame_bytes = event.frame.bytes();
    const marker = "<10'ocapn-peer";
    const peer_start = std.mem.indexOf(u8, frame_bytes, marker) orelse return false;
    var loc_cursor = peer_start;
    const owned_locator = codec.syrup.readLocatorOwned(hook.shared.allocator, frame_bytes, &loc_cursor) catch return false;

    hook.enliven_group.concurrent(hook.io, enlivenOutbound, .{ hook.shared, hook.io, owned_locator }) catch {
        model.freePeerLocator(hook.shared.allocator, owned_locator);
        return false;
    };
    return true;
}

fn enlivenOutbound(shared: *SharedState, io: std.Io, locator: model.PeerLocator) void {
    defer model.freePeerLocator(shared.allocator, locator);
    enlivenOutboundInner(shared, io, locator) catch {};
}

fn enlivenOutboundInner(shared: *SharedState, io: std.Io, locator: model.PeerLocator) !void {
    const allocator = shared.allocator;
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var connect_host: []const u8 = "127.0.0.1";
    var connect_port: u16 = 0;
    for (locator.hints.entries) |entry| {
        if (std.mem.eql(u8, entry.name, "host")) {
            connect_host = switch (entry.value) {
                .string => |s| s,
                else => "127.0.0.1",
            };
        }
        if (std.mem.eql(u8, entry.name, "port")) {
            connect_port = switch (entry.value) {
                .string => |s| std.fmt.parseInt(u16, s, 10) catch 0,
                .integer => |i| @intCast(@as(u64, @bitCast(i))),
                else => 0,
            };
        }
    }
    if (connect_port == 0) return error.MissingPort;

    const address = try tcp.parseHostPort(connect_host, connect_port);
    var conn = try tcp.connectAddress(io, &peer, address, read_buf, write_buf);
    defer conn.deinit();

    var seed: [crypto.SEED_BYTES]u8 = undefined;
    io.randomSecure(&seed) catch return error.HandshakeEntropyFailed;
    const secret = crypto.SecretKey.fromSeed(seed);
    const local_pubkey = secret.publicKey();
    try peer.sendKeyedStartSession(.v1_0, .{
        .transport = "tcp-testing-only",
        .designator = shared.local_designator,
        .hints = model.Hints.emptyFalse(),
    }, secret);
    _ = conn.pump() catch return;

    const local_pid = crypto.derivePublicIdentifier(local_pubkey);
    try shared.registry.registerOutbound(io, allocator, locator.designator, local_pid);
    defer shared.registry.unregister(io, allocator, locator.designator);

    while (true) {
        if (shared.registry.shouldAbortOutbound(io, locator.designator)) {
            try driver.crossed_hellos.maybeAbortOutbound(&shared.registry, locator.designator, &peer, &conn);
            return;
        }
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .real) catch return;
    }
}

fn handoffWithdrawTask(shared: *SharedState, secret: crypto.SecretKey, give_bytes: []const u8, exporter_location: []const u8) void {
    defer shared.allocator.free(give_bytes);
    defer shared.allocator.free(exporter_location);
    handoffWithdrawInner(shared, secret, give_bytes, exporter_location) catch {};
}

fn handoffWithdrawInner(shared: *SharedState, secret: crypto.SecretKey, give_bytes: []const u8, exporter_location: []const u8) !void {
    const allocator = shared.allocator;
    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    const host_sep = std.mem.indexOfScalar(u8, exporter_location, ':') orelse return error.BadLocation;
    const dial_host = exporter_location[0..host_sep];
    const dial_port = std.fmt.parseInt(u16, exporter_location[host_sep + 1 ..], 10) catch return error.BadLocation;

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const address = try tcp.parseHostPort(dial_host, dial_port);
    var conn = try tcp.connectAddress(shared.io, &peer, address, read_buf, write_buf);
    defer conn.deinit();

    try peer.sendKeyedStartSession(.v1_0, .{
        .transport = "tcp-testing-only",
        .designator = exporter_location,
        .hints = model.Hints.emptyFalse(),
    }, secret);
    while (!peer.sessionIsOpen()) {
        const progress = try conn.pump();
        if (progress == .closed) return error.ConnectionClosed;
    }

    const our_pubkey = secret.publicKey();
    const exporter_key = peer.session_state.partnerSessionKey() orelse return error.NoExporterKey;
    const signed_receive = try engine.handoff_recipient.signedReceiveFromGiveBytes(
        allocator,
        peer.session_state.limits,
        peer.giftRegistry(),
        secret,
        our_pubkey,
        exporter_key,
        give_bytes,
    );

    var handoff_msg = model.Handoff{ .receive = signed_receive.message() };
    try peer.sendCopying(.{
        .deliver = .{
            .target = .{ .far = model.FarRef.object(0) },
            .args = &.{ .{ .symbol = "withdraw-gift" }, .{ .handoff = &handoff_msg } },
            .answer = 1,
        },
    });
    _ = conn.pump() catch {};
}
