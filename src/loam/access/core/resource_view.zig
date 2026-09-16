//! A synchronous resource view distinguishes unloaded records from absence.
//! Sources provide records from one revision; managed access validates and traverses
//! them. A miss names the record to load without performing I/O or allocating.
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
            if (self.parent) |parent| {
                if (parent.owner != self.id.owner or parent.generation == 0 or parent.eql(self.id)) return error.InvalidRecord;
            }
        }
    };
    pub const Version = struct { owner: identity.OwnerId, revision: identity.Revision };
    /// A read demand, not a storage completion receipt or capability. The
    /// embedding retains its operation and validates asynchronous completions.
    pub const Request = struct { version: Version, id: ResourceId };
    pub const Absence = enum { unknown, gone };
    pub const Reply = struct {
        version: Version,
        value: union(enum) { present: Record, absent: Absence, unloaded },
    };
    pub const SourceError = error{ ReadFailed, RecoveryRequired, RevisionConflict, InvalidRecord };
    pub const Error = SourceError || error{
        ForeignOwner,
        UnknownResource,
        Gone,
        RevisionConflict,
        InvalidRecord,
        RecordUnloaded,
        DepthLimit,
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

    /// Walks canonical parent edges with bounded work and no allocation. A
    /// positive match still validates the rest of the path to its root: an
    /// unloaded, cyclic, over-depth, or missing ancestor cannot hide behind it.
    pub fn isDescendant(self: *ResourceView, id: ResourceId, root: ResourceId) Error!bool {
        _ = try self.get(root);
        var record = try self.get(id);
        var matched = id.eql(root);
        var depth: u32 = 0;
        while (record.parent) |parent| {
            if (depth == self.max_depth) return error.DepthLimit;
            depth += 1;
            record = try self.get(parent);
            matched = matched or parent.eql(root);
        }
        return matched;
    }
};
