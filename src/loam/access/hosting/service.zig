//! Trusted application method declarations around opaque managed operations.
const std = @import("std");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const storage = @import("loam_access_storage");
const loam = @import("loam_core");
const hosting = @import("loam_hosting");
const driver = @import("driver_core");
const working = @import("working.zig");

pub const ContentCall = opaque {
    /// The retained call arena. Reply values and replacement payloads borrow it.
    pub fn allocator(self: *ContentCall) std.mem.Allocator {
        return state(self).call.arena;
    }

    /// Replaces the bound content payload, preserving its committed edges.
    /// Bytes must survive callback return; allocate them from `allocator()`.
    pub fn replace(self: *ContentCall, payload: []const u8) void {
        state(self).replacement = payload;
    }

    /// Declare that this method's reply hands over a stored reference field's
    /// exact saved authority: the strong edge `index` of the bound content
    /// record. Returns the capability value for the reply. The reply may carry
    /// it, nested or direct; any capability this method did not declare is
    /// refused before settlement (ADR-0172).
    pub fn discloseExact(self: *ContentCall, index: usize) !driver.Value {
        const value = state(self);
        return .{ .capability = try value.call.discloseHeld(try value.call.storedEdge(value.view, index)) };
    }

    /// Declare a returned facet whose every call must pass both the current
    /// invoking-grant authority and the exact authority stored in strong edge
    /// `index`. Unlike `discloseExact`, this never exposes the saved target.
    pub fn discloseDependent(self: *ContentCall, index: usize) !driver.Value {
        const value = state(self);
        const target = try value.call.storedEdge(value.view, index);
        return .{ .capability = try value.call.discloseHeld(try value.call.projectDependent(target)) };
    }

    /// Replace one declared strong reference field in the same transaction as
    /// this method's payload change. Local targets are captured directly; other
    /// targets require a declared, prepared save. Custody survives the outcome.
    pub fn replaceReference(self: *ContentCall, index: usize, replacement: driver.Capability) !void {
        const value = state(self);
        try requireStrongEdge(value.view, index);
        try value.edits.ensureUnusedCapacity(value.call.arena, 1);
        try value.refuseDuplicate(index);
        const captured = try capture(value, replacement);
        value.edits.appendAssumeCapacity(.{ .index = index, .replacement = captured });
    }

    /// Replace from an independently completed save operation. Copying binds
    /// its verified recipe and capability custody to this retained call.
    pub fn replaceSavedReference(self: *ContentCall, index: usize, saved: *hosting.references.Save) !void {
        const value = state(self);
        try requireStrongEdge(value.view, index);
        try value.refuseDuplicate(index);
        const replacement = try hosting.references.copySaved(value.call, saved);
        try value.edits.append(value.call.arena, .{ .index = index, .replacement = replacement });
    }

    /// Remove one declared strong reference field transactionally. Edit
    /// indices address the committed edge list, so multiple edits do not shift
    /// one another while the callback is running.
    pub fn removeReference(self: *ContentCall, index: usize) !void {
        const value = state(self);
        try requireStrongEdge(value.view, index);
        try value.edits.ensureUnusedCapacity(value.call.arena, 1);
        try value.refuseDuplicate(index);
        value.edits.appendAssumeCapacity(.{ .index = index, .replacement = null });
    }

    /// Append a held field after the surviving committed fields. Preparation
    /// verifies foreign recipes before invocation; payload and fields commit
    /// together. Existing edit indices continue to name the committed list.
    /// The replacement spine uses the retained call arena and cannot exceed
    /// the schema's remaining edge capacity; no separate heap owner is created.
    pub fn appendReference(self: *ContentCall, replacement: driver.Capability) !void {
        const value = state(self);
        const schema = for (value.call.attachment.store.cache.schemas) |candidate| {
            if (candidate.id == value.view.schema and candidate.version == value.view.schema_version) break candidate;
        } else return error.UnsupportedSchema;
        var removed: usize = 0;
        for (value.edits.items) |edit| if (edit.replacement == null) {
            removed += 1;
        };
        if (value.view.edge_count - removed + value.appended.items.len >= schema.max_edges) return error.TooManyEdges;
        try value.appended.ensureUnusedCapacity(value.call.arena, 1);
        value.appended.appendAssumeCapacity(try capture(value, replacement));
    }
};

fn capture(value: *ContentCallState, replacement: driver.Capability) !hosting.references.Replacement {
    if (value.call.capture(replacement)) |edge| return .{ .edge = edge } else |err| {
        if (err != error.NotDurable) return err;
    }
    const references = value.call.references orelse return error.NotDurable;
    return references.captured(replacement);
}

pub const ReferenceEdit = struct { index: usize, replacement: ?hosting.references.Replacement };

/// Internal backing for the opaque callback handle. The managed turn owns this
/// state on its stack, and application code can reach it only through the handle.
pub const ContentCallState = struct {
    call: *hosting.Call,
    view: loam.RecordView,
    replacement: ?[]const u8 = null,
    edits: std.ArrayList(ReferenceEdit) = .empty,
    appended: std.ArrayList(hosting.references.Replacement) = .empty,

    pub fn init(call: *hosting.Call, view: loam.RecordView) ContentCallState {
        call.requireDisclosedReply();
        return .{ .call = call, .view = view };
    }

    pub fn handle(self: *ContentCallState) *ContentCall {
        return @ptrCast(self);
    }

    fn refuseDuplicate(self: *ContentCallState, index: usize) !void {
        for (self.edits.items) |edit| if (edit.index == index) return error.DuplicateReferenceEdit;
    }
};

fn state(call: *ContentCall) *ContentCallState {
    return @ptrCast(@alignCast(call));
}

fn requireStrongEdge(view: loam.RecordView, index: usize) !void {
    if (index >= view.edge_count) return error.NoSuchEdge;
    var edges = view.edges();
    var current: usize = 0;
    while (edges.next()) |edge| : (current += 1) {
        if (current == index) {
            if (edge.strength != .strong) return error.NotDurable;
            return;
        }
    }
    unreachable;
}

pub const RetryMode = enum { read_only, idempotent, receipt };

/// A borrowed application registration. Context pointees and returned borrows
/// remain valid through settlement; the attachment never owns or frees them.
pub const ContentBehavior = struct {
    context: ?*anyopaque = null,
    schema: u64,
    version: u32 = 1,
    /// Pure declaration using committed content and retained arguments. Returned
    /// slices live through invocation. Include every fact relevant to the effect.
    requirement: *const fn (?*anyopaque, std.mem.Allocator, loam.RecordView, []const u8, []const driver.Value) anyerror!core.Policy.Requirement,
    /// Every method declares its retry contract. Receipt-backed methods require
    /// mutate(sequence, method, arguments); reads and idempotent effects may be
    /// called directly. Classification is pure and precedes invocation.
    retry: *const fn (?*anyopaque, []const u8, []const driver.Value) anyerror!RetryMode,
    /// Optional structural effect, decoded before invocation. Shared admission
    /// checks source and placement parents under this method's requirement.
    resource: ?*const fn (?*anyopaque, std.mem.Allocator, core.ResourceId, loam.RecordView, []const u8, []const driver.Value) anyerror!?storage.ResourceChange.Action = null,
    /// Declare the invoking grant's requirement for each forwarded method.
    /// The separately held target checks its own authority when dispatched.
    dependent_requirement: ?*const fn (?*anyopaque, std.mem.Allocator, loam.RecordView, []const u8, []const driver.Value) anyerror!core.Policy.Requirement = null,
    /// Pure declaration of the stored fields and held replacements this method
    /// needs. Preparation runs after current grant admission, before invocation.
    references: ?*const fn (?*anyopaque, std.mem.Allocator, loam.RecordView, []const u8, []const driver.Value) anyerror![]const hosting.references.Request = null,
    /// Called only after current authority admits the declared requirement.
    invoke: *const fn (?*anyopaque, *ContentCall, loam.RecordView, []const u8, []const driver.Value) anyerror!driver.Value,
};

pub const Service = struct {
    context: ?*anyopaque = null,
    capabilities: *storage.Capabilities,
    record_capacity: usize = 8,
    contents: []const ContentBehavior,
    /// Optional application vocabulary for policy edits. This decodes a request;
    /// the bound control's powers and shared rules still decide permission.
    /// Loaded powers supply scope without trusting a caller-provided identity.
    decode_control: *const fn (?*anyopaque, std.mem.Allocator, core.Control.Powers, []const u8, []const driver.Value) anyerror!core.Control.Edit = lifecycle,
    /// Enables derive(sequence, application arguments). Resource identity comes
    /// from the endpoint; shared model rules admit the decoded request.
    decode_derive: ?*const fn (?*anyopaque, std.mem.Allocator, core.ResourceId, []const driver.Value) anyerror!core.GrantLedger.Issue = null,
    decode_managed_derive: ?*const fn (?*anyopaque, std.mem.Allocator, core.ResourceId, []const driver.Value) anyerror!ManagedIssue = null,
    decode_attenuation: ?*const fn (?*anyopaque, std.mem.Allocator, core.Control.Powers, []const driver.Value) anyerror!core.Control.Powers = null,
    /// Embedding entropy boundary: fill fresh unpredictable bytes, including
    /// across restart. Called during preparation; never expose these bytes.
    entropy: ?EntropySource = null,

    pub const EntropySource = struct { context: ?*anyopaque, fill: *const fn (?*anyopaque, *driver.Host.DurableSwiss.Entropy) anyerror!void };

    pub const ManagedIssue = struct { request: core.GrantLedger.Issue, powers: core.Control.Powers };

    /// Service, configuration storage and borrowed contexts stay alive until the
    /// attachment successfully closes (Busy leaves pending work alive). Contents
    /// and entropy may be replaced for future preparations; other configuration stays stable
    /// while calls are pending. Outer Attachment behaviors remain immutable.
    /// Operation allocations use Capabilities' allocator and quotas.
    pub const behavior_count = 4;
    pub fn behaviors(self: *Service) [behavior_count]hosting.Behavior {
        return .{
            .{ .schema = records.profile.endpoint, .version = records.EndpointRecord.version, .context = self, .prepare = working.prepare, .invoke = working.invoke },
            @import("observation.zig").behavior(self),
            @import("maintenance.zig").behavior(self),
            @import("maintenance.zig").terminalBehavior(),
        };
    }

    pub fn contentBehavior(self: *Service, view: loam.RecordView) !ContentBehavior {
        var found: ?ContentBehavior = null;
        for (self.contents) |item| if (item.schema == view.schema and item.version == view.schema_version) {
            if (found != null) return error.DuplicateBehavior;
            found = item;
        };
        return found orelse error.UnknownBehavior;
    }
};

fn lifecycle(_: ?*anyopaque, _: std.mem.Allocator, _: core.Control.Powers, verb: []const u8, args: []const driver.Value) !core.Control.Edit {
    if (args.len != 0) return error.InvalidArguments;
    if (std.mem.eql(u8, verb, "pause")) return .pause;
    if (std.mem.eql(u8, verb, "resume")) return .resume_access;
    if (std.mem.eql(u8, verb, "revoke")) return .revoke;
    return error.NoSuchMethod;
}

/// Privileged binding of content to its managed resource, within an open Store
/// batch. The embedding owns this correspondence. The endpoint becomes callable
/// only after commit and restoration through the ordinary hosting attachment.
pub fn stageEndpoint(read: *storage.Read, allocator: std.mem.Allocator, endpoint: records.EndpointRecord, rooted: bool) !loam.ObjectId {
    return storage.stage.endpoint(read, allocator, endpoint, rooted);
}

pub fn stageDerivedEndpoint(operation: *storage.Operation, allocator: std.mem.Allocator, endpoint: records.EndpointRecord, rooted: bool) !loam.ObjectId {
    return storage.stage.endpointFromOperation(operation, allocator, endpoint, rooted);
}

/// Give a committed managed endpoint its one durable name in the current
/// transaction. The endpoint retains the recipe so owner cleanup can fence it.
/// Preparation loads the endpoint before opening the batch; no I/O occurs here.
pub fn stagePublication(store: *loam.Store, lease: loam.Lease, entropy: hosting.publication.Entropy) !loam.ObjectId {
    if (store.phase != .staging) return error.WrongPhase;
    const committed = try store.currentView(lease);
    const proposal = try store.proposed(committed.id);
    const view = if (proposal) |row| row.view else committed;
    var endpoint = try records.EndpointRecord.decode(view);
    if (endpoint.publication != null) return error.AlreadyPublished;
    errdefer if (store.phase == .staging) store.abort() catch unreachable;
    const publication = try hosting.publication.stageTarget(store, entropy, view.id);
    endpoint.publication = publication;
    try putEndpoint(store, store.allocator, view.id, endpoint, view.rooted, if (proposal) |row| row.expected else committed.revision);
    return publication;
}

pub fn putEndpoint(store: *loam.Store, allocator: std.mem.Allocator, id: loam.ObjectId, endpoint: records.EndpointRecord, rooted: bool, expected: ?u64) !void {
    // Fresh endpoints belong to the registration factory. This seam only
    // updates a committed endpoint and cannot bypass weak owner membership.
    if (expected == null) return error.InvalidRecord;
    const proposal = try store.proposed(id);
    const lease = if (proposal == null) try store.resident(id) else null;
    defer if (lease) |held| store.release(held) catch unreachable;
    const prior = if (proposal) |row| row.view else try store.currentView(lease.?);
    if (prior.schema == records.profile.terminal) return error.CapabilityRetired;
    _ = try records.EndpointRecord.decode(prior);
    const payload = try endpoint.encodeAlloc(allocator);
    defer allocator.free(payload);
    var edges: [records.EndpointRecord.max_edges]loam.Edge = undefined;
    try store.putCopying(.{ .id = id, .revision = 0, .schema = records.profile.endpoint, .schema_version = records.EndpointRecord.version, .rooted = rooted, .payload = payload, .edges = endpoint.edges(&edges) }, expected);
}
