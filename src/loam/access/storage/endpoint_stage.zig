//! Endpoint creation and weak owner membership share one staging boundary.
const std = @import("std");
const loam = @import("loam_core");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const Read = @import("read.zig").Read;
const op = @import("capability_operation.zig");
const record = @import("record.zig");

pub fn create(read: *Read, allocator: std.mem.Allocator, value: records.EndpointRecord, rooted: bool) !loam.ObjectId {
    try validate(read, value);
    const store = read.store;
    errdefer if (store.phase == .staging) store.abort() catch unreachable;
    const object = try store.allocateId();
    try stage(read, allocator, object, value, rooted);
    return object;
}

pub fn createFromOperation(operation: *op.Operation, allocator: std.mem.Allocator, value: records.EndpointRecord, rooted: bool) !loam.ObjectId {
    const state = op.state(operation);
    try state.opened();
    return create(&state.read.?, allocator, value, rooted);
}

pub fn stageFromOperation(operation: *op.Operation, allocator: std.mem.Allocator, object: loam.ObjectId, value: records.EndpointRecord, rooted: bool) !void {
    const state = op.state(operation);
    try state.opened();
    try stage(&state.read.?, allocator, object, value, rooted);
}

fn validate(read: *Read, value: records.EndpointRecord) !void {
    try read.opened();
    try read.prepareIdentities(1);
    if (read.store.phase != .staging) return error.WrongPhase;
    var scratch: [core.max_scope_objects * @sizeOf(core.ResourceId)]u8 align(@alignOf(core.ResourceId)) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    const proposed = try read.store.proposed(value.descriptor);
    const lease: ?loam.Lease = if (proposed == null) read.store.resident(value.descriptor) catch |err| {
        if (err == error.ResidencyRequired) return error.RecordUnloaded;
        return err;
    } else null;
    defer if (lease) |held| read.store.release(held) catch unreachable;
    const view = if (proposed) |row| row.view else try read.store.currentView(lease.?);
    var descriptor = try records.CapabilityRecord.decodeOwned(fixed.allocator(), view);
    defer descriptor.deinit(fixed.allocator());
    if (!descriptor.value.owner.eql(read.owner_object)) return error.ForeignOwner;
    if (value.content) |content| {
        if (descriptor.value.role != .use or content.resource.owner != read.header.owner) return error.WrongRole;
    } else if (descriptor.value.role != .control) return error.WrongRole;
}

fn stage(read: *Read, allocator: std.mem.Allocator, object: loam.ObjectId, value: records.EndpointRecord, rooted: bool) !void {
    try validate(read, value);
    errdefer if (read.store.phase == .staging) read.store.abort() catch unreachable;
    _ = try read.stageIdentity(object);
    const payload = try value.encodeAlloc(allocator);
    defer allocator.free(payload);
    var edges: [records.EndpointRecord.max_edges]loam.Edge = undefined;
    try record.put(read.store, object, records.profile.endpoint, payload, value.edges(&edges), null, rooted);
}
