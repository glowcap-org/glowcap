//! The counter, greeter, and reader the vat suite reuses across its files.

const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const Turn = actors.Turn;
const Message = actors.Message;
const Delivery = actors.Delivery;

/// A counter whose `self` *is* its state, `increment`/`add` mutate it in place,
/// the Zig-native "become".
pub const Counter = struct {
    n: i64,

    pub fn handle(self: *Counter, turn: *Turn, msg: Delivery) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "get")) return .{ .integer = self.n };
        if (std.mem.eql(u8, msg.verb, "increment")) {
            self.n += 1;
            return .{ .void = {} };
        }
        if (std.mem.eql(u8, msg.verb, "add")) {
            self.n += try msg.argInt(0);
            return .{ .integer = self.n };
        }
        return error.NoSuchMethod;
    }
};

/// A greeter whose reply is freshly built each turn, so it must allocate. It uses
/// `turn.arena`, the per-turn allocator the vat reclaims, proving a handler can
/// return heap-allocated storage without leaking and without freeing it itself.
pub const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *Turn, msg: Delivery) !model.Argument {
        _ = self;
        const greeting = try std.fmt.allocPrint(turn.arena, "hello, {s}", .{try msg.argBytes(0)});
        return .{ .bytes = greeting };
    }
};

pub fn getN(vat: *actors.Vat, ref: actors.Ref) !i64 {
    return (try vat.near(ref, .{ .verb = "get" })).integer;
}

/// A persistent actor (tier 3): it never mutates `self`, producing its next
/// state with `turn.become`. It defines no `clone`, so a snapshot can only admit
/// it via the persistent (share-only) path.
pub const PersistentCounter = struct {
    pub const snapshot_persistent = true;
    n: i64,

    pub fn handle(self: *const PersistentCounter, turn: *Turn, msg: Delivery) !model.Argument {
        if (std.mem.eql(u8, msg.verb, "get")) return .{ .integer = self.n };
        if (std.mem.eql(u8, msg.verb, "increment")) {
            try turn.become(PersistentCounter, .{ .n = self.n + 1 });
            return .{ .void = {} };
        }
        if (std.mem.eql(u8, msg.verb, "bump-then-fail")) {
            // Stage a become, then error: the staged value must be discarded.
            try turn.become(PersistentCounter, .{ .n = 999 });
            return error.Boom;
        }
        return error.NoSuchMethod;
    }
};

/// A mutable actor whose reply borrows its own heap label. `relabel` frees
/// that label and installs a fresh same-size one, so a resolution that still
/// borrowed the state would read freed (and likely reused) memory.
pub const LabelHolder = struct {
    allocator: std.mem.Allocator,
    label: []u8,

    pub fn handle(self: *LabelHolder, turn: *Turn, msg: Delivery) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "get")) return .{ .bytes = self.label };
        if (std.mem.eql(u8, msg.verb, "relabel")) {
            const fresh = try self.allocator.dupe(u8, try msg.argBytes(0));
            self.allocator.free(self.label);
            self.label = fresh;
            return .{ .void = {} };
        }
        return error.NoSuchMethod;
    }

    pub fn deinit(self: *LabelHolder, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
    }
};

/// Stores the bytes it is sent, but first it scribbles over the
/// turn arena, so a message that (wrongly) still borrowed reset arena storage
/// would arrive corrupted.
pub const Sink = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    pub fn handle(self: *Sink, turn: *Turn, msg: Delivery) !model.Argument {
        const filler = try turn.arena.alloc(u8, 256);
        @memset(filler, 'Z');
        const bytes = try msg.argBytes(0);
        @memcpy(self.buf[0..bytes.len], bytes);
        self.len = bytes.len;
        return .{ .void = {} };
    }
};

/// A listener that first drives the rest of the queue, running a turn that
/// mutates the very state the resolution's value was borrowed from, and only
/// then reads the resolution bytes.
pub const MutateThenRead = struct {
    vat: *actors.Vat,
    buf: [64]u8 = undefined,
    len: usize = 0,
    broke: bool = false,

    pub fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *MutateThenRead = @ptrCast(@alignCast(ctx.?));
        const bytes = switch (resolution) {
            .fulfilled => |value| value.bytes,
            .broken, .give => {
                self.broke = true;
                return;
            },
        };
        // The nested drive runs the queued `relabel`, which frees the actor
        // label the handler's reply borrowed. The resolution this listener
        // holds must be the vat's settle clone, never that borrow.
        self.vat.drive() catch {
            self.broke = true;
            return;
        };
        @memcpy(self.buf[0..bytes.len], bytes);
        self.len = bytes.len;
    }
};

/// Forwards its argument to a sink with a fresh payload built in `turn.arena`,
/// the documented handler pattern for outgoing args. The queued send must
/// survive the turn-arena reset that opens the sink's own turn.
pub const Forwarder = struct {
    sink: actors.Ref,

    pub fn handle(self: *Forwarder, turn: *Turn, msg: Delivery) !model.Argument {
        const payload = try std.fmt.allocPrint(turn.arena, "payload-{s}", .{try msg.argBytes(0)});
        _ = try turn.send(self.sink, .{ .verb = "store", .args = &.{.{ .bytes = payload }} });
        return .{ .void = {} };
    }
};
