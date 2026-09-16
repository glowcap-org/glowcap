//! Versioned structural resource metadata, independent of content and grants.
const std = @import("std");
const core = @import("loam_access_core");
const syrup = @import("syrup");
const syntax = syrup.RecordSyntax;
const fields = @import("fields.zig");

pub const ResourceRecord = struct {
    /// Revision at which this row changed, distinct from a read's snapshot.
    revision: core.Revision,
    resource: core.ResourceView.Record,

    pub const format_version: u64 = 1;
    /// Fixed-width identities and bounded integers keep this record below
    /// this cap. Decode checks it before invoking any length-prefixed reader.
    pub const max_encoded_bytes: usize = 192;
    pub const Error = error{ MalformedRecord, UnsupportedVersion, InvalidRecord, RecordTooLarge };
    const label = "access:resource";

    /// Allocates one exact byte slice through the supplied allocator. The
    /// caller frees that slice; the encoder retains no record or input borrow.
    pub fn encodeAlloc(self: ResourceRecord, allocator: std.mem.Allocator) (Error || syrup.shared.WalkError)![]u8 {
        try self.resource.validate();
        return syrup.render.renderRecordExact(allocator, write, .{self});
    }

    /// Returns owned scalar values with zero allocation or retained byte
    /// borrows. The record must be complete, canonical, and within the cap.
    pub fn decode(bytes: []const u8) Error!ResourceRecord {
        if (bytes.len > max_encoded_bytes) return error.RecordTooLarge;
        return decodeRecord(bytes) catch |err| switch (err) {
            error.UnsupportedVersion => error.UnsupportedVersion,
            error.InvalidRecord => error.InvalidRecord,
            else => error.MalformedRecord,
        };
    }

    fn write(sink: anytype, self: ResourceRecord) !void {
        try syntax.beginRecord(sink);
        try syntax.writeSymbol(sink, label);
        try syntax.writePositiveInt(sink, format_version);
        try syntax.writePositiveInt(sink, @backingInt(self.revision));
        try fields.writeId(sink, self.resource.id);
        try syntax.writePositiveInt(sink, @backingInt(self.resource.kind));
        try fields.writeParent(sink, self.resource.parent);
        try syntax.endRecord(sink);
    }

    fn decodeRecord(bytes: []const u8) !ResourceRecord {
        var cursor: usize = 0;
        try syntax.readByte(bytes, &cursor, '<');
        if (!std.mem.eql(u8, try syntax.readSymbol(bytes, &cursor), label)) return error.MalformedRecord;
        if (try syntax.readPositiveInt(bytes, &cursor) != format_version) return error.UnsupportedVersion;
        const revision: core.Revision = @fromBackingInt(try syntax.readPositiveInt(bytes, &cursor));
        const id = try fields.readId(core.ResourceId, bytes, &cursor);
        const kind: core.KindId = @fromBackingInt(try syntax.readPositiveInt(bytes, &cursor));
        const parent = try fields.readParent(core.ResourceId, bytes, &cursor);
        try syntax.readByte(bytes, &cursor, '>');
        try syntax.expectEnd(bytes, cursor);
        const result: ResourceRecord = .{ .revision = revision, .resource = .{ .id = id, .kind = kind, .parent = parent } };
        try result.resource.validate();
        return result;
    }
};
