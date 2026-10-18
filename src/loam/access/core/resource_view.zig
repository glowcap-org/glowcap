//! A synchronous resource view distinguishes unloaded records from absence.
//! Sources provide records from one revision. Managed access validates and traverses
//! them. A miss names the record to load without performing I/O or allocating.
const std = @import("std");
const identity = @import("identity.zig");
const ResourceId = identity.ResourceId;

pub const ResourceView = struct {
    version: Version,
    max_depth: u32,
    context: *const anyopaque,
    read_record: *const fn (*const anyopaque, ResourceId) SourceError!Reply,
    missing: ?Request = null,

    /// Canonical resource structure. Resident depth and sibling indexes are
    /// projections, not fields required to evaluate stored parent edges.
    pub const Record = struct {
        id: ResourceId,
        kind: identity.KindId,
        parent: ?ResourceId,

        pub fn validate(self: Record) error{InvalidRecord}!void {
            if (self.id.generation == 0) return error.InvalidRecord;
            if (self.parent) |parent| if (!identity.validParent(self.id, parent)) return error.InvalidRecord;
        }
    };
    pub const Version = struct { owner: identity.OwnerId, revision: identity.Revision };
    /// A read demand, not a storage completion receipt or capability. The
    /// embedding retains its operation and validates asynchronous completions.
    pub const Request = struct { version: Version, id: ResourceId };
    pub const Absence = enum { unknown, gone };
    pub const Reply = struct {
        version: Version,
        value: Value,
        pub const Value = union(enum) { present: Record, absent: Absence, unloaded };
    };
    pub const SourceError = error{ ReadFailed, RecoveryRequired, RevisionConflict, InvalidRecord };
    pub const Error = SourceError || error{
        ForeignOwner,
        UnknownResource,
        Gone,
        RecordUnloaded,
        DepthLimit,
        ContainmentCycle,
    };

    /// The source and its record storage outlive this view. Reads are
    /// synchronous and serialized with source changes. A source returns data,
    /// never a scope verdict, and does not block on storage inside this call.
    pub fn init(version: Version, max_depth: u32, context: *const anyopaque, read_record: *const fn (*const anyopaque, ResourceId) SourceError!Reply) ResourceView {
        return .{ .version = version, .max_depth = max_depth, .context = context, .read_record = read_record };
    }

    /// Returns a value copy with no borrowed payload. On RecordUnloaded,
    /// missing identifies this exact demand at the view's expected revision.
    /// A later lookup clears the previous demand before consulting its source.
    pub fn get(self: *ResourceView, id: ResourceId) Error!Record {
        self.missing = null;
        if (id.owner != self.version.owner) return error.ForeignOwner;
        if (id.generation == 0) return error.UnknownResource;
        const reply = try self.read_record(self.context, id);
        if (reply.version.owner != self.version.owner or reply.version.revision != self.version.revision) return error.RevisionConflict;
        switch (reply.value) {
            .unloaded => {
                self.missing = .{ .version = self.version, .id = id };
                return error.RecordUnloaded;
            },
            .absent => |reason| return switch (reason) {
                .unknown => error.UnknownResource,
                .gone => error.Gone,
            },
            .present => |record| {
                if (!record.id.eql(id)) return error.InvalidRecord;
                try record.validate();
                return record;
            },
        }
    }

    pub fn depth(self: *ResourceView, id: ResourceId) Error!u32 {
        return (try self.ancestry(id, null)).depth;
    }

    /// Both resident and persistent moves validate canonical ancestry here.
    /// The caller supplies the inspected subtree's maximum relative depth.
    pub fn checkReparent(self: *ResourceView, id: ResourceId, parent: ?ResourceId, height: u32) Error!void {
        _ = try self.depth(id);
        const new_depth = if (parent) |target| value: {
            if (try self.isDescendant(target, id)) return error.ContainmentCycle;
            const parent_depth = try self.depth(target);
            if (parent_depth == self.max_depth) return error.DepthLimit;
            break :value parent_depth + 1;
        } else 0;
        if (height > self.max_depth - new_depth) return error.DepthLimit;
    }

    /// Includes the root itself. Both names must denote live resources.
    pub fn isDescendant(self: *ResourceView, id: ResourceId, root: ResourceId) Error!bool {
        _ = try self.get(root);
        return (try self.ancestry(id, root)).matched;
    }

    /// Walks canonical parent edges from `id` to its root with bounded work
    /// and no allocation: the depth, and whether `root` was `id` or an
    /// ancestor. A match still validates the rest of the path, so an
    /// unloaded, cyclic, over-depth, or missing ancestor cannot hide behind it.
    fn ancestry(self: *ResourceView, id: ResourceId, root: ?ResourceId) Error!struct { depth: u32, matched: bool } {
        var record = try self.get(id);
        var matched = if (root) |target| id.eql(target) else false;
        var traversed: u32 = 0;
        while (record.parent) |parent| {
            if (traversed == self.max_depth) return error.DepthLimit;
            traversed += 1;
            record = try self.get(parent);
            if (root) |target| matched = matched or parent.eql(target);
        }
        return .{ .depth = traversed, .matched = matched };
    }
};
