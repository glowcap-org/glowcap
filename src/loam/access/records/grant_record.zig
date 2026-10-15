//! Structural grant encoding. Decoding owns bounded selections. Scope coverage,
//! policy schema interpretation, and current authority stay in the access core.
const std = @import("std");
const core = @import("loam_access_core");
const syrup = @import("syrup");
const syntax = syrup.RecordSyntax;
const fields = @import("fields.zig");
const terms = @import("terms.zig");
const Stamp = @import("change_stamp.zig").ChangeStamp;

pub const GrantRecord = struct {
    grant: core.GrantView.Record,
    authority: Stamp = .{},
    inventory: Stamp = .{},
    lifecycle: Stamp = .{},
    children: ?@import("loam_records").ObjectId = null,

    pub const format_version: u64 = 2;
    /// Two 256-member selections, fixed identities, and 32 optional bounds.
    pub const max_encoded_bytes: usize = 32 * 1024;
    /// Bounds the parent edge, the resources both scopes select, and the
    /// children root.
    pub const max_edges = 515;
    pub const Error = error{ MalformedRecord, UnsupportedVersion, InvalidRecord, RecordTooLarge };
    pub const DecodeError = Error || std.mem.Allocator.Error;
    const label = "access:grant";

    /// Exact owned output. No selections are retained by the encoder.
    pub fn encodeAlloc(self: GrantRecord, allocator: std.mem.Allocator) (Error || syrup.shared.WalkError)![]u8 {
        try self.validate();
        return syrup.render.renderRecordExact(allocator, write, .{self});
    }

    pub const Owned = struct {
        value: GrantRecord,

        pub fn deinit(self: *Owned, allocator: std.mem.Allocator) void {
            terms.free(allocator, self.value.grant.ceiling);
            terms.free(allocator, self.value.grant.configured);
            self.* = undefined;
        }
    };

    /// The scalar index identity and its retaining edge describe one root.
    /// Store corruption cannot redirect traversal outside the retained graph.
    pub fn validateChildren(self: GrantRecord, view: @import("loam_records").View) Error!void {
        const root = self.children orelse return;
        if (root.store != view.id.store or root.incarnation == 0 or root.sequence == 0) return error.InvalidRecord;
        var edges = view.edges();
        var last: ?@import("loam_records").Edge = null;
        while (edges.next()) |edge| last = edge;
        if (last == null or last.?.strength != .strong or !last.?.target.eql(root)) return error.InvalidRecord;
    }

    /// At most two exact-sized selection allocations. No input bytes survive
    /// the call; scalar/subtree scopes decode without allocation.
    pub fn decodeOwned(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Owned {
        if (bytes.len > max_encoded_bytes) return error.RecordTooLarge;
        return decodeRecord(allocator, bytes) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.UnsupportedVersion => error.UnsupportedVersion,
            error.InvalidRecord => error.InvalidRecord,
            else => error.MalformedRecord,
        };
    }

    fn validate(self: GrantRecord) Error!void {
        const g = self.grant;
        g.label.validate() catch return error.InvalidRecord;
        try self.authority.validate(@backingInt(g.revision));
        try self.inventory.validate(@backingInt(g.revision));
        try self.lifecycle.validate(@backingInt(g.revision));
        if (g.id.generation == 0) return error.InvalidRecord;
        if (g.parent) |parent| {
            if (parent.owner != g.id.owner or parent.generation == 0 or parent.eql(g.id)) return error.InvalidRecord;
        }
        try terms.validate(g.ceiling, g.id.owner);
        try terms.validate(g.configured, g.id.owner);
        if (g.ceiling.policy.schema != g.configured.policy.schema) return error.InvalidRecord;
    }

    fn write(sink: anytype, self: GrantRecord) !void {
        const g = self.grant;
        try syntax.beginRecord(sink);
        try syntax.writeSymbol(sink, label);
        try syntax.writePositiveInt(sink, format_version);
        try fields.writeId(sink, g.id);
        try syntax.writePositiveInt(sink, @backingInt(g.revision));
        try fields.writeParent(sink, g.parent);
        try terms.write(sink, g.ceiling);
        try terms.write(sink, g.configured);
        try syntax.writeSymbol(sink, @tagName(g.status));
        try syntax.writePositiveInt(sink, g.delegation_depth);
        try syntax.writePositiveInt(sink, g.child_count);
        try syntax.writeBytes(sink, g.label.slice());
        try self.authority.write(sink);
        try self.inventory.write(sink);
        try self.lifecycle.write(sink);
        try syntax.writeBool(sink, self.children != null);
        if (self.children) |id| try fields.writeWide(sink, @backingInt(id.store));
        if (self.children) |id| try syntax.writePositiveInt(sink, id.incarnation);
        if (self.children) |id| try syntax.writePositiveInt(sink, id.sequence);
        try syntax.endRecord(sink);
    }

    fn decodeRecord(allocator: std.mem.Allocator, bytes: []const u8) !Owned {
        var cursor: usize = 0;
        try syntax.readByte(bytes, &cursor, '<');
        if (!std.mem.eql(u8, try syntax.readSymbol(bytes, &cursor), label)) return error.MalformedRecord;
        if (try syntax.readPositiveInt(bytes, &cursor) != format_version) return error.UnsupportedVersion;
        const id = try fields.readId(core.GrantId, bytes, &cursor);
        const revision: core.Revision = @fromBackingInt(try syntax.readPositiveInt(bytes, &cursor));
        const parent = try fields.readParent(core.GrantId, bytes, &cursor);
        const ceiling = try terms.readOwned(allocator, bytes, &cursor, id.owner);
        errdefer terms.free(allocator, ceiling);
        const configured = try terms.readOwned(allocator, bytes, &cursor, id.owner);
        errdefer terms.free(allocator, configured);
        const status = try fields.readStatus(bytes, &cursor);
        const depth = std.math.cast(u16, try syntax.readPositiveInt(bytes, &cursor)) orelse return error.InvalidRecord;
        const children = std.math.cast(u32, try syntax.readPositiveInt(bytes, &cursor)) orelse return error.InvalidRecord;
        const grant_label = @import("loam_access_core").GrantLedger.Label.init(try syntax.readBytes(bytes, &cursor)) catch return error.InvalidRecord;
        const authority = try Stamp.read(bytes, &cursor);
        const inventory = try Stamp.read(bytes, &cursor);
        const lifecycle = try Stamp.read(bytes, &cursor);
        const child_root: ?@import("loam_records").ObjectId = if (try syntax.readBool(bytes, &cursor)) .{ .store = @fromBackingInt(try fields.readWide(bytes, &cursor)), .incarnation = try syntax.readPositiveInt(bytes, &cursor), .sequence = try syntax.readPositiveInt(bytes, &cursor) } else null;
        try syntax.readByte(bytes, &cursor, '>');
        try syntax.expectEnd(bytes, cursor);
        const value: GrantRecord = .{ .children = child_root, .authority = authority, .inventory = inventory, .lifecycle = lifecycle, .grant = .{ .label = grant_label, .id = id, .revision = revision, .parent = parent, .ceiling = ceiling, .configured = configured, .status = status, .delegation_depth = depth, .child_count = children } };
        try value.validate();
        return .{ .value = value };
    }
};
