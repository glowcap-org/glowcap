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
//! (ADR-0234).

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

    pub const none: Inventory = .{};

    pub fn deinit(self: Inventory, allocator: std.mem.Allocator) void {
        allocator.free(self.slots);
    }
};

/// Inventory a deliver's argument slice. The roots live in that heap slice,
/// so every slot is a heap slot.
pub fn ofArguments(self: *Session, args: []const model.Argument) InventoryError!Inventory {
    var walk = Walk.init(self);
    errdefer walk.slots.deinit(self.allocator);
    try model.owned.addArgumentSliceOwnedBytes(&walk.total, args.len);
    for (args) |*argument| try walk.visit(argument, .{ .heap = @constCast(argument) }, 0);
    return walk.finish();
}

/// Inventory a resolution. Its fulfillment is held by value, so that root is
/// the `root` slot when a pass returns to it. A break has no tree.
pub fn ofResolution(self: *Session, resolution: model.Resolution) InventoryError!Inventory {
    switch (resolution) {
        .fulfill => {
            var walk = Walk.init(self);
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
pub fn ofMessage(self: *Session, message: model.Message) InventoryError!Inventory {
    return switch (message) {
        .deliver => |deliver| ofArguments(self, deliver.args),
        .resolve => |resolve| ofResolution(self, resolve.resolution),
        else => .none,
    };
}

const Walk = struct {
    session: *Session,
    allocator: std.mem.Allocator,
    slots: std.ArrayListUnmanaged(Slot) = .empty,
    total: usize = 0,

    fn init(self: *Session) Walk {
        return .{ .session = self, .allocator = self.allocator };
    }

    /// A tree with nothing listed hands back the empty inventory without an
    /// allocator call, so an ordinary application message pays the walk only.
    fn finish(self: *Walk) InventoryError!Inventory {
        if (self.slots.items.len == 0) return .{ .owned_bytes = self.total };
        return .{
            .slots = try self.slots.toOwnedSlice(self.allocator),
            .owned_bytes = self.total,
        };
    }

    /// The nesting bound is the one send-side depth threshold: a container's
    /// items sit one level deeper than it, an empty container included, so
    /// the deliver and resolve paths cannot drift apart.
    fn visit(self: *Walk, argument: *const model.Argument, slot: Slot, depth: usize) InventoryError!void {
        try model.owned.addShallowOwnedBytes(&self.total, argument.*);
        switch (argument.*) {
            .reference, .handoff => try self.slots.append(self.allocator, slot),
            .list => |items| try self.visitItems(items, depth),
            .set => |items| {
                try self.visitItems(items, depth);
                try self.slots.append(self.allocator, slot);
            },
            .tagged => |tagged| try self.visitItems(tagged.value, depth),
            .@"struct" => |entries| {
                if (depth + 1 > self.session.limits.max_nesting_depth) return Error.NestingTooDeep;
                for (entries) |*entry|
                    try self.visit(&entry.value, .{ .heap = @constCast(&entry.value) }, depth + 1);
                // A duplicate struct key refuses here, pre-commit, never at
                // encode. Keys do not change after this walk.
                try passable.checkSentStructKeyUniqueness(self.allocator, entries);
            },
            .bytes, .symbol, .string, .keyword, .integer, .big_integer, .boolean, .float64, .void, .@"error" => {},
        }
    }

    fn visitItems(self: *Walk, items: []const model.Argument, depth: usize) InventoryError!void {
        if (depth + 1 > self.session.limits.max_nesting_depth) return Error.NestingTooDeep;
        for (items) |*item| try self.visit(item, .{ .heap = @constCast(item) }, depth + 1);
    }
};
