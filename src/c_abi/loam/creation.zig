//! Privileged fresh-resource staging uses the same graph and grant participants.
const common = @import("common.zig");
const access = common.access;
const core = common.core;

fn ready(operation: anytype) !void {
    switch (try operation.advance()) {
        .ready => {},
        // Fresh creation resolves this transaction's own proposals only. A
        // submitted read here would mean creation crossed into existing data.
        .read => |request| {
            try operation.completeRead(request.ticket, .{ .failed = error.InvalidTransaction });
            return error.InvalidTransaction;
        },
        .waiting => return error.InvalidTransaction,
    }
}
fn prepared(read: *access.storage.Read, comptime operation: anytype, args: anytype) !@typeInfo(@typeInfo(@TypeOf(operation)).@"fn".return_type.?).error_union.payload {
    for (0..128) |_| {
        return @call(.auto, operation, args) catch |err| {
            if (err != error.RecordUnloaded) return err;
            try ready(read);
            continue;
        };
    }
    return error.InvalidTransaction;
}
/// Opens and stages one complete fresh owner, root resource, grant, content,
/// use/control pair, and weak membership in a single Store transaction. Output
/// names are provisional until the shared write installs; no capability escapes.
pub fn stage(store: *common.Store, policy: access.core.Policy, owner_id: access.core.OwnerId, kind: access.core.KindId, schema: u64, version: u32, payload: []const u8, depth: u16) !common.c.GlowcapLoamResource {
    if (store.attachments != 0) return error.Busy;
    try store.value.begin();
    errdefer if (store.value.phase == .staging or store.value.phase == .prepared) store.value.abort() catch unreachable;
    const transaction = &store.value;
    const owner = try access.storage.stage.createOwner(transaction, owner_id, policy, .{});
    var read = try access.storage.Read.init(store.allocator, transaction, owner, 8);
    defer read.deinit() catch unreachable;
    try ready(&read);
    const resource = blk: {
        var append = try access.storage.Append.init(&read, .resource);
        defer append.deinit() catch unreachable;
        try ready(&append);
        if (try prepared(&read, access.storage.Append.prepareResource, .{ &append, @as(?access.core.ResourceId, null) }) != .ready) return error.InvalidTransaction;
        break :blk try prepared(&read, access.storage.stage.appendResource, .{ &append, kind, @as(?access.core.ResourceId, null) });
    };
    const terms: access.core.Terms = .{ .scope = .{ .object = resource }, .policy = try policy.value(policy.permission_keys[0..policy.permission_count], &.{}) };
    var plan: ?access.core.GrantPlan = null;
    defer if (plan) |*owned| owned.deinit(store.allocator);
    for (0..16) |_| {
        var resources = try read.resourceView();
        var grants = try read.grantView();
        plan = access.core.GrantPlan.prepareCopying(store.allocator, &grants, &resources, &read.header.policy, read.header.max_grant_children, .{ .owner = owner_id, .slot = @intCast(read.header.next_grant), .generation = 1 }, .{ .issue_root = .{ .ceiling = terms, .configured = terms, .delegation_depth = depth } }) catch |err| {
            if (err != error.RecordUnloaded) return err;
            try ready(&read);
            continue;
        };
        break;
    }
    const grant_plan = if (plan) |*value| value else return error.InvalidTransaction;
    try @This().prepared(&read, access.storage.stage.prepareGrant, .{ &read, grant_plan });
    const staged = blk: {
        var append = try access.storage.Append.init(&read, .grant);
        defer append.deinit() catch unreachable;
        try ready(&append);
        break :blk try @This().prepared(&read, access.storage.stage.grant, .{ &read, grant_plan, @as(?*access.storage.Append, &append) });
    };
    var caps = try access.storage.Capabilities.init(store.allocator, transaction, .{});
    defer caps.deinit() catch unreachable;
    var use_descriptor: ?core.ObjectId = null;
    for (0..16) |_| {
        use_descriptor = caps.stageUse(&read, staged.change.grant, false) catch |err| {
            if (err != error.RecordUnloaded) return err;
            try ready(&read);
            continue;
        };
        break;
    }
    const use_id = use_descriptor orelse return error.InvalidTransaction;
    const powers: access.core.Control.Powers = .{ .pause = true, .resume_access = true, .revoke = true, .policy_ceiling = terms };
    const control_descriptor = try @This().prepared(&read, access.storage.Capabilities.stageControl, .{ &caps, &read, staged.change.grant, powers, false });
    const content = try transaction.allocateId();
    const binding = try @This().prepared(&read, resourceObject, .{ &read, resource });
    try transaction.putCopying(.{ .id = content, .revision = 0, .schema = schema, .schema_version = version, .payload = payload, .edges = &.{.{ .target = binding }} }, null);
    const use_endpoint: access.records.EndpointRecord = .{ .descriptor = use_id, .content = .{ .resource = resource, .object = content } };
    const use = try @This().prepared(&read, access.hosting.stageEndpoint, .{ &read, store.allocator, use_endpoint, true });
    const control_endpoint: access.records.EndpointRecord = .{ .descriptor = control_descriptor };
    const control = try @This().prepared(&read, access.hosting.stageEndpoint, .{ &read, store.allocator, control_endpoint, true });
    return .{ .owner = common.objectToC(owner), .use = common.objectToC(use), .control = common.objectToC(control) };
}

fn resourceObject(read: *access.storage.Read, resource: access.core.ResourceId) !core.ObjectId {
    const binding = (try read.binding(.{ .resource = resource })) orelse return error.RecordUnloaded;
    return binding.object orelse error.InvalidRecord;
}
