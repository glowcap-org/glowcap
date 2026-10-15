//! A delivery's arguments as a Value-shaped Host behavior reads them: one
//! accessor set over two backings. A wire deliver that carries no reference
//! or handoff lends the frame's views, so the handler reads the bytes where
//! they lie and the Host builds nothing for it. A deliver that carries one
//! is lifted whole before the handler runs, so every capability arrives as
//! an opaque Host identity under one lift transaction, and a local call
//! lends the caller's own values. A handler that wants the owned tree asks
//! for it (`values`), which costs the lift that a view delivery skipped. A
//! list of integers is read as one slice (`integers`): in place when the
//! codec left it on the wire as a word run, copied into the turn arena
//! otherwise.

const std = @import("std");

const model = @import("model");

const value_mod = @import("../value.zig");
const capability_mod = @import("../capability.zig");
const hosting = @import("hosting.zig");

const Value = value_mod.Value;

pub const Args = struct {
    inner: Inner,

    pub const Inner = union(enum) {
        /// A wire deliver's views, lent for the turn. Session validation
        /// counted no reference or handoff slot in them, so no arm here is
        /// a capability, and `values` lifts nothing but bytes and spines.
        views: Views,
        /// Lifted or caller-owned values, lent for the turn.
        values: Values,
    };

    pub const Views = struct {
        args: model.view.Args,
        turn: *hosting.HostTurn,
    };

    pub const Values = struct {
        items: []const Value,
        /// The turn arena, which owns what an accessor copies.
        arena: std.mem.Allocator,
    };

    /// What an accessor refuses. `MalformedView` is a codec-backed element
    /// that did not project, which session validation makes unreachable on
    /// a wire deliver.
    pub const Error = error{ MissingArgument, WrongArgumentType, MalformedView };

    pub fn fromValues(items: []const Value, arena: std.mem.Allocator) Args {
        return .{ .inner = .{ .values = .{ .items = items, .arena = arena } } };
    }

    pub fn fromViews(args: model.view.Args, turn: *hosting.HostTurn) Args {
        return .{ .inner = .{ .views = .{ .args = args, .turn = turn } } };
    }

    pub fn len(self: Args) Error!usize {
        return switch (self.inner) {
            .views => |v| v.args.len() catch error.MalformedView,
            .values => |v| v.items.len,
        };
    }

    /// The `integer` argument at `i`.
    pub fn int(self: Args, i: usize) Error!i64 {
        return self.leaf(i, .integer);
    }

    /// The `string` argument at `i`.
    pub fn string(self: Args, i: usize) Error![]const u8 {
        return self.leaf(i, .string);
    }

    /// The `bytes` argument at `i`.
    pub fn bytes(self: Args, i: usize) Error![]const u8 {
        return self.leaf(i, .bytes);
    }

    /// The `symbol` argument at `i`.
    pub fn symbol(self: Args, i: usize) Error![]const u8 {
        return self.leaf(i, .symbol);
    }

    /// The `keyword` argument at `i`.
    pub fn keyword(self: Args, i: usize) Error![]const u8 {
        return self.leaf(i, .keyword);
    }

    /// The `boolean` argument at `i`.
    pub fn boolean(self: Args, i: usize) Error!bool {
        return self.leaf(i, .boolean);
    }

    /// The `float64` argument at `i`.
    pub fn float64(self: Args, i: usize) Error!f64 {
        return self.leaf(i, .float64);
    }

    /// The `list` argument at `i`, as arguments over the same backing.
    pub fn list(self: Args, i: usize) Error!Args {
        return self.sequence(i, .list);
    }

    /// The `list` argument at `i` as integers, lent for the turn. A list the
    /// Cap'n Proto codec left on the wire, or Syrup parsed into the frame's
    /// head as a word run, is read in place. Every other backing (an
    /// uncached list, a lifted or local delivery, or incompatible host words) is
    /// copied into the turn arena once per call. An element that is not an
    /// integer refuses with `WrongArgumentType`.
    pub fn integers(self: Args, i: usize) (Error || std.mem.Allocator.Error)![]const i64 {
        const items = try self.sequence(i, .list);
        switch (items.inner) {
            .views => |v| {
                if (v.args.typedRun()) |run| return run;
                const count = v.args.len() catch return error.MalformedView;
                const out = try v.turn.turn.arena.alloc(i64, count);
                var it = v.args.iterator();
                var filled: usize = 0;
                while (it.nextRef() catch return error.MalformedView) |elem| : (filled += 1) {
                    if (filled >= count) return error.MalformedView;
                    out[filled] = if (elem.* == .integer) elem.integer else return error.WrongArgumentType;
                }
                if (filled != count) return error.MalformedView;
                return out;
            },
            .values => |v| {
                const out = try v.arena.alloc(i64, v.items.len);
                for (v.items, out) |item, *slot| slot.* = if (item == .integer) item.integer else return error.WrongArgumentType;
                return out;
            },
        }
    }

    /// The `set` argument at `i`, as arguments over the same backing.
    pub fn set(self: Args, i: usize) Error!Args {
        return self.sequence(i, .set);
    }

    /// The capability at `i`. A view delivery holds none, so it refuses
    /// with `WrongArgumentType` like any other mismatch.
    pub fn capability(self: Args, i: usize) Error!capability_mod.Ref {
        switch (self.inner) {
            .views => |v| {
                _ = try viewAt(v.args, i);
                return error.WrongArgumentType;
            },
            .values => |v| return switch (try valueAt(v.items, i)) {
                .capability => |c| c,
                else => error.WrongArgumentType,
            },
        }
    }

    /// The argument at `i` as an owned value in the turn arena. A view
    /// delivery lifts that one subtree, and a value delivery lends its own.
    pub fn value(self: Args, i: usize) anyerror!Value {
        return switch (self.inner) {
            .views => |v| v.turn.host.liftView(v.turn.session.?, v.turn.turn.arena, try viewAt(v.args, i)),
            .values => |v| try valueAt(v.items, i),
        };
    }

    /// Every argument as owned values in the turn arena: the lift a view
    /// delivery skipped, paid on each call, or the values a value delivery
    /// already holds.
    pub fn values(self: Args) anyerror![]const Value {
        return switch (self.inner) {
            .views => |v| v.turn.host.liftValues(v.turn.session.?, v.turn.turn.arena, v.args),
            .values => |v| v.items,
        };
    }

    fn leaf(self: Args, i: usize, comptime arm: std.meta.Tag(Value)) Error!@FieldType(Value, @tagName(arm)) {
        switch (self.inner) {
            .views => |v| {
                const view = try viewAt(v.args, i);
                return if (view == viewArm(arm)) @field(view, @tagName(arm)) else error.WrongArgumentType;
            },
            .values => |v| {
                const owned = try valueAt(v.items, i);
                return if (owned == arm) @field(owned, @tagName(arm)) else error.WrongArgumentType;
            },
        }
    }

    fn sequence(self: Args, i: usize, comptime arm: std.meta.Tag(Value)) Error!Args {
        switch (self.inner) {
            .views => |v| {
                const view = try viewAt(v.args, i);
                return if (view == viewArm(arm)) fromViews(@field(view, @tagName(arm)), v.turn) else error.WrongArgumentType;
            },
            .values => |v| {
                const owned = try valueAt(v.items, i);
                return if (owned == arm) fromValues(@field(owned, @tagName(arm)), v.arena) else error.WrongArgumentType;
            },
        }
    }

    /// The view arm that carries a value arm's payload: the two unions share
    /// their leaf and sequence arm names, and a view delivery never holds the
    /// arms that differ (`capability` against `reference` and `handoff`).
    fn viewArm(comptime arm: std.meta.Tag(Value)) std.meta.Tag(model.view.Argument) {
        return @field(std.meta.Tag(model.view.Argument), @tagName(arm));
    }

    fn viewAt(args: model.view.Args, i: usize) Error!model.view.Argument {
        const count = args.len() catch return error.MalformedView;
        if (i >= count) return error.MissingArgument;
        return args.at(i) catch error.MalformedView;
    }

    fn valueAt(items: []const Value, i: usize) Error!Value {
        if (i >= items.len) return error.MissingArgument;
        return items[i];
    }
};
