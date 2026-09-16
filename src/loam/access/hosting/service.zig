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
        return .{ .capability = try value.call.storedEdge(value.view, index) };
    }

    /// Declare a returned facet whose every call must pass both the current
    /// invoking-grant authority and the exact authority stored in strong edge
    /// `index`. Unlike `discloseExact`, this never exposes the saved target.
    pub fn discloseDependent(self: *ContentCall, index: usize) !driver.Value {
        const value = state(self);
        const target = try value.call.storedEdge(value.view, index);
        return .{ .capability = try value.call.projectDependent(target) };
    }

    /// Replace one declared strong reference field in the same transaction as
    /// this method's payload change. `replacement` must be a durable local
    /// capability owned by this attachment; it is retained through outcome.
    pub fn replaceReference(self: *ContentCall, index: usize, replacement: driver.Capability) !void {
        const value = state(self);
        try requireStrongEdge(value.view, index);
        try value.edits.ensureUnusedCapacity(value.call.arena, 1);
        try value.refuseDuplicate(index);
        value.edits.appendAssumeCapacity(.{ .index = index, .replacement = try value.call.capture(replacement) });
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
};

pub const ReferenceEdit = struct { index: usize, replacement: ?loam.Edge };

/// Internal backing for the opaque callback handle. The managed turn owns this
/// state on its stack, and application code can reach it only through the handle.
pub const ContentCallState = struct {
    call: *hosting.Call,
    view: loam.RecordView,
    replacement: ?[]const u8 = null,
    edits: std.ArrayList(ReferenceEdit) = .empty,

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

pub const ContentBehavior = struct {
    schema: u64,
    version: u32 = 1,
    /// Pure declaration using committed content and retained arguments. Returned
    /// slices live through invocation. Include every fact relevant to the effect.
    requirement: *const fn (std.mem.Allocator, loam.RecordView, []const u8, []const driver.Value) anyerror!core.Policy.Requirement,
    /// Called only after current authority admits the declared requirement.
    invoke: *const fn (*ContentCall, loam.RecordView, []const u8, []const driver.Value) anyerror!driver.Value,
};

pub const Service = struct {
    capabilities: *storage.Capabilities,
    record_capacity: usize = 8,
    contents: []const ContentBehavior,
    /// Optional application vocabulary for policy edits. This decodes a request;
    /// the bound control's powers and shared rules still decide permission.
    decode_control: *const fn (std.mem.Allocator, []const u8, []const driver.Value) anyerror!core.Control.Edit = lifecycle,
    /// Enables derive(sequence, application arguments). Resource identity comes
    /// from the endpoint; shared model rules admit the decoded request.
    decode_derive: ?*const fn (std.mem.Allocator, core.ResourceId, []const driver.Value) anyerror!core.GrantLedger.Issue = null,
    /// Embedding entropy boundary: fill fresh unpredictable bytes, including
    /// across restart. Called during preparation; never expose these bytes.
    entropy: ?struct { context: ?*anyopaque, fill: *const fn (?*anyopaque, *driver.Host.DurableSwiss.Entropy) anyerror!void } = null,

    /// Service and its borrowed configuration stay stable until the attachment
    /// closes. Operation allocations use Capabilities' allocator and quotas.
    pub fn behavior(self: *Service) hosting.Behavior {
        return .{ .schema = records.profile.endpoint, .version = records.EndpointRecord.version, .context = self, .prepare = working.prepare, .invoke = working.invoke };
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

fn lifecycle(_: std.mem.Allocator, verb: []const u8, args: []const driver.Value) !core.Control.Edit {
    if (args.len != 0) return error.InvalidArguments;
    if (std.mem.eql(u8, verb, "pause")) return .pause;
    if (std.mem.eql(u8, verb, "resume")) return .resume_access;
    if (std.mem.eql(u8, verb, "revoke")) return .revoke;
    return error.NoSuchMethod;
}

/// Privileged binding of content to its managed resource, within an open Store
/// batch. The embedding owns this correspondence. The endpoint becomes callable
/// only after commit and restoration through the ordinary hosting attachment.
pub fn stageEndpoint(store: *loam.Store, allocator: std.mem.Allocator, endpoint: records.EndpointRecord, rooted: bool) !loam.ObjectId {
    const id = try store.allocateId();
    try putEndpoint(store, allocator, id, endpoint, rooted, null);
    return id;
}

pub fn putEndpoint(store: *loam.Store, allocator: std.mem.Allocator, id: loam.ObjectId, endpoint: records.EndpointRecord, rooted: bool, expected: ?u64) !void {
    const payload = try endpoint.encodeAlloc(allocator);
    defer allocator.free(payload);
    var edges: [records.EndpointRecord.max_edges]loam.Edge = undefined;
    try store.putCopying(.{ .id = id, .revision = 0, .schema = records.profile.endpoint, .schema_version = records.EndpointRecord.version, .rooted = rooted, .payload = payload, .edges = endpoint.edges(&edges) }, expected);
}
