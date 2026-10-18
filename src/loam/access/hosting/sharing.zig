//! One derivation's intent, receipt lookup, and reserved publication custody.
const std = @import("std");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const storage = @import("loam_access_storage");
const loam = @import("loam_core");
const hosting = @import("loam_hosting");
const driver = @import("driver_core");
const service = @import("service.zig");
const vocabulary = @import("vocabulary.zig");
const Step = @import("step.zig").Step;

/// Which read a parked sharing step resumes from when the Store delivers it.
const PendingOwner = enum { store, child, control };

pub const Sharing = struct {
    call: *hosting.Call,
    config: *service.Service,
    /// Inline callback/context identity retained across reads in the existing
    /// call arena. The embedding owns the pointee until attachment closure.
    /// Re-reading configuration after a wait could switch the source selected
    /// when issuance was decoded.
    entropy_source: ?service.Service.EntropySource,
    parent: *const records.EndpointRecord,
    /// What the derived endpoint binds: the parent's own content or
    /// administration, or the target of the dependent facet it was called on.
    bound: records.EndpointRecord.Binding,
    sequence: u64,
    request: core.GrantLedger.Issue,
    expected: ?core.Revision = null,
    intent: []const u8,
    source: ?*storage.Operation = null,
    planned: bool = false,
    admitted: bool = false,
    entropy: driver.Host.DurableSwiss.Entropy = undefined,
    // Independent secrets: knowing a use publication cannot reveal control.
    control_entropy: driver.Host.DurableSwiss.Entropy = undefined,
    leases: [Slot.count]?loam.Lease = @splat(null),
    pending: ?struct { ticket: loam.Ticket, owner: PendingOwner } = null,
    child: ?*storage.Operation = null,
    control: ?*storage.Operation = null,
    powers: ?core.Control.Powers = null,
    control_lease: ?loam.Lease = null,
    control_publication_prepared: bool = false,
    result_control: ?driver.Capability = null,
    proposed_control: ?loam.ObjectId = null,
    reservation: ?driver.Host.DurableReservation = null,
    control_reservation: ?driver.Host.DurableReservation = null,
    result_ref: ?driver.Capability = null,
    proposed_endpoint: ?loam.ObjectId = null,

    /// The rows a replayed derivation holds: its receipt, the endpoint it
    /// issued, and that endpoint's publication.
    const Slot = struct {
        const receipt = 0;
        const endpoint = 1;
        const publication = 2;
        const count = 3;
    };

    pub fn initIssue(call: *hosting.Call, config: *service.Service, parent: *const records.EndpointRecord, args: []const driver.Value) !Sharing {
        const administered = parent.administration orelse return error.NotAdministrable;
        const decoder = config.decode_managed_derive orelse return error.NoSuchMethod;
        if (args.len < 2 or args[0] != .integer or args[0].integer < 1) return error.InvalidArguments;
        const expected = try vocabulary.revisionOf(args[1]);
        const issue = try decoder(config.context, call.arena(), administered.resource, args[2..]);
        const encoded = try records.DerivationRecord.encodeManagedIntent(call.arena(), administered.resource.owner, issue.request, issue.powers);
        // Expected revision belongs to exact replay intent as well as fresh
        // admission. Its fixed prefix prevents a changed revision from replaying.
        const intent = try call.arena().alloc(u8, encoded.len + @sizeOf(u64));
        std.mem.writeInt(u64, intent[0..@sizeOf(u64)], @backingInt(expected), .big);
        @memcpy(intent[@sizeOf(u64)..], encoded);
        return .{ .call = call, .config = config, .entropy_source = config.entropy, .parent = parent, .bound = administered, .sequence = @intCast(args[0].integer), .expected = expected, .request = issue.request, .powers = issue.powers, .intent = intent };
    }

    /// Park on `read` until the Store delivers it, remembering which read
    /// owner the delivery resumes.
    fn awaitRead(self: *Sharing, read: loam.Read, owner: PendingOwner) Step {
        self.pending = .{ .ticket = read.ticket, .owner = owner };
        return .{ .read = read };
    }

    pub fn init(call: *hosting.Call, config: *service.Service, parent: *const records.EndpointRecord, bound: records.EndpointRecord.Binding, args: []const driver.Value) !Sharing {
        const decoder = config.decode_derive orelse return error.NoSuchMethod;
        if (args.len == 0 or args[0] != .integer or args[0].integer < 1) return error.InvalidArguments;
        const sequence: u64 = @intCast(args[0].integer);
        const request = try decoder(config.context, call.arena(), bound.resource, args[1..]);
        return .{ .call = call, .config = config, .entropy_source = config.entropy, .parent = parent, .bound = bound, .sequence = sequence, .request = request, .intent = try records.DerivationRecord.encodeIntent(call.arena(), bound.resource.owner, request) };
    }

    pub fn initManaged(call: *hosting.Call, config: *service.Service, parent: *const records.EndpointRecord, bound: records.EndpointRecord.Binding, args: []const driver.Value) !Sharing {
        const decoder = config.decode_managed_derive orelse return error.NoSuchMethod;
        if (args.len == 0 or args[0] != .integer or args[0].integer < 1) return error.InvalidArguments;
        const issue = try decoder(config.context, call.arena(), bound.resource, args[1..]);
        return .{ .call = call, .config = config, .entropy_source = config.entropy, .parent = parent, .bound = bound, .sequence = @intCast(args[0].integer), .request = issue.request, .powers = issue.powers, .intent = try records.DerivationRecord.encodeManagedIntent(call.arena(), bound.resource.owner, issue.request, issue.powers) };
    }

    pub fn advance(self: *Sharing, source: *storage.Operation) !Step {
        self.source = source;
        if (self.expected != null) try loam.reload(source.requireManagement()) orelse return .more;
        if (!self.admitted) {
            _ = try self.parent.derivations.lookup(self.sequence);
            if (self.sequence == self.parent.derivations.next) {
                if (self.parent.derivations.next == std.math.maxInt(i64)) return error.SequenceExhausted;
                const entropy = self.entropy_source orelse return error.EntropyRequired;
                self.entropy = try entropy.draw();
                if (self.powers != null) self.control_entropy = try entropy.draw();
            }
            self.admitted = true;
        }
        if (self.sequence == self.parent.derivations.next) {
            if (!self.planned) {
                const planned = if (self.expected) |revision| source.prepareIssueCopying(self.request, self.powers.?, revision) else if (self.powers) |powers| source.prepareManagedDeriveCopying(self.request, powers) else source.prepareDeriveCopying(self.request);
                try loam.reload(planned) orelse return .more;
                self.planned = true;
                return .more; // Drain the prepared append through source.advance.
            }
            return .ready;
        }
        if (try self.acquire(&self.leases[Slot.receipt], (try self.parent.derivations.lookup(self.sequence)).?)) |step| return step;
        const receipt = try records.DerivationRecord.decode(try self.store().currentView(self.leases[Slot.receipt].?));
        if (!std.mem.eql(u8, receipt.intent, self.intent)) return error.OperationConflict;
        if (try self.acquire(&self.leases[Slot.endpoint], receipt.endpoint)) |step| return step;
        const child_record = try liveEndpoint(try self.store().currentView(self.leases[Slot.endpoint].?));
        const content = child_record.content orelse return error.InvalidRecord;
        // The issued endpoint records which node the sequence shared, so the
        // same request through another dependent facet is a changed intent.
        if (!content.resource.eql(self.bound.resource) or !content.object.eql(self.bound.object)) return error.OperationConflict;
        if (child_record.publication == null or !child_record.publication.?.eql(receipt.publication)) return error.InvalidRecord;
        if (try self.acquire(&self.leases[Slot.publication], receipt.publication)) |step| return step;
        const publication = try self.store().currentView(self.leases[Slot.publication].?);
        try validatePublication(publication, receipt.endpoint);
        self.entropy = hosting.publication.entropyOf(publication);
        if (try self.openManaged(.child, child_record.descriptor)) |step| return step;
        const admission = if (self.expected != null) self.child.?.requireRecovery(content.resource) else self.child.?.require(content.resource, .{ .permissions = &.{} });
        try loam.reload(admission) orelse return .more;
        if (receipt.control) |id| {
            if (try self.discoverControl(id)) |step| return step;
        } else if (self.powers != null) return error.InvalidRecord;
        return .ready;
    }

    /// Rediscover the control endpoint a managed derivation issued: its fixed
    /// secret from the publication row, then its managed window. Null once
    /// the control is open and still available.
    fn discoverControl(self: *Sharing, id: loam.ObjectId) !?Step {
        if (try self.acquire(&self.control_lease, id)) |step| return step;
        const control_endpoint = try liveEndpoint(try self.store().currentView(self.control_lease.?));
        if (control_endpoint.content != null) return error.InvalidRecord;
        if (!self.control_publication_prepared) {
            const lease = switch (try self.acquireRow(control_endpoint.publication orelse return error.InvalidRecord)) {
                .lease => |lease| lease,
                .parked => |step| return step,
            };
            defer self.store().release(lease) catch unreachable;
            const control_publication = try self.store().currentView(lease);
            try validatePublication(control_publication, id);
            // The endpoint lease preserves its immutable recipe edge. Only
            // this fixed secret survives discovery; release the row before
            // opening the control's managed window, preserving residency.
            self.control_entropy = hosting.publication.entropyOf(control_publication);
            self.control_publication_prepared = true;
        }
        if (try self.openManaged(.control, control_endpoint.descriptor)) |step| return step;
        const description = try loam.reload(self.control.?.describeControl()) orelse return .more;
        if (!description.available) return error.ControlRevoked;
        return null;
    }

    /// Open the child or control managed operation from its descriptor row
    /// and advance it until it is ready. The row lease retires as soon as the
    /// operation has begun.
    fn openManaged(self: *Sharing, comptime owner: PendingOwner, descriptor: loam.ObjectId) !?Step {
        const slot = switch (owner) {
            .child => &self.child,
            .control => &self.control,
            .store => unreachable,
        };
        if (slot.* == null) {
            const lease = switch (try self.acquireRow(descriptor)) {
                .lease => |lease| lease,
                .parked => |step| return step,
            };
            defer self.store().release(lease) catch unreachable;
            const ref = switch (owner) {
                .child => try self.config.capabilities.restoreUse(lease),
                .control => try self.config.capabilities.restoreControl(lease),
                .store => unreachable,
            };
            defer ref.release();
            slot.* = try ref.begin(self.config.record_capacity);
        }
        return switch (try slot.*.?.advance()) {
            .read => |read| self.awaitRead(read, owner),
            .waiting => .waiting,
            .ready => null,
        };
    }

    pub fn completeRead(self: *Sharing, ticket: loam.Ticket, result: loam.ReadResult) !void {
        const pending = self.pending orelse return error.StaleCompletion;
        if (!std.meta.eql(pending.ticket, ticket)) return error.StaleCompletion;
        self.pending = null;
        return switch (pending.owner) {
            .store => self.store().completeRead(ticket, result),
            .child => self.child.?.completeRead(ticket, result),
            .control => self.control.?.completeRead(ticket, result),
        };
    }

    pub fn deinit(self: *Sharing) void {
        std.debug.assert(self.pending == null);
        if (self.reservation) |*reservation| reservation.cancel();
        if (self.control_reservation) |*reservation| reservation.cancel();
        if (self.child) |child| child.deinit() catch unreachable;
        if (self.control) |control| control.deinit() catch unreachable;
        if (self.control_lease) |lease| self.store().release(lease) catch unreachable;
        for (self.leases) |lease| if (lease) |held| self.store().release(held) catch unreachable;
    }

    pub fn invoke(self: *Sharing) driver.Value {
        if (self.sequence == self.parent.derivations.next) self.call.transaction = .{ .context = self, .stage = stage };
        self.call.result = reply;
        self.call.confirmation = .{ .context = self, .apply = confirm };
        return .{ .void = {} };
    }

    fn store(self: *Sharing) *loam.Store {
        return self.config.capabilities.store;
    }

    const Acquired = union(enum) { lease: loam.Lease, parked: Step };

    /// Acquire one row for a bounded read window, or the step that parks
    /// this sharing until the store can hand it over.
    fn acquireRow(self: *Sharing, id: loam.ObjectId) !Acquired {
        return switch (try hosting.Preparation.acquire(self.store(), id)) {
            .read => |read| .{ .parked = self.awaitRead(read, .store) },
            .ready => |lease| .{ .lease = lease },
            .waiting => .{ .parked = .waiting },
        };
    }

    /// Fill a held lease slot once; a filled slot needs no store call.
    fn acquire(self: *Sharing, slot: *?loam.Lease, id: loam.ObjectId) !?Step {
        if (slot.* != null) return null;
        switch (try self.acquireRow(id)) {
            .lease => |lease| slot.* = lease,
            .parked => |step| return step,
        }
        return null;
    }
};

/// Decode an endpoint row, refusing a retired one as a retired capability.
fn liveEndpoint(view: loam.RecordView) !records.EndpointRecord {
    if (view.schema == records.profile.terminal) {
        if ((try records.TerminalRecord.decode(view)).kind != .endpoint) return error.InvalidRecord;
        return error.CapabilityRetired;
    }
    return records.EndpointRecord.decode(view);
}

fn state(context: *anyopaque) *Sharing {
    return @ptrCast(@alignCast(context));
}

fn stage(context: *anyopaque, store: *loam.Store) !void {
    const self = state(context);
    if (store != self.store()) return error.ForeignStore;
    const grant = try self.config.capabilities.stage(self.source.?, .reachable);
    const endpoint = try store.allocateId();
    self.proposed_endpoint = endpoint;
    const publication = try hosting.publication.stageTarget(store, self.entropy, endpoint);
    try storage.stage.endpointAtOperation(self.source.?, self.call.arena(), endpoint, .{ .descriptor = grant.derived_use.?, .content = self.bound, .publication = publication }, .reachable);
    if (grant.derived_control) |descriptor| {
        const control = try store.allocateId();
        const control_publication = try hosting.publication.stageTarget(store, self.control_entropy, control);
        try storage.stage.endpointAtOperation(self.source.?, self.call.arena(), control, .{ .descriptor = descriptor, .administration = self.bound, .publication = control_publication }, .reachable);
        self.proposed_control = control;
    }
    const receipt = try store.allocateId();
    var edges: [records.DerivationRecord.max_edges]loam.Edge = .{ .{ .target = endpoint }, .{ .target = publication }, undefined };
    var count: usize = 2;
    if (self.proposed_control) |control| {
        edges[count] = .{ .target = control };
        count += 1;
    }
    try store.putCopying(.{ .id = receipt, .revision = 0, .schema = records.profile.derivation, .payload = self.intent, .edges = edges[0..count] }, null);
    var parent = self.parent.*;
    try parent.derivations.append(receipt);
    try service.putEndpoint(store, self.call.arena(), self.call.view.id, parent, storage.Rooting.ofStored(self.call.view.rooted), self.call.view.revision);
}

fn reply(call: *hosting.Call) !driver.Value {
    const self = state(call.confirmation.?.context);
    if (self.result_ref == null) {
        self.result_ref = if (self.proposed_endpoint) |id| try call.propose(id) else try call.restore(self.leases[Sharing.Slot.endpoint].?);
        self.reservation = try call.attachment.host.reserveDurableCapability(self.entropy, self.result_ref.?);
    }
    if (self.powers != null) {
        if (self.result_control == null) self.result_control = if (self.proposed_control) |id| try call.propose(id) else try call.restore(self.control_lease.?);
        if (self.control_reservation == null) self.control_reservation = try call.attachment.host.reserveDurableCapability(self.control_entropy, self.result_control.?);
        const pair = try call.arena().alloc(driver.Value, 2);
        pair[0] = .{ .capability = self.result_ref.? };
        pair[1] = .{ .capability = self.result_control.? };
        return .{ .list = pair };
    }
    return .{ .capability = self.result_ref.? };
}

fn confirm(context: *anyopaque) void {
    const self = state(context);
    self.reservation.?.commit();
    if (self.control_reservation) |*reservation| reservation.commit();
}

pub fn validatePublication(view: loam.RecordView, endpoint: loam.ObjectId) !void {
    if (!(try hosting.publication.activeTarget(view)).eql(endpoint)) return error.InvalidPublication;
}
