//! Trusted descriptor creation joins the caller's current Store transaction.
const core = @import("loam_access_core");
const loam = @import("loam_core");
const records = @import("loam_access_records");
const Read = @import("read.zig").Read;
const record = @import("record.zig");

pub fn descriptor(store: *loam.Store, value: records.CapabilityRecord, rooted: bool) !loam.ObjectId {
    if (store.phase != .staging) return error.WrongPhase;
    errdefer store.abort() catch unreachable;
    const object = try store.allocateId();
    try record.putEncoded(store, object, records.profile.capability, value, &value.edges(), null, rooted);
    return object;
}

pub fn create(read: *Read, grant: core.GrantId, powers: ?core.Control.Powers, rooted: bool) !loam.ObjectId {
    try read.opened();
    if (read.store.phase != .staging) return error.WrongPhase;
    var grants = try read.grantView();
    const current = try grants.get(grant);
    if (powers) |control| {
        var resources = try read.resourceView();
        try core.Control.validate(&resources, &read.header.policy, current.ceiling, control);
    }
    const binding = (try read.binding(.{ .grant = grant })).?;
    const grant_row = try read.store.currentView(binding.lease.?);
    return descriptor(read.store, .{ .owner = read.owner_object, .grant_object = grant_row.id, .grant = grant, .role = if (powers != null) .control else .use, .powers = powers orelse .{} }, rooted);
}
