//! Immutable actor portraits and effect-restricted durable turns.
const std = @import("std");
const core = @import("loam_core");
const driver = @import("driver_core");
const hosting = @import("attachment.zig");
pub const Preparation = @import("preparation.zig").Preparation;
const call_memory = @import("call_memory.zig");
const references = @import("references.zig");

/// The schema/version selects both structural limits and behavior. Invocation
/// is deterministic for the supplied inputs: no I/O or external effects. State
/// replacement, transaction staging, and held local references are explicit.
pub const Behavior = struct {
    /// The application's call callbacks. Implementors are unknown at this
    /// declaration, so `prepare` and `invoke` keep `anyerror` return sets.
    schema: u64,
    version: u32 = 1,
    context: ?*anyopaque = null,
    /// Borrowed configuration. Preparation state belongs to the retained call.
    prepare: ?*const fn (*Call, []const u8, []const driver.Value) anyerror!Preparation = null,
    /// Reply bytes and spines must remain valid and unchanged until the call
    /// releases, including storage recovery and settlement retries. Use the
    /// supplied arena, retained inputs or prepared portrait. Copy mutable
    /// callback-context data into that arena before returning it.
    invoke: *const fn (*Call, core.RecordView, []const u8, []const driver.Value) anyerror!driver.Value,
};

pub const Call = struct {
    /// A continuation preserves its original source action while dispatching
    /// a separately held target action. These borrows belong to this call's
    /// immutable input owner, never to an application callback.
    pub const Intent = struct { verb: []const u8, args: []const driver.Value };
    pub const Memory = @import("call_memory.zig").Memory;
    pub const max_refusal_bytes = 1024;
    /// Each acquisition may grow held custody and allocate a one-element Host
    /// retain spine, even when it acquires the same capability again.
    pub fn heldAllocationBound(occurrences: usize) !call_memory.AllocationBound {
        var bound: call_memory.AllocationBound = .{};
        try bound.includeArrayGrowth(driver.Capability, occurrences);
        try bound.include(@sizeOf(driver.Capability), @alignOf(driver.Capability), occurrences);
        return bound;
    }
    memory: *Memory,
    attachment: *hosting.Attachment,
    /// Borrowed only through this retained call's preparation. Child effects
    /// remain admitted across Host finish. Resident near calls own no lease.
    /// One inline pointer per operation slot adds no allocation or owner.
    /// The enclosing Operation keeps the actual lease stable until settlement.
    work: ?*const driver.Host.PendingWorkLease = null,
    view: core.RecordView,
    context: ?*anyopaque = null,
    preparation: ?Preparation = null,
    references: ?*references.Set = null,
    transaction: ?Transaction = null,
    /// Materialize at the top-level Host boundary after staging, before write
    /// submission. Reserve custody here. Expose no externally usable authority.
    /// Returned data obeys the same retained lifetime as the invocation reply.
    /// Implementors are unknown at this declaration, so `result` keeps an
    /// `anyerror` return set.
    result: ?*const fn (*Call) anyerror!driver.Value = null,
    /// Infallible activation after confirmed commit, before reply projection.
    /// Runs once even if settlement needs retry. Read-only results activate at
    /// settlement. Preparation.deinit must cancel any unconfirmed reservation.
    confirmation: ?struct {
        context: *anyopaque,
        apply: *const fn (*anyopaque) void,
        cancel: ?*const fn (*anyopaque) void = null,
        requires_commit: bool = false,
    } = null,
    dispatch: ?Intent = null,
    /// A prepared dependent call dispatches once at the top-level boundary.
    /// The operation retains its answer until ordinary resolver settlement.
    forward: ?struct { target: driver.Capability, verb: []const u8, args: []const driver.Value } = null,
    replacement: ?[]const u8 = null,
    /// Application refusal copied into the bounded working arena. Only an
    /// invocation that fails may publish it. Storage and activation failures
    /// keep their own verdict. No successful call allocates refusal storage.
    refusal: ?[]const u8 = null,
    /// A dependent projection enters through `view`'s endpoint authority but
    /// invokes the content behind this separately held durable capability.
    /// The operation owns the retain. The call only borrows it.
    dependent_target: ?driver.Capability = null,
    held: std.ArrayList(driver.Capability) = .empty,
    disclosed_from: usize = unrestricted_reply,
    const unrestricted_reply = std.math.maxInt(usize);

    pub fn arena(self: *Call) std.mem.Allocator {
        return self.memory.working.allocator();
    }

    pub fn refuseCopying(self: *Call, reason: []const u8) !void {
        if (self.refusal != null) return error.WrongPhase;
        if (reason.len == 0 or reason.len > max_refusal_bytes or !std.unicode.utf8ValidateSlice(reason)) return error.InvalidArgument;
        self.refusal = try self.arena().dupe(u8, reason);
    }
    pub const Transaction = struct {
        context: *anyopaque,
        /// Stage only into the attachment's open batch. Never begin or commit.
        /// Implementors are unknown at this declaration, so `stage` keeps an
        /// `anyerror` return set.
        stage: *const fn (*anyopaque, *core.Store) anyerror!void,
    };

    /// Stages replacement payload. The actor's committed edges are unchanged.
    /// The caller's buffer must remain valid through invocation return.
    pub fn replace(self: *Call, payload: []const u8) void {
        self.replacement = payload;
    }

    /// Reserve local routing custody for a record allocated in this batch.
    /// Keep the result inside this call until confirmed settlement.
    pub fn propose(self: *Call, id: core.ObjectId) !driver.Capability {
        if (self.attachment.store.phase != .staging) return error.WrongPhase;
        try self.held.ensureUnusedCapacity(self.arena(), 1);
        const ref = try hosting.restoreEdge(self.attachment, id);
        self.adoptRetain(ref);
        return ref;
    }

    /// Restore a checked record retained by the prepared working set. Unlike a
    /// top-level root, it may be retained through another durable record's edge.
    pub fn restore(self: *Call, lease: core.Lease) !driver.Capability {
        const view = try self.attachment.store.currentView(lease);
        _ = try self.attachment.findBehavior(view);
        try self.held.ensureUnusedCapacity(self.arena(), 1);
        const ref = try hosting.restoreEdge(self.attachment, view.id);
        self.adoptRetain(ref);
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
        const target = try view.edgeAt(index);
        if (target.strength != .strong) return error.NotDurable;
        if (target.restoration == .recipe) {
            const working = self.references orelse return error.ReferenceUnprepared;
            return references.hold(self, try working.restored(view, index));
        }
        try self.held.ensureUnusedCapacity(self.arena(), 1);
        const ref = try hosting.restoreEdge(self.attachment, target.target);
        self.adoptRetain(ref);
        return ref;
    }

    /// Retain a same-attachment durable capability through settlement. This
    /// is the custody seam for a reference-field replacement. Capture proves
    /// its restoration recipe before the content delta records it.
    pub fn capture(self: *Call, ref: driver.Capability) !core.Edge {
        const captured = try self.attachment.capture(ref);
        for (self.held.items) |held| if (held.eql(ref)) return captured;
        try self.held.ensureUnusedCapacity(self.arena(), 1);
        const actor = self.attachment.host.localActorFor(ref) orelse return error.NotDurable;
        self.adoptRetain(try self.attachment.host.retainLocalCapability(actor));
        return captured;
    }

    /// Mint a runtime facet that preserves both the invoking endpoint and a
    /// stored target capability. It is not a durable record: its
    /// two held authorities are the only way to construct or keep it alive.
    pub fn projectDependent(self: *Call, target: driver.Capability) !driver.Capability {
        try self.held.ensureUnusedCapacity(self.arena(), 1);
        const ref = try self.attachment.projectDependent(self.view.id, target);
        self.adoptRetain(ref);
        return ref;
    }

    /// Adopt one already-owned retain after reserving a held-list slot. Custody
    /// alone never authorizes a reply. The prefix owns undisclosed references.
    /// The suffix owns declared references. Insertion rotates one suffix entry
    /// into the new slot, preserving that partition without another allocation.
    pub fn adoptRetain(self: *Call, ref: driver.Capability) void {
        self.held.appendAssumeCapacity(ref);
        if (self.disclosed_from != unrestricted_reply) {
            std.mem.swap(driver.Capability, &self.held.items[self.disclosed_from], &self.held.items[self.held.items.len - 1]);
            self.disclosed_from += 1;
        }
    }

    /// Declare exactly this held capability for the reply. Declaring a facet
    /// does not declare the capabilities it retains. No new retain is acquired.
    /// Freshly adopted custody sits at the end of the undisclosed prefix,
    /// so immediate disclosure checks that slot in constant time. Other held
    /// references scan the arena-bounded inventory. Only the partition changes.
    pub fn discloseHeld(self: *Call, ref: driver.Capability) !driver.Capability {
        const end = if (self.disclosed_from == unrestricted_reply) self.held.items.len else self.disclosed_from;
        if (end != 0 and self.held.items[end - 1].eql(ref)) {
            if (self.disclosed_from != unrestricted_reply) self.disclosed_from -= 1;
            return ref;
        }
        for (self.held.items, 0..) |held, index| if (held.eql(ref)) {
            if (self.disclosed_from != unrestricted_reply and index < self.disclosed_from) {
                self.disclosed_from -= 1;
                std.mem.swap(driver.Capability, &self.held.items[index], &self.held.items[self.disclosed_from]);
            }
            return ref;
        };
        return error.UndeclaredDisclosure;
    }

    /// Restrict this call's reply to explicitly declared held capabilities.
    /// The managed-content handle invokes this before its callback.
    pub fn requireDisclosedReply(self: *Call) void {
        std.debug.assert(self.disclosed_from == unrestricted_reply);
        self.disclosed_from = self.held.items.len;
    }

    pub fn release(self: *Call) void {
        if (self.confirmation) |confirmation| if (confirmation.cancel) |cancel| cancel(confirmation.context);
        self.confirmation = null;
        if (self.references) |working| working.deinit();
        self.references = null;
        for (self.held.items) |ref| self.attachment.host.releaseCapabilityTerminal(ref, null);
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
        _ = try references.hold(self, ref);
    }
};
