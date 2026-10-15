//! The child one hosted call creates under its bound resource. Declared
//! before invocation, prepared through the call's one staging operation,
//! stored under the owner's child descriptor, and replied to as a facet of the
//! invoking endpoint, the same authority a stored field discloses.
const std = @import("std");
const core = @import("loam_access_core");
const storage = @import("loam_access_storage");
const loam = @import("loam_core");
const hosting = @import("loam_hosting");
const driver = @import("driver_core");
const service = @import("service.zig");
const ContentDelta = @import("content_delta.zig").ContentDelta;
const Mutation = @import("mutation.zig").Mutation;

pub const Step = union(enum) { ready, read: loam.Read, waiting, more };

pub const Creation = struct {
    declared: service.Creation,
    /// The owner's child descriptor row. Endpoint staging reads it, so it
    /// stays resident until the call settles.
    descriptor: ?loam.Lease = null,
    prepared: bool = false,
    /// The child's first payload, as the callback gave it.
    payload: ?[]const u8 = null,
    /// The bound content's proposed edit, kept so staging can append the
    /// child's field once its endpoint has an id.
    bound_edit: ?struct { replacement: ?[]const u8, edits: []const service.ReferenceEdit, appended: []const hosting.references.Replacement } = null,
    /// The created child's facet, staged as this call's reply.
    facet: ?driver.Capability = null,

    /// Hold the descriptor row and prepare the append under `parent`. `.more`
    /// asks the caller to drain its operations and call again.
    pub fn prepare(self: *Creation, store: *loam.Store, descriptor: loam.ObjectId, staging: *storage.Operation, parent: core.ResourceId, requirement: core.Policy.Requirement) !Step {
        if (self.descriptor == null) self.descriptor = switch (store.acquire(descriptor) catch |err| {
            if (err == error.PendingRead) return .waiting;
            return err;
        }) {
            .ready => |lease| lease,
            .read => |read| return .{ .read = read },
        };
        staging.prepareChild(parent, requirement) catch |err| {
            if (err == error.RecordUnloaded) return .more;
            return err;
        };
        self.prepared = true;
        return .ready;
    }

    /// Keep what invocation proposed: the child's payload and the bound
    /// content's own edit. Hosting owns a creating call's reply, so the
    /// callback returns void.
    pub fn retain(self: *Creation, returned: driver.Value, invoked: *const service.ContentCallState) !void {
        if (returned != .void) return error.InvalidMutation;
        self.payload = invoked.child_payload orelse return error.ChildNotCreated;
        self.bound_edit = .{ .replacement = invoked.replacement, .edits = invoked.edits.items, .appended = invoked.appended.items };
    }

    /// Append the child, write its first content and its endpoint under the
    /// descriptor, and give the bound content its one new field. Returns the
    /// bound content's delta, which staging journals as the call's content
    /// effect.
    pub fn stage(self: *Creation, store: *loam.Store, staging: *storage.Operation, arena: std.mem.Allocator, call: *hosting.Call, bound: loam.Lease, mutation: ?*Mutation) !ContentDelta {
        const child = try storage.stage.child(staging, self.declared.kind);
        const content = try store.allocateId();
        try store.putCopying(.{ .id = content, .revision = 0, .schema = self.declared.schema, .schema_version = self.declared.version, .payload = self.payload.?, .edges = &.{} }, null);
        const endpoint = try store.allocateId();
        const descriptor = (try store.currentView(self.descriptor.?)).id;
        try storage.stage.endpointAtOperation(staging, arena, endpoint, .{ .descriptor = descriptor, .content = .{ .resource = child.id, .object = content } }, false);
        const edit = self.bound_edit.?;
        const appended = try arena.alloc(hosting.references.Replacement, edit.appended.len + 1);
        @memcpy(appended[0..edit.appended.len], edit.appended);
        appended[edit.appended.len] = .{ .edge = .{ .target = endpoint } };
        const view = try store.currentView(bound);
        const delta = (try ContentDelta.prepare(arena, view, edit.replacement, edit.edits, appended)).?;
        try store.putCopying(.{ .id = view.id, .revision = 0, .schema = view.schema, .schema_version = view.schema_version, .rooted = view.rooted, .payload = delta.payload, .edges = try delta.stageEdges(store, arena) }, view.revision);
        const facet = try call.discloseHeld(try call.projectDependent(try call.propose(endpoint)));
        self.facet = facet;
        if (mutation) |receipt| try receipt.retainFacetResult(facet, endpoint);
        return delta;
    }

    pub fn reply(self: *const Creation) !driver.Value {
        return .{ .capability = self.facet orelse return error.NoPreparedChange };
    }

    pub fn release(self: *Creation, store: *loam.Store) void {
        if (self.descriptor) |lease| store.release(lease) catch unreachable;
        self.descriptor = null;
    }
};
