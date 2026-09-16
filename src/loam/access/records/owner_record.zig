//! Durable owner identity, policy vocabulary, revisions, and directory roots.
const std = @import("std");
const core = @import("loam_access_core");
const loam = @import("loam_records");
const syrup = @import("syrup");
const s = syrup.RecordSyntax;
const fields = @import("fields.zig");
const profile = @import("profile.zig");

pub const OwnerRecord = struct {
    owner: core.OwnerId,
    policy: core.Policy,
    version: core.GrantLedger.Version = .{ .resources = @fromBackingInt(0), .grants = @fromBackingInt(0) },
    next_resource: u64 = 0,
    next_grant: u64 = 0,
    max_resource_depth: u32 = 64,
    max_grant_depth: u16 = 64,
    max_grant_children: u32 = 256,
    resources: ?loam.ObjectId = null,
    grants: ?loam.ObjectId = null,
    change: ?loam.ObjectId = null,

    pub const max_slots: u64 = @as(u64, 1) << 32;

    pub fn encodeAlloc(self: OwnerRecord, allocator: std.mem.Allocator) ![]u8 {
        try self.validate();
        return syrup.render.renderRecordExact(allocator, write, .{self});
    }

    pub fn edges(self: OwnerRecord, buffer: *[3]loam.Edge) []const loam.Edge {
        var count: usize = 0;
        for ([_]?loam.ObjectId{ self.resources, self.grants, self.change }) |root| if (root) |id| {
            buffer[count] = .{ .target = id };
            count += 1;
        };
        return buffer[0..count];
    }

    pub fn decode(view: loam.View) !OwnerRecord {
        if (view.schema != profile.owner or view.schema_version != 1 or view.payload.len > 4096) return error.InvalidRecord;
        const b = view.payload;
        var c: usize = 0;
        try s.readByte(b, &c, '<');
        if (!std.mem.eql(u8, try s.readSymbol(b, &c), "access:owner")) return error.InvalidRecord;
        if (try s.readPositiveInt(b, &c) != 1) return error.UnsupportedVersion;
        const owner: core.OwnerId = @fromBackingInt(try fields.readWide(b, &c));
        const schema: core.Policy.Id = @fromBackingInt(try fields.readWide(b, &c));
        var keys: [core.Policy.max_permissions]core.Policy.Key = undefined;
        const key_count = try s.readPositiveInt(b, &c);
        if (key_count > keys.len) return error.InvalidRecord;
        for (keys[0..@intCast(key_count)]) |*key| key.* = @fromBackingInt(try s.readPositiveInt(b, &c));
        var constraints: [core.Policy.max_constraints]core.Policy.Constraint = undefined;
        const count = try s.readPositiveInt(b, &c);
        if (count > constraints.len) return error.InvalidRecord;
        for (constraints[0..@intCast(count)]) |*field| {
            field.key = @fromBackingInt(try s.readPositiveInt(b, &c));
            field.operator = if (try s.readBool(b, &c)) .lower_bound else .upper_bound;
        }
        var result: OwnerRecord = .{
            .owner = owner,
            .policy = try core.Policy.init(.{ .id = schema, .permissions = keys[0..@intCast(key_count)], .constraints = constraints[0..@intCast(count)] }),
            .version = .{ .resources = @fromBackingInt(try s.readPositiveInt(b, &c)), .grants = @fromBackingInt(try s.readPositiveInt(b, &c)) },
            .next_resource = try s.readPositiveInt(b, &c),
            .next_grant = try s.readPositiveInt(b, &c),
            .max_resource_depth = std.math.cast(u32, try s.readPositiveInt(b, &c)) orelse return error.InvalidRecord,
            .max_grant_depth = std.math.cast(u16, try s.readPositiveInt(b, &c)) orelse return error.InvalidRecord,
            .max_grant_children = std.math.cast(u32, try s.readPositiveInt(b, &c)) orelse return error.InvalidRecord,
        };
        var roots = view.edges();
        for ([_]*?loam.ObjectId{ &result.resources, &result.grants, &result.change }) |root| {
            if (try s.readBool(b, &c)) {
                const edge = roots.next() orelse return error.InvalidRecord;
                if (edge.strength != .strong) return error.InvalidRecord;
                root.* = edge.target;
            }
        }
        if (roots.next() != null) return error.InvalidRecord;
        try s.readByte(b, &c, '>');
        try s.expectEnd(b, c);
        try result.validate();
        return result;
    }

    fn validate(self: OwnerRecord) !void {
        if (self.next_resource > max_slots or self.next_grant > max_slots) return error.InvalidRecord;
        if ((self.next_resource == 0) != (self.resources == null) or (self.next_grant == 0) != (self.grants == null)) return error.InvalidRecord;
        // Validate active descriptor fields rather than serializing native arrays.
        if (self.policy.permission_count > core.Policy.max_permissions or self.policy.constraint_count > core.Policy.max_constraints) return error.InvalidRecord;
        _ = try core.Policy.init(.{ .id = self.policy.id, .permissions = self.policy.permission_keys[0..self.policy.permission_count], .constraints = self.policy.constraint_fields[0..self.policy.constraint_count] });
    }

    fn write(sink: anytype, self: OwnerRecord) !void {
        try s.beginRecord(sink);
        try s.writeSymbol(sink, "access:owner");
        try s.writePositiveInt(sink, 1);
        try fields.writeWide(sink, @backingInt(self.owner));
        try fields.writeWide(sink, @backingInt(self.policy.id));
        try s.writePositiveInt(sink, self.policy.permission_count);
        for (self.policy.permission_keys[0..self.policy.permission_count]) |key| try s.writePositiveInt(sink, @backingInt(key));
        try s.writePositiveInt(sink, self.policy.constraint_count);
        for (self.policy.constraint_fields[0..self.policy.constraint_count]) |field| {
            try s.writePositiveInt(sink, @backingInt(field.key));
            try s.writeBool(sink, field.operator == .lower_bound);
        }
        try s.writePositiveInt(sink, @backingInt(self.version.resources));
        try s.writePositiveInt(sink, @backingInt(self.version.grants));
        try s.writePositiveInt(sink, self.next_resource);
        try s.writePositiveInt(sink, self.next_grant);
        try s.writePositiveInt(sink, self.max_resource_depth);
        try s.writePositiveInt(sink, self.max_grant_depth);
        try s.writePositiveInt(sink, self.max_grant_children);
        for ([_]?loam.ObjectId{ self.resources, self.grants, self.change }) |root| try s.writeBool(sink, root != null);
        try s.endRecord(sink);
    }
};
