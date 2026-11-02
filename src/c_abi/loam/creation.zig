//! Privileged fresh-resource staging through the Zig hosting owner stage.
const foreign_values = @import("foreign_values.zig");
const owners = @import("owners.zig");
const access = owners.access;

/// Opens and stages one complete fresh owner, root resource, grant, content,
/// use/control pair, and weak membership in a single Store transaction. Output
/// names are provisional until the shared write installs. No capability escapes.
pub fn stage(store: *owners.Store, policy: access.core.Policy, owner_id: access.core.OwnerId, kind: access.core.KindId, schema: u64, version: u32, payload: []const u8, depth: u16) !owners.c.GlowcapLoamResource {
    if (store.attachments != 0) return error.Busy;
    try store.value.begin();
    errdefer if (store.value.phase == .staging or store.value.phase == .prepared) store.value.abort() catch unreachable;
    const staged = try access.hosting.stageOwner(&store.value, .{ .id = owner_id, .policy = policy, .kind = kind, .schema = schema, .version = version, .payload = payload, .delegation_depth = depth, .resource_field = true });
    return .{ .owner = foreign_values.objectToC(staged.owner), .use = foreign_values.objectToC(staged.use), .control = foreign_values.objectToC(staged.control) };
}
