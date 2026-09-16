//! Canonical derivation intent and exact durable result retention.
const std = @import("std");
const core = @import("loam_access_core");
const loam = @import("loam_records");
const syrup = @import("syrup");
const terms = @import("terms.zig");
const s = syrup.RecordSyntax;
const profile = @import("profile.zig");

pub const DerivationRecord = struct {
    intent: []const u8,
    endpoint: loam.ObjectId,
    publication: loam.ObjectId,
    pub const max_encoded_bytes = 32 * 1024;

    pub fn encodeIntent(allocator: std.mem.Allocator, owner: core.OwnerId, request: core.GrantLedger.Issue) ![]u8 {
        try terms.validate(request.ceiling, owner);
        try terms.validate(request.configured, owner);
        return syrup.render.renderRecordExact(allocator, write, .{request});
    }

    pub fn decode(view: loam.View) !DerivationRecord {
        if (view.schema != profile.derivation or view.schema_version != 1 or view.edge_count != 2 or view.payload.len > max_encoded_bytes) return error.InvalidRecord;
        var edges = view.edges();
        const endpoint = edges.next().?;
        const publication = edges.next().?;
        if (endpoint.strength != .strong or publication.strength != .strong or endpoint.target.store != publication.target.store) return error.InvalidRecord;
        return .{ .intent = view.payload, .endpoint = endpoint.target, .publication = publication.target };
    }

    fn write(sink: anytype, request: core.GrantLedger.Issue) !void {
        try s.beginRecord(sink);
        try s.writeSymbol(sink, "access:derive");
        try s.writePositiveInt(sink, 1);
        try terms.write(sink, request.ceiling);
        try terms.write(sink, request.configured);
        try s.writePositiveInt(sink, request.delegation_depth);
        try s.writeSymbol(sink, @tagName(request.initial_status));
        try s.endRecord(sink);
    }
};
