//! A tasks board client, written on pancake actors in native Zig. Zig is the home
//! language; this runs on the same core every binding wraps, and it drives the
//! real TCP netlayer.
//!
//! On the driver surface this reads like the other languages: one owning
//! `driver.connect`, `fetch` the board by name, `spawn` a watcher, then add a
//! task, list, mark it done, and list again to confirm, each a blocking
//! `conn.call` that pumps the session until its reply settles. The script reads
//! top to bottom, no phase machine: this is the same sequence every other
//! language's one-shot client runs.
//!
//!   pancake-tasks-client <port> <nick> <task-text>
//!
//! It exits 0 once the full add-list-done-list round trip succeeds.

const std = @import("std");
const pancake = @import("pancake");

const demo_usage = @import("demo_usage");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;
const tcp = pancake.net.tcp;

const host_addr = "127.0.0.1";
const frame_cap: usize = 1 << 16;

const Watcher = struct {
    pub fn handle(self: *Watcher, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "update")) return error.NoSuchMethod;
        return .{ .void = {} };
    }
};

fn printTask(item: model.Argument) void {
    switch (item) {
        .list => |fields| {
            if (fields.len >= 3) {
                const id = switch (fields[0]) {
                    .integer => |v| v,
                    else => 0,
                };
                const text = switch (fields[1]) {
                    .string => |s| s,
                    else => "?",
                };
                const is_done = switch (fields[2]) {
                    .boolean => |v| v,
                    else => false,
                };
                const mark: []const u8 = if (is_done) "[x]" else "[ ]";
                std.debug.print("  {s} #{d} {s}\n", .{ mark, id, text });
            }
        },
        else => {},
    }
}

/// True when the board's `list` reply contains `id` marked done, the
/// confirmation the round trip asserts on.
fn taskIsDone(items: []const model.Argument, id: i64) bool {
    for (items) |item| {
        switch (item) {
            .list => |fields| {
                if (fields.len >= 3) {
                    const fid = switch (fields[0]) {
                        .integer => |v| v,
                        else => 0,
                    };
                    const is_done = switch (fields[2]) {
                        .boolean => |v| v,
                        else => false,
                    };
                    if (fid == id and is_done) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

/// Print the failure and exit non-zero, usable in any expression position
/// (a broken reply or a malformed one ends the one-shot client the same way).
fn die(nick: []const u8, reason: []const u8) noreturn {
    std.debug.print("tasks-client: {s} failed: {s}\n", .{ nick, reason });
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next();
    const port_str = args_iter.next() orelse return fail("missing <port>");
    const nick = args_iter.next() orelse return fail("missing <nick>");
    const task_text = args_iter.next() orelse return fail("missing <task-text>");
    const port = try std.fmt.parseInt(u16, port_str, 10);

    var tcp_resident = tcp.Resident{ .io = io };
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const address = try tcp.parseHostPort(host_addr, port);
    const loc = tcp.locator(&designator_buf, address);
    var conn = try driver.connect(allocator, &.{tcp_resident.netlayer()}, loc, .ephemeral, .{ .frame_cap = frame_cap });
    defer conn.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const board = try conn.fetch("board");
    const watcher = try conn.spawn(Watcher, .{});

    try conn.tell(board, .{ .verb = "watch", .args = &.{watcher.arg()} });

    var text_buf: [256]u8 = undefined;
    const full_text = std.fmt.bufPrint(&text_buf, "[{s}] {s}", .{ nick, task_text }) catch task_text;

    const added_id = switch (try conn.call(board, .{ .verb = "add", .args = &.{.{ .string = full_text }} }, arena)) {
        .fulfilled => |arg| switch (arg) {
            .integer => |id| id,
            else => die(nick, "add did not return a task id"),
        },
        .broken => |reason| die(nick, reason),
        .give => die(nick, "add resolved to an introduction"),
    };
    std.debug.print("[{s}] added task #{d}\n", .{ nick, added_id });

    switch (try conn.call(board, .{ .verb = "list", .args = &.{} }, arena)) {
        .fulfilled => |arg| switch (arg) {
            .list => |items| {
                std.debug.print("[{s}] {d} task(s) on the board\n", .{ nick, items.len });
                for (items) |item| printTask(item);
            },
            else => die(nick, "list did not return a list"),
        },
        .broken => |reason| die(nick, reason),
        .give => return error.UnexpectedIntroduction,
    }

    switch (try conn.call(board, .{ .verb = "done", .args = &.{.{ .integer = added_id }} }, arena)) {
        .fulfilled => std.debug.print("[{s}] completed task #{d}\n", .{ nick, added_id }),
        .broken => |reason| die(nick, reason),
        .give => return error.UnexpectedIntroduction,
    }

    const confirmed = switch (try conn.call(board, .{ .verb = "list", .args = &.{} }, arena)) {
        .fulfilled => |arg| switch (arg) {
            .list => |items| taskIsDone(items, added_id),
            else => die(nick, "list did not return a list"),
        },
        .broken => |reason| die(nick, reason),
        .give => return error.UnexpectedIntroduction,
    };

    if (confirmed) {
        std.debug.print("[{s}] confirmed task #{d} is done\n", .{ nick, added_id });
    } else {
        std.debug.print("tasks-client: {s} failed the round trip\n", .{nick});
        std.process.exit(1);
    }
}

fn fail(message: []const u8) error{Usage} {
    return demo_usage.usage("usage: pancake-tasks-client <port> <nick> <task-text>", message);
}
