//! One walk over an outbound argument tree.
//!
//! An outbound tree answers to several concerns before it is encoded: the
//! Node counts and projects its foreign routes, lowering and shortening
//! rewrite references in place, admission measures the bytes it retains,
//! validation certifies its shape and its references, and apply retains the
//! exports it mentions. Each used to walk the tree again. `ofArguments` and
//! `ofResolution` walk it once: they certify what no later pass changes
//! (nesting depth, struct keys, retained bytes) and list the arguments the
//! later passes return to. Each pass is then a loop over that list, and a
//! tree with nothing to return to lists nothing and allocates nothing
//! (ADR-0064). The walk also takes the codec's meter, so the frame's size
//! is known before the encoder reads the tree and the encoder reads it once
//! (ADR-0064).

const std = @import("std");
const model = @import("model");
const session = @import("mod.zig");
const passable = @import("validate/passable.zig");

const Session = session.Session;
const Error = session.Error;

pub const InventoryError = passable.SendArgError || model.view.ProjectError;

/// One place in the tree a pass returns to.
pub const Slot = union(enum) {
    /// The tree's root, which its owner holds by value: a resolution's
    /// fulfillment. A deliver's roots are its argument slice, so a deliver
    /// inventory never lists this slot.
    root,
    /// An argument in the tree's owned heap, which the walk reads and the
    /// later passes rewrite in place. No pass reallocates the tree, so the
    /// pointer holds for as long as the owner holds the tree.
    heap: *model.Argument,

    /// The argument this slot names, with `root` resolving the by-value root.
    pub fn at(self: Slot, root: ?*model.Argument) *model.Argument {
        return switch (self) {
            .root => root.?,
            .heap => |argument| argument,
        };
    }

    pub fn read(self: Slot, root: ?*const model.Argument) *const model.Argument {
        return switch (self) {
            .root => root.?,
            .heap => |argument| argument,
        };
    }
};

/// What one walk learned about an outbound tree.
pub const Inventory = struct {
    /// The arguments a later pass returns to, in tree order: every reference
    /// and handoff (a capability mention), and every set, whose element
    /// uniqueness is certified after shortening because shortening can fold
    /// two promises onto one target.
    slots: []Slot = &.{},
    /// Bytes the tree retains, equal to the `model.owned` measure of the same
    /// value, so the inventory carries the admission charge too.
    owned_bytes: usize = 0,
    /// The codec bytes of the tree's values as the walk's meter sized them:
    /// outside the references and handoffs lowering rewrites, which the
    /// encoder sizes from the slots, and outside the list a deliver's
    /// arguments ride in, which the encoder adds. Zero under `NoMeter`.
    wire_bytes: usize = 0,

    pub const none: Inventory = .{};

    pub fn deinit(self: Inventory, allocator: std.mem.Allocator) void {
        allocator.free(self.slots);
    }
};

/// The meter a walk takes when no codec sizes the tree ahead of its encode:
/// every value is zero bytes, and the inventory's `wire_bytes` says nothing.
/// A codec's meter has this shape (`codec.syrup.meter`).
pub const NoMeter = struct {
    pub inline fn shallow(argument: anytype) usize {
        _ = argument;
        return 0;
    }
    pub inline fn shallowOf(comptime tag: anytype, payload: anytype) usize {
        _ = tag;
        _ = payload;
        return 0;
    }
    pub inline fn key(text: []const u8) usize {
        _ = text;
        return 0;
    }
};

/// Inventory a deliver's argument slice. The roots live in that heap slice,
/// so every slot is a heap slot. `Meter` sizes the values for the encoder.
pub fn ofArguments(self: *Session, args: []const model.Argument, comptime Meter: type) InventoryError!Inventory {
    var walk = Walk(Meter).init(self);
    errdefer walk.slots.deinit(self.allocator);
    model.owned.addArgumentSliceOwnedBytes(&walk.total, args.len);
    for (args) |*argument| try walk.visit(argument, .{ .heap = @constCast(argument) }, 0);
    return walk.finish();
}

/// Inventory a resolution. Its fulfillment is held by value, so that root is
/// the `root` slot when a pass returns to it. A break has no tree.
pub fn ofResolution(self: *Session, resolution: model.Resolution, comptime Meter: type) InventoryError!Inventory {
    switch (resolution) {
        .fulfill => {
            var walk = Walk(Meter).init(self);
            errdefer walk.slots.deinit(self.allocator);
            walk.total = @sizeOf(model.Resolution);
            try walk.visit(&resolution.fulfill, .root, 0);
            return walk.finish();
        },
        .@"break" => return .{ .owned_bytes = try model.measureResolutionOwnedBytes(resolution) },
    }
}

/// Inventory the tree a message carries: a deliver's arguments or a resolve's
/// resolution. Every other kind carries none.
pub fn ofMessage(self: *Session, message: model.Message, comptime Meter: type) InventoryError!Inventory {
    return switch (message) {
        .deliver => |deliver| ofArguments(self, deliver.args, Meter),
        .resolve => |resolve| ofResolution(self, resolve.resolution, Meter),
        else => .none,
    };
}

fn Walk(comptime Meter: type) type {
    return struct {
        session: *Session,
        allocator: std.mem.Allocator,
        slots: std.ArrayListUnmanaged(Slot) = .empty,
        /// Both totals saturate as `model.owned` measures do, and `finish`
        /// refuses a saturated one, so the walk adds without a check per
        /// value.
        total: usize = 0,
        wire: usize = 0,

        const Self = @This();

        fn init(self: *Session) Self {
            return .{ .session = self, .allocator = self.allocator };
        }

        /// A tree with nothing listed hands back the empty inventory without an
        /// allocator call, so an ordinary application message pays the walk only.
        fn finish(self: *Self) InventoryError!Inventory {
            if (self.total == std.math.maxInt(usize) or self.wire == std.math.maxInt(usize)) return error.MalformedView;
            if (self.slots.items.len == 0) return .{ .owned_bytes = self.total, .wire_bytes = self.wire };
            return .{
                .slots = try self.slots.toOwnedSlice(self.allocator),
                .owned_bytes = self.total,
                .wire_bytes = self.wire,
            };
        }

        /// One dispatch per argument: the owned measure, the wire measure, and
        /// the descent resolve from the tag at compile time, and the arms
        /// inline into the caller's loop, so a leaf is a tag load and two adds
        /// with no call. A container descends through `visitItems` or
        /// `visitStruct`, whose nesting bound is the one send-side depth
        /// threshold: a container's items sit one level deeper than it, an
        /// empty container included, so the deliver and resolve paths cannot
        /// drift apart.
        inline fn visit(self: *Self, argument: *const model.Argument, slot: Slot, depth: usize) InventoryError!void {
            switch (argument.*) {
                inline else => |*payload, tag| {
                    model.owned.addShallowOwnedBytesOf(tag, &self.total, payload);
                    self.wire +|= Meter.shallowOf(tag, payload);
                    switch (tag) {
                        .reference, .handoff => try self.slots.append(self.allocator, slot),
                        .list => try self.visitItems(payload.*, depth),
                        .set => {
                            try self.visitItems(payload.*, depth);
                            try self.slots.append(self.allocator, slot);
                        },
                        .tagged => try self.visitItems(payload.value, depth),
                        .@"struct" => try self.visitStruct(payload.*, depth),
                        .bytes, .symbol, .string, .keyword, .integer, .big_integer, .boolean, .float64, .void, .@"error" => {},
                    }
                },
            }
        }

        fn visitItems(self: *Self, items: []const model.Argument, depth: usize) InventoryError!void {
            if (depth + 1 > self.session.limits.max_nesting_depth) return error.NestingTooDeep;
            for (items) |*item| try self.visit(item, .{ .heap = @constCast(item) }, depth + 1);
        }

        /// A duplicate struct key refuses here, pre-commit, never at encode.
        /// Keys do not change after this walk.
        fn visitStruct(self: *Self, entries: []const model.StructEntry, depth: usize) InventoryError!void {
            if (depth + 1 > self.session.limits.max_nesting_depth) return error.NestingTooDeep;
            for (entries) |*entry| {
                self.wire +|= Meter.key(entry.key);
                try self.visit(&entry.value, .{ .heap = @constCast(&entry.value) }, depth + 1);
            }
            try passable.checkSentStructKeyUniqueness(self.allocator, entries);
        }
    };
}

/// The error set a reference map returns, or none for an infallible map.
fn MapError(comptime map: anytype) type {
    const Return = @typeInfo(@TypeOf(map)).@"fn".return_type.?;
    return switch (@typeInfo(Return)) {
        .error_union => |eu| eu.error_set,
        else => error{},
    };
}

/// Inline so the map call stays one call per reference: this wrapper exists
/// only to pin the error set.
inline fn mapOne(ctx: anytype, comptime map: anytype, reference: model.Reference) MapError(map)!model.Reference {
    return map(ctx, reference);
}

/// Replace every reference a message carries with `map(ctx, reference)`: the
/// header fields that name one, then each inventoried slot. Shortening and
/// the Node's lowering are the two passes, so a field that gains a reference
/// is added here once. The map's error set, if it has one, is the walk's.
pub fn mapMessageReferences(message: *model.Message, inventory: Inventory, ctx: anytype, comptime map: anytype) MapError(map)!void {
    switch (message.*) {
        .deliver => |*deliver| {
            deliver.target = try mapOne(ctx, map, deliver.target);
            if (deliver.resolve_me_desc) |resolver| deliver.resolve_me_desc = try mapOne(ctx, map, resolver);
            try mapSlots(inventory, null, ctx, map);
        },
        .resolve => |*resolve| try mapResolutionReferences(&resolve.resolution, inventory, ctx, map),
        .listen => |*listen| {
            listen.target = try mapOne(ctx, map, listen.target);
            listen.listener = try mapOne(ctx, map, listen.listener);
        },
        .get => |*get| get.receiver = try mapOne(ctx, map, get.receiver),
        .index => |*index| index.receiver = try mapOne(ctx, map, index.receiver),
        .untag => |*untag| untag.receiver = try mapOne(ctx, map, untag.receiver),
        // No reference positions.
        .gc_export, .gc_answer, .start_session, .abort => {},
    }
}

/// `mapMessageReferences` for a resolution held outside a message.
pub fn mapResolutionReferences(resolution: *model.Resolution, inventory: Inventory, ctx: anytype, comptime map: anytype) MapError(map)!void {
    const root: ?*model.Argument = if (resolution.* == .fulfill) &resolution.fulfill else null;
    try mapSlots(inventory, root, ctx, map);
}

fn mapSlots(inventory: Inventory, root: ?*model.Argument, ctx: anytype, comptime map: anytype) MapError(map)!void {
    for (inventory.slots) |slot| {
        const argument = slot.at(root);
        // Handoff records carry their own typed certificate fields rather than
        // semantic `Reference` values, and a set is revisited only for its
        // uniqueness.
        if (argument.* == .reference) argument.* = .{ .reference = try mapOne(ctx, map, argument.reference) };
    }
}
