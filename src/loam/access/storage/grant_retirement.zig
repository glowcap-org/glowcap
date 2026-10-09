//! Pruning one terminal child updates its surviving management inventory.
const std = @import("std");
const core = @import("loam_access_core");
const loam = @import("loam_core");
const records = @import("loam_access_records");
const Read = @import("read.zig").Read;
const history = @import("history.zig");
const record = @import("record.zig");

pub const Path = struct {
    ids: [records.ChangeBatchRecord.max_path]core.GrantId = undefined,
    count: usize = 0,
    pub fn slice(self: *const Path) []const core.GrantId {
        return self.ids[0..self.count];
    }
};
pub fn prepare(read: *Read, grant: core.GrantView.Record) !Path {
    try read.prepareHistory();
    var result: Path = .{};
    result.ids[0] = grant.id;
    result.count = 1;
    var grants = try read.grantView();
    var cursor = grant.parent;
    while (cursor) |id| {
        if (result.count == result.ids.len) return error.DepthLimit;
        for (result.slice()) |prior| if (prior.eql(id)) return error.InvalidRecord;
        const parent = grants.get(id) catch |err| switch (err) {
            error.Gone => break,
            else => return err,
        };
        result.ids[result.count] = id;
        result.count += 1;
        cursor = parent.parent;
    }
    return result;
}
pub fn stage(read: *Read, path: *const Path, child_edit: ?*@import("directory_edit.zig").DirectoryEdit) !void {
    if (path.count == 0) return error.NotPrepared;
    read.header.version.grants = @fromBackingInt(std.math.add(u64, @backingInt(read.header.version.grants), 1) catch return error.RevisionExhausted);
    if (path.count > 1) {
        const parent = try history.row(read, .{ .grant = path.ids[1] });
        var value = try records.GrantRecord.decodeOwned(read.allocator, parent.view.payload);
        defer value.deinit(read.allocator);
        if (value.value.grant.child_count == 0) return error.InvalidRecord;
        value.value.grant.child_count -= 1;
        value.value.grant.revision = read.header.version.grants;
        value.value.inventory = try history.stamp(read, @backingInt(read.header.version.grants));
        var edges: [515]loam.Edge = undefined;
        var iterator = parent.view.edges();
        var count: usize = 0;
        while (iterator.next()) |edge| {
            if (count == edges.len) return error.InvalidRecord;
            edges[count] = edge;
            count += 1;
        }
        const edit = child_edit orelse return error.NotPrepared;
        try edit.rebaseProposed(value.value.children);
        const root = try edit.stage(null);
        const old = value.value.children orelse return error.InvalidRecord;
        if (count == 0 or !edges[count - 1].target.eql(old)) return error.InvalidRecord;
        if (root) |id| edges[count - 1] = .{ .target = id } else count -= 1;
        value.value.children = root;
        try record.putEncoded(read.store, parent.view.id, records.profile.grant, value.value, edges[0..count], parent.expected, false);
        try history.touchGrants(read, path.ids[2..path.count]);
    }
    try history.append(read, .{ .grant_retired = .{ .id = path.ids[0], .path = path.slice() } });
}
