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
    parent: records.EndpointRecord,
    sequence: u64,
    request: core.GrantLedger.Issue,
    intent: []const u8,
    source: ?*storage.Operation = null,
    planned: bool = false,
    admitted: bool = false,
    entropy: driver.Host.DurableSwiss.Entropy = undefined,
    leases: [3]?loam.Lease = @splat(null),
    pending: ?loam.Ticket = null,
    child: ?*storage.Operation = null,
    reservation: ?driver.Host.DurableReservation = null,
    result_ref: ?driver.Capability = null,
    proposed_endpoint: ?loam.ObjectId = null,
    pub const Step = union(enum) { ready, read: loam.Read, waiting, more };

    pub fn init(call: *hosting.Call, config: *service.Service, parent: records.EndpointRecord, args: []const driver.Value) !Sharing {
        const decoder = config.decode_derive orelse return error.NoSuchMethod;
        if (args.len == 0 or args[0] != .integer or args[0].integer < 1) return error.InvalidArguments;
        const sequence: u64 = @intCast(args[0].integer);
        const request = try decoder(call.arena, parent.content.?.resource, args[1..]);
        return .{ .call = call, .config = config, .parent = parent, .sequence = sequence, .request = request, .intent = try records.DerivationRecord.encodeIntent(call.arena, parent.content.?.resource.owner, request) };
    }

    pub fn advance(self: *Sharing, source: *storage.Operation) !Step {
        self.source = source;
        if (!self.admitted) {
            if (self.sequence > self.parent.next_derivation) return error.OperationOutOfOrder;
            if (self.sequence < self.parent.next_derivation - self.parent.receipt_count) return error.ReceiptExpired;
            if (self.sequence == self.parent.next_derivation) {
                if (self.parent.next_derivation == std.math.maxInt(i64)) return error.SequenceExhausted;
                const entropy = self.config.entropy orelse return error.EntropyRequired;
                try entropy.fill(entropy.context, &self.entropy);
            }
            self.admitted = true;
        }
        if (self.sequence == self.parent.next_derivation) {
            if (!self.planned) {
                source.prepareDeriveCopying(self.request) catch |err| {
                    if (err == error.RecordUnloaded) return .more;
                    return err;
                };
                self.planned = true;
                return .more; // Drain the prepared append through source.advance.
            }
            return .ready;
        }
        const offset = self.sequence - (self.parent.next_derivation - self.parent.receipt_count);
        if (try self.load(0, self.parent.receipts[@intCast(offset)])) |step| return step;
        const receipt = try records.DerivationRecord.decode(try self.store().currentView(self.leases[0].?));
        if (!std.mem.eql(u8, receipt.intent, self.intent)) return error.OperationConflict;
        if (try self.load(1, receipt.endpoint)) |step| return step;
        const child_record = try records.EndpointRecord.decode(try self.store().currentView(self.leases[1].?));
        const content = child_record.content orelse return error.InvalidRecord;
        if (!content.resource.eql(self.parent.content.?.resource) or !content.object.eql(self.parent.content.?.object) or child_record.publication == null or !child_record.publication.?.eql(receipt.publication)) return error.InvalidRecord;
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
                    self.pending = read.ticket;
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
            .read => |read| return .{ .read = read },
            .waiting => return .waiting,
            .ready => {},
        }
        self.child.?.require(content.resource, .{ .permissions = &.{} }) catch |err| {
            if (err == error.RecordUnloaded) return .more;
            return err;
        };
        return .ready;
    }

    pub fn completeRead(self: *Sharing, ticket: loam.Ticket, result: loam.ReadResult) !void {
        if (self.pending) |pending| {
            if (!std.meta.eql(pending, ticket)) return error.StaleCompletion;
            self.pending = null;
            return self.store().completeRead(ticket, result);
        }
        return self.child.?.completeRead(ticket, result);
    }

    pub fn deinit(self: *Sharing) void {
        if (self.reservation) |*reservation| reservation.cancel();
        if (self.child) |child| child.deinit() catch unreachable;
        for (self.leases) |lease| if (lease) |held| self.store().release(held) catch unreachable;
    }

    pub fn invoke(self: *Sharing) driver.Value {
        if (self.sequence == self.parent.next_derivation) self.call.transaction = .{ .context = self, .stage = stage };
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
                self.pending = read.ticket;
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
    try service.putEndpoint(store, self.call.arena, endpoint, .{ .descriptor = grant.derived_use.?, .content = self.parent.content, .publication = publication }, false, null);
    const receipt = try store.allocateId();
    try store.putCopying(.{ .id = receipt, .revision = 0, .schema = records.profile.derivation, .payload = self.intent, .edges = &.{ .{ .target = endpoint }, .{ .target = publication } } }, null);
    var parent = self.parent;
    if (parent.receipt_count == records.EndpointRecord.max_receipts) {
        std.mem.copyForwards(loam.ObjectId, parent.receipts[0 .. parent.receipt_count - 1], parent.receipts[1..parent.receipt_count]);
        parent.receipt_count -= 1;
    }
    parent.receipts[parent.receipt_count] = receipt;
    parent.receipt_count += 1;
    parent.next_derivation += 1;
    try service.putEndpoint(store, self.call.arena, self.call.view.id, parent, self.call.view.rooted, self.call.view.revision);
}

fn reply(call: *hosting.Call) !driver.Value {
    const self = state(call.confirmation.?.context);
    if (self.result_ref == null) {
        self.result_ref = if (self.proposed_endpoint) |id| try call.propose(id) else try call.restore(self.leases[1].?);
        self.reservation = try call.attachment.host.reserveDurableCapability(self.entropy, self.result_ref.?);
    }
    return .{ .capability = self.result_ref.? };
}

fn confirm(context: *anyopaque) void {
    state(context).reservation.?.commit();
}

pub fn validatePublication(view: loam.RecordView, endpoint: loam.ObjectId) !void {
    if (!(try hosting.publication.activeTarget(view)).eql(endpoint)) return error.InvalidPublication;
}
