//! Durable role and management terms, retaining exact owner and grant records.
const std = @import("std");
const core = @import("loam_access_core");
const loam = @import("loam_records");
const s = @import("syrup").RecordSyntax;
const syrup = @import("syrup");
const fields = @import("fields.zig");
const terms = @import("terms.zig");
const profile = @import("profile.zig");

pub const CapabilityRecord = struct {
    owner: loam.ObjectId,
    grant_object: loam.ObjectId,
    grant: core.GrantId,
    role: Role,
    powers: core.Control.Powers = .{},
    pub const Role = enum { use, control };
    pub const max_encoded_bytes = 16 * 1024;

    pub fn edges(self: CapabilityRecord) [2]loam.Edge {
        return .{ .{ .target = self.owner }, .{ .target = self.grant_object } };
    }

    pub fn encodeAlloc(self: CapabilityRecord, allocator: std.mem.Allocator) ![]u8 {
        try self.validate();
        return syrup.render.renderRecordExact(allocator, write, .{self});
    }

    pub const Owned = struct {
        value: CapabilityRecord,
        pub fn deinit(self: *Owned, allocator: std.mem.Allocator) void {
            if (self.value.powers.policy_ceiling) |ceiling| terms.free(allocator, ceiling);
            self.* = undefined;
        }
    };

    /// Only a selected management ceiling allocates, with at most 256 IDs.
    pub fn decodeOwned(allocator: std.mem.Allocator, view: loam.View) !Owned {
        if (view.schema != profile.capability or view.schema_version != 1 or view.payload.len > max_encoded_bytes or view.edge_count != 2) return error.InvalidRecord;
        var edges_it = view.edges();
        const owner = edges_it.next().?;
        const grant_object = edges_it.next().?;
        if (owner.strength != .strong or grant_object.strength != .strong) return error.InvalidRecord;
        const b = view.payload;
        var c: usize = 0;
        try s.readByte(b, &c, '<');
        if (!std.mem.eql(u8, try s.readSymbol(b, &c), "access:capability")) return error.InvalidRecord;
        if (try s.readPositiveInt(b, &c) != 1) return error.UnsupportedVersion;
        const grant = try fields.readId(core.GrantId, b, &c);
        const tag = try s.readSymbol(b, &c);
        const role: Role = if (std.mem.eql(u8, tag, "use")) .use else if (std.mem.eql(u8, tag, "control")) .control else return error.InvalidRecord;
        var result: Owned = .{ .value = .{ .owner = owner.target, .grant_object = grant_object.target, .grant = grant, .role = role } };
        errdefer result.deinit(allocator);
        if (try s.readBool(b, &c)) result.value.powers.policy_ceiling = try terms.readOwned(allocator, b, &c, grant.owner);
        result.value.powers.pause = try s.readBool(b, &c);
        result.value.powers.resume_access = try s.readBool(b, &c);
        result.value.powers.revoke = try s.readBool(b, &c);
        try s.readByte(b, &c, '>');
        try s.expectEnd(b, c);
        try result.value.validate();
        return result;
    }

    fn validate(self: CapabilityRecord) !void {
        if (self.grant.generation == 0 or self.owner.store != self.grant_object.store) return error.InvalidRecord;
        if (self.role == .use and (self.powers.policy_ceiling != null or self.powers.pause or self.powers.resume_access or self.powers.revoke)) return error.InvalidRecord;
        if (self.powers.policy_ceiling) |ceiling| try terms.validate(ceiling, self.grant.owner);
    }

    fn write(sink: anytype, self: CapabilityRecord) !void {
        try s.beginRecord(sink);
        try s.writeSymbol(sink, "access:capability");
        try s.writePositiveInt(sink, 1);
        try fields.writeId(sink, self.grant);
        try s.writeSymbol(sink, @tagName(self.role));
        try s.writeBool(sink, self.powers.policy_ceiling != null);
        if (self.powers.policy_ceiling) |ceiling| try terms.write(sink, ceiling);
        try s.writeBool(sink, self.powers.pause);
        try s.writeBool(sink, self.powers.resume_access);
        try s.writeBool(sink, self.powers.revoke);
        try s.endRecord(sink);
    }
};
