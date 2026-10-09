//! One derivation's intent, receipt lookup, and reserved publication custody.
const std = @import("std");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const storage = @import("loam_access_storage");
const loam = @import("loam_core");
const hosting = @import("loam_hosting");
const driver = @import("driver_core");
const service = @import("service.zig");

pub const Sharing = struct {
    call: *hosting.Call,
    config: *service.Service,
    /// Inline callback/context identity retained across reads in the existing
    /// call arena. The embedding owns the pointee until attachment closure.
    /// Re-reading configuration after a wait could switch the source selected
    /// when issuance was decoded.
    entropy_source: ?service.Service.EntropySource,
    parent: *const records.EndpointRecord,
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
    leases: [3]?loam.Lease = @splat(null),
    pending: ?struct { ticket: loam.Ticket, owner: enum { store, child, control } } = null,
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
    pub const Step = union(enum) { ready, read: loam.Read, waiting, more };

    pub fn initIssue(call: *hosting.Call, config: *service.Service, parent: *const records.EndpointRecord, args: []const driver.Value) !Sharing {
        const administered = parent.administration orelse return error.NotAdministrable;
        const decoder = config.decode_managed_derive orelse return error.NoSuchMethod;
        if (args.len < 2 or args[0] != .integer or args[0].integer < 1 or args[1] != .bytes or args[1].bytes.len != 8) return error.InvalidArguments;
        const expected = std.mem.readInt(u64, args[1].bytes[0..8], .big);
        const issue = try decoder(config.context, call.arena(), administered.resource, args[2..]);
        const encoded = try records.DerivationRecord.encodeManagedIntent(call.arena(), administered.resource.owner, issue.request, issue.powers);
        // Expected revision belongs to exact replay intent as well as fresh
        // admission. Its fixed prefix prevents a changed revision from replaying.
        const intent = try call.arena().alloc(u8, encoded.len + 8);
        std.mem.writeInt(u64, intent[0..8], expected, .big);
        @memcpy(intent[8..], encoded);
        return .{ .call = call, .config = config, .entropy_source = config.entropy, .parent = parent, .sequence = @intCast(args[0].integer), .expected = @fromBackingInt(expected), .request = issue.request, .powers = issue.powers, .intent = intent };
    }

    fn binding(self: *const Sharing) records.EndpointRecord.Binding {
        return (self.parent.content orelse self.parent.administration).?;
    }

    pub fn init(call: *hosting.Call, config: *service.Service, parent: *const records.EndpointRecord, args: []const driver.Value) !Sharing {
        const decoder = config.decode_derive orelse return error.NoSuchMethod;
        if (args.len == 0 or args[0] != .integer or args[0].integer < 1) return error.InvalidArguments;
        const sequence: u64 = @intCast(args[0].integer);
        const request = try decoder(config.context, call.arena(), parent.content.?.resource, args[1..]);
        return .{ .call = call, .config = config, .entropy_source = config.entropy, .parent = parent, .sequence = sequence, .request = request, .intent = try records.DerivationRecord.encodeIntent(call.arena(), parent.content.?.resource.owner, request) };
    }

    pub fn initManaged(call: *hosting.Call, config: *service.Service, parent: *const records.EndpointRecord, args: []const driver.Value) !Sharing {
        const decoder = config.decode_managed_derive orelse return error.NoSuchMethod;
        if (args.len == 0 or args[0] != .integer or args[0].integer < 1) return error.InvalidArguments;
        const issue = try decoder(config.context, call.arena(), parent.content.?.resource, args[1..]);
        return .{ .call = call, .config = config, .entropy_source = config.entropy, .parent = parent, .sequence = @intCast(args[0].integer), .request = issue.request, .powers = issue.powers, .intent = try records.DerivationRecord.encodeManagedIntent(call.arena(), parent.content.?.resource.owner, issue.request, issue.powers) };
    }

    pub fn advance(self: *Sharing, source: *storage.Operation) !Step {
        self.source = source;
        if (self.expected != null) source.requireManagement() catch |err| {
            if (err == error.RecordUnloaded) return .more;
            return err;
        };
        if (!self.admitted) {
            _ = try self.parent.derivations.lookup(self.sequence);
            if (self.sequence == self.parent.derivations.next) {
                if (self.parent.derivations.next == std.math.maxInt(i64)) return error.SequenceExhausted;
                const entropy = self.entropy_source orelse return error.EntropyRequired;
                try entropy.fill(entropy.context, &self.entropy);
                if (self.powers != null) try entropy.fill(entropy.context, &self.control_entropy);
            }
            self.admitted = true;
        }
        if (self.sequence == self.parent.derivations.next) {
            if (!self.planned) {
                const planned = if (self.expected) |revision| source.prepareIssueCopying(self.request, self.powers.?, revision) else if (self.powers) |powers| source.prepareManagedDeriveCopying(self.request, powers) else source.prepareDeriveCopying(self.request);
                planned catch |err| {
                    if (err == error.RecordUnloaded) return .more;
                    return err;
                };
                self.planned = true;
                return .more; // Drain the prepared append through source.advance.
            }
            return .ready;
        }
        if (try self.load(0, (try self.parent.derivations.lookup(self.sequence)).?)) |step| return step;
        const receipt = try records.DerivationRecord.decode(try self.store().currentView(self.leases[0].?));
        if (!std.mem.eql(u8, receipt.intent, self.intent)) return error.OperationConflict;
        if (try self.load(1, receipt.endpoint)) |step| return step;
        const child_view = try self.store().currentView(self.leases[1].?);
        if (child_view.schema == records.profile.terminal) {
            if ((try records.TerminalRecord.decode(child_view)).kind != .endpoint) return error.InvalidRecord;
            return error.CapabilityRetired;
        }
        const child_record = try records.EndpointRecord.decode(child_view);
        const content = child_record.content orelse return error.InvalidRecord;
        if (!content.resource.eql(self.binding().resource) or !content.object.eql(self.binding().object) or child_record.publication == null or !child_record.publication.?.eql(receipt.publication)) return error.InvalidRecord;
        if (try self.load(2, receipt.publication)) |step| return step;
        const publication = try self.store().currentView(self.leases[2].?);
        try validatePublication(publication, receipt.endpoint);
        self.entropy = publication.payload[0..@sizeOf(driver.Host.DurableSwiss.Entropy)].*;
        if (self.child == null) {
            const acquired = self.store().acquire(child_record.descriptor) catch |err| {
                if (err == error.PendingRead) return .waiting;
                return err;
            };
            switch (acquired) {
                .read => |read| {
                    self.pending = .{ .ticket = read.ticket, .owner = .store };
                    return .{ .read = read };
                },
                .ready => |lease| {
                    defer self.store().release(lease) catch unreachable;
                    const ref = try self.config.capabilities.restoreUse(lease);
                    defer ref.release();
                    self.child = try ref.begin(self.config.record_capacity);
                },
            }
        }
        switch (try self.child.?.advance()) {
            .read => |read| {
                self.pending = .{ .ticket = read.ticket, .owner = .child };
                return .{ .read = read };
            },
            .waiting => return .waiting,
            .ready => {},
        }
        const admission = if (self.expected != null) self.child.?.requireRecovery(content.resource) else self.child.?.require(content.resource, .{ .permissions = &.{} });
        admission catch |err| {
            if (err == error.RecordUnloaded) return .more;
            return err;
        };
        if (receipt.control) |id| {
            if (self.control_lease == null) {
                const acquired = self.store().acquire(id) catch |err| {
                    if (err == error.PendingRead) return .waiting;
                    return err;
                };
                switch (acquired) {
                    .read => |read| {
                        self.pending = .{ .ticket = read.ticket, .owner = .store };
                        return .{ .read = read };
                    },
                    .ready => |lease| self.control_lease = lease,
                }
            }
            const control_view = try self.store().currentView(self.control_lease.?);
            if (control_view.schema == records.profile.terminal) {
                if ((try records.TerminalRecord.decode(control_view)).kind != .endpoint) return error.InvalidRecord;
                return error.CapabilityRetired;
            }
            const control_endpoint = try records.EndpointRecord.decode(control_view);
            if (control_endpoint.content != null) return error.InvalidRecord;
            if (!self.control_publication_prepared) {
                const acquired = self.store().acquire(control_endpoint.publication orelse return error.InvalidRecord) catch |err| {
                    if (err == error.PendingRead) return .waiting;
                    return err;
                };
                const lease = switch (acquired) {
                    .read => |read| {
                        self.pending = .{ .ticket = read.ticket, .owner = .store };
                        return .{ .read = read };
                    },
                    .ready => |lease| lease,
                };
                defer self.store().release(lease) catch unreachable;
                const control_publication = try self.store().currentView(lease);
                try validatePublication(control_publication, id);
                // The endpoint lease preserves its immutable recipe edge. Only
                // this fixed secret survives discovery; release the row before
                // opening the control's managed window, preserving residency.
                self.control_entropy = control_publication.payload[0..@sizeOf(driver.Host.DurableSwiss.Entropy)].*;
                self.control_publication_prepared = true;
            }
            if (self.control == null) {
                const acquired = self.store().acquire(control_endpoint.descriptor) catch |err| {
                    if (err == error.PendingRead) return .waiting;
                    return err;
                };
                switch (acquired) {
                    .read => |read| {
                        self.pending = .{ .ticket = read.ticket, .owner = .store };
                        return .{ .read = read };
                    },
                    .ready => |lease| {
                        defer self.store().release(lease) catch unreachable;
                        const ref = try self.config.capabilities.restoreControl(lease);
                        defer ref.release();
                        self.control = try ref.begin(self.config.record_capacity);
                    },
                }
            }
            switch (try self.control.?.advance()) {
                .read => |read| {
                    self.pending = .{ .ticket = read.ticket, .owner = .control };
                    return .{ .read = read };
                },
                .waiting => return .waiting,
                .ready => {},
            }
            const description = self.control.?.describeControl() catch |err| {
                if (err == error.RecordUnloaded) return .more;
                return err;
            };
            if (!description.available) return error.ControlRevoked;
        } else if (self.powers != null) return error.InvalidRecord;
        return .ready;
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

    fn load(self: *Sharing, index: usize, id: loam.ObjectId) !?Step {
        if (self.leases[index] != null) return null;
        const acquired = self.store().acquire(id) catch |err| {
            if (err == error.PendingRead) return .waiting;
            return err;
        };
        switch (acquired) {
            .read => |read| {
                self.pending = .{ .ticket = read.ticket, .owner = .store };
                return .{ .read = read };
            },
            .ready => |lease| self.leases[index] = lease,
        }
        return null;
    }
};

fn state(context: *anyopaque) *Sharing {
    return @ptrCast(@alignCast(context));
}

fn stage(context: *anyopaque, store: *loam.Store) !void {
    const self = state(context);
    if (store != self.store()) return error.ForeignStore;
    const grant = try self.config.capabilities.stage(self.source.?, false);
    const endpoint = try store.allocateId();
    self.proposed_endpoint = endpoint;
    const publication = try hosting.publication.stageTarget(store, self.entropy, endpoint);
    try storage.stage.endpointAtOperation(self.source.?, self.call.arena(), endpoint, .{ .descriptor = grant.derived_use.?, .content = self.binding(), .publication = publication }, false);
    if (grant.derived_control) |descriptor| {
        const control = try store.allocateId();
        const control_publication = try hosting.publication.stageTarget(store, self.control_entropy, control);
        try storage.stage.endpointAtOperation(self.source.?, self.call.arena(), control, .{ .descriptor = descriptor, .administration = self.binding(), .publication = control_publication }, false);
        self.proposed_control = control;
    }
    const receipt = try store.allocateId();
    var edges: [3]loam.Edge = .{ .{ .target = endpoint }, .{ .target = publication }, undefined };
    if (self.proposed_control) |control| edges[2] = .{ .target = control };
    try store.putCopying(.{ .id = receipt, .revision = 0, .schema = records.profile.derivation, .payload = self.intent, .edges = edges[0..if (self.proposed_control != null) @as(usize, 3) else 2] }, null);
    var parent = self.parent.*;
    try parent.derivations.append(receipt);
    try service.putEndpoint(store, self.call.arena(), self.call.view.id, parent, self.call.view.rooted, self.call.view.revision);
}

fn reply(call: *hosting.Call) !driver.Value {
    const self = state(call.confirmation.?.context);
    if (self.result_ref == null) {
        self.result_ref = if (self.proposed_endpoint) |id| try call.propose(id) else try call.restore(self.leases[1].?);
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
