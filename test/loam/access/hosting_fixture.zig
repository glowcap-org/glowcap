//! Shared managed endpoint fixture for portable and LMDB persistence tests.
const std = @import("std");
pub const c = @import("capability_fixture.zig");
pub const f = c.f;
pub const loam = f.loam;
pub const access = loam.access.hosting;
pub const driver = f.glowcap.driver.core;
pub const actors = f.glowcap.actors;
pub const host_support = @import("../../support/core_host.zig");
pub const a = std.testing.allocator;
pub const schemas = f.schemas ++ [_]loam.core.Schema{loam.hosting.publication.schema};
pub const limits: loam.core.Store.Limits = blk: {
    var value = f.limits;
    value.cache_slots = 48;
    value.max_leases = 48;
    value.resident_bytes = 48 * 64 * 1024;
    break :blk value;
};
pub const contents = [_]access.ContentBehavior{.{ .schema = 7, .requirement = requirement, .retry = retry, .resource = resourceAction, .invoke = counter }};

pub const Application = struct {
    /// Undeclared authority for disclosure refusal scenarios.
    smuggle: ?driver.Capability = null,
    /// Authority captured only through ContentCall's transactional seam.
    replacement: ?driver.Capability = null,
};

fn application(context: ?*anyopaque) !*Application {
    return @ptrCast(@alignCast(context orelse return error.Refused));
}

fn requirement(_: ?*anyopaque, _: std.mem.Allocator, input: access.ContentInvocation) !c.core.Policy.Requirement {
    const verb = input.verb;
    const args = input.args;
    if ((std.mem.eql(u8, verb, "get") or std.mem.startsWith(u8, verb, "share") or std.mem.startsWith(u8, verb, "smuggle")) and args.len == 0) return .{ .permissions = &.{f.vocabulary.read} };
    if ((std.mem.startsWith(u8, verb, "replace-reference") or std.mem.startsWith(u8, verb, "remove-reference")) and args.len == 0) return .{ .permissions = &.{f.vocabulary.post} };
    if (std.mem.eql(u8, verb, "delete-resource") and args.len == 0) return .{ .permissions = &.{f.vocabulary.post} };
    if (std.mem.eql(u8, verb, "move-resource") and args.len == 1 and args[0] == .integer) return .{ .permissions = &.{f.vocabulary.post} };
    if ((std.mem.eql(u8, verb, "add") or std.mem.eql(u8, verb, "fail")) and args.len == 1 and args[0] == .integer) return .{ .permissions = &.{f.vocabulary.post} };
    return error.NoSuchMethod;
}

fn wrap(call: *access.ContentCall, verb: []const u8, value: driver.Value) !driver.Value {
    const allocator = call.allocator();
    if (std.mem.endsWith(u8, verb, "-list") or std.mem.endsWith(u8, verb, "-set")) {
        const items = try allocator.alloc(driver.Value, 1);
        items[0] = value;
        return if (std.mem.endsWith(u8, verb, "-list")) .{ .list = items } else .{ .set = items };
    }
    if (std.mem.endsWith(u8, verb, "-tagged")) {
        const items = try allocator.alloc(driver.Value, 1);
        items[0] = value;
        return .{ .tagged = .{ .tag = "test:disclosure", .value = items } };
    }
    if (std.mem.endsWith(u8, verb, "-struct")) {
        const items = try allocator.alloc(driver.Value.StructEntry, 1);
        items[0] = .{ .key = "capability", .value = value };
        return .{ .@"struct" = items };
    }
    return value;
}

fn counter(context: ?*anyopaque, call: *access.ContentCall, input: access.ContentInvocation) !driver.Value {
    const view = input.content;
    const verb = input.verb;
    const args = input.args;
    if (view.payload.len != 8) return error.InvalidRecord;
    const old = std.mem.readInt(i64, view.payload[0..8], .little);
    if (std.mem.eql(u8, verb, "get")) return .{ .integer = old };
    if (std.mem.eql(u8, verb, "share-dependent-smuggle-exact")) {
        _ = try call.discloseDependent(0);
        return .{ .capability = (try application(context)).smuggle orelse return error.Refused };
    }
    if (std.mem.eql(u8, verb, "replace-reference-smuggle")) {
        const target = (try application(context)).replacement orelse return error.Refused;
        try call.replaceReference(0, target);
        return .{ .capability = target };
    }
    if (std.mem.eql(u8, verb, "share-append-read-only")) {
        try call.appendReference((try application(context)).replacement orelse return error.Refused);
        return .{ .boolean = true };
    }
    if (std.mem.eql(u8, verb, "share-dependent-weak")) return try call.discloseDependent(1);
    if (std.mem.startsWith(u8, verb, "share-dependent")) return wrap(call, verb, try call.discloseDependent(0));
    if (std.mem.eql(u8, verb, "share-weak")) return try call.discloseExact(1);
    if (std.mem.eql(u8, verb, "share-none")) return try call.discloseExact(5);
    if (std.mem.startsWith(u8, verb, "share")) return wrap(call, verb, try call.discloseExact(0));
    if (std.mem.startsWith(u8, verb, "smuggle")) return wrap(call, verb, .{ .capability = (try application(context)).smuggle orelse return error.Refused });
    if (std.mem.eql(u8, verb, "replace-reference")) {
        try call.replaceReference(0, (try application(context)).replacement orelse return error.Refused);
        return .{ .boolean = true };
    }
    if (std.mem.eql(u8, verb, "replace-reference-weak")) {
        try call.replaceReference(1, (try application(context)).replacement orelse return error.Refused);
        return .{ .boolean = true };
    }
    if (std.mem.eql(u8, verb, "remove-reference")) {
        try call.removeReference(0);
        return .{ .boolean = true };
    }
    if (std.mem.eql(u8, verb, "remove-reference-weak")) {
        try call.removeReference(1);
        return .{ .boolean = true };
    }
    if (std.mem.eql(u8, verb, "move-resource") or std.mem.eql(u8, verb, "delete-resource")) {
        const bytes = try call.allocator().alloc(u8, 8);
        std.mem.writeInt(i64, bytes[0..8], try std.math.add(i64, old, 1), .little);
        call.replace(bytes);
        return .{ .boolean = true };
    }
    const next = try std.math.add(i64, old, args[0].integer);
    const bytes = try call.allocator().alloc(u8, 8);
    std.mem.writeInt(i64, bytes[0..8], next, .little);
    call.replace(bytes);
    if (std.mem.eql(u8, verb, "fail")) return error.Refused;
    return .{ .integer = next };
}

pub const Data = struct {
    owner: loam.core.ObjectId,
    resource: c.core.ResourceId,
    grant: c.core.GrantId,
    target_grant: ?c.core.GrantId = null,
    content: loam.core.ObjectId,
    use: loam.core.ObjectId,
    control: loam.core.ObjectId,
    target_control: ?loam.core.ObjectId = null,
};
pub fn seed(store: *loam.core.Store, backend: anytype) !Data {
    return seedDepth(store, backend, 0);
}
pub fn seedDepth(store: *loam.core.Store, backend: anytype, depth: u16) !Data {
    return seedPolicy(store, backend, depth, try c.core.Policy.init(f.vocabulary.descriptor), &.{});
}
pub fn seedPolicy(store: *loam.core.Store, backend: anytype, depth: u16, policy: c.core.Policy, bounds: []const c.core.Policy.Bound) !Data {
    return seedConfigured(store, backend, depth, policy, bounds, false, @fromBackingInt(81));
}
pub fn seedIndependentTarget(store: *loam.core.Store, backend: anytype) !Data {
    return seedConfigured(store, backend, 0, try c.core.Policy.init(f.vocabulary.descriptor), &.{}, true, @fromBackingInt(81));
}
pub fn seedAuthority(store: *loam.core.Store, backend: anytype, owner_id: c.core.OwnerId) !Data {
    return seedConfigured(store, backend, 0, try c.core.Policy.init(f.vocabulary.descriptor), &.{}, false, owner_id);
}
fn seedConfigured(store: *loam.core.Store, backend: anytype, depth: u16, policy: c.core.Policy, bounds: []const c.core.Policy.Bound, independent_target: bool, owner_id: c.core.OwnerId) !Data {
    try store.begin();
    const owner = try c.storage.stage.createOwner(store, owner_id, policy, .{});
    try f.commit(store, backend);
    const resource = try f.resource(store, backend, owner, null);
    const terms: c.core.Terms = .{ .scope = .{ .objects = &.{resource} }, .policy = try policy.value(policy.permission_keys[0..policy.permission_count], bounds) };
    const ancestor = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(terms, if (independent_target) 1 else depth) })).?.grant;
    const grant = if (independent_target)
        (try f.change(store, backend, owner, .{ .derive = .{ .parent = ancestor, .request = f.vocabulary.issue(terms, 0) } })).?.grant
    else
        ancestor;
    const target_grant = if (independent_target)
        (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(terms, depth) })).?.grant
    else
        grant;
    var caps = try c.storage.Capabilities.init(store.allocator, store, .{});
    defer caps.deinit() catch unreachable;
    const use_descriptor = try c.descriptor(&caps, backend, owner, grant, null, false);
    const control_descriptor = try c.descriptor(&caps, backend, owner, if (independent_target) ancestor else grant, .{ .delegate_control = true, .pause = true, .resume_access = true, .revoke = true, .policy_ceiling = terms }, false);
    const target_use_descriptor = try c.descriptor(&caps, backend, owner, target_grant, null, false);
    const target_control_descriptor = if (independent_target)
        try c.descriptor(&caps, backend, owner, target_grant, .{ .delegate_control = true, .pause = true, .resume_access = true, .revoke = true, .policy_ceiling = terms }, false)
    else
        null;
    var endpoint_owner = try c.storage.Read.init(store.allocator, store, owner, 1);
    defer endpoint_owner.deinit() catch unreachable;
    try prepareEndpointOwner(&endpoint_owner, backend, 4);
    const use_lease = try c.load(store, backend, use_descriptor);
    defer store.release(use_lease) catch unreachable;
    const control_lease = try c.load(store, backend, control_descriptor);
    defer store.release(control_lease) catch unreachable;
    const target_use_lease = try c.load(store, backend, target_use_descriptor);
    defer store.release(target_use_lease) catch unreachable;
    const target_control_lease = if (target_control_descriptor) |id| try c.load(store, backend, id) else null;
    defer if (target_control_lease) |held| store.release(held) catch unreachable;
    try store.begin();
    const content = try store.allocateId();
    const use = try access.stageEndpoint(&endpoint_owner, store.allocator, .{ .descriptor = use_descriptor, .content = .{ .resource = resource, .object = content } }, true);
    const control = try access.stageEndpoint(&endpoint_owner, store.allocator, .{ .descriptor = control_descriptor }, true);
    const target_control = if (target_control_descriptor) |descriptor|
        try access.stageEndpoint(&endpoint_owner, store.allocator, .{ .descriptor = descriptor }, true)
    else
        null;
    // Edge 0 is the stored reference field the share verbs disclose. A weak
    // edge at 1 retains nothing: disclosing it must fail closed.
    const peer = try access.stageEndpoint(&endpoint_owner, store.allocator, .{ .descriptor = target_use_descriptor, .content = .{ .resource = resource, .object = content } }, false);
    try store.putCopying(.{ .id = content, .revision = 0, .schema = 7, .payload = &@as([8]u8, @splat(0)), .edges = &.{ .{ .target = peer }, .{ .target = control, .strength = .weak } } }, null);
    try f.commit(store, backend);
    return .{ .owner = owner, .resource = resource, .grant = grant, .target_grant = if (independent_target) target_grant else null, .content = content, .use = use, .control = control, .target_control = target_control };
}

pub fn prepareEndpointOwner(read: *c.storage.Read, backend: anytype, count: usize) !void {
    _ = try f.pump(read, backend);
    for (0..128) |_| {
        read.prepareIdentities(count) catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try f.pump(read, backend);
            continue;
        };
        return;
    }
    return error.NoProgress;
}

pub const Hosted = struct {
    host: driver.Host,
    caps: c.storage.Capabilities,
    service: access.Service,
    application: Application,
    contents: [contents.len]access.ContentBehavior,
    behaviors: [access.Service.behavior_count]loam.hosting.Behavior,
    attached: *loam.hosting.Attachment,
    use: driver.Capability,
    control: driver.Capability,

    pub fn init(self: *Hosted, store: *loam.core.Store, backend: anytype, data: Data) !void {
        return self.initOptions(store, backend, data, .{ .sleep_policy = .every_turn });
    }
    pub fn initOptions(self: *Hosted, store: *loam.core.Store, backend: anytype, data: Data, options: loam.hosting.Options) !void {
        return self.initIdentity(store, backend, data, options, @splat(0x61));
    }
    pub fn initIdentity(self: *Hosted, store: *loam.core.Store, backend: anytype, data: Data, options: loam.hosting.Options, identity: [32]u8) !void {
        return self.open(store, backend, data.use, data.control, options, identity);
    }
    pub fn open(self: *Hosted, store: *loam.core.Store, backend: anytype, use: loam.core.ObjectId, control: loam.core.ObjectId, options: loam.hosting.Options, identity: [32]u8) !void {
        self.host = host_support.init(store.allocator, identity, driver.Host.Options.withFrameCap(4096));
        errdefer self.host.deinit();
        self.caps = try c.storage.Capabilities.init(store.allocator, store, .{});
        errdefer self.caps.deinit() catch unreachable;
        self.application = .{};
        self.contents = contents;
        self.contents[0].context = &self.application;
        self.service = .{ .capabilities = &self.caps, .contents = &self.contents, .record_capacity = 8 };
        self.behaviors = self.service.behaviors();
        self.attached = try loam.hosting.Attachment.create(store.allocator, &self.host, store, &self.behaviors, options);
        errdefer self.attached.destroy() catch unreachable;
        self.use = try self.restore(backend, use);
        errdefer self.host.releaseCapabilityTerminal(self.use, null);
        self.control = try self.restore(backend, control);
    }
    pub fn restore(self: *Hosted, backend: anytype, id: loam.core.ObjectId) !driver.Capability {
        const lease = try c.load(self.caps.store, backend, id);
        defer self.caps.store.release(lease) catch unreachable;
        return self.attached.restore(lease);
    }
    pub fn deinit(self: *Hosted) void {
        self.host.releaseCapability(self.use, 1) catch unreachable;
        self.host.releaseCapability(self.control, 1) catch unreachable;
        self.attached.destroy() catch unreachable;
        self.host.deinit();
        self.caps.deinit() catch unreachable;
    }
    pub fn send(self: *Hosted, ref: driver.Capability, verb: []const u8, args: []const f.glowcap.ocapn.model.Argument, answer: *Answer) !void {
        _ = try self.host.vat.sendObservedFromIngress(.local, self.host.localActorFor(ref).?, .{ .verb = verb, .args = args }, .{ .ctx = answer, .func = Answer.record });
    }
    pub fn mutate(self: *Hosted, ref: driver.Capability, sequence: i64, verb: []const u8, args: []const f.glowcap.ocapn.model.Argument, answer: *Answer) !void {
        const model = f.glowcap.ocapn.model;
        const wrapped = try a.alloc(model.Argument, args.len + 2);
        defer a.free(wrapped);
        wrapped[0] = .{ .integer = sequence };
        wrapped[1] = .{ .string = verb };
        @memcpy(wrapped[2..], args);
        try self.send(ref, "mutate", wrapped, answer);
    }
    pub fn reads(self: *Hosted, backend: anytype) !?loam.core.Batch {
        while (try self.attached.nextWork()) |work| switch (work) {
            .read => |request| try self.attached.completeRead(request.ticket, backend.read(request)),
            .lookup => |request| try self.attached.completeLookup(request.ticket, backend.lookup(request)),
            .write => |batch| return batch,
        };
        return null;
    }
    pub fn drain(self: *Hosted, backend: anytype) !void {
        for (0..256) |_| {
            _ = try self.host.vat.driveIngressBudgeted(.local, 64);
            try self.attached.advance();
            if (try self.reads(backend)) |batch| try self.attached.completeWrite(batch.ticket, backend.commit(batch));
            if (!self.attached.hasPendingWork()) return;
        }
        return error.DidNotQuiesce;
    }
    pub fn untilWrite(self: *Hosted, backend: anytype) !loam.core.Batch {
        for (0..256) |_| {
            _ = try self.host.vat.driveIngressBudgeted(.local, 64);
            try self.attached.advance();
            if (try self.reads(backend)) |batch| return batch;
        }
        return error.DidNotWrite;
    }
};
pub const Answer = struct {
    number: ?i64 = null,
    changed: ?bool = null,
    broken: bool = false,
    reason_buf: [64]u8 = undefined,
    reason_len: usize = 0,
    pub fn record(ctx: ?*anyopaque, result: actors.Resolution) void {
        const self: *Answer = @ptrCast(@alignCast(ctx.?));
        switch (result) {
            .fulfilled => |value| switch (value) {
                .integer => |n| self.number = n,
                .boolean => |b| self.changed = b,
                else => unreachable,
            },
            .broken => |text| {
                self.broken = true;
                self.reason_len = @min(text.len, self.reason_buf.len);
                @memcpy(self.reason_buf[0..self.reason_len], text[0..self.reason_len]);
            },
            .give => self.broken = true,
        }
    }
    /// The recorded break text. Copying in `record` keeps both local and wire
    /// failures comparable after callback return and quiescence.
    pub fn reason(self: *const Answer) []const u8 {
        return self.reason_buf[0..self.reason_len];
    }
};

fn retry(_: ?*anyopaque, verb: []const u8, _: []const driver.Value) !access.RetryMode {
    return if (std.mem.eql(u8, verb, "get") or std.mem.startsWith(u8, verb, "share") or std.mem.startsWith(u8, verb, "smuggle")) .read_only else .receipt;
}

fn resourceAction(_: ?*anyopaque, _: std.mem.Allocator, input: access.ContentInvocation) !?c.storage.ResourceChange.Action {
    const resource = input.bound_resource.id;
    const verb = input.verb;
    const args = input.args;
    if (std.mem.eql(u8, verb, "delete-resource")) return .delete_leaf;
    if (std.mem.eql(u8, verb, "move-resource")) {
        if (args[0].integer < 0) return .{ .move = null };
        return .{ .move = .{ .owner = resource.owner, .slot = std.math.cast(u32, args[0].integer) orelse return error.InvalidArguments, .generation = 1 } };
    }
    return null;
}
