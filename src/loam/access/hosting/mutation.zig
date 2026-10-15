//! Exact mutation replay shares endpoint sequencing and the hosting transaction.
const std = @import("std");
const records = @import("loam_access_records");
const loam = @import("loam_core");
const hosting = @import("loam_hosting");
const driver = @import("driver_core");
const service = @import("service.zig");

pub const Mutation = struct {
    /// The complete inbound argument topology bounds the inner receipt args.
    /// Replay uses the persisted reply topology and borrows its byte leaves.
    pub fn allocationBound(arguments: hosting.ValueBounds, reply: hosting.ValueBounds, dependent: bool) !hosting.references.AllocationBound {
        const key_bytes = @sizeOf(@typeInfo(@TypeOf(loam.ObjectId.key)).@"fn".return_type.?);
        var bound: hosting.references.AllocationBound = .{};
        try bound.include(@sizeOf(Mutation), @alignOf(Mutation), 1);
        try bound.include(try std.math.mul(usize, try std.math.add(usize, arguments.values, 2), @sizeOf(driver.Value)), @alignOf(driver.Value), 1);
        if (dependent) try bound.include(key_bytes, 1, 1);
        const intent = try records.ValueRecord.encodedSizeBound(driver.Value, try std.math.add(usize, arguments.values, 3), arguments.struct_entries, try std.math.add(usize, arguments.bytes, if (dependent) key_bytes else 0), arguments.capabilities);
        const result = try records.ValueRecord.encodedSizeBound(driver.Value, reply.values, reply.struct_entries, reply.bytes, reply.capabilities);
        try bound.include(intent, 1, 1);
        try bound.include(result, 1, 1);
        try bound.include(try records.MutationRecord.encodedSizeBound(intent, result), 1, 1);
        try bound.include(records.EndpointRecord.max_encoded_bytes, 1, 1);
        const bindings = @min(try std.math.add(usize, arguments.capabilities, reply.capabilities), records.MutationRecord.max_edges);
        try bound.includeArrayGrowth(Binding, bindings);
        // Fresh results copy at the foreign boundary. Cold replay allocates
        // typed containers instead; counting both bounds either path's demand.
        var containers = reply;
        containers.bytes = 0;
        try bound.merge(try hosting.valueAllocationBound(driver.Value, containers));
        return bound;
    }
    call: *hosting.Call,
    endpoint: *const records.EndpointRecord,
    sequence: u64,
    intent: []const u8 = undefined,
    result: []const u8 = undefined,
    lease: ?loam.Lease = null,
    pending: ?loam.Ticket = null,
    checked: usize = 0,
    /// The persisted receipt's facet mask, read with its result.
    facets: u64 = 0,
    bindings: std.ArrayList(Binding) = .empty,
    /// What a receipt edge restores. A durable edge restores its own saved
    /// authority. A designated edge names the endpoint a dependent facet
    /// argument pointed at: it identifies the intent and never restores
    /// authority. A facet edge names the endpoint a dependent facet result
    /// pointed at, and replay projects that facet again.
    pub const Binding = struct { ref: driver.Capability, edge: loam.Edge, role: Role = .durable };
    pub const Role = enum { durable, designated, facet };
    pub const Step = union(enum) { ready, read: loam.Read, waiting };

    pub fn init(call: *hosting.Call, endpoint: *const records.EndpointRecord, sequence: u64, verb: []const u8, args: []const driver.Value, dependent: ?loam.ObjectId) !Mutation {
        var self: Mutation = .{ .call = call, .endpoint = endpoint, .sequence = sequence };
        const items = try call.arena().alloc(driver.Value, args.len + 2);
        items[0] = .{ .string = verb };
        items[1] = .{ .bytes = if (dependent) |target| try call.arena().dupe(u8, &target.key()) else &.{} };
        @memcpy(items[2..], args);
        const request: driver.Value = .{ .list = items };
        try request.forEachCapability(&self, captureArgument);
        self.intent = try records.ValueRecord.encode(call.arena(), request, &self);
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
        self.facets = receipt.facets;
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
        return records.ValueRecord.decode(driver.Value, self.call.arena(), self.result, self);
    }

    pub fn retainResult(self: *Mutation, value: driver.Value) !void {
        // Validation precedes capture: an undeclared reply must not gain
        // disclosure merely because the receipt codec retained it.
        _ = try self.call.prepareReply(value, .validate_only);
        try value.forEachCapability(self, capture);
        self.result = try records.ValueRecord.encode(self.call.arena(), value, self);
    }

    /// Retain a reply that is one dependent facet of endpoint `target`, which
    /// this call's own staging created. Replay projects the same facet again.
    pub fn retainFacetResult(self: *Mutation, facet: driver.Capability, target: loam.ObjectId) !void {
        const value: driver.Value = .{ .capability = facet };
        _ = try self.call.prepareReply(value, .validate_only);
        try self.bind(.{ .ref = facet, .edge = .{ .target = target }, .role = .facet });
        self.result = try records.ValueRecord.encode(self.call.arena(), value, self);
    }

    pub fn stage(self: *Mutation, store: *loam.Store) !void {
        if (store != self.call.attachment.store) return error.ForeignStore;
        const receipt = try store.allocateId();
        var edges: [records.MutationRecord.max_edges]loam.Edge = undefined;
        var facets: u64 = 0;
        for (self.bindings.items, edges[0..self.bindings.items.len], 0..) |binding, *edge, index| {
            edge.* = binding.edge;
            if (binding.role == .facet) facets |= @as(u64, 1) << @intCast(index);
        }
        const bytes = try (records.MutationRecord{ .intent = self.intent, .result = self.result, .facets = facets }).encodeAlloc(self.call.arena());
        try store.putCopying(.{ .id = receipt, .revision = 0, .schema = records.profile.mutation, .payload = bytes, .edges = edges[0..self.bindings.items.len] }, null);
        var endpoint = self.endpoint.*;
        try endpoint.mutations.append(receipt);
        try service.putEndpoint(store, self.call.arena(), self.call.view.id, endpoint, self.call.view.rooted, self.call.view.revision);
    }

    pub fn id(self: *const Mutation, ref: driver.Capability) loam.ObjectId {
        for (self.bindings.items) |binding| if (binding.ref.eql(ref)) return binding.edge.target;
        unreachable; // Both codec passes follow the already-captured value.
    }

    pub fn restore(self: *Mutation, object: loam.ObjectId) !driver.Capability {
        const view = try self.call.attachment.store.currentView(self.lease.?);
        var edges = view.edges();
        var index: usize = 0;
        while (edges.next()) |edge| : (index += 1) if (edge.target.eql(object)) {
            const stored = try self.call.storedEdge(view, index);
            const facet = index < 64 and self.facets >> @intCast(index) & 1 != 0;
            return self.call.discloseHeld(if (facet) try self.call.projectDependent(stored) else stored);
        };
        return error.InvalidRecord;
    }

    /// A reply capability must be durable itself, so replay can restore it.
    fn capture(self: *Mutation, ref: driver.Capability) !void {
        for (self.bindings.items) |binding| if (binding.ref.eql(ref)) {
            if (binding.role == .designated) return error.NotDurable;
            return;
        };
        try self.bind(.{ .ref = ref, .edge = try self.call.capture(ref) });
    }

    /// An argument may also be a dependent facet, recorded by what it names.
    fn captureArgument(self: *Mutation, ref: driver.Capability) !void {
        for (self.bindings.items) |binding| if (binding.ref.eql(ref)) return;
        const edge = self.call.capture(ref) catch |err| {
            if (err != error.NotDurable) return err;
            return self.bind(.{ .ref = ref, .edge = .{ .target = try self.call.attachment.designated(ref) }, .role = .designated });
        };
        try self.bind(.{ .ref = ref, .edge = edge });
    }

    fn bind(self: *Mutation, binding: Binding) !void {
        if (self.bindings.items.len == records.MutationRecord.max_edges) return error.ReceiptCapacity;
        try self.bindings.append(self.call.arena(), binding);
    }
};
