//! A Tasks board client in Zig, on the same driver surface every binding wraps.
//!
//! It fetches the board by the name the server printed and starts watching it,
//! adds a task to the first list, marks it done by moving it to the second
//! list, and reads both lists to confirm. The watcher then reports that the
//! board changed. Each change names a fresh sequence number from
//! `mutation-sequence`, so a retried change applies once.
//!
//!   glowcap-tasks-client <port> <board-name> <nick> <task-text>
//!
//! It exits 0 once the task shows up in the second list and the watcher saw
//! the change.

const std = @import("std");
const glowcap = @import("glowcap");

const demo_usage = @import("demo_usage");

const driver = glowcap.driver;
const tcp = glowcap.net.tcp;

const host_addr = "127.0.0.1";
const frame_cap: usize = 1 << 16;

const Client = struct {
    session: *driver.Session,
    arena: std.mem.Allocator,
    nick: []const u8,

    fn call(self: Client, target: driver.Capability, verb: []const u8, args: []const driver.Value) driver.Value {
        return switch (self.session.call(target, verb, args, self.arena) catch |err| die(self.nick, @errorName(err))) {
            .fulfilled => |value| value,
            .broken => |reason| die(self.nick, reason),
        };
    }

    fn integer(self: Client, target: driver.Capability, verb: []const u8, args: []const driver.Value) i64 {
        const value = self.call(target, verb, args);
        return if (value == .integer) value.integer else die(self.nick, "expected an integer reply");
    }

    fn facet(self: Client, target: driver.Capability, verb: []const u8, at: i64) driver.Capability {
        const value = self.call(target, verb, &.{.{ .integer = at }});
        return if (value == .capability) value.capability else die(self.nick, "expected a capability reply");
    }

    /// One change with a fresh sequence number, so a retry applies once.
    fn mutate(self: Client, target: driver.Capability, args: []const driver.Value) driver.Value {
        var wrapped: [4]driver.Value = undefined;
        wrapped[0] = .{ .integer = self.integer(target, "mutation-sequence", &.{}) };
        @memcpy(wrapped[1 .. 1 + args.len], args);
        return self.call(target, "mutate", wrapped[0 .. 1 + args.len]);
    }

    /// Poll a watcher from `cursor`. Returns whether the board changed since,
    /// and moves `cursor` to the reply's.
    fn changed(self: Client, receiver: driver.Capability, cursor: *[]const u8) bool {
        const value = self.call(receiver, "poll", if (cursor.len == 0) &.{} else &.{.{ .bytes = cursor.* }});
        if (value != .tagged or value.tagged.value.len != 5) die(self.nick, "the watcher sent no observation");
        // Loam's `access:observation` record, see docs/loam/access-observation.md:
        // fields[0] is the cursor and fields[3] is whether anything changed.
        const fields = value.tagged.value;
        if (fields[0] != .bytes or fields[3] != .boolean) die(self.nick, "the watcher sent no observation");
        cursor.* = fields[0].bytes;
        return fields[3].boolean;
    }

    /// Print a list and report whether it holds `wanted`.
    fn show(self: Client, list: driver.Capability, wanted: []const u8) bool {
        const name = self.call(list, "name", &.{});
        const count = self.integer(list, "count", &.{});
        std.debug.print("[{s}] {s}: {d} task(s)\n", .{ self.nick, if (name == .string) name.string else "?", count });
        var found = false;
        for (0..@intCast(count)) |i| {
            const text = self.call(self.facet(list, "task", @intCast(i)), "text", &.{});
            if (text != .string) die(self.nick, "a task had no text");
            std.debug.print("  {s}\n", .{text.string});
            found = found or std.mem.eql(u8, text.string, wanted);
        }
        return found;
    }
};

/// Print the failure and exit non-zero, usable in any expression position.
fn die(nick: []const u8, reason: []const u8) noreturn {
    std.debug.print("tasks-client: {s} failed: {s}\n", .{ nick, reason });
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next();
    const port_str = args_iter.next() orelse return fail("missing <port>");
    const board_name = args_iter.next() orelse return fail("missing <board-name>");
    const nick = args_iter.next() orelse return fail("missing <nick>");
    const task_text = args_iter.next() orelse return fail("missing <task-text>");
    const port = std.fmt.parseInt(u16, port_str, 10) catch return fail("<port> must be a number");

    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const loc = tcp.locatorFromAddress(&designator_buf, try tcp.parseHostPort(host_addr, port));
    const session = try driver.connect(init.gpa, init.io, .{ .symbols = &.{.tcp} }, loc, .ephemeral, .{ .frame_cap = frame_cap, .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } });
    defer session.deinit();
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const client: Client = .{ .session = session, .arena = arena_state.allocator(), .nick = nick };

    var text_buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "[{s}] {s}", .{ nick, task_text }) catch return fail(std.fmt.comptimePrint("<nick> and <task-text> together must fit in {d} bytes", .{text_buf.len - "[] ".len}));

    const board = try session.fetch(board_name);
    // Watching replies with a receiver to poll and a canceller that frees the
    // owner's observation context.
    const watch = client.mutate(board, &.{.{ .string = "observe" }});
    if (watch != .list or watch.list.len != 2 or watch.list[0] != .capability) die(nick, "watching returned no receiver");
    const receiver = watch.list[0].capability;
    const canceller = watch.list[1];
    if (canceller != .capability) die(nick, "watching returned no canceller");
    var cursor: []const u8 = &.{};
    _ = client.changed(receiver, &cursor);
    const todo = client.facet(board, "list", 0);
    const done = client.facet(board, "list", 1);
    // Adding replies with the new task, and the move names it by that
    // capability, so it moves exactly this task whatever else changed.
    const added = client.mutate(todo, &.{ .{ .string = "add" }, .{ .string = text } });
    const task = if (added == .capability) added.capability else die(nick, "adding a task returned no task");
    std.debug.print("[{s}] added a task\n", .{nick});
    _ = client.mutate(todo, &.{ .{ .string = "move" }, .{ .capability = task }, .{ .capability = done } });
    std.debug.print("[{s}] marked it done\n", .{nick});
    _ = client.show(todo, text);
    if (!client.show(done, text)) die(nick, "the task is not in the done list");
    std.debug.print("[{s}] confirmed the task is done\n", .{nick});
    if (!client.changed(receiver, &cursor)) die(nick, "the watcher saw no change");
    std.debug.print("[{s}] the watcher saw the board change\n", .{nick});
    const cancelled = client.call(canceller.capability, "cancel", &.{});
    if (cancelled != .boolean) die(nick, "cancelling the watcher returned no boolean");
}

fn fail(message: []const u8) error{Usage} {
    return demo_usage.usage("usage: glowcap-tasks-client <port> <board-name> <nick> <task-text>", message);
}
