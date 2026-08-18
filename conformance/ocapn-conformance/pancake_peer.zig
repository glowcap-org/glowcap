//! Thin conformance host: canonical swiss-nums over the build-selected
//! conformance transport, served by one `driver.core.Host` behind a
//! `driver.Bridge` over a completion loop,
//! the single-thread, many-session host tier (ADR-0076), not a thread per
//! connection.
//!
//! The Host owns every protocol-policy seam the suite exercises through the
//! library rather than this file: crossed-hellos tiebreak (`Host.CrossedHellos`,
//! ADR-0030), one node identity reused as every session's signing key, and the
//! live-session directory that reaches each Peer-owned gift table. What stays
//! here is what the Host cannot know: the conformance actors, the
//! promise-resolver interceptor, and Host wiring. Gift/recipient interceptors
//! and the `tcp-testing-only` address table live in `handoff.zig` and
//! `conf_state.zig`.
//!
//!   * the promise-resolver bootstrap object (a `fulfill`/`break` to a minted
//!     resolver export becomes an `op:resolve` on its paired answer);
//!   * a `desc:handoff-give` delivered to the greeter (the recipient half) —
//!     owned by `handoff.zig`;
//!   * a sturdyref enliven to the enlivener (the gifter half) — owned by
//!     `handoff.zig`.

const std = @import("std");
const pancake = @import("pancake");
const peer_options = @import("ocapn_peer_options");
const conf_state = @import("conf_state.zig");
const handoff = @import("handoff.zig");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const crypto = pancake.foundation.crypto;
const net = pancake.net;
const driver = pancake.driver;
const tcp = net.tcp;
const onion = net.onion;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;

const use_onion = peer_options.use_onion;
const transport_name = conf_state.transport_name;
const AddrTable = conf_state.AddrTable;
const ConfLoop = conf_state.ConfLoop;
const ConfBridge = conf_state.ConfBridge;
const ConfCtx = conf_state.ConfCtx;
const Shared = conf_state.Shared;
const CAR_FACTORY_BUILDER = conf_state.CAR_FACTORY_BUILDER;
const ECHO = conf_state.ECHO;
const GREETER = conf_state.GREETER;
const PROMISE_RESOLVER = conf_state.PROMISE_RESOLVER;
const STURDYREF_ENLIVENER = conf_state.STURDYREF_ENLIVENER;

const host_ip = "127.0.0.1";
/// The suite dials this fixed port; `--port=N` (threaded by
/// `run-against-pancake.sh` from `zig build ocapn-conformance -Dport=N`)
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
        const answer_name = promise.answer_name;
        const resolver_export = try peer.session_state.allocateExport();
        var resolver_owned = true;
        errdefer if (resolver_owned)
            peer.session_state.releaseUnsharedExport(resolver_export);
        try self.conf.resolver_map.put(turn.vat.allocator, resolver_export.int(), answer_name);
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

const Unimplemented = struct {
    pub fn handle(self: *Unimplemented, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        _ = msg;
        return error.NotImplemented;
    }
};

fn publishLocal(turn: *actors.Turn, ref: actors.Ref) !u64 {
    const peer = (turn.port orelse return error.NotConnected).peer;
    const export_position = try peer.session_state.allocateExport();
    try (turn.port orelse return error.NotConnected).bindExport(turn.vat, ref, export_position.int());
    return export_position.int();
}

// ── Bridge hooks ─────────────────────────────────────────────────────────────

/// Publish the five bootstrap actors on every accepted session and allocate its
/// conformance state. Runs at adoption, before any inbound frame is served, so
/// a partner's first fetch cannot race the registration.
fn publishConf(ctx: ?*anyopaque, served: *driver.Served, vat: *actors.Vat) anyerror!void {
    const shared: *Shared = @ptrCast(@alignCast(ctx.?));
    const session: *HostSession = @fieldParentPtr("served", served);

    const conf = try shared.allocator.create(ConfCtx);
    errdefer shared.allocator.destroy(conf);
    conf.* = .{
        .shared = shared,
        .session = session,
        .host_serve_options = served.serve_options,
    };
    try shared.confs.put(shared.allocator, session.peer_id, conf);

    // Decorate, rather than replace, the Host's policy hook. Host.serveEvent
    // drains every event still queued after the loop hands it the first event
    // in a batch; an outer completion-loop serve wrapper therefore cannot see
    // every event. Keeping the interceptors here makes batching irrelevant and
    // preserves crossed-hellos, handoff, and trace policy in the saved hook.
    served.serve_options = .{
        .gc_stateless = true,
        .hook_ctx = conf,
        .before_serve = confBeforeServe,
    };

    _ = try served.publish(vat, ECHO, Echo, .{});
    _ = try served.publish(vat, GREETER, Greeter, .{});
    _ = try served.publish(vat, CAR_FACTORY_BUILDER, CarFactoryBuilder, .{});
    _ = try served.publish(vat, PROMISE_RESOLVER, PromiseResolver, .{ .conf = conf });
    _ = try served.publish(vat, STURDYREF_ENLIVENER, Unimplemented, .{});
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

/// Decorate the Host's per-event policy with the suite-only protocol actors.
/// Claimed events never enter the Vat. Top-level effects are retained for
/// `confServe`, after the enclosing Host dispatch opens its callback latch.
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

/// Host.serveEvent may drain several queued events through `confBeforeServe`.
/// Only after it returns is the callback latch open for the top-level effects
/// those events classified.
fn confServe(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
    const shell: *ConfBridge.Slot = @ptrCast(@alignCast(conn_ctx.?));
    const bridge = shell.bridge;
    const shared: *Shared = @ptrCast(@alignCast(bridge.publish_ctx.?));
    std.debug.assert(shared.deferred.items.len == 0);
    ConfBridge.serve(conn_ctx, peer, event) catch |err| {
        handoff.discardDeferred(shared);
        return err;
    };
    try handoff.drainDeferred(shared);
    try bridge.drainActions();
}

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
    const answer_name = conf.resolver_map.get(target_id) orelse return false;
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
    try peer.sendAnswerResolutionCopying(answer_name, resolution);
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
                std.debug.print("pancake-ocapn-onion-peer: --port is not valid for an onion service\n", .{});
                return error.BadArgument;
            }
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

    var shared = Shared{ .allocator = allocator, .host = &host, .bridge = undefined };
    defer shared.deinit();

    var loop: ConfLoop = undefined;
    var bridge = ConfBridge.init(allocator, &host, io, &loop, .{
        .publish = publishConf,
        .publish_ctx = &shared,
        .on_open = handoff.confOnOpen,
        .on_open_ctx = &shared,
    });
    defer bridge.deinit();
    shared.bridge = &bridge;

    var loop_options = ConfBridge.hookOptions(net.completion.Options{
        .max_conns = 256,
        .listen = if (use_onion) 0 else port,
    });
    const backend_options: net.completion.BackendOptions = .{};
    loop_options.serve = confServe;
    loop_options.free_conn_ctx = confFreeConnCtx;

    var control_cookie: ?[]u8 = null;
    defer if (control_cookie) |bytes| allocator.free(bytes);

    loop = if (use_onion) blk: {
        const socks_text = requiredEnv(init.environ_map, "PANCAKE_OCAPN_TOR_SOCKS") catch |err| {
            std.debug.print("pancake-ocapn-onion-peer: PANCAKE_OCAPN_TOR_SOCKS is required (host:port)\n", .{});
            return err;
        };
        const control_text = requiredEnv(init.environ_map, "PANCAKE_OCAPN_TOR_CONTROL") catch |err| {
            std.debug.print("pancake-ocapn-onion-peer: PANCAKE_OCAPN_TOR_CONTROL is required (host:port)\n", .{});
            return err;
        };
        const socks_target = tcp.parseDesignator(socks_text) catch {
            std.debug.print("pancake-ocapn-onion-peer: invalid SOCKS endpoint '{s}'; expected host:port\n", .{socks_text});
            return error.BadTorEndpoint;
        };
        const control_target = tcp.parseDesignator(control_text) catch {
            std.debug.print("pancake-ocapn-onion-peer: invalid control endpoint '{s}'; expected host:port\n", .{control_text});
            return error.BadTorEndpoint;
        };

        const password = init.environ_map.get("PANCAKE_OCAPN_TOR_CONTROL_PASSWORD");
        const cookie_file = init.environ_map.get("PANCAKE_OCAPN_TOR_CONTROL_COOKIE_FILE");
        if (password != null and cookie_file != null) {
            std.debug.print("pancake-ocapn-onion-peer: set at most one Tor control credential\n", .{});
            return error.AmbiguousTorAuthentication;
        }
        const auth: onion.control.Auth = if (password) |value|
            .{ .password = value }
        else if (cookie_file) |path| cookie: {
            control_cookie = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096)) catch |err| {
                std.debug.print("pancake-ocapn-onion-peer: cannot read control cookie '{s}': {s}\n", .{ path, @errorName(err) });
                return err;
            };
            if (control_cookie.?.len == 0) {
                std.debug.print("pancake-ocapn-onion-peer: Tor control cookie is empty\n", .{});
                return error.BadTorCredential;
            }
            break :cookie .{ .cookie = control_cookie.? };
        } else .none;

        // Apply the same pool options as `Loop.init` while constructing the
        // configured adapter that `initWithBackend` requires.
        const inner = try net.Backend.init(
            allocator,
            backend_options.queue_entries,
            backend_options.read_buffers,
            backend_options.read_buffer_bytes,
        );
        const backend = net.OnionBackend.initOnion(allocator, inner, .{
            .socks = socks_target,
            .control = control_target,
            .auth = auth,
        });
        break :blk try ConfLoop.initWithBackend(
            allocator,
            backend,
            ConfBridge.makePeer,
            @ptrCast(&bridge),
            loop_options,
        );
    } else try ConfLoop.init(allocator, ConfBridge.makePeer, @ptrCast(&bridge), loop_options);
    defer loop.deinit();

    if (use_onion) {
        const service_id = loop.listenerAddress().?;
        try bridge.attach(.{
            .symbol = transport_name,
            .designator_scheme = .address,
        }, &service_id, "");
        std.debug.print("PANCAKE-OCAPN-PEER-READY ocapn://{s}.onion\n", .{&service_id});
    } else {
        try bridge.attach(.{
            .symbol = transport_name,
            .designator_scheme = .address,
        }, CAR_FACTORY_BUILDER, "");
        const bound_port = loop.port().?;
        // The suite's `tcp-testing-only` designator is a bare uuid; pancake
        // advertises the reused CAR_FACTORY_BUILDER swiss as its own, and its
        // address lives in the banner's host/port hints.
        std.debug.print(
            "PANCAKE-OCAPN-PEER-READY ocapn://{s}.tcp-testing-only?host={s}&port={d}\n",
            .{ CAR_FACTORY_BUILDER, host_ip, bound_port },
        );
    }

    try loop.run(.forever);
}

fn requiredEnv(environ: *std.process.Environ.Map, name: []const u8) ![]const u8 {
    const value = environ.get(name) orelse return error.MissingEnvironment;
    if (value.len == 0) return error.MissingEnvironment;
    return value;
}
