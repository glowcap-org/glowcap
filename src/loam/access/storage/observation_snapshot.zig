//! One scoped dependency digest, using the same evaluator as protected calls.
const std = @import("std");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const op = @import("capability_operation.zig");
const history = @import("history.zig");
const Hash = std.crypto.hash.sha2.Sha256;

pub const Control = struct {
    available: bool,
    grant_status: core.GrantLedger.Status,
    policy: core.Policy,
    pause: bool,
    resume_access: bool,
    revoke: bool,
    ceiling: ?core.Policy.Value,
    subtree: bool,
    inspect: bool = false,
    issue_ceiling: ?core.Policy.Value = null,
    delegate_control: bool = false,
    revision: core.Revision = @fromBackingInt(0),
};
pub const Snapshot = union(enum) { use: op.Operation.Description, control: Control };
pub const Prepared = struct {
    snapshot: Snapshot,
    digest: [32]u8,
    position: u64 = 0,
    grants: [records.ChangeBatchRecord.max_path]core.GrantId = undefined,
    grant_count: usize = 0,
    resources: [records.ChangeBatchRecord.max_path]core.ResourceId = undefined,
    resource_count: usize = 0,

    pub fn active(self: *const Prepared) bool {
        return switch (self.snapshot) {
            .use => |use| use.access == .active,
            .control => |control| control.available,
        };
    }
};

pub fn prepare(operation: *op.Operation, target: ?core.ResourceId) !Prepared {
    const state = op.state(operation);
    var prepared: Prepared = .{ .snapshot = undefined, .digest = undefined };
    prepared.snapshot = if (state.binding.role == .use) .{ .use = operation.describe(target orelse return error.WrongRole) catch |err| switch (err) {
        error.Gone => .{ .access = .out_of_scope, .policy = state.read.?.header.policy },
        else => return err,
    } } else blk: {
        const description = try operation.describeControl();
        break :blk .{ .control = .{
            .available = description.available,
            .grant_status = description.grant_status,
            .policy = description.policy,
            .pause = description.powers.pause,
            .resume_access = description.powers.resume_access,
            .revoke = description.powers.revoke,
            .inspect = description.powers.inspect,
            .issue_ceiling = if (description.powers.issue_ceiling) |ceiling| ceiling.policy else null,
            .delegate_control = description.powers.delegate_control,
            .revision = description.revision,
            .ceiling = if (description.powers.policy_ceiling) |ceiling| ceiling.policy else null,
            .subtree = if (description.powers.policy_ceiling) |ceiling| ceiling.scope == .owned_subtree else false,
        } };
    };
    if (state.binding.role == .control and target != null) return error.WrongRole;
    var hash = Hash.init(.{});
    hash.update("glowcap:observation-dependencies:1");
    switch (prepared.snapshot) {
        .use => |use| hash.update(@tagName(use.access)),
        .control => |control| {
            if (control.available) {
                hash.update(@tagName(control.grant_status));
                number(&hash, 1);
            } else hash.update("unavailable");
        },
    }
    // Terminal contexts disclose their existing status only. Neither policy
    // nor inventory activity can perturb their cursor afterward.
    const terminal = switch (prepared.snapshot) {
        .use => |use| use.access == .revoked,
        .control => |control| !control.available,
    };
    if (terminal) {
        hash.final(&prepared.digest);
        return prepared;
    }
    var grants = try state.read.?.grantView();
    var ancestry = grants.ancestry(state.descriptor.grant);
    while (try ancestry.next()) |grant| {
        if (prepared.grant_count == prepared.grants.len) return error.DepthLimit;
        prepared.grants[prepared.grant_count] = grant.id;
        prepared.grant_count += 1;
        const row = try history.row(&state.read.?, .{ .grant = grant.id });
        // The fixed scratch owns terms only until the next grant lookup. Decode
        // the stamp fields before asking the resource view for another row.
        var stored = try records.GrantRecord.decodeOwned(state.binding.owner.allocator, row.view.payload);
        defer stored.deinit(state.binding.owner.allocator);
        stamp(&prepared, &hash, if (state.binding.role == .control or prepared.snapshot.use.access == .paused) stored.value.lifecycle else stored.value.authority);
        if (state.binding.role == .control and grant.id.eql(state.descriptor.grant)) stamp(&prepared, &hash, stored.value.inventory);
        if (prepared.snapshot == .use and prepared.active()) {
            for ([_]core.Terms{ stored.value.grant.ceiling, stored.value.grant.configured }) |terms| {
                if (terms.scope == .owned_subtree) try containment(&state.read.?, &prepared, &hash, target.?, terms.scope.owned_subtree);
            }
        }
    }
    if (prepared.snapshot == .use and prepared.active()) {
        try resource(&state.read.?, &prepared, &hash, target.?);
        const row = try history.row(&state.read.?, .{ .resource = target.? });
        const stored = try records.ResourceRecord.decode(row.view);
        stamp(&prepared, &hash, stored.content);
    }
    hash.final(&prepared.digest);
    return prepared;
}

fn containment(read: *@import("read.zig").Read, prepared: *Prepared, hash: *Hash, target: core.ResourceId, anchor: core.ResourceId) !void {
    var cursor = target;
    for (0..records.ChangeBatchRecord.max_path) |_| {
        if (cursor.eql(anchor)) return;
        try resource(read, prepared, hash, cursor);
        var resources = try read.resourceView();
        cursor = (try resources.get(cursor)).parent orelse return error.OutOfScope;
    }
    return error.DepthLimit;
}

fn resource(read: *@import("read.zig").Read, prepared: *Prepared, hash: *Hash, id: core.ResourceId) !void {
    for (prepared.resources[0..prepared.resource_count]) |prior| if (prior.eql(id)) return;
    if (prepared.resource_count == prepared.resources.len) return error.DepthLimit;
    var resources = try read.resourceView();
    _ = try resources.get(id);
    const row = try history.row(read, .{ .resource = id });
    const stored = try records.ResourceRecord.decode(row.view);
    number(hash, id.slot);
    number(hash, id.generation);
    stamp(prepared, hash, stored.placement);
    prepared.resources[prepared.resource_count] = id;
    prepared.resource_count += 1;
}

fn number(hash: *Hash, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .big);
    hash.update(&bytes);
}

fn stamp(prepared: *Prepared, hash: *Hash, value: records.ChangeStamp) void {
    number(hash, value.revision);
    prepared.position = @max(prepared.position, value.position);
}
