//! Irreversible identity refusal, without former authority or receipt edges.
const std = @import("std");
const loam = @import("loam_records");
const syrup = @import("syrup");
const s = syrup.RecordSyntax;
const profile = @import("profile.zig");

pub const TerminalRecord = struct {
    kind: Kind,
    derivation_floor: u64 = 0,
    mutation_floor: u64 = 0,
    pub const Kind = enum { capability, endpoint, grant, resource };
    pub const max_encoded_bytes = 128;

    pub fn encodeAlloc(self: TerminalRecord, allocator: std.mem.Allocator) ![]u8 {
        try self.validate();
        return syrup.render.renderRecordExact(allocator, write, .{self});
    }
    pub fn decode(view: loam.View) !TerminalRecord {
        if (view.schema != profile.terminal or view.schema_version != 1 or view.edge_count != 0 or view.payload.len > max_encoded_bytes) return error.InvalidRecord;
        var cursor: usize = 0;
        try s.readByte(view.payload, &cursor, '<');
        if (!std.mem.eql(u8, try s.readSymbol(view.payload, &cursor), "access:terminal")) return error.InvalidRecord;
        if (try s.readPositiveInt(view.payload, &cursor) != 1) return error.UnsupportedVersion;
        const value: TerminalRecord = .{
            .kind = std.meta.stringToEnum(Kind, try s.readSymbol(view.payload, &cursor)) orelse return error.InvalidRecord,
            .derivation_floor = try s.readPositiveInt(view.payload, &cursor),
            .mutation_floor = try s.readPositiveInt(view.payload, &cursor),
        };
        try s.readByte(view.payload, &cursor, '>');
        try s.expectEnd(view.payload, cursor);
        try value.validate();
        return value;
    }
    fn validate(self: TerminalRecord) !void {
        if (self.kind != .endpoint and (self.derivation_floor != 0 or self.mutation_floor != 0)) return error.InvalidRecord;
    }
    fn write(sink: anytype, self: TerminalRecord) !void {
        try s.beginRecord(sink);
        try s.writeSymbol(sink, "access:terminal");
        try s.writePositiveInt(sink, 1);
        try s.writeSymbol(sink, @tagName(self.kind));
        try s.writePositiveInt(sink, self.derivation_floor);
        try s.writePositiveInt(sink, self.mutation_floor);
        try s.endRecord(sink);
    }
};
