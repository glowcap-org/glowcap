//! Thin conformance host: canonical swiss-nums over the build-selected
//! conformance transport, served by one `driver.core.Host` on a
//! `driver.HostRuntime`: one thread serving many sessions, not a thread per
//! connection.
//!
//! The Host owns every protocol-policy seam the suite exercises through the
//! library rather than this file: crossed-hellos tiebreak (`Host.CrossedHellos`,
//! ADR-0030), a distinct session identity derived from its process-fresh root
//! and monotonic counter (ADR-0097), and the live-session directory that reaches
//! each Peer-owned gift table. What stays here is what the Host cannot know:
//! the conformance actors, the
//! promise-resolver interceptor, and Host wiring. Gift/recipient interceptors
//! and the `tcp-testing-only` address table live in `handoff.zig` and
//! `conf_state.zig`.
//!
//!   * the promise-resolver bootstrap object (a `fulfill`/`break` to a minted
//!     resolver export becomes an `op:resolve` on its paired answer),
//!   * a `desc:handoff-give` delivered to the greeter (the recipient half),
//!     owned by `handoff.zig`,
//!   * a sturdyref enliven to the enlivener (the gifter half), owned by
//!     `handoff.zig`.

const std = @import("std");
const glowcap = @import("glowcap");
const peer_options = @import("ocapn_peer_options");
const conf_state = @import("conf_state.zig");
const handoff = @import("handoff.zig");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const actors = glowcap.actors;
const crypto = glowcap.foundation.crypto;
const net = glowcap.net;
const driver = glowcap.driver;
const tcp = net.tcp;
const onion = net.onion;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;

const use_onion = peer_options.use_onion;
const transport_name = conf_state.transport_name;
const AddrTable = conf_state.AddrTable;
const ConfCtx = conf_state.ConfCtx;
const Shared = conf_state.Shared;
const CAR_FACTORY_BUILDER = conf_state.CAR_FACTORY_BUILDER;
const ECHO = conf_state.ECHO;
const GREETER = conf_state.GREETER;
const PROMISE_RESOLVER = conf_state.PROMISE_RESOLVER;
const STURDYREF_ENLIVENER = conf_state.STURDYREF_ENLIVENER;

const host_ip = "127.0.0.1";
/// The suite dials this fixed port, `--port=N` (threaded by
/// `run-against-glowcap.sh` from `zig build ocapn-conformance -Dport=N`)
/// moves it when 22055 is taken.
const default_port: u16 = 22055;
const frame_cap: usize = 1 << 16;

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
        const peer = (turn.port orelse return error.NotConnected).peer;
        // This value crosses as desc:import-promise, so its authoritative
        // export slot must be unresolved from allocation onward. The paired
        // inbound answer stores the value that settles that promise.
        const promise = try peer.session_state.allocateLocalPromiseProjection();
        var promise_owned = true;
        errdefer if (promise_owned)
            peer.session_state.abandonLocalPromiseProjection(promise.export_position);
        const promise_export = promise.export_position;
        const answer_target = promise.answer_target;
        const resolver_export = try peer.session_state.allocateExport();
        var resolver_owned = true;
        errdefer if (resolver_owned)
            peer.session_state.releaseUnsharedExport(resolver_export);
        try self.conf.resolver_map.put(turn.vat.allocator, resolver_export.int(), answer_target);
        var mapping_owned = true;
        errdefer if (mapping_owned)
            std.debug.assert(self.conf.resolver_map.remove(resolver_export.int()));
        const pair = try turn.vat.allocator.alloc(model.Argument, 2);
        pair[0] = .{ .reference = .{ .near = model.NearRef.promise(promise_export.int()) } };
        pair[1] = .{ .reference = .{ .near = model.NearRef.object(resolver_export.int()) } };
        promise_owned = false;
        resolver_owned = false;
        mapping_owned = false;
        return .{ .list = pair };
    }
};

/// The supported sturdyref-enlivener deliveries are consumed by
/// `handoff.tryGifterEnliven` before Vat dispatch. Reaching this actor means the
/// message named the reserved bootstrap object but was not that wire form.
const InterceptedSturdyrefEnlivener = struct {
    pub fn handle(self: *InterceptedSturdyrefEnlivener, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        _ = msg;
        return error.UnsupportedConformanceEnliven;
    }
};

fn publishLocal(turn: *actors.Turn, ref: actors.Ref) !u64 {
    const peer = (turn.port orelse return error.NotConnected).peer;
    const export_position = try peer.session_state.allocateExport();
    try (turn.port orelse return error.NotConnected).bindExport(turn.vat, ref, export_position.int());
    return export_position.int();
}

// ── Session setup ────────────────────────────────────────────────────────────

/// Publish the five bootstrap actors on an accepted session, decorate its serve
/// policy, and only then attend it. The runtime holds the session's inbound at
/// open until it is attended, so a partner's first fetch cannot race the
/// registration.
fn admitAccepted(shared: *Shared, session: *HostSession) !void {
    const conf = try shared.allocator.create(ConfCtx);
    errdefer shared.allocator.destroy(conf);
    conf.* = .{
        .shared = shared,
        .session = session,
        .host_serve_options = session.served.serve_options,
    };
    try shared.confs.put(shared.allocator, session.peer_handle, conf);

    // Decorate, rather than replace, the Host's policy hook. Host.serveEvent
    // drains every event still queued after the runtime hands it the first
    // event in a batch, so only a per-event hook sees every event. Keeping the
    // interceptors here preserves crossed-hellos, handoff, and trace policy in
    // the saved hook.
    const served = &session.served;
    served.serve_options = .{
        .gc_stateless = true,
        .hook_ctx = conf,
        .before_serve = confBeforeServe,
    };
    const vat = &session.host.vat;
    _ = try served.publish(vat, ECHO, Echo, .{});
    _ = try served.publish(vat, GREETER, Greeter, .{});
    _ = try served.publish(vat, CAR_FACTORY_BUILDER, CarFactoryBuilder, .{});
    _ = try served.publish(vat, PROMISE_RESOLVER, PromiseResolver, .{ .conf = conf });
    _ = try served.publish(vat, STURDYREF_ENLIVENER, InterceptedSturdyrefEnlivener, .{});
    try shared.runtime.attendSession(session);
}

/// Release every owned session whose wire has closed, with its conformance
/// state.
fn releaseClosed(shared: *Shared) void {
    var i: usize = 0;
    while (i < shared.owned.items.len) {
        const session = shared.owned.items[i];
        if (session.lifecyclePhase() == .active) {
            i += 1;
            continue;
        }
        _ = shared.owned.swapRemove(i);
        if (shared.confs.fetchRemove(session.peer_handle)) |kv| {
            kv.value.resolver_map.deinit(shared.allocator);
            shared.allocator.destroy(kv.value);
        }
        shared.runtime.releaseWire(session) catch |err|
            std.debug.print("glowcap-ocapn-peer: session release failed: {s}\n", .{@errorName(err)});
    }
}

/// Everything a step classified but could not run under its callback latch:
/// set up the sessions it opened, run the Host effects the interceptors
/// deferred, and release the sessions it closed. A failed effect belongs to
/// the session that raised it. The peer reports it and keeps serving.
fn settleStep(shared: *Shared) void {
    for (shared.accepted.items) |session| admitAccepted(shared, session) catch |err|
        std.debug.print("glowcap-ocapn-peer: session setup failed: {s}\n", .{@errorName(err)});
    shared.accepted.clearRetainingCapacity();
    for (shared.dialed.items) |session| handoff.runPendingEnlivens(shared, session) catch |err|
        std.debug.print("glowcap-ocapn-peer: gifter fetch failed: {s}\n", .{@errorName(err)});
    shared.dialed.clearRetainingCapacity();
    if (shared.callback_err) |err| {
        std.debug.print("glowcap-ocapn-peer: interceptor failed: {s}\n", .{@errorName(err)});
        handoff.discardDeferred(shared);
        shared.callback_err = null;
    }
    handoff.drainDeferred(shared) catch |err|
        std.debug.print("glowcap-ocapn-peer: deferred effect failed: {s}\n", .{@errorName(err)});
    releaseClosed(shared);
}

/// Decorate the Host's per-event policy with the suite-only protocol actors.
/// Claimed events never enter the Vat. Top-level effects are retained for
/// `settleStep`, after the enclosing step unwinds.
fn confBeforeServe(ctx: ?*anyopaque, served: *driver.core.Served, event: *engine.Event) anyerror!bool {
    const conf: *ConfCtx = @ptrCast(@alignCast(ctx.?));
    const host_options = conf.host_serve_options;
    if (host_options.before_serve) |host_hook| {
        if (try host_hook(host_options.hook_ctx, served, event)) return true;
    }
    if (event.kind() == .deliver) {
        if (try tryPromiseResolve(conf, event)) return true;
        if (try handoff.tryRecipientGive(conf, event)) return true;
        if (try handoff.tryGifterEnliven(conf, event)) return true;
    }
    return false;
}

/// Queue each accepted session for `settleStep`: the observer runs inside the
/// step, where top-level Host verbs are refused.
const AcceptQueue = struct {
    fn opened(ctx: *anyopaque, _: u64, session: *HostSession) anyerror!void {
        const shared: *Shared = @ptrCast(@alignCast(ctx));
        try shared.owned.ensureUnusedCapacity(shared.allocator, 1);
        try shared.accepted.append(shared.allocator, session);
        shared.owned.appendAssumeCapacity(session);
    }

    fn failed(_: *anyopaque, _: u64, failure: driver.OperationFailure) void {
        std.debug.print("glowcap-ocapn-peer: listener failed: {s}\n", .{failure.primaryName()});
    }

    fn observer(shared: *Shared) driver.HostRuntime.SessionAcceptObserver {
        return .{ .ctx = shared, .opened = opened, .failed = failed };
    }
};

// ── Interceptors ─────────────────────────────────────────────────────────────

/// A `fulfill`/`break` deliver to a resolver export minted by the promise
/// resolver: push the matching `op:resolve` on its paired answer. Returns false
/// for any deliver to a target that is not a live resolver.
fn tryPromiseResolve(conf: *ConfCtx, event: *engine.Event) !bool {
    const peer = conf.session.served.port.peer;
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
    const answer_target = conf.resolver_map.get(target_id) orelse return false;
    const arg_count = deliver.args.len() catch return false;
    if (arg_count < 2) return false;
    const verb = switch (deliver.args.at(0) catch return false) {
        .symbol => |sym| sym,
        else => return false,
    };
    const value = deliver.args.at(1) catch return false;
    const resolution: model.Resolution = if (std.mem.eql(u8, verb, "fulfill"))
        .{ .fulfill = try value.toOwned(allocator) }
    else if (std.mem.eql(u8, verb, "break"))
        .{ .@"break" = switch (value) {
            .@"error" => |reason| try reason.toOwned(allocator),
            .symbol => |message| .{ .message = try allocator.dupe(u8, message) },
            .string => |message| .{ .message = try allocator.dupe(u8, message) },
            else => .{ .message = try allocator.dupe(u8, "broken") },
        } }
    else
        return false;
    defer model.freeResolution(allocator, resolution);
    try peer.sendAnswerTargetResolutionCopying(answer_target, resolution);
    return true;
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
            if (use_onion) {
                std.debug.print("glowcap-ocapn-onion-peer: --port is not valid for an onion service\n", .{});
                return error.BadArgument;
            }
            port = std.fmt.parseInt(u16, arg["--port=".len..], 10) catch {
                std.debug.print("glowcap-ocapn-peer: --port must be an integer in 1..65535\n", .{});
                return error.BadPort;
            };
        } else {
            std.debug.print("glowcap-ocapn-peer: unknown argument '{s}'\n", .{arg});
            return error.BadArgument;
        }
    }

    var addrs = AddrTable{ .allocator = allocator };
    defer addrs.deinit();
    conf_state.g_addrs = &addrs;
    defer conf_state.g_addrs = null;

    var seed: [crypto.SEED_BYTES]u8 = undefined;
    try io.randomSecure(&seed);
    var session_root: [crypto.SEED_BYTES]u8 = undefined;
    try io.randomSecure(&session_root);

    var host = try Host.init(allocator, seed, session_root, blk: {
        var o = Host.Options.withFrameCap(frame_cap);
        o.local_turn_budget = 64;
        break :blk o;
    });
    defer host.deinit();

    var control_cookie: ?[]u8 = null;
    defer if (control_cookie) |bytes| allocator.free(bytes);

    // The runtime borrows the testing resident, so it outlives the runtime.
    var testing_resident: TestingResident = undefined;
    var testing_live = false;
    defer if (testing_live) {
        testing_resident.closeAndDrain(2_000) catch |err| std.debug.print("glowcap-ocapn-peer: resident drain failed: {s}\n", .{@errorName(err)});
        testing_resident.deinit();
    };
    var registrations: [1]driver.HostRuntime.ProviderRegistration = undefined;
    const transports: driver.Transports = if (use_onion) .{
        .symbols = &.{.onion},
        .onion = try onionConfig(io, allocator, init.environ_map, &control_cookie),
    } else blk: {
        testing_resident = try TestingResident.init(allocator, try net.Backend.init(allocator, 64, 16, frame_cap), .{});
        testing_live = true;
        registrations = .{.{
            .profile = .{ .symbol = transport_name, .designator_scheme = .address },
            .resident = testing_resident.resident(),
        }};
        break :blk .{ .residents = &registrations };
    };

    var runtime = try driver.HostRuntime.initWithCore(allocator, io, &host, transports, .{
        .handshake = .{ .ms = 30_000 },
        .settle = .{ .ms = 30_000 },
    });
    defer runtime.deinit();

    var shared = Shared{ .allocator = allocator, .host = &host, .runtime = &runtime };
    defer shared.deinit();

    var bind_buf: [32]u8 = undefined;
    const bind = if (use_onion) "" else try std.fmt.bufPrint(&bind_buf, "{s}:{d}", .{ host_ip, port });
    var listener = try runtime.bindListener(transport_name, bind, .inherit);
    var prepared = switch (runtime.prepareListenerLocatorOutcome(&listener)) {
        .ready => |value| value,
        .failed => |failure| {
            if (runtime.closeListener(&listener)) |cleanup| runtime.noteTerminalOperationFailure(cleanup);
            return failure.cause;
        },
    };
    const listener_tag: u64 = 1;
    if (use_onion) {
        std.debug.print("GLOWCAP-OCAPN-PEER-READY ocapn://{s}.onion\n", .{prepared.value.designator});
    } else {
        // The suite's `tcp-testing-only` designator is a bare uuid; glowcap
        // advertises the reused CAR_FACTORY_BUILDER swiss as its own, and its
        // address lives in the banner's host/port hints.
        std.debug.print(
            "GLOWCAP-OCAPN-PEER-READY ocapn://{s}.tcp-testing-only?host={s}&port={d}\n",
            .{ CAR_FACTORY_BUILDER, host_ip, port },
        );
    }
    try runtime.activateOwnedListener(&listener, &prepared, listener_tag, AcceptQueue.observer(&shared));
    _ = try runtime.selectOwnedListener(listener_tag);

    while (true) {
        _ = try runtime.stepAny(-1);
        settleStep(&shared);
    }
}

const TestingResident = net.completion_resident.Resident(net.Backend, conf_state.TestingPolicy(net.Backend));

/// The Tor endpoints and control credential the onion build reads from its
/// environment. `control_cookie` owns a cookie file's bytes for the run.
fn onionConfig(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    control_cookie: *?[]u8,
) !driver.Transports.OnionConfig {
    const socks_text = requiredEnv(environ_map, "GLOWCAP_OCAPN_TOR_SOCKS") catch |err| {
        std.debug.print("glowcap-ocapn-onion-peer: GLOWCAP_OCAPN_TOR_SOCKS is required (host:port)\n", .{});
        return err;
    };
    const control_text = requiredEnv(environ_map, "GLOWCAP_OCAPN_TOR_CONTROL") catch |err| {
        std.debug.print("glowcap-ocapn-onion-peer: GLOWCAP_OCAPN_TOR_CONTROL is required (host:port)\n", .{});
        return err;
    };
    const socks_target = tcp.parseDesignator(socks_text) catch {
        std.debug.print("glowcap-ocapn-onion-peer: invalid SOCKS endpoint '{s}'; expected host:port\n", .{socks_text});
        return error.BadTorEndpoint;
    };
    const control_target = tcp.parseDesignator(control_text) catch {
        std.debug.print("glowcap-ocapn-onion-peer: invalid control endpoint '{s}'; expected host:port\n", .{control_text});
        return error.BadTorEndpoint;
    };

    const password = environ_map.get("GLOWCAP_OCAPN_TOR_CONTROL_PASSWORD");
    const cookie_file = environ_map.get("GLOWCAP_OCAPN_TOR_CONTROL_COOKIE_FILE");
    if (password != null and cookie_file != null) {
        std.debug.print("glowcap-ocapn-onion-peer: set at most one Tor control credential\n", .{});
        return error.AmbiguousTorAuthentication;
    }
    const auth: onion.control.Auth = if (password) |value|
        .{ .password = value }
    else if (cookie_file) |path| cookie: {
        control_cookie.* = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096)) catch |err| {
            std.debug.print("glowcap-ocapn-onion-peer: cannot read control cookie '{s}': {s}\n", .{ path, @errorName(err) });
            return err;
        };
        if (control_cookie.*.?.len == 0) {
            std.debug.print("glowcap-ocapn-onion-peer: Tor control cookie is empty\n", .{});
            return error.BadTorCredential;
        }
        break :cookie .{ .cookie = control_cookie.*.? };
    } else .none;
    return .{ .socks = socks_target, .control = control_target, .auth = auth };
}

fn requiredEnv(environ: *std.process.Environ.Map, name: []const u8) ![]const u8 {
    const value = environ.get(name) orelse return error.MissingEnvironment;
    if (value.len == 0) return error.MissingEnvironment;
    return value;
}
