//! The fixed reference host for the per-language consumer-cost bench
//! (`zig build bench-langs`). It serves the bench taskboard app on pancake's
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
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;
const tcp = pancake.net.tcp;

const host_addr = "127.0.0.1";
const frame_cap: usize = 1 << 16;

/// One task: capability minted by `create`, driven through assign, complete,
/// and status. State is a single `done` flag held in the behavior, so `status`
/// answers the bytes `done` after `complete` and `open` before it.
const Task = struct {
    done: bool = false,

    pub fn handle(self: *Task, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "assign")) return .{ .bytes = "assigned" };
        if (std.mem.eql(u8, msg.verb, "complete")) {
            self.done = true;
            return .{ .bytes = "done" };
        }
        if (std.mem.eql(u8, msg.verb, "status")) {
            return .{ .bytes = if (self.done) "done" else "open" };
        }
        return error.NoSuchMethod;
    }
};

/// The board root: `create` spawns a task at a fresh export position and returns
/// the capability, so the client invokes the returned task several times over
/// the wire, the capability-passing the bench measures.
const Board = struct {
    pub fn handle(self: *Board, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        if (!std.mem.eql(u8, msg.verb, "create")) return error.NoSuchMethod;
        const cap = try driver.spawnAt(turn.vat, Task, .{});
        return cap.arg();
    }
};

/// Serve one accepted connection: publish the board by name, serve until the
/// partner leaves, then free the connection. Errors are swallowed because a
/// partner that hangs up mid-conversation is normal bench teardown, not a host
/// fault.
fn serveConn(conn: *driver.Connection) void {
    defer conn.close();
    _ = conn.publish("root", Board, .{}) catch return;
    conn.serve() catch {};
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next();
    const port: u16 = if (args_iter.next()) |p| try std.fmt.parseInt(u16, p, 10) else 0;

    var designator_buf: [64]u8 = undefined;
    const bind_designator = try std.fmt.bufPrint(&designator_buf, "{s}:{d}", .{ host_addr, port });

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(tcp_resident.netlayer(), allocator, .{ .designator = bind_designator }, .ephemeral, .{ .frame_cap = frame_cap });
    defer server.close();

    var addr_buf: [64]u8 = undefined;
    const local = server.localDesignator(&addr_buf);

    var stdout_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print("{{\"v\":1,\"event\":\"ready\",\"listen\":\"{s}\"}}\n", .{local});
    try stdout.interface.flush();

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const conn = server.accept() catch return;
        group.concurrent(io, serveConn, .{conn}) catch {
            conn.close();
            continue;
        };
    }
}
