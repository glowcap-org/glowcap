//! Exact mutation replay shares endpoint sequencing and the hosting transaction.
const std = @import("std");
const records = @import("loam_access_records");
const loam = @import("loam_core");
const hosting = @import("loam_hosting");
const driver = @import("driver_core");
const service = @import("service.zig");

pub const Mutation = struct {
    call: *hosting.Call,
    endpoint: *const records.EndpointRecord,
    sequence: u64,
    intent: []const u8 = undefined,
    result: []const u8 = undefined,
    lease: ?loam.Lease = null,
    pending: ?loam.Ticket = null,
    checked: usize = 0,
    bindings: std.ArrayList(Binding) = .empty,
    pub const Binding = struct { ref: driver.Capability, edge: loam.Edge };
    pub const Step = union(enum) { ready, read: loam.Read, waiting };

    pub fn init(call: *hosting.Call, endpoint: *const records.EndpointRecord, sequence: u64, verb: []const u8, args: []const driver.Value, dependent: ?loam.ObjectId) !Mutation {
        var self: Mutation = .{ .call = call, .endpoint = endpoint, .sequence = sequence };
        const items = try call.arena.alloc(driver.Value, args.len + 2);
        items[0] = .{ .string = verb };
        items[1] = .{ .bytes = if (dependent) |target| try call.arena.dupe(u8, &target.key()) else &.{} };
        @memcpy(items[2..], args);
        const request: driver.Value = .{ .list = items };
        try request.forEachCapability(&self, capture);
        self.intent = try records.ValueRecord.encode(call.arena, request, &self);
        return self;
    }

    pub fn advance(self: *Mutation) !Step {
        const receipt_id = (try self.endpoint.mutations.lookup(self.sequence)) orelse return .ready;
        if (self.lease == null) {
            const result = self.call.attachment.store.acquire(receipt_id) catch |err| {
                if (err == error.PendingRead) return .waiting;
                return err;
            };
            switch (result) {
                .read => |read| {
                    self.pending = read.ticket;
                    return .{ .read = read };
                },
                .ready => |lease| self.lease = lease,
            }
        }
        const receipt = try records.MutationRecord.decode(try self.call.attachment.store.currentView(self.lease.?));
        if (!std.mem.eql(u8, receipt.intent, self.intent)) return error.OperationConflict;
        // Receipt custody can outlive a returned managed identity. Prepare its
        // retained fields before replay; a dead result must refuse, never be
        // restored as a newly callable capability or a replacement identity.
        const view = try self.call.attachment.store.currentView(self.lease.?);
        var edges = view.edges();
        var index: usize = 0;
        while (edges.next()) |edge| : (index += 1) {
            if (index < self.checked) continue;
            const acquired = self.call.attachment.store.acquire(edge.target) catch |err| {
                if (err == error.PendingRead) return .waiting;
                return err;
            };
            const lease = switch (acquired) {
                .read => |request| {
                    self.pending = request.ticket;
                    return .{ .read = request };
                },
                .ready => |lease| lease,
            };
            defer self.call.attachment.store.release(lease) catch unreachable;
            const field = try self.call.attachment.store.currentView(lease);
            if (field.schema == records.profile.terminal) {
                _ = try records.TerminalRecord.decode(field);
                return error.CapabilityRetired;
            }
            self.checked += 1;
        }
        self.result = receipt.result;
        return .ready;
    }

    pub fn completeRead(self: *Mutation, ticket: loam.Ticket, result: loam.ReadResult) !void {
        if (self.pending == null or !std.meta.eql(self.pending.?, ticket)) return error.StaleCompletion;
        self.pending = null;
        try self.call.attachment.store.completeRead(ticket, result);
    }

    pub fn deinit(self: *Mutation) void {
        if (self.lease) |lease| self.call.attachment.store.release(lease) catch unreachable;
    }

    pub fn replay(self: *Mutation) !driver.Value {
        self.call.requireDisclosedReply();
        return records.ValueRecord.decode(driver.Value, self.call.arena, self.result, self);
    }

    pub fn retainResult(self: *Mutation, value: driver.Value) !void {
        // Validation precedes capture: an undeclared reply must not gain
        // disclosure merely because the receipt codec retained it.
        _ = try self.call.prepareReply(value, .validate_only);
        try value.forEachCapability(self, capture);
        self.result = try records.ValueRecord.encode(self.call.arena, value, self);
    }

    pub fn stage(self: *Mutation, store: *loam.Store) !void {
        if (store != self.call.attachment.store) return error.ForeignStore;
        const receipt = try store.allocateId();
        const bytes = try (records.MutationRecord{ .intent = self.intent, .result = self.result }).encodeAlloc(self.call.arena);
        var edges: [records.MutationRecord.max_edges]loam.Edge = undefined;
        for (self.bindings.items, edges[0..self.bindings.items.len]) |binding, *edge| edge.* = binding.edge;
        try store.putCopying(.{ .id = receipt, .revision = 0, .schema = records.profile.mutation, .payload = bytes, .edges = edges[0..self.bindings.items.len] }, null);
        var endpoint = self.endpoint.*;
        try endpoint.mutations.append(receipt);
        try service.putEndpoint(store, self.call.arena, self.call.view.id, endpoint, self.call.view.rooted, self.call.view.revision);
    }

    pub fn id(self: *const Mutation, ref: driver.Capability) loam.ObjectId {
        for (self.bindings.items) |binding| if (binding.ref.eql(ref)) return binding.edge.target;
        unreachable; // Both codec passes follow the already-captured value.
    }

    pub fn restore(self: *Mutation, object: loam.ObjectId) !driver.Capability {
        const view = try self.call.attachment.store.currentView(self.lease.?);
        var edges = view.edges();
        var index: usize = 0;
        while (edges.next()) |edge| : (index += 1) if (edge.target.eql(object)) return self.call.discloseHeld(try self.call.storedEdge(view, index));
        return error.InvalidRecord;
    }

    fn capture(self: *Mutation, ref: driver.Capability) !void {
        for (self.bindings.items) |binding| if (binding.ref.eql(ref)) return;
        if (self.bindings.items.len == records.MutationRecord.max_edges) return error.ReceiptCapacity;
        try self.bindings.ensureUnusedCapacity(self.call.arena, 1);
        self.bindings.appendAssumeCapacity(.{ .ref = ref, .edge = try self.call.capture(ref) });
    }
};
