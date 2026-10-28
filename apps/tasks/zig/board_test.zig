//! The Tasks server over real TCP, with its board in a temporary SQLite store.
//! A client adds and moves tasks, an oversized task is refused without a
//! change, and after the server closes and opens the same directory, the same
//! name reaches the same board with every task on it. A failure points at
//! the board's behaviors (`board.zig`) or the server's storage loop.
const std = @import("std");
const glowcap = @import("glowcap");
const board = @import("board.zig");
const server_mod = @import("server.zig");
const Storage = server_mod.Storage;
const driver = glowcap.driver;
const tcp = glowcap.net.tcp;

const io = std.testing.io;
const a = std.testing.allocator;

/// One running server: the listener, its board, and the thread serving both.
const Running = struct {
    server: *driver.Server,
    storage: Storage,
    stop: std.atomic.Value(bool) = .init(false),
    thread: std.Thread,
    port: u16,

    fn start(self: *Running, path: [:0]const u8) !void {
        self.* = .{ .server = undefined, .storage = undefined, .thread = undefined, .port = 0 };
        self.server = try driver.listen(a, io, .{ .symbols = &.{.tcp} }, glowcap.ocapn.model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, server_mod.session_opts);
        errdefer self.server.deinit();
        try self.storage.open(a, io, self.server.runtime.core, path);
        errdefer self.storage.close() catch {}; // tolerant: the start already failed.
        var buf: [tcp.designator_buf_len]u8 = undefined;
        self.port = switch (try tcp.parseDesignator(try self.server.localDesignator(&buf))) {
            .ip4 => |address| address.port,
            .ip6 => |address| address.port,
        };
        self.thread = try std.Thread.spawn(.{}, serveUntilStopped, .{self});
    }

    fn serveUntilStopped(self: *Running) void {
        server_mod.serve(self.server, &self.storage, &self.stop) catch |err| std.debug.panic("serving failed: {s}", .{@errorName(err)});
    }

    fn finish(self: *Running) !void {
        self.stop.store(true, .release);
        self.thread.join();
        try self.storage.close();
        self.server.deinit();
    }
};

const Client = struct {
    session: *driver.Session,
    arena: std.heap.ArenaAllocator,
    /// Why the last refused call was refused.
    reason: []const u8 = "",

    fn connect(port: u16) !Client {
        var buf: [tcp.designator_buf_len]u8 = undefined;
        const locator = tcp.locatorFromAddress(&buf, try tcp.parseHostPort("127.0.0.1", port));
        return .{ .session = try driver.connect(a, io, .{ .symbols = &.{.tcp} }, locator, .ephemeral, server_mod.session_opts), .arena = .init(a) };
    }

    fn deinit(self: *Client) void {
        self.session.deinit();
        self.arena.deinit();
    }

    fn reply(self: *Client, target: driver.Capability, verb: []const u8, args: []const driver.Value) !driver.Value {
        return switch (try self.session.call(target, verb, args, self.arena.allocator())) {
            .fulfilled => |value| value,
            .broken => |reason| {
                self.reason = reason;
                return error.Refused;
            },
        };
    }

    fn integer(self: *Client, target: driver.Capability, verb: []const u8, args: []const driver.Value) !i64 {
        const value = try self.reply(target, verb, args);
        return if (value == .integer) value.integer else error.NotAnInteger;
    }

    fn facet(self: *Client, target: driver.Capability, verb: []const u8, at: i64) !driver.Capability {
        const value = try self.reply(target, verb, &.{.{ .integer = at }});
        return if (value == .capability) value.capability else error.NotACapability;
    }

    fn mutate(self: *Client, target: driver.Capability, args: []const driver.Value) !driver.Value {
        return self.mutateAt(target, try self.integer(target, "mutation-sequence", &.{}), args);
    }

    fn mutateAt(self: *Client, target: driver.Capability, sequence: i64, args: []const driver.Value) !driver.Value {
        var wrapped: [4]driver.Value = undefined;
        wrapped[0] = .{ .integer = sequence };
        @memcpy(wrapped[1 .. 1 + args.len], args);
        return self.reply(target, "mutate", wrapped[0 .. 1 + args.len]);
    }

    /// Add a task at `sequence` and return the task the list replies with.
    fn addAt(self: *Client, list: driver.Capability, sequence: i64, task: []const u8) !driver.Capability {
        const value = try self.mutateAt(list, sequence, &.{ .{ .string = "add" }, .{ .string = task } });
        return if (value == .capability) value.capability else error.NotACapability;
    }

    fn textOf(self: *Client, task: driver.Capability) ![]const u8 {
        const value = try self.reply(task, "text", &.{});
        return if (value == .string) value.string else error.NotAString;
    }

    /// The call is refused, and the reason names `cause`.
    fn expectRefused(self: *Client, cause: []const u8, result: anytype) !void {
        try std.testing.expectError(error.Refused, result);
        if (std.mem.indexOf(u8, self.reason, cause) == null) {
            std.debug.print("refused for \"{s}\", expected \"{s}\"\n", .{ self.reason, cause });
            return error.WrongRefusal;
        }
    }

    fn text(self: *Client, list: driver.Capability, at: i64) ![]const u8 {
        return self.textOf(try self.facet(list, "task", at));
    }
};

test "tasks board keeps its lists, tasks, and name across a restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    const terminated = try a.dupeSentinel(u8, path, 0);
    defer a.free(terminated);

    var first: Running = undefined;
    try first.start(terminated);
    var name: [64]u8 = undefined;
    const name_len = first.storage.name.slice().len;
    @memcpy(name[0..name_len], first.storage.name.slice());
    {
        errdefer first.finish() catch {}; // tolerant: the test already failed.
        var client = try Client.connect(first.port);
        defer client.deinit();
        const root = try client.session.fetch(name[0..name_len]);
        try std.testing.expectEqual(@as(i64, 2), try client.integer(root, "lists", &.{}));
        const todo = try client.facet(root, "list", 0);
        const done = try client.facet(root, "list", 1);
        // Adding replies with the new task. A retried add with the same
        // sequence number applies once and replies with the same task.
        const sequence = try client.integer(todo, "mutation-sequence", &.{});
        const first_task = try client.addAt(todo, sequence, "write tests");
        try std.testing.expectEqualStrings("write tests", try client.textOf(try client.addAt(todo, sequence, "write tests")));
        try std.testing.expectEqual(@as(i64, 1), try client.integer(todo, "count", &.{}));
        const second_task = try client.addAt(todo, sequence + 1, "ship it");
        try std.testing.expectEqualStrings("ship it", try client.textOf(second_task));
        const moved = try client.mutate(todo, &.{ .{ .string = "move" }, .{ .capability = first_task }, .{ .capability = done } });
        try std.testing.expectEqual(@as(i64, 1), moved.integer);
        // The moved task's capability still reads it, now from Done.
        try std.testing.expectEqualStrings("write tests", try client.textOf(first_task));

        // Too long for a task: refused, and the list is unchanged.
        const oversized = try a.alloc(u8, board.max_text_bytes + 1);
        defer a.free(oversized);
        @memset(oversized, 'x');
        try client.expectRefused("InvalidArguments", client.mutate(todo, &.{ .{ .string = "add" }, .{ .string = oversized } }));
        // A task can't move into the list it is already in or into a task.
        const remaining = try client.facet(todo, "task", 0);
        try client.expectRefused("DuplicateParticipant", client.mutate(todo, &.{ .{ .string = "move" }, .{ .capability = remaining }, .{ .capability = todo } }));
        try client.expectRefused("InvalidArguments", client.mutate(todo, &.{ .{ .string = "move" }, .{ .capability = remaining }, .{ .capability = first_task } }));
        // A list moves only a task it holds.
        try client.expectRefused("NotInThisList", client.mutate(done, &.{ .{ .string = "move" }, .{ .capability = remaining }, .{ .capability = todo } }));
        // A list has no task at a position past its end.
        try client.expectRefused("NoSuchEdge", client.facet(todo, "task", 5));
        try std.testing.expectEqual(@as(i64, 1), try client.integer(todo, "count", &.{}));
        try std.testing.expectEqual(@as(i64, 1), try client.integer(done, "count", &.{}));
    }
    try first.finish();

    var second: Running = undefined;
    try second.start(terminated);
    defer second.finish() catch |err| std.debug.panic("closing the server failed: {s}", .{@errorName(err)});
    try std.testing.expectEqualStrings(name[0..name_len], second.storage.name.slice());
    var client = try Client.connect(second.port);
    defer client.deinit();
    const root = try client.session.fetch(name[0..name_len]);
    try std.testing.expectEqual(@as(i64, 2), try client.integer(root, "lists", &.{}));
    const todo = try client.facet(root, "list", 0);
    const done = try client.facet(root, "list", 1);
    try std.testing.expectEqualStrings("ship it", try client.text(todo, 0));
    try std.testing.expectEqualStrings("write tests", try client.text(done, 0));
    try std.testing.expectEqual(@as(i64, 1), try client.integer(done, "count", &.{}));
}

/// The shared vocabulary's terms for `permissions` on the Tasks policy. The
/// values point into this struct, so it stays put while a call uses them.
const Terms = struct {
    identity: [16]u8,
    mask: [8]u8,
    masks: [1]driver.Value,
    values: [3]driver.Value,

    fn init(self: *Terms, permissions: u64) []const driver.Value {
        std.mem.writeInt(u128, &self.identity, @backingInt(board.policy.id), .big);
        std.mem.writeInt(u64, &self.mask, permissions, .big);
        self.masks = .{.{ .bytes = &self.mask }};
        self.values = .{ .{ .bytes = &self.identity }, .{ .list = &self.masks }, .{ .list = &.{} } };
        return &self.values;
    }
};
const read_bit = 1 << 0;
const post_bit = 1 << 1;

/// Share `target` with `permissions`. Lists and tasks are facets of the board,
/// so the board's root capability owns the derivation sequence and receipts.
fn share(client: *Client, owner: driver.Capability, target: driver.Capability, scope: []const u8, permissions: u64, depth: i64) !driver.Capability {
    var terms: Terms = undefined;
    const policy = terms.init(permissions);
    const sequence = try client.integer(owner, "derivation-sequence", &.{});
    const value = try client.reply(target, "derive", &.{ .{ .integer = sequence }, .{ .symbol = scope }, policy[0], policy[1], policy[2], .{ .integer = depth } });
    return if (value == .capability) value.capability else error.NotACapability;
}

fn durableName(client: *Client, target: driver.Capability, buffer: []u8) ![]const u8 {
    const value = try client.reply(target, "durable-name", &.{});
    if (value != .string) return error.NotAString;
    @memcpy(buffer[0..value.string.len], value.string);
    return buffer[0..value.string.len];
}

test "tasks board shares read-only links that survive a restart and revokes a shared board" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    const terminated = try a.dupeSentinel(u8, path, 0);
    defer a.free(terminated);

    var first: Running = undefined;
    try first.start(terminated);
    var list_name_buf: [128]u8 = undefined;
    var task_name_buf: [128]u8 = undefined;
    var list_name: []const u8 = undefined;
    var task_name: []const u8 = undefined;
    {
        errdefer first.finish() catch {}; // tolerant: the test already failed.
        var client = try Client.connect(first.port);
        defer client.deinit();
        const root = try client.session.fetch(first.storage.name.slice());
        const todo = try client.facet(root, "list", 0);
        const done = try client.facet(root, "list", 1);
        _ = try client.mutate(todo, &.{ .{ .string = "add" }, .{ .string = "write tests" } });

        // A read-only share of the list reads it and is refused a change.
        const reader = try share(&client, root, todo, "object", read_bit, 1);
        try std.testing.expectEqual(@as(i64, 1), try client.integer(reader, "count", &.{}));
        try client.expectRefused("Denied", client.mutate(reader, &.{ .{ .string = "add" }, .{ .string = "sneak in" } }));
        // A share can pass on what it holds and no more: an object share
        // can't derive a share of everything under it.
        try client.expectRefused("CeilingExceeded", share(&client, reader, reader, "subtree", read_bit, 0));
        // An object share of the board reaches the board and none of its lists.
        const board_only = try share(&client, root, root, "object", read_bit, 0);
        try std.testing.expectEqual(@as(i64, 2), try client.integer(board_only, "lists", &.{}));
        try client.expectRefused("OutOfScope", client.integer(try client.facet(board_only, "list", 0), "count", &.{}));
        list_name = try durableName(&client, reader, &list_name_buf);

        // A read-only share of a task keeps reading it after the task moves.
        const task = try client.facet(todo, "task", 0);
        const shared_task = try share(&client, root, task, "object", read_bit, 0);
        _ = try client.mutate(todo, &.{ .{ .string = "move" }, .{ .capability = task }, .{ .capability = done } });
        const moved = try client.reply(shared_task, "text", &.{});
        try std.testing.expectEqualStrings("write tests", moved.string);
        task_name = try durableName(&client, shared_task, &task_name_buf);

        // A managed subtree share of the whole board reaches every list until
        // its control revokes it, and then reaches nothing below it either.
        var terms: Terms = undefined;
        const policy = terms.init(read_bit | post_bit);
        const sequence = try client.integer(root, "derivation-sequence", &.{});
        const pair = try client.reply(root, "derive-managed", &.{ .{ .integer = sequence }, .{ .symbol = "subtree" }, policy[0], policy[1], policy[2], .{ .integer = 0 }, .{ .list = &.{ .void, .void, .{ .integer = 4 } } } });
        if (pair != .list or pair.list.len != 2 or pair.list[0] != .capability or pair.list[1] != .capability) return error.NotAPair;
        const guest = pair.list[0].capability;
        const control = pair.list[1].capability;
        try std.testing.expectEqual(@as(i64, 2), try client.integer(guest, "lists", &.{}));
        const guest_list = try client.facet(guest, "list", 1);
        try std.testing.expectEqual(@as(i64, 1), try client.integer(guest_list, "count", &.{}));
        try std.testing.expectEqualStrings("write tests", try client.text(guest_list, 0));
        // The share reaches a task added after it was issued.
        _ = try client.mutate(done, &.{ .{ .string = "add" }, .{ .string = "added later" } });
        try std.testing.expectEqualStrings("added later", try client.text(guest_list, 1));
        const described = try client.reply(control, "describe-control", &.{});
        if (described != .tagged or described.tagged.value.len != 10 or described.tagged.value[9] != .integer) return error.NotAControl;
        var revision: [8]u8 = undefined;
        std.mem.writeInt(u64, &revision, @intCast(described.tagged.value[9].integer), .big);
        const revoke_sequence = try client.integer(control, "mutation-sequence", &.{});
        _ = try client.reply(control, "mutate", &.{ .{ .integer = revoke_sequence }, .{ .string = "revoke" }, .{ .bytes = &revision } });
        try client.expectRefused("Revoked", client.integer(guest, "lists", &.{}));
        try client.expectRefused("Revoked", client.integer(guest_list, "count", &.{}));
        // The owner's own access is untouched.
        try std.testing.expectEqual(@as(i64, 2), try client.integer(root, "lists", &.{}));
    }
    try first.finish();

    var second: Running = undefined;
    try second.start(terminated);
    defer second.finish() catch |err| std.debug.panic("closing the server failed: {s}", .{@errorName(err)});
    var client = try Client.connect(second.port);
    defer client.deinit();
    // Both read-only links still work after the restart, and still read only.
    const reader = try client.session.fetch(list_name);
    try std.testing.expectEqual(@as(i64, 0), try client.integer(reader, "count", &.{}));
    try client.expectRefused("Denied", client.mutate(reader, &.{ .{ .string = "add" }, .{ .string = "sneak in" } }));
    const shared_task = try client.session.fetch(task_name);
    const text = try client.reply(shared_task, "text", &.{});
    try std.testing.expectEqualStrings("write tests", text.string);
}

/// One observation reply: its cursor (copied out of the reply) and whether
/// something below the board changed since the cursor the poll sent.
const Seen = struct {
    cursor: [56]u8,
    changed: bool,
    below: bool,

    fn of(value: driver.Value) !Seen {
        if (value != .tagged or !std.mem.eql(u8, value.tagged.tag, "access:observation") or value.tagged.value.len != 5) return error.NotAnObservation;
        const fields = value.tagged.value;
        if (fields[0] != .bytes or fields[0].bytes.len != 56 or fields[2] != .boolean or fields[3] != .boolean or fields[4] != .list) return error.NotAnObservation;
        var below = false;
        for (fields[4].list) |notice| if (notice == .symbol and std.mem.eql(u8, notice.symbol, "subtree")) {
            below = true;
        };
        return .{ .cursor = fields[0].bytes[0..56].*, .changed = fields[3].boolean, .below = below };
    }
};

test "tasks board watcher catches up on changes made while it was away, across a restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    const terminated = try a.dupeSentinel(u8, path, 0);
    defer a.free(terminated);

    var first: Running = undefined;
    try first.start(terminated);
    var receiver_name_buf: [128]u8 = undefined;
    var receiver_name: []const u8 = undefined;
    var cursor: [56]u8 = undefined;
    {
        errdefer first.finish() catch {}; // tolerant: the test already failed.
        var client = try Client.connect(first.port);
        defer client.deinit();
        const root = try client.session.fetch(first.storage.name.slice());
        // Watch the whole board. The receiver has its own durable name.
        const sequence = try client.integer(root, "mutation-sequence", &.{});
        const fronts = try client.reply(root, "mutate", &.{ .{ .integer = sequence }, .{ .string = "observe" } });
        if (fronts != .list or fronts.list.len != 2 or fronts.list[0] != .capability or fronts.list[1] != .capability) return error.NotAReceiver;
        const receiver = fronts.list[0].capability;
        receiver_name = try durableName(&client, receiver, &receiver_name_buf);
        const start = try Seen.of(try client.reply(receiver, "poll", &.{}));

        // A task added to a list is a change below the board.
        _ = try client.mutate(try client.facet(root, "list", 0), &.{ .{ .string = "add" }, .{ .string = "write tests" } });
        const seen = try Seen.of(try client.reply(receiver, "receive", &.{.{ .bytes = &start.cursor }}));
        try std.testing.expect(seen.changed and seen.below);
        cursor = seen.cursor;
    }
    try first.finish();

    var second: Running = undefined;
    try second.start(terminated);
    defer second.finish() catch |err| std.debug.panic("closing the server failed: {s}", .{@errorName(err)});
    // Another client changes the board while the watcher is away.
    {
        var other = try Client.connect(second.port);
        defer other.deinit();
        const root = try other.session.fetch(second.storage.name.slice());
        const todo = try other.facet(root, "list", 0);
        _ = try other.mutate(todo, &.{ .{ .string = "move" }, .{ .capability = try other.facet(todo, "task", 0) }, .{ .capability = try other.facet(root, "list", 1) } });
    }
    // The watcher comes back with its receiver's name and last cursor, and
    // learns that the board changed without missing the move.
    var watcher = try Client.connect(second.port);
    defer watcher.deinit();
    const receiver = try watcher.session.fetch(receiver_name);
    const caught_up = try Seen.of(try watcher.reply(receiver, "poll", &.{.{ .bytes = &cursor }}));
    try std.testing.expect(caught_up.changed and caught_up.below);
    // Nothing changed since, so its new cursor reports no change.
    const settled = try Seen.of(try watcher.reply(receiver, "poll", &.{.{ .bytes = &caught_up.cursor }}));
    try std.testing.expect(!settled.changed);
}

test "tasks board fills a list to its limit and moves a task between full lists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    const terminated = try a.dupeSentinel(u8, path, 0);
    defer a.free(terminated);
    var running: Running = undefined;
    try running.start(terminated);
    defer running.finish() catch |err| std.debug.panic("closing the server failed: {s}", .{@errorName(err)});
    var client = try Client.connect(running.port);
    defer client.deinit();
    const root = try client.session.fetch(running.storage.name.slice());
    const todo = try client.facet(root, "list", 0);
    const done = try client.facet(root, "list", 1);
    // One client holds every task it adds, a full list's worth.
    var first: driver.Capability = undefined;
    for (0..board.max_tasks) |i| {
        const task = try client.addAt(todo, try client.integer(todo, "mutation-sequence", &.{}), "task");
        if (i == 0) first = task;
    }
    // A full list refuses another task and changes nothing.
    try client.expectRefused("TooManyEdges", client.mutate(todo, &.{ .{ .string = "add" }, .{ .string = "one too many" } }));
    try std.testing.expectEqual(@as(i64, board.max_tasks), try client.integer(todo, "count", &.{}));
    for (0..board.max_tasks - 1) |_| _ = try client.mutate(done, &.{ .{ .string = "add" }, .{ .string = "done" } });
    // A move between two full-size lists fits one call.
    _ = try client.mutate(todo, &.{ .{ .string = "move" }, .{ .capability = first }, .{ .capability = done } });
    try std.testing.expectEqual(@as(i64, board.max_tasks - 1), try client.integer(todo, "count", &.{}));
    try std.testing.expectEqual(@as(i64, board.max_tasks), try client.integer(done, "count", &.{}));
}

// Independent expectations for test/interface/contracts.syrup. A failure means
// the authored contract disagrees with the current Tasks server.
test "tasks interface creation boundaries and public result" {
    try std.testing.expectEqual(@as(usize, 64), board.max_name_bytes);
    try std.testing.expectEqual(@as(usize, 4096), board.max_text_bytes);
    try std.testing.expectEqual(@as(usize, 16), board.max_lists);
    try std.testing.expectEqual(@as(usize, 256), board.max_tasks);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    const terminated = try a.dupeSentinel(u8, path, 0);
    defer a.free(terminated);
    var running: Running = undefined;
    try running.start(terminated);
    defer running.finish() catch |err| std.debug.panic("closing failed: {s}", .{@errorName(err)});
    var client = try Client.connect(running.port);
    defer client.deinit();
    const root = try client.session.fetch(running.storage.name.slice());
    const list = try client.facet(root, "list", 0);
    try client.expectRefused("InvalidArguments", client.mutate(list, &.{ .{ .string = "add" }, .{ .string = "" } }));
    const text: [4096]u8 = @splat('x');
    const sequence = try client.integer(list, "mutation-sequence", &.{});
    const args = [_]driver.Value{ .{ .integer = sequence }, .{ .string = "add" }, .{ .string = &text } };
    // Assert the public envelope directly, without Client.addAt/mutateAt.
    const reply = try client.reply(list, "mutate", &args);
    try std.testing.expect(reply == .capability);
    try std.testing.expectEqualStrings(&text, try client.textOf(reply.capability));
    const replay = try client.reply(list, "mutate", &args);
    try std.testing.expect(replay == .capability);
    try std.testing.expectEqualStrings(&text, try client.textOf(replay.capability));
    try std.testing.expectEqual(@as(i64, 1), try client.integer(list, "count", &.{}));
    const too_long: [4097]u8 = @splat('x');
    try client.expectRefused("InvalidArguments", client.mutate(list, &.{ .{ .string = "add" }, .{ .string = &too_long } }));
    try std.testing.expectEqual(@as(i64, 1), try client.integer(list, "count", &.{}));
}
