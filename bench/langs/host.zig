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
//! accepted connection from one `driver.Server` thread until it is killed:
//!
//!   {"v":1,"event":"ready","listen":"127.0.0.1:<port>"}

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;

const host_addr = "127.0.0.1";

const opts: driver.SessionOptions = .{
    .frame_cap = 1 << 16,
    .handshake = .{ .ms = 30_000 },
    .settle = .{ .ms = 30_000 },
};

/// One task: capability minted by `create`, driven through assign, complete,
/// and status. State is a single `done` flag held in the behavior, so `status`
/// answers the bytes `done` after `complete` and `open` before it.
const Task = struct {
    done: bool = false,

    pub fn handle(self: *Task, _: *driver.HostTurn, verb: []const u8, _: []const driver.Value) !driver.Value {
        if (std.mem.eql(u8, verb, "assign")) return .{ .bytes = "assigned" };
        if (std.mem.eql(u8, verb, "complete")) {
            self.done = true;
            return .{ .bytes = "done" };
        }
        if (std.mem.eql(u8, verb, "status")) {
            return .{ .bytes = if (self.done) "done" else "open" };
        }
        return error.NoSuchMethod;
    }
};

/// The board root: `create` spawns a task and returns the capability, so the
/// client invokes the returned task several times over the wire, the
/// capability-passing the bench measures.
const Board = struct {
    pub fn handle(_: *Board, ht: *driver.HostTurn, verb: []const u8, _: []const driver.Value) !driver.Value {
        if (!std.mem.eql(u8, verb, "create")) return error.NoSuchMethod;
        return .{ .capability = try ht.spawn(Task, .{}) };
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next();
    const port: u16 = if (args_iter.next()) |p| try std.fmt.parseInt(u16, p, 10) else 0;

    var bind_buf: [32]u8 = undefined;
    const bind = try std.fmt.bufPrint(&bind_buf, "{s}:{d}", .{ host_addr, port });
    var server = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = bind }, .ephemeral, opts);
    defer server.deinit();
    try server.publish("root", Board, .{});

    var designator_buf: [64]u8 = undefined;
    var stdout_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print("{{\"v\":1,\"event\":\"ready\",\"listen\":\"{s}\"}}\n", .{try server.localDesignator(&designator_buf)});
    try stdout.interface.flush();

    var sessions: std.ArrayListUnmanaged(*driver.Session) = .empty;
    defer {
        for (sessions.items) |session| session.deinit();
        sessions.deinit(allocator);
    }
    while (true) {
        if (try server.waitAcceptable(0)) {
            const session = try server.accept();
            sessions.append(allocator, session) catch |err| {
                session.deinit();
                return err;
            };
            // An accepted session dispatches nothing until its owner attends.
            try session.attend();
            continue;
        }
        _ = try server.runtime.stepAny(-1);
    }
}
