//! Pruning one terminal child updates its surviving management inventory.
const core = @import("loam_access_core");
const loam = @import("loam_core");
const records = @import("loam_access_records");
const Read = @import("read.zig").Read;
const history = @import("history.zig");
const record = @import("record.zig");
const directory_edit = @import("directory_edit.zig");

pub const Path = struct {
    ids: [records.ChangeBatchRecord.max_path]core.GrantId = undefined,
    count: usize = 0,
    pub fn slice(self: *const Path) []const core.GrantId {
        return self.ids[0..self.count];
    }
};
/// The terminal grant and every surviving ancestor, nearest first.
pub fn prepare(read: *Read, grant: core.GrantId, parent: ?core.GrantId) !Path {
    try read.prepareHistory();
    var result: Path = .{};
    result.ids[0] = grant;
    result.count = 1;
    var grants = try read.grantView();
    var cursor = parent;
    while (cursor) |id| {
        if (result.count == result.ids.len) return error.DepthLimit;
        for (result.slice()) |prior| if (prior.eql(id)) return error.InvalidRecord;
        const next = grants.borrow(id) catch |err| switch (err) {
            error.Gone => break,
            else => return err,
        };
        defer grants.release();
        result.ids[result.count] = id;
        result.count += 1;
        cursor = next.parent;
    }
    return result;
}
pub fn stage(read: *Read, path: *const Path, child_edit: ?*directory_edit.DirectoryEdit) !void {
    if (path.count == 0) return error.NotPrepared;
    read.header.version.grants = read.header.version.grants.next() orelse return error.RevisionExhausted;
    if (path.count > 1) {
        const parent = try history.row(read, .{ .grant = path.ids[1] });
        var value: records.GrantRecord = undefined;
        try value.decodeOwned(read.allocator, parent.view.payload);
        defer value.deinit(read.allocator);
        if (value.grant.child_count == 0) return error.InvalidRecord;
        value.grant.child_count -= 1;
        value.grant.revision = read.header.version.grants;
        value.inventory = try history.stamp(read, @backingInt(read.header.version.grants));
        var edges: [records.GrantRecord.max_edges]loam.Edge = undefined;
        var count = try record.copyEdges(parent.view, &edges);
        const edit = child_edit orelse return error.NotPrepared;
        try edit.rebaseProposed(value.children);
        const root = try edit.stage(null);
        const old = value.children orelse return error.InvalidRecord;
        if (count == 0 or !edges[count - 1].target.eql(old)) return error.InvalidRecord;
        if (root) |id| edges[count - 1] = .{ .target = id } else count -= 1;
        value.children = root;
        try record.putEncoded(read.store, parent.view.id, records.profile.grant, value, edges[0..count], parent.expected, .reachable);
        try history.touchGrants(read, path.ids[2..path.count]);
    }
    try history.append(read, .{ .grant_retired = .{ .id = path.ids[0], .path = path.slice() } });
}
