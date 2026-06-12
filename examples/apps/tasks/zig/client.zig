//! A tasks board client, written on pancake actors in native Zig. Zig is the home
//! language, this runs on the same core every binding wraps, and it drives the
//! real TCP netlayer.
//!
//! On the driver surface this reads like the other languages: one owning
//! `driver.connect`, `fetch` the board by
//! name, `spawn` a watcher, then add a task, list, mark it done, list again to
//! confirm, and exit. The pump/poll/serve loop is one `step()`, still owned by
//! the caller. This is the same sequence every other language's one-shot client runs.
//!
//!   pancake-tasks-client <port> <nick> <task-text>
//!
//! It exits 0 once the full add-list-done-list round trip succeeds. The phases
//! alternate: a resolve callback advances a `wait_*` phase to its `send_*` phase,
//! and the main loop sends and advances that `send_*` phase back to a `wait_*` one.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;
const tcp = pancake.net_adapter.tcp;

const host_addr = "127.0.0.1";
const frame_cap: usize = 1 << 16;

const Phase = enum {
    wait_add,
    send_list_before,
    wait_list_before,
    send_done,
    wait_done,
    send_list_after,
    wait_list_after,
    done,
    failed,
};

const State = struct {
    nick: []const u8,
    phase: Phase = .wait_add,
    added_id: i64 = 0,
    confirmed: bool = false,
};

const Watcher = struct {
    pub fn handle(self: *Watcher, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "update")) return error.NoSuchMethod;
        return .{ .void = {} };
    }
};

fn onResolve(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    switch (state.phase) {
        .wait_add => switch (resolution) {
            .fulfilled => |arg| switch (arg) {
                .integer => |id| {
                    state.added_id = id;
                    state.phase = .send_list_before;
                    std.debug.print("[{s}] added task #{d}\n", .{ state.nick, id });
                },
                else => state.phase = .failed,
            },
            .broken => |reason| {
                std.debug.print("[{s}] add failed: {s}\n", .{ state.nick, reason });
                state.phase = .failed;
            },
        },
        .wait_list_before => switch (resolution) {
            .fulfilled => |arg| switch (arg) {
                .list => |items| {
                    std.debug.print("[{s}] {d} task(s) on the board\n", .{ state.nick, items.len });
                    for (items) |item| printTask(item);
                    state.phase = .send_done;
                },
                else => state.phase = .failed,
            },
            .broken => state.phase = .failed,
        },
        .wait_done => {
            state.phase = .send_list_after;
            std.debug.print("[{s}] completed task #{d}\n", .{ state.nick, state.added_id });
        },
        .wait_list_after => switch (resolution) {
            .fulfilled => |arg| switch (arg) {
                .list => |items| {
                    for (items) |item| {
                        switch (item) {
                            .list => |fields| {
                                if (fields.len >= 3) {
                                    const id = switch (fields[0]) {
                                        .integer => |v| v,
                                        else => 0,
                                    };
                                    const is_done = switch (fields[2]) {
                                        .boolean => |v| v,
                                        else => false,
                                    };
                                    if (id == state.added_id and is_done) state.confirmed = true;
                                }
                            },
                            else => {},
                        }
                    }
                    if (state.confirmed) {
                        std.debug.print("[{s}] confirmed task #{d} is done\n", .{ state.nick, state.added_id });
                        state.phase = .done;
                    } else {
                        std.debug.print("[{s}] FAIL — task #{d} not marked completed\n", .{ state.nick, state.added_id });
                        state.phase = .failed;
                    }
                },
                else => state.phase = .failed,
            },
            .broken => state.phase = .failed,
        },
        else => {},
    }
}

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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next();
    const port_str = args_iter.next() orelse return fail("missing <port>");
    const nick = args_iter.next() orelse return fail("missing <nick>");
    const task_text = args_iter.next() orelse return fail("missing <task-text>");
    const port = try std.fmt.parseInt(u16, port_str, 10);

    var state = State{ .nick = nick };

    const address = try tcp.parseHostPort(host_addr, port);
    var conn = try driver.connect(io, allocator, address, .{ .frame_cap = frame_cap });
    defer conn.close();

    const board = try conn.fetch("board");
    const watcher = try conn.spawn(Watcher, .{});

    // Watch the board — fire-and-forget, so `tell`: one deliver, no answer
    // minted (the round-trip below is what the client asserts on).
    try conn.tell(board, .{
        .verb = "watch",
        .args = &.{watcher.arg()},
    });

    var text_buf: [256]u8 = undefined;
    const full_text = std.fmt.bufPrint(&text_buf, "[{s}] {s}", .{ nick, task_text }) catch task_text;

    const add_promise = try conn.send(board, .{
        .verb = "add",
        .args = &.{.{ .string = full_text }},
    });
    try conn.on(add_promise, .{ .ctx = &state, .func = onResolve });

    var rounds: usize = 0;
    while (state.phase != .done and state.phase != .failed and rounds < 200) : (rounds += 1) {
        const progress = conn.step() catch |err| {
            std.debug.print("tasks-client: step error: {s}\n", .{@errorName(err)});
            break;
        };

        switch (state.phase) {
            .send_list_before => {
                const p = try conn.send(board, .{ .verb = "list", .args = &.{} });
                state.phase = .wait_list_before;
                try conn.on(p, .{ .ctx = &state, .func = onResolve });
            },
            .send_done => {
                const p = try conn.send(board, .{
                    .verb = "done",
                    .args = &.{.{ .integer = state.added_id }},
                });
                state.phase = .wait_done;
                try conn.on(p, .{ .ctx = &state, .func = onResolve });
            },
            .send_list_after => {
                const p = try conn.send(board, .{ .verb = "list", .args = &.{} });
                state.phase = .wait_list_after;
                try conn.on(p, .{ .ctx = &state, .func = onResolve });
            },
            else => {},
        }

        if (progress == .closed) break;
    }

    if (!state.confirmed) {
        std.debug.print("tasks-client: {s} failed the round trip\n", .{nick});
        std.process.exit(1);
    }
}

fn fail(message: []const u8) error{Usage} {
    std.debug.print("usage: pancake-tasks-client <port> <nick> <task-text>\n  ({s})\n", .{message});
    return error.Usage;
}
