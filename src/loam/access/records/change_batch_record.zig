//! One owner's committed effects. Raw names remain private to scoped projection.
const std = @import("std");
const core = @import("loam_access_core");
const loam = @import("loam_records");
const syrup = @import("syrup");
const s = syrup.RecordSyntax;
const fields = @import("fields.zig");
const profile = @import("profile.zig");

pub const ChangeBatchRecord = struct {
    owner: core.OwnerId,
    commit_revision: u64,
    sequence: u64,
    effects: []const Effect,

    pub const max_effects = 16;
    pub const max_path = 65;
    pub const max_encoded_bytes = 64 * 1024;
    pub const Effect = union(enum) {
        grant: struct { change: core.GrantPlan.Change, path: []const core.GrantId },
        grant_retired: struct { id: core.GrantId, path: []const core.GrantId },
        resource: struct {
            id: core.ResourceId,
            kind: enum { created, moved, deleted },
            before: []const core.ResourceId,
            after: []const core.ResourceId,
        },
        content: struct { id: core.ResourceId, path: []const core.ResourceId },
        control: struct { object: loam.ObjectId, kind: enum { attenuated, revoked } },
    };

    pub const Owned = struct {
        value: ChangeBatchRecord,

        pub fn deinit(self: *Owned, allocator: std.mem.Allocator) void {
            for (self.value.effects) |effect| freeEffect(allocator, effect);
            allocator.free(self.value.effects);
            self.* = undefined;
        }
    };

    pub fn encodeAlloc(self: ChangeBatchRecord, allocator: std.mem.Allocator) ![]u8 {
        try self.validate(null);
        const bytes = try syrup.render.renderRecordExact(allocator, write, .{self});
        errdefer allocator.free(bytes);
        if (bytes.len > max_encoded_bytes) return error.RecordTooLarge;
        return bytes;
    }

    /// Owns the bounded effect array and its paths. No input bytes survive.
    /// Batch edges retain no application payload or capability descriptor.
    pub fn decodeOwned(allocator: std.mem.Allocator, view: loam.View) !Owned {
        if (view.schema != profile.change_batch or view.schema_version != 1 or view.edge_count != 0 or view.payload.len > max_encoded_bytes) return error.InvalidRecord;
        const bytes = view.payload;
        var cursor: usize = 0;
        try s.readByte(bytes, &cursor, '<');
        if (!std.mem.eql(u8, try s.readSymbol(bytes, &cursor), "access:change-batch")) return error.InvalidRecord;
        if (try s.readPositiveInt(bytes, &cursor) != 1) return error.UnsupportedVersion;
        const owner: core.OwnerId = @fromBackingInt(try fields.readWide(bytes, &cursor));
        const revision = try s.readPositiveInt(bytes, &cursor);
        const sequence = try s.readPositiveInt(bytes, &cursor);
        const count = try s.readPositiveInt(bytes, &cursor);
        if (count == 0 or count > max_effects) return error.InvalidRecord;
        const effects = try allocator.alloc(Effect, @intCast(count));
        errdefer allocator.free(effects);
        var initialized: usize = 0;
        errdefer for (effects[0..initialized]) |effect| freeEffect(allocator, effect);
        for (effects) |*effect| {
            effect.* = try readEffect(allocator, bytes, &cursor, owner);
            initialized += 1;
        }
        try s.readByte(bytes, &cursor, '>');
        try s.expectEnd(bytes, cursor);
        const result: ChangeBatchRecord = .{ .owner = owner, .commit_revision = revision, .sequence = sequence, .effects = effects };
        try result.validate(view.id.store);
        if (revision != view.revision) return error.InvalidRecord;
        return .{ .value = result };
    }

    fn validate(self: ChangeBatchRecord, store: ?loam.StoreId) !void {
        if (self.commit_revision == 0 or self.sequence == 0 or self.effects.len == 0 or self.effects.len > max_effects) return error.InvalidRecord;
        for (self.effects) |effect| switch (effect) {
            .grant_retired => |grant| try validatePath(core.GrantId, self.owner, grant.id, grant.path),
            .grant => |grant| {
                try validatePath(core.GrantId, self.owner, grant.change.grant, grant.path);
                switch (grant.change.kind) {
                    .issued => |parent| {
                        if (!std.meta.eql(parent, if (grant.path.len > 1) @as(?core.GrantId, grant.path[1]) else null)) return error.InvalidRecord;
                    },
                    .status_changed => |status| if (status.before == status.after or status.before == .revoked) return error.InvalidRecord,
                    .policy_changed, .label_changed => {},
                }
            },
            .resource => |resource| {
                const id = resource.id;
                if (id.owner != self.owner or id.generation == 0) return error.InvalidRecord;
                if (resource.kind != .created) try validatePath(core.ResourceId, self.owner, id, resource.before) else if (resource.before.len != 0) return error.InvalidRecord;
                if (resource.kind != .deleted) try validatePath(core.ResourceId, self.owner, id, resource.after) else if (resource.after.len != 0) return error.InvalidRecord;
                if (resource.kind == .moved and pathsEqual(resource.before, resource.after)) return error.InvalidRecord;
            },
            .content => |content| try validatePath(core.ResourceId, self.owner, content.id, content.path),
            .control => |control| {
                if (control.object.incarnation == 0 or control.object.sequence == 0) return error.InvalidRecord;
                if (store) |expected| if (control.object.store != expected) return error.InvalidRecord;
            },
        };
    }

    fn pathsEqual(before: []const core.ResourceId, after: []const core.ResourceId) bool {
        if (before.len != after.len) return false;
        for (before, after) |a, b| if (!a.eql(b)) return false;
        return true;
    }

    fn validatePath(comptime Id: type, owner: core.OwnerId, target: Id, path: []const Id) !void {
        if (path.len == 0 or path.len > max_path or !path[0].eql(target)) return error.InvalidRecord;
        for (path, 0..) |id, index| {
            if (id.owner != owner or id.generation == 0) return error.InvalidRecord;
            for (path[0..index]) |prior| if (prior.eql(id)) return error.InvalidRecord;
        }
    }

    fn write(sink: anytype, self: ChangeBatchRecord) !void {
        try s.beginRecord(sink);
        try s.writeSymbol(sink, "access:change-batch");
        try s.writePositiveInt(sink, 1);
        try fields.writeWide(sink, @backingInt(self.owner));
        try s.writePositiveInt(sink, self.commit_revision);
        try s.writePositiveInt(sink, self.sequence);
        try s.writePositiveInt(sink, self.effects.len);
        for (self.effects) |effect| {
            try s.beginRecord(sink);
            try s.writeSymbol(sink, @tagName(effect));
            switch (effect) {
                .grant_retired => |grant| {
                    try writeName(sink, grant.id);
                    try writePath(sink, grant.path);
                },
                .grant => |grant| {
                    const change = grant.change;
                    try s.writePositiveInt(sink, @backingInt(change.version.resources));
                    try s.writePositiveInt(sink, @backingInt(change.version.grants));
                    try writeName(sink, change.grant);
                    try s.writeSymbol(sink, @tagName(change.kind));
                    switch (change.kind) {
                        .issued => |parent| {
                            try s.writeBool(sink, parent != null);
                            if (parent) |id| try writeName(sink, id);
                        },
                        .status_changed => |status| {
                            try s.writeSymbol(sink, @tagName(status.before));
                            try s.writeSymbol(sink, @tagName(status.after));
                        },
                        .policy_changed, .label_changed => {},
                    }
                    try writePath(sink, grant.path);
                },
                .resource => |resource| {
                    try writeName(sink, resource.id);
                    try s.writeSymbol(sink, @tagName(resource.kind));
                    try writePath(sink, resource.before);
                    try writePath(sink, resource.after);
                },
                .content => |content| {
                    try writeName(sink, content.id);
                    try writePath(sink, content.path);
                },
                .control => |control| {
                    try fields.writeWide(sink, @backingInt(control.object.store));
                    try s.writePositiveInt(sink, control.object.incarnation);
                    try s.writePositiveInt(sink, control.object.sequence);
                    try s.writeSymbol(sink, @tagName(control.kind));
                },
            }
            try s.endRecord(sink);
        }
        try s.endRecord(sink);
    }

    fn writeName(sink: anytype, id: anytype) !void {
        try s.writePositiveInt(sink, id.slot);
        try s.writePositiveInt(sink, id.generation);
    }

    fn writePath(sink: anytype, path: anytype) !void {
        try s.writePositiveInt(sink, path.len);
        for (path) |id| try writeName(sink, id);
    }

    fn readName(comptime Id: type, bytes: []const u8, cursor: *usize, owner: core.OwnerId) !Id {
        return .{
            .owner = owner,
            .slot = std.math.cast(u32, try s.readPositiveInt(bytes, cursor)) orelse return error.InvalidRecord,
            .generation = try s.readPositiveInt(bytes, cursor),
        };
    }

    fn readPath(comptime Id: type, allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize, owner: core.OwnerId) ![]const Id {
        const count = try s.readPositiveInt(bytes, cursor);
        if (count > max_path) return error.InvalidRecord;
        const path = try allocator.alloc(Id, @intCast(count));
        errdefer allocator.free(path);
        for (path) |*id| id.* = try readName(Id, bytes, cursor, owner);
        return path;
    }

    fn readEffect(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize, owner: core.OwnerId) !Effect {
        try s.readByte(bytes, cursor, '<');
        const tag = try s.readSymbol(bytes, cursor);
        const effect: Effect = if (std.mem.eql(u8, tag, "grant")) result: {
            const version: core.GrantLedger.Version = .{
                .resources = @fromBackingInt(try s.readPositiveInt(bytes, cursor)),
                .grants = @fromBackingInt(try s.readPositiveInt(bytes, cursor)),
            };
            const grant = try readName(core.GrantId, bytes, cursor, owner);
            const kind_tag = try s.readSymbol(bytes, cursor);
            const kind: core.GrantPlan.Change.Kind = if (std.mem.eql(u8, kind_tag, "issued"))
                .{ .issued = if (try s.readBool(bytes, cursor)) try readName(core.GrantId, bytes, cursor, owner) else null }
            else if (std.mem.eql(u8, kind_tag, "status_changed"))
                .{ .status_changed = .{ .before = try fields.readStatus(bytes, cursor), .after = try fields.readStatus(bytes, cursor) } }
            else if (std.mem.eql(u8, kind_tag, "policy_changed"))
                .policy_changed
            else if (std.mem.eql(u8, kind_tag, "label_changed"))
                .label_changed
            else
                return error.InvalidRecord;
            break :result .{ .grant = .{ .change = .{ .version = version, .grant = grant, .kind = kind }, .path = try readPath(core.GrantId, allocator, bytes, cursor, owner) } };
        } else if (std.mem.eql(u8, tag, "grant_retired")) result: {
            const id = try readName(core.GrantId, bytes, cursor, owner);
            break :result .{ .grant_retired = .{ .id = id, .path = try readPath(core.GrantId, allocator, bytes, cursor, owner) } };
        } else if (std.mem.eql(u8, tag, "resource")) result: {
            const id = try readName(core.ResourceId, bytes, cursor, owner);
            const Kind = @FieldType(@FieldType(Effect, "resource"), "kind");
            const kind = std.meta.stringToEnum(Kind, try s.readSymbol(bytes, cursor)) orelse return error.InvalidRecord;
            const before = try readPath(core.ResourceId, allocator, bytes, cursor, owner);
            errdefer allocator.free(before);
            break :result .{ .resource = .{ .id = id, .kind = kind, .before = before, .after = try readPath(core.ResourceId, allocator, bytes, cursor, owner) } };
        } else if (std.mem.eql(u8, tag, "content")) result: {
            const id = try readName(core.ResourceId, bytes, cursor, owner);
            break :result .{ .content = .{ .id = id, .path = try readPath(core.ResourceId, allocator, bytes, cursor, owner) } };
        } else if (std.mem.eql(u8, tag, "control")) result: {
            const object: loam.ObjectId = .{
                .store = @fromBackingInt(try fields.readWide(bytes, cursor)),
                .incarnation = try s.readPositiveInt(bytes, cursor),
                .sequence = try s.readPositiveInt(bytes, cursor),
            };
            const Kind = @FieldType(@FieldType(Effect, "control"), "kind");
            break :result .{ .control = .{ .object = object, .kind = std.meta.stringToEnum(Kind, try s.readSymbol(bytes, cursor)) orelse return error.InvalidRecord } };
        } else return error.InvalidRecord;
        errdefer freeEffect(allocator, effect);
        try s.readByte(bytes, cursor, '>');
        return effect;
    }

    fn freeEffect(allocator: std.mem.Allocator, effect: Effect) void {
        switch (effect) {
            .grant_retired => |grant| allocator.free(grant.path),
            .grant => |grant| allocator.free(grant.path),
            .resource => |resource| {
                allocator.free(resource.before);
                allocator.free(resource.after);
            },
            .content => |content| allocator.free(content.path),
            .control => {},
        }
    }
};
