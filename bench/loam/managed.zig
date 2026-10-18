//! Managed resources share one owner, bounded cache, and the existing Host/Vat.
const std = @import("std");
const g = @import("glowcap");
const loam = g.loam;
const access = loam.access;
const core = access.core;
const driver = g.driver.core;
const w = @import("workload.zig");
const executor = @import("executor.zig");
const setup = @import("managed_setup.zig");

pub const cache_slots = 64;
pub const record_capacity = 32;
pub const max_calls = 8;
const read_key: core.Policy.Key = @fromBackingInt(10);
const edit_key: core.Policy.Key = @fromBackingInt(20);
const descriptor: core.Policy.Descriptor = .{ .id = @fromBackingInt(1), .permissions = &.{ read_key, edit_key } };
const schemas = access.records.profile.schemas ++ [_]loam.core.Schema{ .{ .id = 7, .version = 1, .max_payload = 128, .max_edges = 1 }, loam.hosting.publication.schema, loam.hosting.references.schema };
const max_record_edges = blk: {
    var maximum: usize = 0;
    for (schemas) |schema| maximum = @max(maximum, schema.max_edges);
    break :blk maximum;
};
// Read traverses the DirectoryPage levels before each pinned model row. Outside
// that model budget, a hosted read acquires its endpoint, restored descriptor,
// operation descriptor, owner header and content record.
const directory_levels = @as(usize, std.math.maxInt(@FieldType(access.records.DirectoryPage.Header, "level"))) + 1;
const read_acquisitions_per_call = 5 + record_capacity * (directory_levels + 1);
// Calibration serializes eight read-only calls to one endpoint, then finishes
// collection. Each acquisition can report a cold ID plus its portrait/edges;
// each call also restores one native Binding retention. This does not promise
// admission for arbitrary churn between collection batches.
const collection_window_roots = max_calls * (1 + read_acquisitions_per_call * (2 + max_record_edges));
const contents = [_]access.hosting.ContentBehavior{.{ .schema = 7, .requirement = requirement, .retry = retry, .references = references, .dependent_requirement = requirement, .invoke = content }};

/// This fixture admits an edit envelope, one capability reply and two held
/// occurrences. The shared owners size retained invocation and one restored
/// field. The callback adds its request spine and 128-byte replacement. Native
/// access operations and Store staging retain their separate allocator owners.
pub fn callAllocationBound() !loam.hosting.references.AllocationBound {
    var bound = try access.hosting.invocationAllocationBound(.{
        .arguments = .{ .values = 2, .bytes = "edit".len },
        .reply = .{ .values = 1, .capabilities = 1 },
        .verb_bytes = "dependent".len,
        .held_occurrences = 2,
        .receipt = true,
        .dependent = true,
    });
    try bound.merge(try loam.hosting.references.allocationBound(1, 0, 0));
    try bound.include(@sizeOf(loam.hosting.references.Request), @alignOf(loam.hosting.references.Request), 1);
    try bound.include(128, 1, 1);
    return bound;
}

fn references(_: ?*anyopaque, arena: std.mem.Allocator, input: access.hosting.ContentInvocation) ![]const loam.hosting.references.Request {
    const verb = input.verb;
    if (!std.mem.eql(u8, verb, "exact") and !std.mem.eql(u8, verb, "dependent")) return &.{};
    const requests = try arena.alloc(loam.hosting.references.Request, 1);
    requests[0] = .{ .restore = 0 };
    return requests;
}

fn requirement(_: ?*anyopaque, _: std.mem.Allocator, input: access.hosting.ContentInvocation) !core.Policy.Requirement {
    const verb = input.verb;
    const args = input.args;
    if (args.len != 0) return error.InvalidArguments;
    if (std.mem.eql(u8, verb, "read") or std.mem.eql(u8, verb, "exact") or std.mem.eql(u8, verb, "dependent")) return .{ .permissions = &.{read_key} };
    if (std.mem.eql(u8, verb, "edit")) return .{ .permissions = &.{edit_key} };
    return error.NoSuchMethod;
}

fn content(_: ?*anyopaque, call: *access.hosting.ContentCall, input: access.hosting.ContentInvocation) !driver.Value {
    const view = input.content;
    const verb = input.verb;
    if (view.payload.len != 128) return error.InvalidRecord;
    const old = std.mem.readInt(i64, view.payload[0..8], .little);
    if (std.mem.eql(u8, verb, "read")) return .{ .integer = old };
    if (std.mem.eql(u8, verb, "exact")) return call.discloseExact(0);
    if (std.mem.eql(u8, verb, "dependent")) return call.discloseDependent(0);
    const next = try std.math.add(i64, old, 1);
    const bytes = try call.allocator().dupe(u8, view.payload);
    std.mem.writeInt(i64, bytes[0..8], next, .little);
    call.replace(bytes);
    return .{ .integer = next };
}

pub const Item = struct {
    mutation_sequence: i64 = 1,
    resource: core.ResourceId,
    content: loam.core.ObjectId,
    use: driver.Capability = undefined,
    control: driver.Capability = undefined,
};

pub const Answer = struct {
    number: ?i64 = null,
    changed: ?bool = null,
    reason: [64]u8 = undefined,
    reason_len: usize = 0,
    fn receive(ctx: ?*anyopaque, result: g.actors.Resolution) void {
        const self: *Answer = @ptrCast(@alignCast(ctx.?));
        switch (result) {
            .fulfilled => |value| switch (value) {
                .integer => |n| self.number = n,
                .boolean => |b| self.changed = b,
                else => unreachable,
            },
            .broken => |reason| {
                self.reason_len = @min(reason.len, self.reason.len);
                @memcpy(self.reason[0..self.reason_len], reason[0..self.reason_len]);
            },
            .give => unreachable,
        }
    }
    pub fn requireNumber(self: Answer, expected: i64) !void {
        if (self.number != expected or self.reason_len != 0) {
            std.debug.print("managed reply expected={d} number={any} reason={s}\n", .{ expected, self.number, self.reason[0..self.reason_len] });
            return error.InvalidManagedReply;
        }
    }
    pub fn requireChanged(self: Answer) !void {
        if (self.changed != true or self.reason_len != 0) return error.InvalidManagedReply;
    }
    pub fn requireRevoked(self: Answer) !void {
        if (!std.mem.eql(u8, self.reason[0..self.reason_len], "Revoked")) return error.InvalidRevocation;
    }
};

pub const Managed = struct {
    allocator: std.mem.Allocator,
    db: *w.Lmdb,
    store: loam.core.Store,
    host: driver.Host,
    capabilities: access.storage.Capabilities,
    service: access.hosting.Service,
    behaviors: [access.hosting.Service.behavior_count]loam.hosting.Behavior,
    attachment: *loam.hosting.Attachment,
    owner: loam.core.ObjectId,
    parent_resource: core.ResourceId,
    parent_grant: core.GrantId,
    parent_use: *access.storage.Use,
    items: []Item,
    shared: usize = 0,
    reads: u64 = 0,
    /// Encoded record bytes the executor's reads returned.
    read_bytes: u64 = 0,
    lookups: u64 = 0,
    writes: u64 = 0,

    pub fn init(self: *Managed, allocator: std.mem.Allocator, db: *w.Lmdb, count: usize, depth: u16) !void {
        return self.initIdentity(allocator, db, count, depth, 0x83, try (try callAllocationBound()).physicalBytes());
    }

    /// The held endpoints and the Store limits one run declares. `held`
    /// resources get a use and a control endpoint, and sizes the retention and
    /// grant-child limits. Resources beyond `held` live only in storage.
    pub const Shape = struct {
        held: usize,
        cache_slots: usize = cache_slots,
        resident_bytes: usize = cache_slots * 64 * 1024,
        max_changes: usize = 32,
        staging_bytes: usize = 256 * 1024,

        pub fn population(count: usize) Shape {
            return .{ .held = count };
        }
    };

    pub fn initIdentity(self: *Managed, allocator: std.mem.Allocator, db: *w.Lmdb, count: usize, depth: u16, identity: u8, call_bytes: usize) !void {
        return self.initShaped(allocator, db, .population(count), depth, identity, call_bytes);
    }

    pub fn initShaped(self: *Managed, allocator: std.mem.Allocator, db: *w.Lmdb, shape: Shape, depth: u16, identity: u8, call_bytes: usize) !void {
        const count = shape.held;
        const max_retentions = count * 2 + 32;
        self.* = .{
            .allocator = allocator,
            .db = db,
            .store = try loam.core.Store.init(allocator, db.metadata, &schemas, .{
                .records = .{ .max_record_bytes = 64 * 1024, .max_edges = max_record_edges },
                .cache_slots = shape.cache_slots,
                // Eight admitted preparations each declare record_capacity;
                // two extra slots cover the native issuer's current read.
                .max_leases = max_calls * record_capacity + 2,
                .resident_bytes = shape.resident_bytes,
                .max_changes = shape.max_changes,
                .staging_bytes = shape.staging_bytes,
                .max_retentions = max_retentions,
                // Initial registry/loading/pinned custody plus the declared
                // calibration window. Journal allocation grows only as needed.
                .max_collection_roots = max_retentions + shape.cache_slots * (1 + max_record_edges) + collection_window_roots,
            }),
            .host = undefined,
            .capabilities = undefined,
            .service = undefined,
            .behaviors = undefined,
            .attachment = undefined,
            .owner = undefined,
            .parent_resource = undefined,
            .parent_grant = undefined,
            .parent_use = undefined,
            .items = undefined,
        };
        errdefer self.store.deinit() catch unreachable;
        // Local, socket-free measurement identity; benchmark stores are isolated.
        self.host = try driver.Host.init(allocator, @splat(identity), @splat(identity + 1), driver.Host.Options.withFrameCap(4096));
        errdefer self.host.deinit();
        self.capabilities = try access.storage.Capabilities.init(allocator, &self.store, .{});
        errdefer self.capabilities.deinit() catch unreachable;
        self.service = .{ .capabilities = &self.capabilities, .contents = &contents, .record_capacity = record_capacity };
        self.behaviors = self.service.behaviors();
        self.attachment = try loam.hosting.Attachment.create(allocator, &self.host, &self.store, &self.behaviors, .{
            .max_endpoints = count * 2 + 1,
            .max_calls = max_calls,
            .call_bytes = call_bytes,
            .pending_bytes = try std.math.mul(usize, max_calls, call_bytes),
            .ingress_bytes = try std.math.mul(usize, max_calls, call_bytes),
            .forward_reply_bytes = 512,
        });
        errdefer self.attachment.destroy() catch unreachable;
        self.items = try allocator.alloc(Item, count);
        errdefer allocator.free(self.items);
        const policy = try core.Policy.init(descriptor);
        try self.store.begin();
        self.owner = try access.storage.stage.createOwner(&self.store, @fromBackingInt(1), policy, .{ .max_grant_children = @intCast(count) });
        try self.finish(try self.store.prepare());
        self.parent_resource = try setup.resource(self, null);
        const terms: core.Terms = .{ .scope = .{ .owned_subtree = self.parent_resource }, .policy = try policy.value(&.{ read_key, edit_key }, &.{}) };
        var grant = try setup.issue(self, .{ .issue_root = .{ .ceiling = terms, .configured = terms, .delegation_depth = depth + 1 } });
        for (0..depth) |i| {
            self.parent_resource = try setup.resource(self, self.parent_resource);
            grant = try setup.issue(self, .{ .derive = .{ .parent = grant, .request = .{ .ceiling = terms, .configured = terms, .delegation_depth = depth - @as(u16, @intCast(i)) } } });
        }
        self.parent_grant = grant;
        const parent_descriptor = try setup.descriptor(self, grant, null);
        const lease = try self.load(parent_descriptor);
        defer self.store.release(lease) catch unreachable;
        self.parent_use = try self.capabilities.restoreUse(lease);
    }

    pub fn deinit(self: *Managed) void {
        for (self.items[0..self.shared]) |item| {
            self.host.releaseCapability(item.use, 1) catch unreachable;
            self.host.releaseCapability(item.control, 1) catch unreachable;
        }
        self.parent_use.release();
        self.attachment.destroy() catch unreachable;
        self.host.deinit();
        self.capabilities.deinit() catch unreachable;
        self.store.deinit() catch unreachable;
        self.allocator.free(self.items);
    }

    pub fn create(self: *Managed, index: usize) !void {
        const resource = try setup.resource(self, self.parent_resource);
        try self.store.begin();
        const object = try self.store.allocateId();
        try self.store.putCopying(.{ .id = object, .revision = 0, .schema = 7, .payload = &@as([128]u8, @splat(0)) }, null);
        try self.finish(try self.store.prepare());
        self.items[index] = .{ .resource = resource, .content = object };
    }

    /// Native managed issuance stores separate use/control custody and both
    /// endpoints atomically. Hosted receipt and publication costs are separate.
    pub fn share(self: *Managed, index: usize) !void {
        std.debug.assert(index == self.shared);
        const item = &self.items[index];
        const policy = try core.Policy.init(descriptor);
        const terms: core.Terms = .{ .scope = .{ .object = item.resource }, .policy = try policy.value(&.{ read_key, edit_key }, &.{}) };
        var operation = try self.parent_use.begin(record_capacity);
        defer operation.deinit() catch unreachable;
        try setup.pump(self, operation);
        var prepared = false;
        for (0..128) |_| {
            operation.prepareManagedDeriveCopying(.{ .ceiling = terms, .configured = terms }, .{ .revoke = true, .delegate_control = true }) catch |err| {
                if (err != error.RecordUnloaded) return err;
                try setup.pump(self, operation);
                continue;
            };
            prepared = true;
            break;
        }
        if (!prepared) return error.NoProgress;
        try setup.pump(self, operation);
        try self.store.begin();
        const staged = try self.capabilities.stage(operation, .reachable);
        const use_endpoint = try access.hosting.stageDerivedEndpoint(operation, self.allocator, .{ .descriptor = staged.derived_use.?, .content = .{ .resource = item.resource, .object = item.content } }, .rooted);
        const control_endpoint = try access.hosting.stageDerivedEndpoint(operation, self.allocator, .{ .descriptor = staged.derived_control.? }, .rooted);
        try self.finish(try self.store.prepare());
        item.use = try self.restore(use_endpoint);
        errdefer self.host.releaseCapability(item.use, 1) catch unreachable;
        item.control = try self.restore(control_endpoint);
        self.shared += 1;
    }

    fn restore(self: *Managed, id: loam.core.ObjectId) !driver.Capability {
        const lease = try self.load(id);
        defer self.store.release(lease) catch unreachable;
        return self.attachment.restore(lease);
    }

    pub fn call(self: *Managed, index: usize, verb: []const u8) !Answer {
        var answer: Answer = .{};
        const item = &self.items[index];
        const editing = std.mem.eql(u8, verb, "edit");
        const target = if (std.mem.eql(u8, verb, "revoke")) item.control else item.use;
        const args = [_]g.ocapn.model.Argument{ .{ .integer = item.mutation_sequence }, .{ .string = verb } };
        _ = try self.host.vat.sendObservedFromIngress(.local, self.host.localActorFor(target).?, .{ .verb = if (editing) "mutate" else verb, .args = if (editing) &args else &.{} }, .{ .ctx = &answer, .func = Answer.receive });
        try self.drain();
        if (editing and answer.number != null) item.mutation_sequence += 1;
        return answer;
    }

    /// The workload client reserves one monotonically increasing receipt per
    /// admitted edit. A failed reply aborts the measured run, without reuse.
    pub fn send(self: *Managed, index: usize, verb: []const u8, answer: *w.Answer) !void {
        const item = &self.items[index];
        const editing = std.mem.eql(u8, verb, "edit");
        const args = [_]g.ocapn.model.Argument{ .{ .integer = item.mutation_sequence }, .{ .string = verb } };
        _ = try self.host.vat.sendObservedFromIngress(.local, self.host.localActorFor(item.use).?, .{ .verb = if (editing) "mutate" else verb, .args = if (editing) &args else &.{} }, .{ .ctx = answer, .func = w.Answer.receive });
        if (editing) item.mutation_sequence += 1;
    }

    pub const load = executor.load;
    pub const finish = executor.finish;
    pub const drain = executor.drain;
};

fn retry(_: ?*anyopaque, verb: []const u8, _: []const driver.Value) !access.hosting.RetryMode {
    return if (std.mem.eql(u8, verb, "edit")) .receipt else .read_only;
}
