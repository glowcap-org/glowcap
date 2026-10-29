//! Child-process halves of the live peer-scaling measurement.
//!
//! The coordinator keeps server and load-side RSS distinct by spawning one
//! process for each half, and neither gives a connection a thread of its own.
//! The server half runs the product path: `driver.HostRuntime` shards serving
//! TCP through a completion resident (ADR-0018). The load half drives raw
//! `engine.Peer`s from `completion.Loop`s, because it measures nothing but must
//! cost as little as possible. Server shards stay live until the coordinator
//! samples them, while every client proves a signed handshake and bootstrap
//! fetch before its shard reaches the barrier.

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const engine = glowcap.ocapn.engine;
const foundation = glowcap.foundation;
const model = glowcap.ocapn.model;
const net = glowcap.net;
const tcp = net.tcp;

const Host = driver.core.Host;
const TcpResident = net.completion_resident.Resident(net.Backend, tcp.CompletionPolicy(net.Backend));

const frame_cap: usize = 4096;
/// Keep dial admission behind the signed-handshake and bootstrap-fetch barrier.
/// A batch-only bound still lets a fast submitter place the entire target in
/// the kernel before the application has served it, turning a scale measurement
/// into a connection-establishment timeout test.
const client_in_flight_per_shard: usize = 64;
const greeting = "peer-scaling live";

const Greeter = struct {
    pub fn handle(_: *Greeter, ht: *driver.HostTurn, selector: ?[]const u8, args: driver.Args) !driver.Value {
        defer ht.releaseArguments(args);
        const verb = selector orelse return error.NoSuchMethod;
        if (!std.mem.eql(u8, verb, "greet")) return error.NoSuchMethod;
        return .{ .string = greeting };
    }
};

fn rootFor(role: u8, shard: usize) [32]u8 {
    var root: [32]u8 = @splat(role);
    std.mem.writeInt(u64, root[0..8], @intCast(shard), .little);
    return root;
}

/// A shard's Host admits exactly the sessions the coordinator assigns it, so
/// the run measures the session cap at the bound a service would set.
fn initHost(allocator: std.mem.Allocator, role: u8, shard: usize, max_sessions: usize) !Host {
    return Host.init(allocator, rootFor(role, 0), rootFor(role, shard + 1), .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .max_sessions = max_sessions,
    });
}

fn shardQuota(total: usize, shards: usize, shard: usize) usize {
    return total / shards + @intFromBool(shard < total % shards);
}

fn waitForRelease(io: std.Io) !void {
    var buf: [32]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buf);
    _ = try reader.interface.takeDelimiterInclusive('\n');
}

fn driveUntil(loop: *net.TcpLoop, done: *const std.atomic.Value(bool), out_err: *?anyerror) void {
    loop.runUntil(done, 0) catch |err| {
        out_err.* = err;
    };
}

fn drain(loop: *net.TcpLoop, out_err: *?anyerror) void {
    loop.closeAndDrain() catch |err| {
        out_err.* = err;
    };
}

const ServerShared = struct {
    opened: std.atomic.Value(usize) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
};

/// One `HostRuntime` over its own Host and TCP completion resident. Every
/// shard shares the Host identity, as one service spread across cores would.
const ServerShard = struct {
    host: Host,
    resident: TcpResident,
    runtime: driver.HostRuntime,
    shared: *ServerShared,
    port: u16,
    loop_error: ?anyerror = null,

    const listener_tag: u64 = 1;

    fn acceptObserver(self: *ServerShard) driver.HostRuntime.SessionAcceptObserver {
        return .{ .ctx = self, .opened = opened, .failed = failed };
    }

    fn opened(ctx: *anyopaque, _: u64, _: *driver.core.HostSession) anyerror!void {
        const self: *ServerShard = @ptrCast(@alignCast(ctx));
        _ = self.shared.opened.fetchAdd(1, .acq_rel);
    }

    fn failed(ctx: *anyopaque, _: u64, failure: driver.OperationFailure) void {
        const self: *ServerShard = @ptrCast(@alignCast(ctx));
        if (self.loop_error == null) self.loop_error = failure.chain.cause;
    }

    fn init(
        self: *ServerShard,
        allocator: std.mem.Allocator,
        io: std.Io,
        shared: *ServerShared,
        shard: usize,
        quota: usize,
    ) !void {
        self.host = try initHost(allocator, 0x53, shard, quota);
        errdefer self.host.deinit();
        self.shared = shared;
        self.loop_error = null;
        self.resident = try TcpResident.init(allocator, try net.Backend.init(allocator, 256, 256, frame_cap), .{});
        errdefer retireResident(&self.resident);
        self.runtime = try driver.HostRuntime.initWithCore(allocator, io, &self.host, .{}, .{
            .max_pending_opens = 2 * client_in_flight_per_shard,
            .handshake = .{ .ms = 30_000 },
            .settle = .{ .ms = 30_000 },
        });
        errdefer self.runtime.deinit();
        _ = try self.runtime.addResident(model.transport.Known.tcp.metadata(), self.resident.resident());
        try self.runtime.publish("greeter", Greeter, .{});

        // Until activation takes them, the listener and its prepared locator
        // are this function's to release.
        var listener = try self.runtime.bindListener(model.transport.tcp, "127.0.0.1:0", .{});
        var owns_listener = true;
        errdefer if (owns_listener) {
            if (self.runtime.closeListener(&listener)) |failure| self.runtime.noteTerminalOperationFailure(failure);
        };
        var prepared = switch (self.runtime.prepareListenerLocatorOutcome(&listener)) {
            .ready => |value| value,
            .failed => |failure| return failure.cause,
        };
        var owns_prepared = true;
        defer if (owns_prepared) prepared.deinit(allocator);
        self.port = (try tcp.parseDesignator(prepared.value.designator)).getPort();
        try self.runtime.activateOwnedListener(&listener, &prepared, listener_tag, self.acceptObserver());
        owns_listener = false;
        owns_prepared = false;
        if (!try self.runtime.selectOwnedListener(listener_tag)) return error.ListenerNotSelected;
    }

    fn run(self: *ServerShard) void {
        while (!self.shared.stop.load(.acquire)) {
            _ = self.runtime.stepAny(20) catch |err| {
                self.loop_error = err;
                return;
            };
        }
    }

    fn deinit(self: *ServerShard) void {
        self.runtime.deinit();
        retireResident(&self.resident);
        self.host.deinit();
    }
};

/// The resident outlives its runtime and retires the operations it still owes.
fn retireResident(resident: *TcpResident) void {
    resident.closeAndDrain(5_000) catch |err| std.debug.panic("TCP completion resident drain failed: {t}", .{err});
    resident.deinit();
}

const ClientConn = struct {
    shard: *ClientShard,
    fetch_sent: bool = false,
    answer_position: model.AnswerPosition = .from(0),
    resolver_export: ?model.ExportPosition = null,
};

const ClientShard = struct {
    allocator: std.mem.Allocator,
    loop: net.TcpLoop,
    index: usize,
    next_id: usize,
    port: u16,
    target: usize,
    submitted: usize = 0,
    completed: usize = 0,
    done: std.atomic.Value(bool) = .init(false),
    loop_error: ?anyerror = null,
    connection_error: ?anyerror = null,

    fn fail(self: *ClientShard, err: anyerror) void {
        if (self.connection_error == null) self.connection_error = err;
        self.done.store(true, .release);
    }

    fn makePeer(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!engine.Peer {
        const self: *ClientShard = @ptrCast(@alignCast(ctx.?));
        const id = self.next_id;
        self.next_id += 1;
        const ordinal = id + 1;
        var designator_buf: [32]u8 = undefined;
        const designator = try std.fmt.bufPrint(&designator_buf, "127.{d}.{d}.{d}:1", .{
            (ordinal >> 16) & 0xff,
            (ordinal >> 8) & 0xff,
            ordinal & 0xff,
        });
        var seed: [foundation.crypto.seed_bytes]u8 = @splat(0x71);
        std.mem.writeInt(u64, seed[0..8], @intCast(ordinal), .little);
        var peer = engine.Peer.initNegotiating(allocator);
        errdefer peer.deinit();
        peer.session_state.limits.max_frame_bytes = frame_cap;
        try peer.sendKeyedStartSession(.{
            .transport = tcp.transport_name,
            .designator = designator,
            .hints = model.Hints.emptyFalse(),
        }, foundation.crypto.SecretKey.fromSeed(seed));
        return peer;
    }

    fn makeConnCtx(ctx: ?*anyopaque, _: *engine.Peer, _: usize) anyerror!?*anyopaque {
        const self: *ClientShard = @ptrCast(@alignCast(ctx.?));
        const conn = try self.allocator.create(ClientConn);
        conn.* = .{ .shard = self };
        return conn;
    }

    fn serve(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
        const conn: *ClientConn = @ptrCast(@alignCast(conn_ctx.?));
        if (!conn.fetch_sent and peer.sessionIsOpen()) {
            const prepared = try engine.fetch.prepareFetchSwissnum(
                conn.shard.allocator,
                &peer.session_state,
                "greeter",
            );
            conn.fetch_sent = true;
            conn.answer_position = prepared.answer.position;
            conn.resolver_export = prepared.resolver_export;
            try peer.send(prepared.message);
        }
        if (!conn.fetch_sent) return;

        const owned = try event.decodeOwned(conn.shard.allocator);
        const matched = try engine.fetch.tryMatchFetchOutcome(
            conn.shard.allocator,
            conn.resolver_export,
            conn.answer_position,
            owned,
        );
        switch (matched) {
            .settled => |outcome| switch (outcome) {
                .fulfilled => |reference| {
                    model.freeReference(conn.shard.allocator, reference);
                    conn.shard.completed += 1;
                    if (conn.shard.completed == conn.shard.target)
                        conn.shard.done.store(true, .release);
                },
                .broken => |reason| {
                    conn.shard.allocator.free(reason);
                    return error.FetchBroke;
                },
                .malformed => return error.FetchMalformed,
            },
            .unrelated => |message| model.freeMessage(conn.shard.allocator, message),
        }
    }

    fn freeConnCtx(ctx: ?*anyopaque, conn_ctx: ?*anyopaque) void {
        const self: *ClientShard = @ptrCast(@alignCast(ctx.?));
        const conn: *ClientConn = @ptrCast(@alignCast(conn_ctx orelse return));
        self.allocator.destroy(conn);
    }

    fn onClose(ctx: ?*anyopaque, _: usize, _: ?*anyopaque, report: net.completion.CloseReport) void {
        const self: *ClientShard = @ptrCast(@alignCast(ctx.?));
        if (self.done.load(.acquire)) return;
        const failure = if (report.failure) |info| info.error_name else "none";
        std.debug.print(
            "peer_scaling client close shard={d} submitted={d}/{d} completed={d}/{d} " ++
                "opened={} reason={s} failure={s}\n",
            .{
                self.index,
                self.submitted,
                self.target,
                self.completed,
                self.target,
                report.opened,
                @tagName(report.reason),
                failure,
            },
        );
        self.fail(error.ConnectionClosed);
    }

    fn submitDials(ctx: ?*anyopaque) anyerror!bool {
        const self: *ClientShard = @ptrCast(@alignCast(ctx.?));
        if (self.submitted == self.target) return false;
        const in_flight = self.submitted - self.completed;
        if (in_flight >= client_in_flight_per_shard) return false;
        var designator_buf: [tcp.designator_buf_len]u8 = undefined;
        const address = try tcp.parseHostPort("127.0.0.1", self.port);
        const locator = tcp.locatorFromAddress(&designator_buf, address);
        const available = client_in_flight_per_shard - in_flight;
        const end = @min(self.target, self.submitted + available);
        while (self.submitted < end) : (self.submitted += 1)
            _ = try self.loop.dialLocator(locator);
        return true;
    }

    fn init(
        self: *ClientShard,
        allocator: std.mem.Allocator,
        first_id: usize,
        index: usize,
        port: u16,
        target: usize,
    ) !void {
        self.allocator = allocator;
        self.index = index;
        self.next_id = first_id;
        self.port = port;
        self.target = target;
        self.submitted = 0;
        self.completed = 0;
        self.done = .init(false);
        self.loop_error = null;
        self.connection_error = null;
        self.loop = try net.TcpLoop.initWithBackendOptions(
            allocator,
            .{ .read_buffer_bytes = frame_cap },
            makePeer,
            self,
            .{
                .max_conns = target,
                .make_conn_ctx = makeConnCtx,
                .serve = serve,
                .free_conn_ctx = freeConnCtx,
                .on_close = onClose,
                .on_loop_turn = submitDials,
            },
        );
    }

    fn deinit(self: *ClientShard) void {
        self.loop.deinit();
    }
};

fn awaitDrains(io: std.Io, loops: anytype) !void {
    const Future = @TypeOf(io.concurrent(drain, .{ &loops[0].loop, &loops[0].loop_error }) catch unreachable);
    const futures = try std.heap.smp_allocator.alloc(Future, loops.len);
    defer std.heap.smp_allocator.free(futures);
    for (loops, futures) |*shard, *future| {
        shard.loop_error = null;
        future.* = try io.concurrent(drain, .{ &shard.loop, &shard.loop_error });
    }
    for (futures) |*future| future.await(io);
    for (loops) |*shard| if (shard.loop_error) |err| return err;
}

pub fn runServer(io: std.Io, allocator: std.mem.Allocator, total: usize, shard_count: usize) !void {
    if (total == 0 or shard_count == 0 or shard_count > total) return error.InvalidLiveShape;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const worker_io = threaded.io();

    var shared = ServerShared{};
    const shards = try allocator.alloc(ServerShard, shard_count);
    defer allocator.free(shards);
    const Future = @TypeOf(worker_io.concurrent(ServerShard.run, .{&shards[0]}) catch unreachable);
    const futures = try allocator.alloc(Future, shard_count);
    defer allocator.free(futures);

    var initialized: usize = 0;
    errdefer for (shards[0..initialized]) |*shard| shard.deinit();
    while (initialized < shard_count) : (initialized += 1) {
        try shards[initialized].init(allocator, worker_io, &shared, initialized, shardQuota(total, shard_count, initialized));
    }
    var started: usize = 0;
    errdefer {
        shared.stop.store(true, .release);
        for (futures[0..started]) |*future| future.await(worker_io);
    }
    while (started < shard_count) : (started += 1) {
        futures[started] = try worker_io.concurrent(ServerShard.run, .{&shards[started]});
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.writeAll("PORTS ");
    for (shards, 0..) |*shard, i| {
        if (i != 0) try stdout.interface.writeByte(',');
        try stdout.interface.print("{d}", .{shard.port});
    }
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();

    try waitForRelease(io);
    const opened_before_stop = shared.opened.load(.acquire);
    shared.stop.store(true, .release);
    for (futures) |*future| future.await(worker_io);
    started = 0;
    for (shards) |*shard| if (shard.loop_error) |err| return err;
    if (opened_before_stop != total) return error.LiveConnectShortfall;
    for (shards) |*shard| shard.deinit();
    initialized = 0;
}

pub fn runClient(
    io: std.Io,
    allocator: std.mem.Allocator,
    total: usize,
    ports: []const u16,
) !void {
    if (total == 0 or ports.len == 0 or ports.len > total) return error.InvalidLiveShape;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const worker_io = threaded.io();

    const shards = try allocator.alloc(ClientShard, ports.len);
    defer allocator.free(shards);
    const Future = @TypeOf(worker_io.concurrent(driveUntil, .{ &shards[0].loop, &shards[0].done, &shards[0].loop_error }) catch unreachable);
    const futures = try allocator.alloc(Future, ports.len);
    defer allocator.free(futures);

    var initialized: usize = 0;
    var first_id: usize = 0;
    errdefer for (shards[0..initialized]) |*shard| shard.deinit();
    while (initialized < ports.len) : (initialized += 1) {
        const quota = shardQuota(total, ports.len, initialized);
        try shards[initialized].init(allocator, first_id, initialized, ports[initialized], quota);
        first_id += quota;
        futures[initialized] = try worker_io.concurrent(driveUntil, .{
            &shards[initialized].loop,
            &shards[initialized].done,
            &shards[initialized].loop_error,
        });
    }

    for (futures) |*future| future.await(worker_io);
    var completed: usize = 0;
    for (shards) |*shard| {
        if (shard.loop_error) |err| return err;
        if (shard.connection_error) |err| return err;
        completed += shard.completed;
    }
    if (completed != total) return error.LiveCallShortfall;

    var stdout_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print("CLIENT_READY {d}\n", .{completed});
    try stdout.interface.flush();

    try waitForRelease(io);
    try awaitDrains(worker_io, shards);
    for (shards) |*shard| shard.deinit();
}
