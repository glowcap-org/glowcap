//! The further same-owner resources one hosted content call reads or changes.
//! Each is admitted by every grant the call carries before invocation, and
//! each change stages through the call's one staging operation, so the call
//! still commits one owner header and one change batch.
const std = @import("std");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const storage = @import("loam_access_storage");
const loam = @import("loam_core");
const hosting = @import("loam_hosting");
const driver = @import("driver_core");
const service = @import("service.zig");
const ContentDelta = @import("content_delta.zig").ContentDelta;
const Step = @import("step.zig").Step;

/// The grants one call carries: the invoking endpoint's, and a dependent
/// call's target.
pub const grant_slots = 2;

const Entry = struct {
    declared: service.Participant,
    endpoint_object: loam.ObjectId,
    field: ?usize = null,
    endpoint_lease: ?loam.Lease = null,
    binding: ?records.EndpointRecord.Binding = null,
    content_lease: ?loam.Lease = null,
    resource: ?storage.Operation.BoundResource = null,
    admitted: [grant_slots]bool = @splat(false),
    prepared: bool = false,
    delta: ?ContentDelta = null,
};

pub const Participants = struct {
    entries: []Entry,
    /// Filled once every participant is admitted and loaded.
    loaded: []const service.ParticipantView = &.{},

    /// The fixed call-arena state `count` participants add to one call.
    pub fn allocationBound(count: usize) !hosting.references.AllocationBound {
        var bound: hosting.references.AllocationBound = .{};
        if (count == 0) return bound;
        if (count > service.max_participants) return error.TooManyParticipants;
        try bound.include(@sizeOf(Entry) * count, @alignOf(Entry), 1);
        try bound.include(@sizeOf(service.ParticipantView) * count, @alignOf(service.ParticipantView), 1);
        try bound.include(@sizeOf(service.ContentCallState) * count, @alignOf(service.ContentCallState), 1);
        return bound;
    }

    /// Resolve each declaration to the endpoint it designates. A field names a
    /// local strong edge of the bound content. An argument names a capability
    /// of this attachment. Designation admits nothing.
    pub fn init(arena: std.mem.Allocator, attachment: *hosting.Attachment, declared: []const service.Participant, content: loam.RecordView, args: []const driver.Value) !Participants {
        if (declared.len > service.max_participants) return error.TooManyParticipants;
        const entries = try arena.alloc(Entry, declared.len);
        for (entries, declared) |*entry, participant| entry.* = .{ .declared = participant, .endpoint_object = switch (participant.source) {
            .field => |index| try fieldEndpoint(content, index),
            .argument => |index| blk: {
                if (index >= args.len or args[index] != .capability) return error.InvalidArguments;
                break :blk try attachment.designated(args[index].capability);
            },
        } };
        for (entries, 0..) |*entry, index| {
            for (entries[0..index]) |prior| if (prior.endpoint_object.eql(entry.endpoint_object)) return error.DuplicateParticipant;
            // A field participant is its declared field, even when another
            // field stores the same endpoint.
            entry.field = switch (entry.declared.source) {
                .field => |field| field,
                .argument => fieldNaming(content, entry.endpoint_object),
            };
        }
        return .{ .entries = entries };
    }

    /// Load each endpoint and content row, admit each resource under its
    /// requirement through every carried grant, and bind it canonically.
    /// `.more` asks the caller to drain its operations and call again.
    pub fn advance(self: *Participants, arena: std.mem.Allocator, store: *loam.Store, owner: core.OwnerId, bound: core.ResourceId, grants: [grant_slots]?*storage.Operation, staging: *storage.Operation) !Step {
        for (self.entries) |*entry| {
            if (entry.endpoint_lease == null) entry.endpoint_lease = switch (try hosting.Preparation.acquire(store, entry.endpoint_object)) {
                .ready => |lease| lease,
                .read => |read| return .{ .read = read },
                .waiting => return .waiting,
            };
            if (entry.binding == null) {
                const endpoint = try records.EndpointRecord.decode(try store.currentView(entry.endpoint_lease.?));
                const content = endpoint.content orelse return error.NotUsable;
                // Independent owners meet through capability delivery, never
                // through one owner's evaluator over another owner's resource.
                if (content.resource.owner != owner) return error.ForeignOwner;
                if (content.resource.eql(bound)) return error.DuplicateParticipant;
                for (self.entries) |other| if (other.binding) |seen| if (seen.resource.eql(content.resource)) return error.DuplicateParticipant;
                entry.binding = content;
            }
            for (grants, &entry.admitted) |grant, *admitted| if (grant) |operation| if (!admitted.*) {
                try loam.reload(operation.require(entry.binding.?.resource, entry.declared.requirement)) orelse return .more;
                admitted.* = true;
            };
            if (entry.resource == null) entry.resource = try loam.reload(staging.boundResource(entry.binding.?.resource)) orelse return .more;
            if (entry.content_lease == null) entry.content_lease = switch (try hosting.Preparation.acquire(store, entry.binding.?.object)) {
                .ready => |lease| lease,
                .read => |read| return .{ .read = read },
                .waiting => return .waiting,
            };
        }
        const views = try arena.alloc(service.ParticipantView, self.entries.len);
        for (views, self.entries) |*view, entry| view.* = .{ .resource = entry.resource.?, .content = try store.currentView(entry.content_lease.?), .field = entry.field };
        self.loaded = views;
        return .ready;
    }

    /// Load each participant's history path in the staging operation before
    /// invocation, as the bound content's path already is. `.more` asks the
    /// caller to drain its operations and call again.
    pub fn prepareContent(self: *Participants, staging: *storage.Operation) !enum { ready, more } {
        for (self.entries) |*entry| if (!entry.prepared) {
            try loam.reload(storage.stage.prepareContent(staging, entry.binding.?.resource)) orelse return .more;
            entry.prepared = true;
        };
        return .ready;
    }

    /// One callback state per participant, sharing the bound call's reply
    /// policy and staging operation.
    pub fn calls(self: *const Participants, arena: std.mem.Allocator, bound: *const service.ContentCallState) ![]service.ContentCallState {
        const result = try arena.alloc(service.ContentCallState, self.entries.len);
        for (result, self.loaded) |*call, view| call.* = .initParticipant(bound, view.content);
        return result;
    }

    /// Keep each participant's proposed change for staging.
    pub fn retain(self: *Participants, arena: std.mem.Allocator, invoked: []const service.ContentCallState) !void {
        for (self.entries, invoked) |*entry, call| {
            if (call.graph_replaced) return error.NotContentGraph;
            entry.delta = try ContentDelta.prepare(arena, call.view, call.replacement, call.edits.items, call.appended.items);
        }
    }

    pub fn changed(self: *const Participants) bool {
        for (self.entries) |entry| if (entry.delta != null) return true;
        return false;
    }

    pub fn resource(self: *const Participants, index: usize) !core.ResourceId {
        if (index >= self.entries.len) return error.NoSuchParticipant;
        return self.entries[index].binding.?.resource;
    }

    /// Put each changed content row. History follows through `stageHistory`.
    pub fn stageRows(self: *const Participants, store: *loam.Store, arena: std.mem.Allocator) !void {
        for (self.entries) |entry| if (entry.delta) |delta| {
            try delta.put(store, arena, try store.currentView(entry.content_lease.?));
        };
    }

    /// Journal each changed participant after the call's first effect,
    /// skipping the one a structural effect already journaled.
    pub fn stageHistory(self: *const Participants, staging: *storage.Operation, journaled: ?core.ResourceId) !void {
        for (self.entries) |entry| if (entry.delta != null) {
            const id = entry.binding.?.resource;
            if (journaled != null and journaled.?.eql(id)) continue;
            try storage.stage.contentAlso(staging, id);
        };
    }

    pub fn release(self: *Participants, store: *loam.Store) void {
        for (self.entries) |*entry| {
            if (entry.content_lease) |lease| store.release(lease) catch unreachable;
            if (entry.endpoint_lease) |lease| store.release(lease) catch unreachable;
            entry.content_lease = null;
            entry.endpoint_lease = null;
        }
    }
};

fn fieldEndpoint(content: loam.RecordView, index: usize) !loam.ObjectId {
    const edge = try content.edgeAt(index);
    if (edge.strength != .strong or edge.restoration != .object) return error.NotDurable;
    return edge.target;
}

fn fieldNaming(content: loam.RecordView, endpoint: loam.ObjectId) ?usize {
    var edges = content.edges();
    var index: usize = 0;
    while (edges.next()) |edge| : (index += 1) {
        if (edge.strength == .strong and edge.restoration == .object and edge.target.eql(endpoint)) return index;
    }
    return null;
}
