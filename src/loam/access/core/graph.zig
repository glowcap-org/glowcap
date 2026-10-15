//! Bounded owned containment, independent of actor or capability identity.
//! One allocation reserves the requested slots. Reads and mutations allocate
//! nothing. Depth is derived from parent edges, so a subtree move reads its
//! descendants once to bound their new depth and rewrites only its own edges.

const std = @import("std");
const identity = @import("identity.zig");
const ResourceView = @import("resource_view.zig").ResourceView;
const OwnerId = identity.OwnerId;
const ResourceId = identity.ResourceId;
const KindId = identity.KindId;
const Revision = identity.Revision;
const Policy = @import("policy.zig").Policy;

const Node = struct {
    kind: KindId,
    parent: ?u32 = null,
    first_child: ?u32 = null,
    previous: ?u32 = null,
    next: ?u32 = null,
};

const Slot = struct {
    generation: u64 = 1,
    node: ?Node = null,
    next_free: ?u32 = null,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    owner: OwnerId,
    limits: Limits,
    slots: []Slot,
    free_head: ?u32,
    live_count: u32 = 0,
    current_revision: Revision = @fromBackingInt(@intCast(0)),
    reservation: ?Reservation = null,
    reservation_sequence: u64 = 0,

    /// A local reservation keeps prepared scope checks valid until completion.
    /// It carries no resource authority and must not be sent to a peer.
    pub const Reservation = struct { owner: OwnerId, sequence: u64 };

    pub const Limits = struct {
        capacity: u32,
        /// Root depth is zero. This bounds every ancestry walk.
        max_depth: u32 = 64,
    };

    pub const Error = ResourceView.Error || Policy.Error || error{
        InvalidLimits,
        CapacityExceeded,
        RevisionExhausted,
        ContainmentCycle,
        HasChildren,
        Busy,
        InvalidReservation,
        ReservationExhausted,
    };

    pub const Record = struct {
        id: ResourceId,
        kind: KindId,
        parent: ?ResourceId,
        depth: u32,
    };

    /// Allocate an empty owner graph. Slots are reserved up front so mutation
    /// cannot fail for allocation after its validation has completed.
    pub fn init(allocator: std.mem.Allocator, owner: OwnerId, limits: Limits) (Error || std.mem.Allocator.Error)!Graph {
        if (limits.capacity == 0) return error.InvalidLimits;
        const slots = try allocator.alloc(Slot, limits.capacity);
        for (slots, 0..) |*slot, i| slot.* = .{
            .next_free = if (i + 1 < slots.len) @intCast(i + 1) else null,
        };
        return .{ .allocator = allocator, .owner = owner, .limits = limits, .slots = slots, .free_head = 0 };
    }

    pub fn deinit(self: *Graph) error{Busy}!void {
        if (self.reservation != null) return error.Busy;
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn revision(self: *const Graph) Revision {
        return self.current_revision;
    }

    /// Reserves the current structure without changing its public revision.
    /// Reads remain available. Mutations and destruction refuse while reserved.
    pub fn reserve(self: *Graph, base: Revision) Error!Reservation {
        try self.checkWritable(base);
        if (self.reservation_sequence == std.math.maxInt(u64)) return error.ReservationExhausted;
        self.reservation_sequence += 1;
        const token: Reservation = .{ .owner = self.owner, .sequence = self.reservation_sequence };
        self.reservation = token;
        return token;
    }

    pub fn ownsReservation(self: *const Graph, token: Reservation) bool {
        const held = self.reservation orelse return false;
        return token.owner == held.owner and token.sequence == held.sequence;
    }

    pub fn release(self: *Graph, token: Reservation) Error!void {
        if (!self.ownsReservation(token)) return error.InvalidReservation;
        self.reservation = null;
    }

    pub fn count(self: *const Graph) u32 {
        return self.live_count;
    }

    pub fn get(self: *const Graph, id: ResourceId) Error!Record {
        const index = try self.indexOf(id);
        const node = self.slots[index].node.?;
        return .{
            .id = id,
            .kind = node.kind,
            .parent = if (node.parent) |parent| self.idAt(parent) else null,
            .depth = self.depthOf(index),
        };
    }

    /// Includes the root itself. Both names must denote live resources in this
    /// exact owner, even when the result would otherwise be false.
    pub fn isDescendant(self: *const Graph, id: ResourceId, root: ResourceId) Error!bool {
        var view = self.readView();
        return view.isDescendant(id, root);
    }

    /// Captures a read revision without copying records or allocating. All
    /// scope consumers use this same view as a future paged record source.
    pub fn readView(self: *const Graph) ResourceView {
        return ResourceView.init(.{ .owner = self.owner, .revision = self.revision() }, self.limits.max_depth, self, readRecord);
    }

    fn readRecord(context: *const anyopaque, id: ResourceId) ResourceView.SourceError!ResourceView.Reply {
        const self: *const Graph = @ptrCast(@alignCast(context));
        const version: ResourceView.Version = .{ .owner = self.owner, .revision = self.revision() };
        if (id.slot >= self.slots.len or id.generation == 0) return .{ .version = version, .value = .{ .absent = .unknown } };
        const slot = self.slots[id.slot];
        if (slot.generation != id.generation or slot.node == null) return .{ .version = version, .value = .{ .absent = .gone } };
        const node = slot.node.?;
        return .{ .version = version, .value = .{ .present = .{
            .id = id,
            .kind = node.kind,
            .parent = if (node.parent) |parent| self.idAt(parent) else null,
        } } };
    }

    /// Trusted structural mutation. Callers compose it with their content and
    /// authority transaction. The expected revision prevents stale writes.
    pub fn create(self: *Graph, base: Revision, policy: *const Policy, kind: KindId, parent: ?ResourceId) Error!ResourceId {
        const next_revision = try self.nextRevision(base);
        const parent_index = if (parent) |id| try self.indexOf(id) else null;
        try policy.validatePlacement(kind, if (parent_index) |index| self.slots[index].node.?.kind else null);
        _ = try self.childDepth(parent_index);
        const index = self.free_head orelse return error.CapacityExceeded;
        const slot = &self.slots[index];
        self.free_head = slot.next_free;
        slot.next_free = null;
        slot.node = .{ .kind = kind };
        self.attach(index, parent_index);
        self.live_count += 1;
        self.current_revision = next_revision;
        return self.idAt(index);
    }

    /// Move a whole owned subtree. Validation reads every descendant once to
    /// bound the subtree's new depth before modifying any edge, and the move
    /// itself rewrites only the moved resource's edges. Reparenting to the same
    /// parent is a validated no-op and does not advance the revision.
    pub fn reparent(self: *Graph, base: Revision, policy: *const Policy, id: ResourceId, parent: ?ResourceId) Error!void {
        try self.checkWritable(base);
        const index = try self.indexOf(id);
        const parent_index = if (parent) |p| try self.indexOf(p) else null;
        try policy.validatePlacement(self.slots[index].node.?.kind, if (parent_index) |index_| self.slots[index_].node.?.kind else null);
        if (self.slots[index].node.?.parent == parent_index) return;
        const next_revision = try self.nextRevision(base);
        var resources = self.readView();
        _ = try resources.checkReparent(id, parent, self.subtreeHeight(index));
        self.detach(index);
        self.attach(index, parent_index);
        self.current_revision = next_revision;
    }

    /// Destroy a leaf. Children require an explicit operation rather than an
    /// implicit cascade. Reused slots receive a fresh generation. An exhausted
    /// generation retires its slot permanently instead of wrapping.
    pub fn destroy(self: *Graph, base: Revision, id: ResourceId) Error!void {
        const next_revision = try self.nextRevision(base);
        const index = try self.indexOf(id);
        const slot = &self.slots[index];
        if (slot.node.?.first_child != null) return error.HasChildren;
        self.detach(index);
        slot.node = null;
        if (slot.generation != std.math.maxInt(u64)) {
            slot.generation += 1;
            slot.next_free = self.free_head;
            self.free_head = index;
        }
        self.live_count -= 1;
        self.current_revision = next_revision;
    }

    fn nextRevision(self: *const Graph, base: Revision) Error!Revision {
        try self.checkWritable(base);
        return @fromBackingInt(@intCast(std.math.add(u64, @backingInt(base), 1) catch return error.RevisionExhausted));
    }

    fn checkWritable(self: *const Graph, base: Revision) Error!void {
        if (self.reservation != null) return error.Busy;
        if (base != self.current_revision) return error.RevisionConflict;
    }

    fn indexOf(self: *const Graph, id: ResourceId) Error!u32 {
        if (id.owner != self.owner) return error.ForeignOwner;
        if (id.slot >= self.slots.len or id.generation == 0) return error.UnknownResource;
        const slot = self.slots[id.slot];
        if (slot.generation != id.generation or slot.node == null) return error.Gone;
        return id.slot;
    }

    fn idAt(self: *const Graph, index: u32) ResourceId {
        return .{ .owner = self.owner, .slot = index, .generation = self.slots[index].generation };
    }

    fn childDepth(self: *const Graph, parent: ?u32) Error!u32 {
        const index = parent orelse return 0;
        const depth = self.depthOf(index);
        if (depth >= self.limits.max_depth) return error.DepthLimit;
        return depth + 1;
    }

    /// Parent edges above a live node. Every mutation keeps depth within
    /// `max_depth`, so the walk is bounded.
    fn depthOf(self: *const Graph, index: u32) u32 {
        var depth: u32 = 0;
        var cursor = self.slots[index].node.?.parent;
        while (cursor) |parent| : (cursor = self.slots[parent].node.?.parent) depth += 1;
        return depth;
    }

    /// The deepest descendant's distance below `root`, found in one walk.
    fn subtreeHeight(self: *const Graph, root: u32) u32 {
        var height: u32 = 0;
        var level: u32 = 0;
        var cursor = root;
        while (true) {
            if (self.slots[cursor].node.?.first_child) |child| {
                cursor = child;
                level += 1;
                height = @max(height, level);
                continue;
            }
            while (cursor != root) {
                const node = self.slots[cursor].node.?;
                if (node.next) |sibling| {
                    cursor = sibling;
                    break;
                }
                cursor = node.parent.?;
                level -= 1;
            } else return height;
        }
    }

    fn attach(self: *Graph, index: u32, parent: ?u32) void {
        const node = &self.slots[index].node.?;
        node.parent = parent;
        if (parent) |p| {
            const first = self.slots[p].node.?.first_child;
            node.next = first;
            if (first) |sibling| self.slots[sibling].node.?.previous = index;
            self.slots[p].node.?.first_child = index;
        }
    }

    fn detach(self: *Graph, index: u32) void {
        const node = &self.slots[index].node.?;
        if (node.previous) |previous| {
            self.slots[previous].node.?.next = node.next;
        } else if (node.parent) |parent| {
            self.slots[parent].node.?.first_child = node.next;
        }
        if (node.next) |next| self.slots[next].node.?.previous = node.previous;
        node.parent = null;
        node.previous = null;
        node.next = null;
    }
};
