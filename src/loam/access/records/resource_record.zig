//! Versioned structural resource metadata, independent of content and grants.
const std = @import("std");
const loam = @import("loam_records");
const core = @import("loam_access_core");
const syrup = @import("syrup");
const syntax = syrup.RecordSyntax;
const fields = @import("fields.zig");
const profile = @import("profile.zig");
const Stamp = @import("change_stamp.zig").ChangeStamp;

pub const ResourceRecord = struct {
    /// Revision at which this row changed, distinct from a read's snapshot.
    revision: core.Revision,
    resource: core.ResourceView.Record,
    live: bool = true,
    children: ?loam.ObjectId = null,
    placement: Stamp = .{},
    subtree: Stamp = .{},
    content: Stamp = .{},

    pub const format_version: u64 = 1;
    /// Fixed-width identities and bounded integers keep this record below
    /// this cap. Decode checks it before invoking any length-prefixed reader.
    pub const max_encoded_bytes: usize = 384;
    pub const max_edges = 2;
    pub const Error = error{ MalformedRecord, UnsupportedVersion, InvalidRecord, RecordTooLarge };
    const label = "access:resource";

    /// Allocates one exact byte slice through the supplied allocator. The
    /// caller frees that slice. The encoder retains no record or input borrow.
    pub fn encodeAlloc(self: ResourceRecord, allocator: std.mem.Allocator) (Error || syrup.shared.WalkError)![]u8 {
        try self.validate();
        if (!self.live and (self.resource.parent != null or self.children != null)) return error.InvalidRecord;
        return syrup.render.renderRecordExact(allocator, write, .{self});
    }

    /// The live child of `parent` at `slot` that `view` holds.
    pub fn decodeChildOf(view: loam.View, parent: core.ResourceId, slot: u32) Error!ResourceRecord {
        const record = try decode(view);
        const id = record.resource.id;
        const canonical = record.resource.parent orelse return error.InvalidRecord;
        if (!record.live or id.owner != parent.owner or id.slot != slot or !canonical.eql(parent)) return error.InvalidRecord;
        return record;
    }

    /// Returns owned scalar values with zero allocation or retained byte
    /// borrows. The record must be complete, canonical, and within the cap.
    pub fn decode(view: loam.View) Error!ResourceRecord {
        if (view.schema != profile.resource or view.schema_version != format_version) return error.InvalidRecord;
        if (view.payload.len > max_encoded_bytes) return error.RecordTooLarge;
        return decodeRecord(view) catch |err| switch (err) {
            error.UnsupportedVersion => error.UnsupportedVersion,
            error.InvalidRecord => error.InvalidRecord,
            else => error.MalformedRecord,
        };
    }

    /// Child identity lives only in its strong edge. Parent model identity is
    /// encoded in the payload. The caller supplies its resolved storage target.
    pub fn edges(self: ResourceRecord, parent: ?loam.ObjectId, buffer: *[max_edges]loam.Edge) Error![]const loam.Edge {
        if ((parent != null) != (self.resource.parent != null)) return error.InvalidRecord;
        if (!self.live and (parent != null or self.children != null)) return error.InvalidRecord;
        var count: usize = 0;
        for ([_]?loam.ObjectId{ parent, self.children }) |target| if (target) |id| {
            buffer[count] = .{ .target = id };
            count += 1;
        };
        return buffer[0..count];
    }

    fn write(sink: anytype, self: ResourceRecord) !void {
        try syntax.beginRecord(sink);
        try syntax.writeSymbol(sink, label);
        try syntax.writePositiveInt(sink, format_version);
        try syntax.writePositiveInt(sink, @backingInt(self.revision));
        try fields.writeId(sink, self.resource.id);
        try syntax.writePositiveInt(sink, @backingInt(self.resource.kind));
        try fields.writeParent(sink, self.resource.parent);
        try syntax.writeBool(sink, self.live);
        try syntax.writeBool(sink, self.children != null);
        try self.placement.write(sink);
        try self.subtree.write(sink);
        try self.content.write(sink);
        try syntax.endRecord(sink);
    }

    fn validate(self: ResourceRecord) Error!void {
        try self.resource.validate();
        const revision = @backingInt(self.revision);
        try self.placement.validate(revision);
        try self.subtree.validate(revision);
        try self.content.validate(revision);
    }

    fn decodeRecord(view: loam.View) !ResourceRecord {
        const bytes = view.payload;
        var cursor: usize = 0;
        try syntax.readByte(bytes, &cursor, '<');
        if (!std.mem.eql(u8, try syntax.readSymbol(bytes, &cursor), label)) return error.MalformedRecord;
        if (try syntax.readPositiveInt(bytes, &cursor) != format_version) return error.UnsupportedVersion;
        const revision: core.Revision = @fromBackingInt(try syntax.readPositiveInt(bytes, &cursor));
        const id = try fields.readId(core.ResourceId, bytes, &cursor);
        const kind: core.KindId = @fromBackingInt(try syntax.readPositiveInt(bytes, &cursor));
        const parent = try fields.readParent(core.ResourceId, bytes, &cursor);
        const live = try syntax.readBool(bytes, &cursor);
        var edges_it = view.edges();
        if (parent != null) _ = try fields.readEdge(&edges_it, view.id.store);
        const children = if (try syntax.readBool(bytes, &cursor)) try fields.readEdge(&edges_it, view.id.store) else null;
        if (edges_it.next() != null) return error.InvalidRecord;
        if (!live and (parent != null or children != null)) return error.InvalidRecord;
        const placement = try Stamp.read(bytes, &cursor);
        const subtree = try Stamp.read(bytes, &cursor);
        const content = try Stamp.read(bytes, &cursor);
        try syntax.readByte(bytes, &cursor, '>');
        try syntax.expectEnd(bytes, cursor);
        const result: ResourceRecord = .{ .revision = revision, .resource = .{ .id = id, .kind = kind, .parent = parent }, .live = live, .children = children, .placement = placement, .subtree = subtree, .content = content };
        try result.validate();
        return result;
    }
};
