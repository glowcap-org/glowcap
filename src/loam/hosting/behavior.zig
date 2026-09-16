//! Immutable actor portraits and effect-restricted durable turns.
const std = @import("std");
const core = @import("loam_core");
const driver = @import("driver_core");
const hosting = @import("attachment.zig");
pub const Preparation = @import("preparation.zig").Preparation;

/// The schema/version selects both structural limits and behavior. Invocation
/// is deterministic for the supplied inputs: no I/O or external effects. State
/// replacement, transaction staging, and held local references are explicit.
pub const Behavior = struct {
    schema: u64,
    version: u32 = 1,
    context: ?*anyopaque = null,
    /// Borrowed configuration; preparation state belongs to the retained call.
    prepare: ?*const fn (*Call, []const u8, []const driver.Value) anyerror!Preparation = null,
    invoke: *const fn (*Call, core.RecordView, []const u8, []const driver.Value) anyerror!driver.Value,
};

pub const Call = struct {
    arena: std.mem.Allocator,
    attachment: *hosting.Attachment,
    view: core.RecordView,
    context: ?*anyopaque = null,
    preparation: ?Preparation = null,
    transaction: ?Transaction = null,
    /// Materialize at the top-level Host boundary after staging, before write
    /// submission. Reserve custody here; expose no externally usable authority.
    result: ?*const fn (*Call) anyerror!driver.Value = null,
    /// Infallible activation after confirmed commit, before reply projection.
    /// Runs once even if settlement needs retry. Read-only results activate at
    /// settlement. Preparation.deinit must cancel any unconfirmed reservation.
    confirmation: ?struct { context: *anyopaque, apply: *const fn (*anyopaque) void } = null,
    replacement: ?[]const u8 = null,
    /// A dependent projection enters through `view`'s endpoint authority but
    /// invokes the content behind this separately held durable capability.
    /// The operation owns the retain; the call only borrows it.
    dependent_target: ?driver.Capability = null,
    held: std.ArrayList(driver.Capability) = .empty,
    disclosed_from: usize = unrestricted_reply,
    const unrestricted_reply = std.math.maxInt(usize);
    pub const Transaction = struct {
        context: *anyopaque,
        /// Stage only into the attachment's open batch; never begin or commit.
        stage: *const fn (*anyopaque, *core.Store) anyerror!void,
    };

    /// Stages replacement payload; the actor's committed edges are unchanged.
    /// The caller's buffer must remain valid through invocation return.
    pub fn replace(self: *Call, payload: []const u8) void {
        self.replacement = payload;
    }

    /// Reserve local routing custody for a record allocated in this batch.
    /// Keep the result inside this call until confirmed settlement.
    pub fn propose(self: *Call, id: core.ObjectId) !driver.Capability {
        if (self.attachment.store.phase != .staging) return error.WrongPhase;
        try self.held.ensureUnusedCapacity(self.arena, 1);
        const ref = try hosting.restoreEdge(self.attachment, id);
        self.held.appendAssumeCapacity(ref);
        return ref;
    }

    /// Restore a checked record retained by the prepared working set. Unlike a
    /// top-level root, it may be retained through another durable record's edge.
    pub fn restore(self: *Call, lease: core.Lease) !driver.Capability {
        const view = try self.attachment.store.currentView(lease);
        _ = try self.attachment.findBehavior(view);
        try self.held.ensureUnusedCapacity(self.arena, 1);
        const ref = try hosting.restoreEdge(self.attachment, view.id);
        self.held.appendAssumeCapacity(ref);
        return ref;
    }

    /// Restore exactly the local authority retained by this stored field.
    /// This does not load the target's behavior or recursively traverse edges.
    /// The returned capability borrows the call's retain until it settles.
    pub fn edge(self: *Call, index: usize) !driver.Capability {
        return self.storedEdge(self.view, index);
    }

    /// Restore a stored reference field of a record view this call holds, with
    /// the same authority contract as `edge`: a strong edge carries its saved
    /// exact authority, a weak edge retains nothing and is refused.
    pub fn storedEdge(self: *Call, view: core.RecordView, index: usize) !driver.Capability {
        if (index >= view.edge_count) return error.NoSuchEdge;
        var edges = view.edges();
        var current: usize = 0;
        const target = while (edges.next()) |item| : (current += 1) {
            if (current == index) break item;
        } else unreachable;
        if (target.strength != .strong) return error.NotDurable;
        try self.held.ensureUnusedCapacity(self.arena, 1);
        const ref = try hosting.restoreEdge(self.attachment, target.target);
        self.held.appendAssumeCapacity(ref);
        return ref;
    }

    /// Retain a same-attachment durable capability through settlement. This
    /// is the custody seam for a reference-field replacement; capture proves
    /// its restoration recipe before the content delta records it.
    pub fn capture(self: *Call, ref: driver.Capability) !core.Edge {
        const captured = try self.attachment.capture(ref);
        for (self.held.items) |held| if (held.eql(ref)) return captured;
        try self.held.ensureUnusedCapacity(self.arena, 1);
        const actor = self.attachment.host.localActorFor(ref) orelse return error.NotDurable;
        self.held.appendAssumeCapacity(try self.attachment.host.retainLocalCapability(actor));
        return captured;
    }

    /// Mint a runtime facet that preserves both the invoking endpoint and a
    /// stored target capability. It is deliberately not a durable record: its
    /// two held authorities are the only way to construct or keep it alive.
    pub fn projectDependent(self: *Call, target: driver.Capability) !driver.Capability {
        try self.held.ensureUnusedCapacity(self.arena, 1);
        const ref = try self.attachment.projectDependent(self.view.id, target);
        self.held.appendAssumeCapacity(ref);
        return ref;
    }

    /// Restrict this call's reply to capabilities subsequently restored by
    /// `storedEdge`. The managed-content handle invokes this before its callback.
    pub fn requireDisclosedReply(self: *Call) void {
        std.debug.assert(self.disclosed_from == unrestricted_reply);
        self.disclosed_from = self.held.items.len;
    }

    pub fn release(self: *Call) void {
        for (self.held.items) |ref| self.attachment.host.releaseCapability(ref, 1) catch unreachable;
        self.held.clearRetainingCapacity();
    }

    pub const ReplyCustody = enum { validate_only, retain };

    /// Validate this call's capability policy and apply the requested custody.
    /// Returns whether the value contained a capability.
    pub fn prepareReply(self: *Call, value: driver.Value, custody: ReplyCustody) !bool {
        var context: ReplyCapabilities = .{ .call = self, .custody = custody };
        try value.forEachCapability(&context, retainCapability);
        return context.found;
    }

    const ReplyCapabilities = struct {
        call: *Call,
        custody: ReplyCustody,
        found: bool = false,
    };

    fn retainCapability(context: *ReplyCapabilities, ref: driver.Capability) !void {
        const self = context.call;
        context.found = true;
        if (self.disclosed_from != unrestricted_reply) {
            var disclosed = false;
            for (self.held.items[self.disclosed_from..]) |held| if (held.eql(ref)) {
                disclosed = true;
                break;
            };
            if (!disclosed) return error.UndeclaredDisclosure;
        }
        if (context.custody == .validate_only) return;
        for (self.held.items) |held| if (held.eql(ref)) return;
        const target = try self.attachment.capture(ref);
        try self.held.ensureUnusedCapacity(self.arena, 1);
        const retained = try hosting.restoreEdge(self.attachment, target.target);
        self.held.appendAssumeCapacity(retained);
    }
};
