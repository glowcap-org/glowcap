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
    dependency: ?loam.ObjectId = null,
    revoked: bool = false,
    pub const Role = enum { use, control };
    pub const format_version: u64 = 2;
    pub const max_edges = 3;
    const label = "access:capability";
    pub const max_encoded_bytes = 32 * 1024;
    /// Both independent ceilings can select the complete bounded scope.
    /// Fixed decoder storage owns the selections for the operation lifetime.
    pub const selection_bytes = 2 * core.max_scope_objects * @sizeOf(core.ResourceId);

    pub fn edges(self: CapabilityRecord, buffer: *[max_edges]loam.Edge) []const loam.Edge {
        buffer[0] = .{ .target = self.owner };
        buffer[1] = .{ .target = self.grant_object };
        if (self.dependency) |parent| {
            buffer[2] = .{ .target = parent };
            return buffer;
        }
        return buffer[0..2];
    }

    pub fn encodeAlloc(self: CapabilityRecord, allocator: std.mem.Allocator) ![]u8 {
        try self.validate();
        return syrup.render.renderRecordExact(allocator, write, .{self});
    }

    /// Releases the ceilings `decodeOwned` took from `allocator`.
    pub fn deinit(self: *CapabilityRecord, allocator: std.mem.Allocator) void {
        if (self.powers.policy_ceiling) |ceiling| ceiling.deinitOwned(allocator);
        if (self.powers.issue_ceiling) |ceiling| ceiling.deinitOwned(allocator);
        self.* = undefined;
    }

    /// Fills `self` from `view`. Each selected ceiling owns at most 256 IDs
    /// from `allocator`, independently, until `deinit`.
    pub fn decodeOwned(self: *CapabilityRecord, allocator: std.mem.Allocator, view: loam.View) !void {
        if (view.schema != profile.capability or view.schema_version != format_version or view.payload.len > max_encoded_bytes or (view.edge_count != 2 and view.edge_count != 3)) return error.InvalidRecord;
        var edges_it = view.edges();
        const owner = try fields.readEdge(&edges_it, view.id.store);
        const grant_object = try fields.readEdge(&edges_it, view.id.store);
        const b = view.payload;
        var c: usize = 0;
        try s.readByte(b, &c, '<');
        if (!std.mem.eql(u8, try s.readSymbol(b, &c), label)) return error.InvalidRecord;
        if (try s.readPositiveInt(b, &c) != format_version) return error.UnsupportedVersion;
        const grant = try fields.readId(core.GrantId, b, &c);
        const role = std.meta.stringToEnum(Role, try s.readSymbol(b, &c)) orelse return error.InvalidRecord;
        self.* = .{ .owner = owner, .grant_object = grant_object, .grant = grant, .role = role };
        errdefer self.deinit(allocator);
        if (try s.readBool(b, &c)) self.powers.policy_ceiling = try terms.readOwned(allocator, b, &c, grant.owner);
        if (try s.readBool(b, &c)) self.powers.issue_ceiling = try terms.readOwned(allocator, b, &c, grant.owner);
        self.powers.inspect = try s.readBool(b, &c);
        self.powers.delegate_control = try s.readBool(b, &c);
        self.powers.pause = try s.readBool(b, &c);
        self.powers.resume_access = try s.readBool(b, &c);
        self.powers.revoke = try s.readBool(b, &c);
        self.revoked = try s.readBool(b, &c);
        if (view.edge_count == 3) self.dependency = try fields.readEdge(&edges_it, view.id.store);
        try s.readByte(b, &c, '>');
        try s.expectEnd(b, c);
        try self.validate();
    }

    fn validate(self: CapabilityRecord) !void {
        if (self.grant.generation == 0 or self.owner.store != self.grant_object.store) return error.InvalidRecord;
        if (self.role == .use and (self.powers.policy_ceiling != null or self.powers.issue_ceiling != null or self.powers.inspect or self.powers.delegate_control or self.powers.pause or self.powers.resume_access or self.powers.revoke or self.dependency != null or self.revoked)) return error.InvalidRecord;
        if (self.dependency) |parent| if (parent.store != self.owner.store) return error.InvalidRecord;
        if (self.powers.policy_ceiling) |ceiling| try terms.validate(ceiling, self.grant.owner);
        if (self.powers.issue_ceiling) |ceiling| try terms.validate(ceiling, self.grant.owner);
    }

    fn write(sink: anytype, self: CapabilityRecord) !void {
        try s.beginRecord(sink);
        try s.writeSymbol(sink, label);
        try s.writePositiveInt(sink, format_version);
        try fields.writeId(sink, self.grant);
        try s.writeSymbol(sink, @tagName(self.role));
        try terms.writePowers(sink, self.powers);
        try s.writeBool(sink, self.revoked);
        try s.endRecord(sink);
    }
};
