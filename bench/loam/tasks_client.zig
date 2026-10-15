//! A hosted-call client for the Tasks board, in process.
//!
//! Every call goes through `Storage.call`, the same local owning call the app
//! uses at startup, so a measured call pays the Host/Vat, the attachment and
//! the storage engine and no socket. A reply belongs to the call that returned it, and a
//! capability in it stays valid until that call is released.
const std = @import("std");
const g = @import("glowcap");
const tasks = @import("tasks_storage");

const driver = g.driver.core;
const board = tasks.board;

pub const read_bit = 1 << 0;
/// Room for the largest reply a call here makes, which is an observation.
const reply_bytes = 16 * 1024;

/// A call whose reply the caller keeps, such as the facet of a list.
pub const Held = struct {
    call: *driver.Host.Call,

    pub fn value(self: Held) driver.Value {
        return self.call.result().ready;
    }
    pub fn cap(self: Held) driver.Capability {
        return self.value().capability;
    }
    pub fn deinit(self: Held) void {
        self.call.deinit();
    }
};

/// The change since a cursor, from one observation reply.
pub const Seen = struct {
    cursor: [56]u8,
    changed: bool,

    pub fn of(value: driver.Value) !Seen {
        if (value != .tagged or value.tagged.value.len != 5) return error.NotAnObservation;
        const fields = value.tagged.value;
        if (fields[0] != .bytes or fields[0].bytes.len != 56 or fields[3] != .boolean) return error.NotAnObservation;
        return .{ .cursor = fields[0].bytes[0..56].*, .changed = fields[3].boolean };
    }
};

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

/// A client over the app's `Storage` on one engine.
pub fn Client(comptime Storage: type) type {
    return struct {
        const Self = @This();
        storage: *Storage,
        allocator: std.mem.Allocator,

        pub fn call(self: Self, target: driver.Capability, verb: []const u8, args: []const driver.Value) !Held {
            return .{ .call = try self.storage.call(self.allocator, target, verb, args, reply_bytes) };
        }

        pub fn integer(self: Self, target: driver.Capability, verb: []const u8, args: []const driver.Value) !i64 {
            const held = try self.call(target, verb, args);
            defer held.deinit();
            const answer = held.value();
            return if (answer == .integer) answer.integer else error.NotAnInteger;
        }

        /// The child capability `verb at` names, as `list` and `task` return it.
        pub fn facet(self: Self, target: driver.Capability, verb: []const u8, at: usize) !Held {
            const held = try self.call(target, verb, &.{.{ .integer = @intCast(at) }});
            errdefer held.deinit();
            if (held.value() != .capability) return error.NotACapability;
            return held;
        }

        /// `mutate` at `sequence`, which advances only when the call settles.
        pub fn mutate(self: Self, target: driver.Capability, sequence: *i64, args: []const driver.Value) !Held {
            var wrapped: [4]driver.Value = undefined;
            wrapped[0] = .{ .integer = sequence.* };
            @memcpy(wrapped[1 .. 1 + args.len], args);
            const held = try self.call(target, "mutate", wrapped[0 .. 1 + args.len]);
            sequence.* += 1;
            return held;
        }

        /// Add a task and return the capability the list replies with.
        pub fn add(self: Self, list: driver.Capability, sequence: *i64, text: []const u8) !void {
            const held = try self.mutate(list, sequence, &.{ .{ .string = "add" }, .{ .string = text } });
            defer held.deinit();
            if (held.value() != .capability) return error.NotACapability;
        }

        /// Read a task and require its text.
        pub fn expectText(self: Self, task: driver.Capability, expected: []const u8) !void {
            const held = try self.call(task, "text", &.{});
            defer held.deinit();
            const answer = held.value();
            if (answer != .string or !std.mem.eql(u8, answer.string, expected)) return error.WrongTaskText;
        }

        /// Move `task` from `source` to the end of `destination`, and return the
        /// destination's count.
        pub fn move(self: Self, source: driver.Capability, sequence: *i64, task: driver.Capability, destination: driver.Capability) !i64 {
            const held = try self.mutate(source, sequence, &.{ .{ .string = "move" }, .{ .capability = task }, .{ .capability = destination } });
            defer held.deinit();
            const answer = held.value();
            return if (answer == .integer) answer.integer else error.NotAnInteger;
        }

        /// Derive a read-only share of `target` limited to that one object.
        /// Lists and tasks are facets of the board, so the board's root owns the
        /// derivation sequence.
        pub fn shareReadOnly(self: Self, root: driver.Capability, target: driver.Capability) !Held {
            var terms: Terms = undefined;
            const policy = terms.init(read_bit);
            const sequence = try self.integer(root, "derivation-sequence", &.{});
            const held = try self.call(target, "derive", &.{ .{ .integer = sequence }, .{ .symbol = "object" }, policy[0], policy[1], policy[2], .{ .integer = 0 } });
            errdefer held.deinit();
            if (held.value() != .capability) return error.NotACapability;
            return held;
        }

        /// Start watching the board. The first held reply is the receiver.
        pub fn observe(self: Self, root: driver.Capability, sequence: *i64) !Held {
            const held = try self.mutate(root, sequence, &.{.{ .string = "observe" }});
            errdefer held.deinit();
            const fronts = held.value();
            if (fronts != .list or fronts.list.len != 2 or fronts.list[0] != .capability) return error.NotAReceiver;
            return held;
        }

        /// Ask the receiver what changed since `cursor`, or for its first cursor.
        pub fn poll(self: Self, held: Held, cursor: ?[56]u8) !Seen {
            const receiver = held.value().list[0].capability;
            var bytes: [56]u8 = undefined;
            if (cursor) |value| bytes = value;
            const one = [_]driver.Value{.{ .bytes = &bytes }};
            const args: []const driver.Value = if (cursor != null) &one else &.{};
            const reply = try self.call(receiver, "poll", args);
            defer reply.deinit();
            return Seen.of(reply.value());
        }
    };
}
