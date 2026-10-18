//! Trusted application method declarations around opaque managed operations.
const std = @import("std");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const storage = @import("loam_access_storage");
const loam = @import("loam_core");
const hosting = @import("loam_hosting");
const driver = @import("driver_core");
const working = @import("working.zig");
pub const graph = @import("content_graph.zig");
const commit = @import("commit.zig");
const observation = @import("observation.zig");
const maintenance = @import("maintenance.zig");
const vocabulary = @import("vocabulary.zig");

comptime {
    // The receipt codec and the Host's value walk admit one nesting.
    std.debug.assert(records.ValueRecord.max_depth == driver.Value.max_depth);
}

pub const ContentCall = opaque {
    /// A failed application invocation may carry a bounded UTF-8 explanation.
    /// This stages no mutation and grants no retry authority.
    pub fn refuseCopying(self: *ContentCall, reason: []const u8) !void {
        try state(self).call.refuseCopying(reason);
    }

    /// Copy accounting names from the admitted source grant chain.
    pub fn accountingPath(self: *ContentCall, buffer: []loam.ObjectId) ![]const loam.ObjectId {
        return (state(self).operation orelse return error.WrongPhase).accountingPath(buffer);
    }
    /// Own one occurrence of exact prepared reference custody beyond callback
    /// return. Preparation validates its recipe. This grants no disclosure.
    /// The Host retain adds no buffer or parallel inventory. Caller releases it.
    pub fn retainPreparedReference(self: *ContentCall, target: driver.Capability) !driver.Capability {
        const value = state(self);
        const references = value.call.references orelse return error.ReferenceUnprepared;
        _ = try references.captured(target);
        _ = try value.call.attachment.host.projectOwnedValue(.{ .capability = target }, {}, struct {
            fn keep(_: void, _: driver.Value) !void {}
        }.keep);
        return target;
    }
    /// Own one occurrence of the actual invoking endpoint. Receipt recovery
    /// compares held authority, never descriptive resource or policy metadata.
    /// The caller releases this retain. Obtaining it declares no disclosure.
    pub fn retainSource(self: *ContentCall) !driver.Capability {
        const value = state(self);
        const owner = value.call.attachment;
        const entry = owner.liveEntry(value.call.view.id) orelse return error.NotDurable;
        return owner.host.retainLocalCapability(entry.actor.?);
    }
    /// Reserve independent effect custody before replacing content with its
    /// receipt. The source is the actual invoking endpoint. An idempotent
    /// application may own its receipt. Activation still requires confirmed
    /// mutation. Read-only calls cannot reserve external effects.
    pub fn reserveContinuationCopying(self: *ContentCall, targets: []const driver.Capability, activation: hosting.Continuation.Activation) !*hosting.ContinuationReservation {
        const value = state(self);
        if (!value.receipt and value.retry != .idempotent) return error.RetryRequired;
        return hosting.Continuation.reserveCopying(value.call, value.intent, targets, activation);
    }
    /// The retained call arena. Reply values and replacement payloads borrow it.
    pub fn allocator(self: *ContentCall) std.mem.Allocator {
        return state(self).call.arena();
    }

    /// Replaces the bound content payload, preserving its committed edges.
    /// Bytes must survive callback return. Allocate them from `allocator()`.
    pub fn replace(self: *ContentCall, payload: []const u8) void {
        state(self).replacement = payload;
    }

    /// The content of declared participant `index`, with the same payload and
    /// field edits as the bound content. Its changes commit in this call's
    /// batch. Disclosure through it still applies the invoking grant.
    pub fn participant(self: *ContentCall, index: usize) !*ContentCall {
        const value = state(self);
        if (index >= value.participants.len) return error.NoSuchParticipant;
        return value.participants[index].handle();
    }

    /// The first payload of the child this method declared with
    /// `ContentBehavior.create`. Its field naming the child's endpoint is
    /// appended to the bound content. Bytes must survive callback return.
    /// The method returns `.void`, and the call replies with the child as a
    /// facet of the invoking endpoint, as `discloseDependent` would.
    pub fn createChild(self: *ContentCall, payload: []const u8) !void {
        const value = state(self);
        if (!value.creates) return error.NoDeclaredChild;
        if (value.child_payload == null) try reserveEdge(value);
        value.child_payload = payload;
    }

    /// Borrow exact prepared field custody for an edit or internal act. This
    /// grants no disclosure. The retained call owns it through settlement.
    pub fn reference(self: *ContentCall, index: usize) !driver.Capability {
        const value = state(self);
        if (value.graph != null) return error.NotReferenceField;
        return value.call.storedEdge(value.view, index);
    }

    /// Declare that this method's reply hands over a stored reference field's
    /// exact saved authority: the strong edge `index` of the bound content
    /// record. Returns the capability value for the reply. The reply may carry
    /// it, nested or direct. Any capability this method did not declare is
    /// refused before settlement (ADR-0172).
    pub fn discloseExact(self: *ContentCall, index: usize) !driver.Value {
        const value = state(self);
        return .{ .capability = try value.call.discloseHeld(try self.reference(index)) };
    }

    /// Borrow the stable facet made by an explicit live dependent declaration.
    /// Its reservation owns custody. This does not authorize public disclosure.
    pub fn preparedLiveDependent(self: *ContentCall, source: driver.Capability, target: driver.Capability) !driver.Capability {
        const value = state(self);
        const references = value.call.references orelse return error.ReferenceUnprepared;
        return references.preparedDependent(source, target);
    }

    /// Verify the actual guarded pair of a committed live facet on retry.
    pub fn matchesLiveDependent(self: *ContentCall, facet: driver.Capability, source: driver.Capability, target: driver.Capability) !bool {
        const scope = state(self).call.attachment.options.live_scope orelse return error.LiveScopeRequired;
        return scope.matchesDependent(facet, source, target);
    }

    /// Borrow exporter metadata from this attachment's committed live custody.
    /// No target capability is returned and no new retain or facade is made.
    pub fn liveDependentExporter(self: *ContentCall, facet: driver.Capability) !?*driver.HostSession {
        const scope = state(self).call.attachment.options.live_scope orelse return error.LiveScopeRequired;
        return scope.dependentExporter(facet);
    }

    /// Declare a returned facet whose every call must pass both the current
    /// invoking-grant authority and the exact authority stored in strong edge
    /// `index`. Unlike `discloseExact`, this never exposes the saved target.
    pub fn discloseDependent(self: *ContentCall, index: usize) !driver.Value {
        const value = state(self);
        const target = try self.reference(index);
        return .{ .capability = try value.call.discloseHeld(try value.call.projectDependent(target)) };
    }

    /// Declare a read facade over actual held authority. The original admitted
    /// intent governs every later invocation and every recursive result. Trusted
    /// content supplies only read interfaces. Effect dispatch uses receipts.
    pub fn discloseReadsCopying(self: *ContentCall, target: driver.Capability, interfaces: []const hosting.ReadScope.Interface, role: usize) !driver.Value {
        const value = state(self);
        if (value.receipt or value.retry != .read_only) return error.ReadOnlyRequired;
        try value.call.held.ensureUnusedCapacity(value.call.arena(), 1);
        const scope = try hosting.ReadScope.createCopying(value.call, value.intent, interfaces);
        defer scope.release();
        const front = try scope.project(target, role);
        value.call.adoptRetain(front);
        return .{ .capability = try value.call.discloseHeld(front) };
    }

    /// Replace one declared strong reference field in the same transaction as
    /// this method's payload change. Local targets are captured directly. Other
    /// targets require a declared, prepared save. Custody survives the outcome.
    pub fn replaceReference(self: *ContentCall, index: usize, replacement: driver.Capability) !void {
        const value = state(self);
        if (value.graph != null) return error.NotReferenceField;
        try requireStrongEdge(value.view, index);
        try value.edits.ensureUnusedCapacity(value.call.arena(), 1);
        try value.refuseDuplicate(index);
        const captured = try capture(value, replacement);
        value.edits.appendAssumeCapacity(.{ .index = index, .replacement = captured });
    }

    /// Replace from an independently completed save operation. Copying binds
    /// its verified recipe and capability custody to this retained call.
    pub fn replaceSavedReference(self: *ContentCall, index: usize, saved: *hosting.references.Save) !void {
        const value = state(self);
        if (value.graph != null) return error.NotReferenceField;
        try requireStrongEdge(value.view, index);
        try value.refuseDuplicate(index);
        const replacement = try hosting.references.copySaved(value.call, saved);
        try value.edits.append(value.call.arena(), .{ .index = index, .replacement = replacement });
    }

    /// Remove one declared strong reference field transactionally. Edit
    /// indices address the committed edge list, so multiple edits do not shift
    /// one another while the callback is running.
    pub fn removeReference(self: *ContentCall, index: usize) !void {
        const value = state(self);
        if (value.graph != null) return error.NotReferenceField;
        try requireStrongEdge(value.view, index);
        try value.edits.ensureUnusedCapacity(value.call.arena(), 1);
        try value.refuseDuplicate(index);
        value.edits.appendAssumeCapacity(.{ .index = index, .replacement = null });
    }

    /// Append a held field after the surviving committed fields. Preparation
    /// verifies foreign recipes before invocation. Payload and fields commit
    /// together. Existing edit indices continue to name the committed list.
    /// The replacement spine uses the retained call arena and cannot exceed
    /// the schema's remaining edge capacity. No separate heap owner is created.
    pub fn appendReference(self: *ContentCall, replacement: driver.Capability) !void {
        const value = state(self);
        if (value.graph != null) return error.NotReferenceField;
        try reserveEdge(value);
        try value.appended.ensureUnusedCapacity(value.call.arena(), 1);
        value.appended.appendAssumeCapacity(try capture(value, replacement));
    }

    /// Borrow the exact held authority of a prepared page field. The reserved
    /// binding is excluded: index zero names the page's first capability field.
    /// Custody belongs to the retained call and does not authorize disclosure.
    pub fn pageReference(self: *ContentCall, page: *const graph.PageHandle, index: usize) !driver.Capability {
        const value = state(self);
        const prepared = value.graph orelse return error.NotContentGraph;
        return value.call.storedEdge(try prepared.snapshot.page(page), try std.math.add(usize, index, 1));
    }

    pub fn disclosePage(self: *ContentCall, page: *const graph.PageHandle, index: usize, dependent: bool) !driver.Value {
        const value = state(self);
        const held = try self.pageReference(page, index);
        return .{ .capability = try value.call.discloseHeld(if (dependent) try value.call.projectDependent(held) else held) };
    }

    /// Explicit restoration or inspection may retain its canonical foreign recipe URI.
    /// The bytes borrow this Call. Local and live recipes return null, never a guessed
    /// locator. Obtaining metadata grants no capability disclosure.
    pub fn pageSavedUri(self: *ContentCall, page: *const graph.PageHandle, index: usize) !?[]const u8 {
        const value = state(self);
        const prepared = value.graph orelse return error.NotContentGraph;
        const refs = value.call.references orelse return error.ReferenceUnprepared;
        return refs.restoredUri(try prepared.snapshot.page(page), try std.math.add(usize, index, 1));
    }

    /// Stage a complete resource-owned graph. Root/page payloads borrow the
    /// retained arena through settlement. The page and field spines are copied
    /// there. Held fields are captured by the same saved-reference machinery
    /// as ordinary content edits. Retained page tokens preserve unchanged rows.
    pub fn replaceGraph(self: *ContentCall, payload: []const u8, pages: []const GraphPage) !void {
        const value = state(self);
        const prepared = value.graph orelse return error.NotContentGraph;
        if (value.graph_replaced) return error.DuplicateGraphReplacement;
        if (!try prepared.validateCandidate(payload, pages)) {
            value.graph_replaced = true;
            return;
        }
        try validateFields(prepared, pages);
        const candidates = try value.call.arena().alloc(graph.Replacement, pages.len);
        for (pages, candidates) |input, *candidate| candidate.* = switch (input) {
            .keep => |page| .{ .keep = page },
            .update => |update| .{ .update = .{ .page = update.page, .payload = update.payload } },
            .write => |write| fresh: {
                const fields = try value.call.arena().alloc(hosting.references.Replacement, write.fields.len);
                for (write.fields, fields) |field, *target| target.* = switch (field) {
                    .held => |held| try capture(value, held),
                    .retained => |retained| .{ .edge = try prepared.snapshot.field(retained.page, retained.index) },
                };
                break :fresh .{ .write = .{ .schema = write.schema, .payload = write.payload, .fields = fields } };
            },
        };
        const delta = try prepared.replacement(payload, candidates);
        value.graph_delta = delta;
        value.graph_replaced = true;
    }

    pub fn graphLimits(self: *ContentCall) ?graph.Spec {
        return if (state(self).graph) |prepared| prepared.spec else null;
    }

    pub fn validateGraph(self: *ContentCall, payload: []const u8, pages: []const GraphPage) !void {
        const prepared = state(self).graph orelse return error.NotContentGraph;
        _ = try prepared.validateCandidate(payload, pages);
        try validateFields(prepared, pages);
    }
};

fn validateFields(prepared: *graph.Prepared, pages: []const GraphPage) !void {
    for (pages) |page| if (page == .write) {
        for (page.write.fields) |field| if (field == .retained) {
            _ = try prepared.snapshot.field(field.retained.page, field.retained.index);
        };
    };
}

pub const GraphPage = union(enum) {
    keep: *const graph.PageHandle,
    update: struct { page: *const graph.PageHandle, payload: []const u8 },
    write: struct { schema: graph.Schema, payload: []const u8, fields: []const GraphField },
};

/// Retaining a prepared field copies its exact committed recipe edge, without
/// restoring or invoking its target. The token borrows this call's current
/// graph. It cannot select a binding, an arbitrary object or another graph.
pub const GraphField = union(enum) {
    held: driver.Capability,
    retained: struct { page: *const graph.PageHandle, index: usize },
};

/// Add the shared candidate/field copies made by ContentCall.replaceGraph.
/// Foreign candidates and payload ownership are added at the embedding seam.
pub fn graphAllocationBound(pages: usize, payload_bytes: usize, fields: usize) !hosting.references.AllocationBound {
    var bound = try graph.allocationBound(pages, payload_bytes, fields);
    try bound.include(try std.math.mul(usize, pages, @sizeOf(graph.Replacement)), @alignOf(graph.Replacement), 1);
    try bound.includeTotal(try std.math.mul(usize, fields, @sizeOf(hosting.references.Replacement)), @alignOf(hosting.references.Replacement), pages);
    return bound;
}

fn capture(value: *ContentCallState, replacement: driver.Capability) !hosting.references.Replacement {
    if (value.call.references) |references| {
        if (references.captured(replacement)) |captured| return captured else |err| {
            if (err != error.ReferenceUnprepared) return err;
        }
    }
    return .{ .edge = try value.call.capture(replacement) };
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
    graph: ?*graph.Prepared = null,
    graph_delta: ?graph.Delta = null,
    graph_replaced: bool = false,
    intent: hosting.Call.Intent,
    receipt: bool,
    retry: RetryMode,
    operation: ?*storage.Operation = null,
    participants: []ContentCallState = &.{},
    creates: bool = false,
    child_payload: ?[]const u8 = null,

    pub fn init(call: *hosting.Call, view: loam.RecordView, intent: hosting.Call.Intent, receipt: bool, retry: RetryMode) ContentCallState {
        call.requireDisclosedReply();
        return .{ .call = call, .view = view, .intent = intent, .receipt = receipt, .retry = retry };
    }

    /// A participant's content in a call whose reply policy the bound content
    /// already set. It offers no participants or child of its own.
    pub fn initParticipant(bound: *const ContentCallState, view: loam.RecordView) ContentCallState {
        return .{ .call = bound.call, .view = view, .intent = bound.intent, .receipt = bound.receipt, .retry = bound.retry, .operation = bound.operation };
    }

    /// Whether the callback proposed any write to this content.
    pub fn writes(self: *const ContentCallState) bool {
        return self.replacement != null or self.edits.items.len != 0 or self.appended.items.len != 0 or self.graph_replaced;
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

/// Refuse a field append, including a created child's field, that would
/// exceed the bound content's schema edge limit.
fn reserveEdge(value: *const ContentCallState) !void {
    const schema = try graph.registered(value.call.attachment.store, .{ .id = value.view.schema, .version = value.view.schema_version });
    var removed: usize = 0;
    for (value.edits.items) |edit| if (edit.replacement == null) {
        removed += 1;
    };
    const child: usize = @intFromBool(value.child_payload != null);
    if (value.view.edge_count - removed + value.appended.items.len + child >= schema.max_edges) return error.TooManyEdges;
}

fn requireStrongEdge(view: loam.RecordView, index: usize) !void {
    if ((try view.edgeAt(index)).strength != .strong) return error.NotDurable;
}

pub const RetryMode = enum { read_only, idempotent, receipt };

/// Synchronous callback input from the selected endpoint and current resource
/// row. Local dependent calls bind their selected target. Forwarding binds only
/// the mediating source, never facts about the separately held dispatch target.
/// Metadata can be copied as data. It supplies no admission after the callback.
pub const ContentInvocation = struct {
    bound_resource: storage.Operation.BoundResource,
    delivery: enum { local, forwarding },
    content: loam.RecordView,
    /// Present after complete page preparation. Declared requirements receive
    /// pages for Graph.Spec.requirement_verbs. Other requirements read root data.
    /// References and invocation receive the complete admitted graph.
    graph: ?graph.Snapshot = null,
    /// Declared participants in order, present to the resource and create
    /// declarations and to invocation. Empty for requirement and participant
    /// declaration.
    participants: []const ParticipantView = &.{},
    verb: []const u8,
    args: []const driver.Value,
};

/// Borrowed work metadata for application admission before forwarding.
pub const ForwardWork = struct {
    selector: []const u8,
    method: []const u8,
    material_bytes: usize,

    /// Count borrowed payload leaves without constructing another invocation.
    /// The owning value boundary limits nesting. This walk keeps that bound.
    pub fn measure(selector: []const u8, intent: hosting.Call.Intent) !ForwardWork {
        return .{ .selector = selector, .method = intent.verb, .material_bytes = try bytes(intent.args, 0) };
    }
    fn bytes(args: []const driver.Value, depth: usize) !usize {
        if (depth > driver.Value.max_depth) return error.ValueTooDeep;
        var total: usize = 0;
        for (args) |arg| {
            const size = switch (arg) {
                .string, .bytes => |leaf| leaf.len,
                .list, .set => |items| try bytes(items, depth + 1),
                .tagged => |tag| try bytes(tag.value, depth + 1),
                .@"struct" => |items| blk: {
                    var sum: usize = 0;
                    for (items) |item| sum = try std.math.add(usize, sum, try bytes(&.{item.value}, depth + 1));
                    break :blk sum;
                },
                else => 0,
            };
            total = try std.math.add(usize, total, size);
        }
        return total;
    }
};

/// A borrowed application registration. Context pointees and returned borrows
/// remain valid through settlement. The attachment never owns or frees them.
/// The application registration's callbacks. Implementors are unknown at
/// this declaration, so every verb keeps an `anyerror` return set.
pub const ContentBehavior = struct {
    context: ?*anyopaque = null,
    schema: u64,
    version: u32 = 1,
    graph: ?graph.Spec = null,
    /// Pure declaration using committed content and retained arguments. Returned
    /// slices live through invocation. Include every fact relevant to the effect.
    requirement: *const fn (?*anyopaque, std.mem.Allocator, ContentInvocation) anyerror!core.Policy.Requirement,
    /// Every method declares its retry contract. Receipt-backed methods require
    /// mutate(sequence, method, arguments). Reads and idempotent effects may be
    /// called directly. Classification is pure and precedes invocation.
    retry: *const fn (?*anyopaque, []const u8, []const driver.Value) anyerror!RetryMode,
    /// Optional structural effect, decoded before invocation with participants
    /// loaded. Shared admission checks source and placement parents under this
    /// method's requirement through every grant the call carries.
    resource: ?*const fn (?*anyopaque, std.mem.Allocator, ContentInvocation) anyerror!?ResourceEffect = null,
    /// Optional child of the bound resource, decoded before invocation. The
    /// method must be receipt-backed, supplies the child's first payload with
    /// `ContentCall.createChild`, and cannot also declare a structural effect.
    create: ?*const fn (?*anyopaque, std.mem.Allocator, ContentInvocation) anyerror!?Creation = null,
    /// Pure declaration of up to `max_participants` more resources of the same
    /// owner this method reads or changes. Each is admitted by every grant the
    /// call carries under its own requirement, before invocation.
    participants: ?*const fn (?*anyopaque, std.mem.Allocator, ContentInvocation) anyerror![]const Participant = null,
    /// Declare the invoking grant's requirement for each forwarded method.
    /// The separately held target checks its own authority when dispatched.
    dependent_requirement: ?*const fn (?*anyopaque, std.mem.Allocator, ContentInvocation) anyerror!core.Policy.Requirement = null,
    /// Pure declaration of the stored fields and held replacements this method
    /// needs. Preparation runs after current grant admission, before invocation.
    references: ?*const fn (?*anyopaque, std.mem.Allocator, ContentInvocation) anyerror![]const hosting.references.Request = null,
    /// Forwarding bypasses invoke. This optional hook admits application work
    /// against the already validated source before dispatching the held target.
    /// It stages no content or reply. Ordinary local invokes own their admission.
    admit_forward: ?*const fn (?*anyopaque, *ContentCall, ForwardWork) anyerror!void = null,
    /// Called only after current authority admits the declared requirement.
    /// Reply bytes and spines remain valid and unchanged through settlement,
    /// recovery and confirmation. Allocate them in the supplied call arena or
    /// borrow retained inputs. Copy mutable callback-context data before return.
    invoke: *const fn (?*anyopaque, *ContentCall, ContentInvocation) anyerror!driver.Value,
};

/// The most extra resources one hosted call can touch beside its bound one.
pub const max_participants = 2;

/// A further resource of the bound owner. A field names a strong field of the
/// bound content. An argument names a capability argument that designates a
/// same-owner endpoint or dependent facet on this attachment. Designation
/// admits nothing: the requirement does, through every grant of the call.
pub const Participant = struct {
    source: union(enum) { field: usize, argument: usize },
    requirement: core.Policy.Requirement,
};

/// One loaded participant: canonical resource metadata and its content row.
pub const ParticipantView = struct {
    resource: storage.Operation.BoundResource,
    content: loam.RecordView,
    /// The bound content's strong field that names this participant: the
    /// declared field for a field participant, and otherwise the first field
    /// storing its endpoint, or null when none does. A capability a field
    /// disclosed designates that field's endpoint, so a caller can name a
    /// listed node by the capability it holds instead of by a position that
    /// may shift.
    field: ?usize,
};

/// A structural change of the bound resource or of one participant.
pub const ResourceEffect = struct {
    target: union(enum) { bound, participant: usize } = .bound,
    action: storage.ResourceChange.Action,
};

/// The child a creating method adds under its bound resource.
pub const Creation = struct { kind: core.KindId, schema: u64, version: u32 = 1 };

pub const Service = struct {
    context: ?*anyopaque = null,
    capabilities: *storage.Capabilities,
    record_capacity: usize = 8,
    contents: []const ContentBehavior,
    /// Optional application vocabulary for policy edits. This decodes a request.
    /// The bound control's powers and shared rules still decide permission.
    /// Loaded powers supply scope without trusting a caller-provided identity.
    decode_control: *const fn (?*anyopaque, std.mem.Allocator, core.Control.Powers, []const u8, []const driver.Value) anyerror!core.Control.Edit = lifecycle,
    decode_control_revision: ?*const fn ([]const u8, []const driver.Value) anyerror!core.Revision = null,
    /// Enables derive(sequence, application arguments). Resource identity comes
    /// from the endpoint. Shared model rules admit the decoded request.
    decode_derive: ?*const fn (?*anyopaque, std.mem.Allocator, core.ResourceId, []const driver.Value) anyerror!core.GrantLedger.Issue = null,
    decode_managed_derive: ?*const fn (?*anyopaque, std.mem.Allocator, core.ResourceId, []const driver.Value) anyerror!ManagedIssue = null,
    decode_attenuation: ?*const fn (?*anyopaque, std.mem.Allocator, core.Control.Powers, []const driver.Value) anyerror!core.Control.Powers = null,
    /// The use descriptor an owner's created children are stored under, so a
    /// stored child never depends on who created it. Readers still reach it
    /// through a dependent facet that applies their own grant.
    child_descriptor: ?*const fn (?*anyopaque, core.OwnerId) ?loam.ObjectId = null,
    /// Embedding entropy boundary: fill fresh unpredictable bytes, including
    /// across restart. Called during preparation. Never expose these bytes.
    entropy: ?EntropySource = null,

    pub const EntropySource = struct {
        /// Implementors are unknown at this declaration, so `fill` keeps an
        /// `anyerror` return set.
        context: ?*anyopaque,
        fill: *const fn (?*anyopaque, *driver.Host.DurableSwiss.Entropy) anyerror!void,

        /// Fresh bytes from the embedding.
        pub fn draw(self: EntropySource) !driver.Host.DurableSwiss.Entropy {
            var bytes: driver.Host.DurableSwiss.Entropy = undefined;
            try self.fill(self.context, &bytes);
            return bytes;
        }
    };

    pub const ManagedIssue = struct { request: core.GrantLedger.Issue, powers: core.Control.Powers };

    /// Service, configuration storage and borrowed contexts stay alive until the
    /// attachment successfully closes (Busy leaves pending work alive). Contents
    /// and entropy may be replaced for future preparations. Other configuration stays stable
    /// while calls are pending. Outer Attachment behaviors remain immutable.
    /// Operation allocations use Capabilities' allocator and quotas.
    pub const behavior_count = 4;
    pub fn behaviors(self: *Service) [behavior_count]hosting.Behavior {
        return .{
            .{ .schema = records.profile.endpoint, .version = records.EndpointRecord.format_version, .context = self, .prepare = working.prepare, .invoke = commit.invoke },
            observation.behavior(self),
            maintenance.behavior(self),
            maintenance.terminalBehavior(),
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
    return vocabulary.lifecycle(verb, args);
}

/// Privileged binding of content to its managed resource, within an open Store
/// batch. The embedding owns this correspondence. The endpoint becomes callable
/// only after commit and restoration through the ordinary hosting attachment.
pub fn stageEndpoint(read: *storage.Read, allocator: std.mem.Allocator, endpoint: records.EndpointRecord, rooting: storage.Rooting) !loam.ObjectId {
    return storage.stage.endpoint(read, allocator, endpoint, rooting);
}

pub fn stageDerivedEndpoint(operation: *storage.Operation, allocator: std.mem.Allocator, endpoint: records.EndpointRecord, rooting: storage.Rooting) !loam.ObjectId {
    return storage.stage.endpointFromOperation(operation, allocator, endpoint, rooting);
}

/// Give a committed managed endpoint its one durable name in the current
/// transaction. The endpoint retains the recipe so owner cleanup can fence it.
/// Preparation loads the endpoint before opening the batch. No I/O occurs here.
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
    try putEndpoint(store, store.allocator, view.id, endpoint, storage.Rooting.ofStored(view.rooted), if (proposal) |row| row.expected else committed.revision);
    return publication;
}

pub fn putEndpoint(store: *loam.Store, allocator: std.mem.Allocator, id: loam.ObjectId, endpoint: records.EndpointRecord, rooting: storage.Rooting, expected: ?u64) !void {
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
    try store.putCopying(.{ .id = id, .revision = 0, .schema = records.profile.endpoint, .schema_version = records.EndpointRecord.format_version, .rooted = rooting == .rooted, .payload = payload, .edges = endpoint.edges(&edges) }, expected);
}
