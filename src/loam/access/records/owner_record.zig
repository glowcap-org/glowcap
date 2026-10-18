//! Durable owner identity, policy vocabulary, revisions, and directory roots.
const std = @import("std");
const core = @import("loam_access_core");
const loam = @import("loam_records");
const syrup = @import("syrup");
const s = syrup.RecordSyntax;
const fields = @import("fields.zig");
const profile = @import("profile.zig");
const maintenance_position = @import("maintenance_position.zig");
const directory_page = @import("directory_page.zig");

pub const OwnerRecord = struct {
    lifecycle: Lifecycle = .active,
    maintenance: maintenance_position.MaintenancePosition = .{},
    owner: core.OwnerId,
    policy: core.Policy,
    version: core.GrantLedger.Version = .{ .resources = @fromBackingInt(0), .grants = @fromBackingInt(0) },
    control_revision: u64 = 0,
    next_resource: u64 = 0,
    next_grant: u64 = 0,
    next_identity: u64 = 0,
    max_resource_depth: u32 = core.max_depth,
    max_grant_depth: u16 = core.max_depth,
    max_grant_children: u32 = 256,
    resources: ?loam.ObjectId = null,
    grants: ?loam.ObjectId = null,
    history: ?loam.ObjectId = null,
    roots: ?loam.ObjectId = null,
    observations: ?loam.ObjectId = null,
    identities: ?loam.ObjectId = null,
    pub const max_edges = root_fields.len;
    pub const Lifecycle = enum { active, retiring, retired };
    pub const max_encoded_bytes = 4096;
    pub const format_version: u64 = 1;
    const label = "access:owner";

    /// The directory roots, in edge order.
    const root_fields = [_][]const u8{ "resources", "grants", "history", "roots", "observations", "identities" };
    pub const max_slots: u64 = @as(u64, 1) << 32;

    pub fn encodeAlloc(self: OwnerRecord, allocator: std.mem.Allocator) ![]u8 {
        try self.validate();
        return syrup.render.renderRecordExact(allocator, write, .{self});
    }

    pub fn edges(self: OwnerRecord, buffer: *[max_edges]loam.Edge) []const loam.Edge {
        var count: usize = 0;
        inline for (root_fields) |name| if (@field(self, name)) |id| {
            buffer[count] = .{ .target = id };
            count += 1;
        };
        return buffer[0..count];
    }

    pub fn decode(view: loam.View) !OwnerRecord {
        if (view.schema != profile.owner or view.schema_version != format_version or view.payload.len > max_encoded_bytes) return error.InvalidRecord;
        const b = view.payload;
        var c: usize = 0;
        try s.readByte(b, &c, '<');
        if (!std.mem.eql(u8, try s.readSymbol(b, &c), label)) return error.InvalidRecord;
        if (try s.readPositiveInt(b, &c) != format_version) return error.UnsupportedVersion;
        const owner: core.OwnerId = @fromBackingInt(try fields.readWide(b, &c));
        const schema: core.Policy.Id = @fromBackingInt(try fields.readWide(b, &c));
        var keys: [core.Policy.max_permissions]core.Policy.Key = undefined;
        const key_count = try s.readPositiveInt(b, &c);
        if (key_count > keys.len) return error.InvalidRecord;
        for (keys[0..@intCast(key_count)]) |*key| key.* = @fromBackingInt(try s.readPositiveInt(b, &c));
        try s.readByte(b, &c, '[');
        var prerequisite_masks: [core.Policy.max_permissions]u64 = @splat(0);
        for (prerequisite_masks[0..@intCast(key_count)]) |*mask| {
            const encoded = try s.readBytes(b, &c);
            if (encoded.len != 8) return error.InvalidRecord;
            mask.* = std.mem.readInt(u64, encoded[0..8], .big);
        }
        try s.readByte(b, &c, ']');
        try s.readByte(b, &c, '[');
        var kinds: [core.Policy.max_kinds]core.Policy.KindRule = undefined;
        var kind_count: usize = 0;
        while (c < b.len and b[c] != ']') {
            if (kind_count == kinds.len) return error.PolicyLimit;
            const encoded = try s.readBytes(b, &c);
            if (encoded.len != 24) return error.InvalidRecord;
            kinds[kind_count] = .{
                .kind = @fromBackingInt(std.mem.readInt(u64, encoded[0..8], .big)),
                .permissions = std.mem.readInt(u64, encoded[8..16], .big),
                .subtree_permissions = std.mem.readInt(u64, encoded[16..24], .big),
            };
            kind_count += 1;
        }
        try s.readByte(b, &c, ']');
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
            .control_revision = try s.readPositiveInt(b, &c),
            .next_resource = try s.readPositiveInt(b, &c),
            .next_grant = try s.readPositiveInt(b, &c),
            .next_identity = try s.readPositiveInt(b, &c),
            .lifecycle = std.meta.stringToEnum(Lifecycle, try s.readSymbol(b, &c)) orelse return error.InvalidRecord,
            .maintenance = .{
                .sequence = try s.readPositiveInt(b, &c),
                .last = std.meta.stringToEnum(maintenance_position.MaintenancePosition.Command, try s.readSymbol(b, &c)) orelse return error.InvalidRecord,
                .phase = std.meta.stringToEnum(maintenance_position.MaintenancePosition.Phase, try s.readSymbol(b, &c)) orelse return error.InvalidRecord,
                .cursor = try s.readPositiveInt(b, &c),
            },
            .max_resource_depth = std.math.cast(u32, try s.readPositiveInt(b, &c)) orelse return error.InvalidRecord,
            .max_grant_depth = std.math.cast(u16, try s.readPositiveInt(b, &c)) orelse return error.InvalidRecord,
            .max_grant_children = std.math.cast(u32, try s.readPositiveInt(b, &c)) orelse return error.InvalidRecord,
        };
        var roots = view.edges();
        inline for (root_fields) |name| {
            if (try s.readBool(b, &c)) @field(result, name) = try fields.readEdge(&roots, view.id.store);
        }
        if (roots.next() != null) return error.InvalidRecord;
        try s.readByte(b, &c, '>');
        try s.expectEnd(b, c);
        try result.policy.setPrerequisiteMasks(&prerequisite_masks);
        try result.policy.setKinds(kinds[0..kind_count]);
        try result.validate();
        return result;
    }

    /// The directory root a family's slots index.
    pub fn root(self: *const OwnerRecord, family: directory_page.DirectoryPage.Family) ?loam.ObjectId {
        return switch (family) {
            .resource => self.resources,
            .grant => self.grants,
            .identity => self.identities,
        };
    }

    pub fn setRoot(self: *OwnerRecord, family: directory_page.DirectoryPage.Family, value: ?loam.ObjectId) void {
        switch (family) {
            .resource => self.resources = value,
            .grant => self.grants = value,
            .identity => self.identities = value,
        }
    }

    /// The slot a family mints next.
    pub fn nextSlot(self: *const OwnerRecord, family: directory_page.DirectoryPage.Family) u64 {
        return switch (family) {
            .resource => self.next_resource,
            .grant => self.next_grant,
            .identity => self.next_identity,
        };
    }

    fn hasRoots(self: *const OwnerRecord) bool {
        inline for (root_fields) |name| if (@field(self, name) != null) return true;
        return false;
    }

    fn validate(self: *const OwnerRecord) !void {
        if (self.maintenance.cursor > max_slots) return error.InvalidRecord;
        if ((self.maintenance.sequence == 0) != (self.maintenance.last == .none)) return error.InvalidRecord;
        if (self.lifecycle == .retired and (self.maintenance.phase != .idle or self.hasRoots())) return error.InvalidRecord;
        if (self.max_resource_depth > core.max_depth or self.max_grant_depth > core.max_depth) return error.InvalidRecord;
        if (self.next_resource > max_slots or self.next_grant > max_slots or self.next_identity > max_slots) return error.InvalidRecord;
        if ((self.next_resource == 0 and self.resources != null) or (self.next_grant == 0 and self.grants != null) or (self.next_identity == 0 and self.identities != null)) return error.InvalidRecord;
        try self.policy.check();
    }

    fn write(sink: anytype, self: OwnerRecord) !void {
        try s.beginRecord(sink);
        try s.writeSymbol(sink, label);
        try s.writePositiveInt(sink, format_version);
        try fields.writeWide(sink, @backingInt(self.owner));
        try fields.writeWide(sink, @backingInt(self.policy.id));
        try s.writePositiveInt(sink, self.policy.permission_count);
        for (self.policy.permission_keys[0..self.policy.permission_count]) |key| try s.writePositiveInt(sink, @backingInt(key));
        try s.beginList(sink);
        for (self.policy.prerequisite_masks[0..self.policy.permission_count]) |mask| {
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, mask, .big);
            try s.writeBytes(sink, &bytes);
        }
        try s.endList(sink);
        try s.beginList(sink);
        for (self.policy.kind_rules[0..self.policy.kind_count]) |rule| {
            var bytes: [24]u8 = undefined;
            std.mem.writeInt(u64, bytes[0..8], @backingInt(rule.kind), .big);
            std.mem.writeInt(u64, bytes[8..16], rule.permissions, .big);
            std.mem.writeInt(u64, bytes[16..24], rule.subtree_permissions, .big);
            try s.writeBytes(sink, &bytes);
        }
        try s.endList(sink);
        try s.writePositiveInt(sink, self.policy.constraint_count);
        for (self.policy.constraint_fields[0..self.policy.constraint_count]) |field| {
            try s.writePositiveInt(sink, @backingInt(field.key));
            try s.writeBool(sink, field.operator == .lower_bound);
        }
        try s.writePositiveInt(sink, @backingInt(self.version.resources));
        try s.writePositiveInt(sink, @backingInt(self.version.grants));
        try s.writePositiveInt(sink, self.control_revision);
        try s.writePositiveInt(sink, self.next_resource);
        try s.writePositiveInt(sink, self.next_grant);
        try s.writePositiveInt(sink, self.next_identity);
        try s.writeSymbol(sink, @tagName(self.lifecycle));
        try s.writePositiveInt(sink, self.maintenance.sequence);
        try s.writeSymbol(sink, @tagName(self.maintenance.last));
        try s.writeSymbol(sink, @tagName(self.maintenance.phase));
        try s.writePositiveInt(sink, self.maintenance.cursor);
        try s.writePositiveInt(sink, self.max_resource_depth);
        try s.writePositiveInt(sink, self.max_grant_depth);
        try s.writePositiveInt(sink, self.max_grant_children);
        inline for (root_fields) |name| try s.writeBool(sink, @field(self, name) != null);
        try s.endRecord(sink);
    }
};
