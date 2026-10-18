//! Canonical derivation intent and exact durable result retention.
const std = @import("std");
const core = @import("loam_access_core");
const loam = @import("loam_records");
const syrup = @import("syrup");
const fields = @import("fields.zig");
const terms = @import("terms.zig");
const s = syrup.RecordSyntax;
const profile = @import("profile.zig");

pub const DerivationRecord = struct {
    intent: []const u8,
    endpoint: loam.ObjectId,
    publication: loam.ObjectId,
    control: ?loam.ObjectId = null,
    pub const max_encoded_bytes = 64 * 1024;
    pub const format_version: u64 = 1;
    pub const max_edges = 3;
    const label = "access:derive";

    pub fn encodeIntent(allocator: std.mem.Allocator, owner: core.OwnerId, request: core.GrantLedger.Issue) ![]u8 {
        try request.label.validate();
        try terms.validate(request.ceiling, owner);
        try terms.validate(request.configured, owner);
        return syrup.render.renderRecordExact(allocator, write, .{ request, @as(?core.Control.Powers, null) });
    }

    pub fn encodeManagedIntent(allocator: std.mem.Allocator, owner: core.OwnerId, request: core.GrantLedger.Issue, powers: core.Control.Powers) ![]u8 {
        try request.label.validate();
        try terms.validate(request.ceiling, owner);
        try terms.validate(request.configured, owner);
        if (powers.policy_ceiling) |ceiling| try terms.validate(ceiling, owner);
        if (powers.issue_ceiling) |ceiling| try terms.validate(ceiling, owner);
        return syrup.render.renderRecordExact(allocator, write, .{ request, @as(?core.Control.Powers, powers) });
    }

    pub fn decode(view: loam.View) !DerivationRecord {
        if (view.schema != profile.derivation or view.schema_version != format_version or (view.edge_count != 2 and view.edge_count != 3) or view.payload.len > max_encoded_bytes) return error.InvalidRecord;
        var edges = view.edges();
        const endpoint = try fields.readEdge(&edges, view.id.store);
        const publication = try fields.readEdge(&edges, view.id.store);
        const control = if (view.edge_count == 3) try fields.readEdge(&edges, view.id.store) else null;
        return .{ .intent = view.payload, .endpoint = endpoint, .publication = publication, .control = control };
    }

    fn write(sink: anytype, request: core.GrantLedger.Issue, powers: ?core.Control.Powers) !void {
        try s.beginRecord(sink);
        try s.writeSymbol(sink, label);
        try s.writePositiveInt(sink, format_version);
        try terms.write(sink, request.ceiling);
        try terms.write(sink, request.configured);
        try s.writePositiveInt(sink, request.delegation_depth);
        try s.writeSymbol(sink, @tagName(request.initial_status));
        try s.writeBytes(sink, request.label.slice());
        try s.writeBool(sink, powers != null);
        if (powers) |control| try terms.writePowers(sink, control);
        try s.endRecord(sink);
    }
};
