//! The fixed reference host for the per-language consumer-cost bench
//! (`zig build bench-langs`). It serves the bench taskboard app on glowcap's
//! native Zig runtime, so the only thing that varies between bench rows is the
//! client language dialing in, the server adds no Chez, V8, or CPython noise.
//!
//! The board publishes one verb, `create`, which mints a fresh task capability
//! and returns it. Each task answers `assign`, `complete`, and `status`, the
//! same four-verb shape `bench/goblins/apps/taskboard.rkt` drives, and `status`
//! returns the bytes `done` once the task is complete so the result compares
//! equal across every client language.
//!
//!   bench-langs-host [port]
//!
//! With no port (or port 0) it binds an ephemeral loopback port and announces
//! the chosen one. It prints one NDJSON readiness line and then serves every
//! accepted connection, each on its own concurrent fiber, until it is killed:
//!
//!   {"v":1,"event":"ready","listen":"127.0.0.1:<port>"}

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const driver = glowcap.driver;
const net = glowcap.net;
const tcp = net.tcp;

const host_addr = "127.0.0.1";
const frame_cap: usize = 1 << 16;
const TcpBridge = driver.Bridge(net.TcpLoop);

/// One task: capability minted by `create`, driven through assign, complete,
/// and status. State is a single `done` flag held in the behavior, so `status`
/// answers the bytes `done` after `complete` and `open` before it.
const Task = struct {
    done: bool = false,

    pub fn handle(self: *Task, turn: *actors.Turn, message: actors.Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, message.verb, "assign")) return .{ .bytes = "assigned" };
        if (std.mem.eql(u8, message.verb, "complete")) {
            self.done = true;
            return .{ .bytes = "done" };
        }
        if (std.mem.eql(u8, message.verb, "status")) {
            return .{ .bytes = if (self.done) "done" else "open" };
        }
        return error.NoSuchMethod;
    }
};

/// The board root: `create` spawns a task at a fresh export position and returns
/// the capability, so the client invokes the returned task several times over
/// the wire, the capability-passing the bench measures.
const Board = struct {
    pub fn handle(self: *Board, turn: *actors.Turn, message: actors.Message) !model.Argument {
        _ = self;
        if (!std.mem.eql(u8, message.verb, "create")) return error.NoSuchMethod;
        return (try driver.spawnAt(turn, Task, .{})).arg();
    }
};

fn publishBoard(ctx: ?*anyopaque, served: *driver.Served, vat: *actors.Vat) anyerror!void {
    _ = ctx;
    _ = try served.publish(vat, "root", Board, .{});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next();
    const port: u16 = if (args_iter.next()) |p| try std.fmt.parseInt(u16, p, 10) else 0;

    var identity_seed: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &identity_seed);
    try io.randomSecure(&identity_seed);
    var session_root: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &session_root);
    try io.randomSecure(&session_root);

    var host = try driver.core.Host.init(allocator, identity_seed, session_root, blk: {
        var options = driver.core.Host.Options.withFrameCap(frame_cap);
        options.local_turn_budget = driver.core.default_loop_local_turn_budget;
        break :blk options;
    });
    defer host.deinit();

    var loop: net.TcpLoop = undefined;
    var bridge = TcpBridge.init(allocator, &host, io, &loop, .{ .publish = publishBoard });
    defer bridge.deinit();
    loop = try net.TcpLoop.initWithBackendOptions(
        allocator,
        .{ .read_buffer_bytes = frame_cap },
        TcpBridge.makePeer,
        @ptrCast(&bridge),
        TcpBridge.hookOptions(.{
            .max_conns = driver.default_max_pending_opens,
            .listen = port,
        }),
    );
    defer loop.deinit();

    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const bound_addr = try tcp.parseHostPort(host_addr, loop.port().?);
    const local = tcp.locatorFromAddress(&designator_buf, bound_addr).designator;
    try bridge.attach(model.transport.Known.tcp.metadata(), local, &.{});

    var stdout_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print("{{\"v\":1,\"event\":\"ready\",\"listen\":\"{s}\"}}\n", .{local});
    try stdout.interface.flush();

    try loop.run(.forever);
}
