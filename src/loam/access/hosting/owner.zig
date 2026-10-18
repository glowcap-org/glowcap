//! Fresh owner staging: one owner, its root resource and grant, the root
//! content, and a use and control endpoint pair, in the caller's open Store
//! transaction. Names stay provisional until the caller's write installs.
const std = @import("std");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const storage = @import("loam_access_storage");
const loam = @import("loam_core");
const service = @import("service.zig");

pub const Owner = struct {
    /// The owner's identity in its policy.
    id: core.OwnerId,
    policy: core.Policy,
    /// The root resource's kind and its content's schema and first payload.
    kind: core.KindId,
    schema: u64,
    version: u32 = 1,
    payload: []const u8,
    delegation_depth: u16,
    /// What the root grant covers, in the share vocabulary's words: the root
    /// object alone, or its subtree, everything created or moved below it.
    scope: enum { object, subtree } = .object,
    /// Give the root content one first field naming its resource record, the
    /// way C and Rust content reads the resource it is bound to. A tree
    /// application leaves its fields for the children it creates.
    resource_field: bool = false,
};

pub const Staged = struct {
    owner: loam.ObjectId,
    use: loam.ObjectId,
    control: loam.ObjectId,
    /// The root use descriptor. A tree application stores created children's
    /// endpoints under it (`Service.child_descriptor`).
    descriptor: loam.ObjectId,
};

/// Stage the owner into the open transaction of a Store with no attachment.
/// Every read resolves this transaction's own proposals, so a read request
/// means the store already held conflicting data and refuses the stage.
pub fn stageOwner(store: *loam.Store, options: Owner) !Staged {
    const owner = try storage.stage.createOwner(store, options.id, options.policy, .{});
    var read: storage.Read = undefined;
    try read.init(store.allocator, store, owner, 8, null);
    defer read.deinit() catch unreachable;
    try ready(&read);
    const resource = blk: {
        var append = try storage.Append.init(&read, .resource);
        defer append.deinit() catch unreachable;
        try ready(&append);
        if (try retried(&read, storage.Append.prepareResource, .{ &append, @as(?core.ResourceId, null) }) != .ready) return error.InvalidTransaction;
        break :blk try retried(&read, storage.stage.appendResource, .{ &append, options.kind, @as(?core.ResourceId, null) });
    };
    const initial: core.Policy.Value = .{ .schema = options.policy.id, .permissions = try options.policy.supported(options.kind, false) };
    const terms: core.Terms = .{ .scope = switch (options.scope) {
        .object => .{ .object = resource },
        .subtree => .{ .owned_subtree = resource },
    }, .policy = initial };
    // Null means the policy issues no root grant here.
    var plan = try retried(&read, rootPlan, .{ &read, store.allocator, options.id, terms, options.delegation_depth }) orelse return error.InvalidTransaction;
    defer plan.deinit(store.allocator);
    try retried(&read, storage.stage.prepareGrant, .{ &read, &plan });
    const staged = blk: {
        var append = try storage.Append.init(&read, .grant);
        defer append.deinit() catch unreachable;
        try ready(&append);
        break :blk try retried(&read, storage.stage.grant, .{ &read, &plan, @as(?*storage.Append, &append) });
    };
    var caps = try storage.Capabilities.init(store.allocator, store, .{});
    defer caps.deinit() catch unreachable;
    const descriptor = try retried(&read, storage.Capabilities.stageUse, .{ &caps, &read, staged.change.grant, .reachable });
    const powers: core.Control.Powers = .{ .inspect = true, .issue_ceiling = terms, .delegate_control = true, .pause = true, .resume_access = true, .revoke = true, .policy_ceiling = terms };
    const control_descriptor = try retried(&read, storage.Capabilities.stageControl, .{ &caps, &read, staged.change.grant, powers, .reachable });
    const content = try store.allocateId();
    var fields: [1]loam.Edge = undefined;
    if (options.resource_field) fields[0] = .{ .target = try retried(&read, resourceObject, .{ &read, resource }) };
    try store.putCopying(.{ .id = content, .revision = 0, .schema = options.schema, .schema_version = options.version, .payload = options.payload, .edges = fields[0..@intFromBool(options.resource_field)] }, null);
    const use_endpoint: records.EndpointRecord = .{ .descriptor = descriptor, .content = .{ .resource = resource, .object = content } };
    const use = try retried(&read, service.stageEndpoint, .{ &read, store.allocator, use_endpoint, .rooted });
    const control_endpoint: records.EndpointRecord = .{ .descriptor = control_descriptor, .administration = use_endpoint.content };
    const control = try retried(&read, service.stageEndpoint, .{ &read, store.allocator, control_endpoint, .rooted });
    return .{ .owner = owner, .use = use, .control = control, .descriptor = descriptor };
}

fn ready(operation: anytype) !void {
    switch (try operation.advance()) {
        .ready => {},
        .read => |request| {
            try operation.completeRead(request.ticket, .{ .failed = error.InvalidTransaction });
            return error.InvalidTransaction;
        },
        .waiting => return error.InvalidTransaction,
    }
}

fn retried(read: *storage.Read, comptime operation: anytype, args: anytype) !@typeInfo(@typeInfo(@TypeOf(operation)).@"fn".return_type.?).error_union.payload {
    for (0..128) |_| {
        return @call(.auto, operation, args) catch |err| {
            if (err != error.RecordUnloaded) return err;
            try ready(read);
            continue;
        };
    }
    return error.InvalidTransaction;
}

fn rootPlan(read: *storage.Read, allocator: std.mem.Allocator, owner: core.OwnerId, terms: core.Terms, delegation_depth: u16) !?core.GrantPlan {
    var resources = try read.resourceView();
    var grants = try read.grantView();
    return core.GrantPlan.prepareCopying(allocator, &grants, &resources, &read.header.policy, read.header.max_grant_children, .{ .owner = owner, .slot = @intCast(read.header.next_grant), .generation = core.first_generation }, .{ .issue_root = .{ .ceiling = terms, .configured = terms, .delegation_depth = delegation_depth } });
}

fn resourceObject(read: *storage.Read, resource: core.ResourceId) !loam.ObjectId {
    const binding = (try read.binding(.{ .resource = resource })) orelse return error.RecordUnloaded;
    return binding.object orelse error.InvalidRecord;
}
