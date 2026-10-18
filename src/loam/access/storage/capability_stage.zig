//! Trusted descriptor creation joins the caller's current Store transaction.
const core = @import("loam_access_core");
const loam = @import("loam_core");
const records = @import("loam_access_records");
const Read = @import("read.zig").Read;
const record = @import("record.zig");

pub fn descriptor(read: *Read, value: records.CapabilityRecord, rooting: record.Rooting) !loam.ObjectId {
    const store = read.store;
    if (!value.owner.eql(read.owner_object)) return error.ForeignOwner;
    try read.prepareIdentities(1);
    if (store.phase != .staging) return error.WrongPhase;
    errdefer if (store.phase == .staging) store.abort() catch unreachable;
    const object = try store.allocateId();
    _ = try read.stageIdentity(object);
    var edges: [records.CapabilityRecord.max_edges]loam.Edge = undefined;
    try record.putEncoded(store, object, records.profile.capability, value, value.edges(&edges), null, rooting);
    return object;
}

pub fn create(read: *Read, grant: core.GrantId, powers: ?core.Control.Powers, rooting: record.Rooting) !loam.ObjectId {
    try read.opened();
    if (read.store.phase != .staging) return error.WrongPhase;
    var grants = try read.grantView();
    {
        const current = try grants.borrow(grant);
        defer grants.release();
        if (powers) |control| {
            var resources = try read.resourceView();
            try core.Control.validate(&resources, &read.header.policy, current.ceiling, control);
        }
    }
    const binding = (try read.binding(.{ .grant = grant })).?;
    const grant_row = (try Read.rowFor(read.store, binding) orelse return error.Gone).view;
    return descriptor(read, .{ .owner = read.owner_object, .grant_object = grant_row.id, .grant = grant, .role = if (powers != null) .control else .use, .powers = powers orelse .{} }, rooting);
}
