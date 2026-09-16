//! Shared managed endpoint fixture for portable and native persistence tests.
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
const contents = [_]access.ContentBehavior{.{ .schema = 7, .requirement = requirement, .invoke = counter }};

/// An attachment-local capability for the undeclared-disclosure test: the
/// smuggle verb returns it without declaring it, proving the reply check
/// refuses capabilities the method never named (ADR-0172).
pub var smuggle: ?driver.Capability = null;
/// Application-owned authority used to exercise transactional field updates.
/// The callback can only persist it through ContentCall's capture seam.
pub var replacement: ?driver.Capability = null;

fn requirement(_: std.mem.Allocator, _: loam.core.RecordView, verb: []const u8, args: []const driver.Value) !c.core.Policy.Requirement {
    if ((std.mem.eql(u8, verb, "get") or std.mem.startsWith(u8, verb, "share") or std.mem.startsWith(u8, verb, "smuggle")) and args.len == 0) return .{ .permissions = &.{f.vocabulary.read} };
    if ((std.mem.startsWith(u8, verb, "replace-reference") or std.mem.startsWith(u8, verb, "remove-reference")) and args.len == 0) return .{ .permissions = &.{f.vocabulary.post} };
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

fn counter(call: *access.ContentCall, view: loam.core.RecordView, verb: []const u8, args: []const driver.Value) !driver.Value {
    if (view.payload.len != 8) return error.InvalidRecord;
    const old = std.mem.readInt(i64, view.payload[0..8], .little);
    if (std.mem.eql(u8, verb, "get")) return .{ .integer = old };
    if (std.mem.eql(u8, verb, "share-dependent-weak")) return try call.discloseDependent(1);
    if (std.mem.startsWith(u8, verb, "share-dependent")) return wrap(call, verb, try call.discloseDependent(0));
    if (std.mem.eql(u8, verb, "share-weak")) return try call.discloseExact(1);
    if (std.mem.eql(u8, verb, "share-none")) return try call.discloseExact(5);
    if (std.mem.startsWith(u8, verb, "share")) return wrap(call, verb, try call.discloseExact(0));
    if (std.mem.startsWith(u8, verb, "smuggle")) return wrap(call, verb, .{ .capability = smuggle orelse return error.Refused });
    if (std.mem.eql(u8, verb, "replace-reference")) {
        try call.replaceReference(0, replacement orelse return error.Refused);
        return .{ .boolean = true };
    }
    if (std.mem.eql(u8, verb, "replace-reference-weak")) {
        try call.replaceReference(1, replacement orelse return error.Refused);
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
    return seedConfigured(store, backend, depth, policy, bounds, false);
}
pub fn seedIndependentTarget(store: *loam.core.Store, backend: anytype) !Data {
    return seedConfigured(store, backend, 0, try c.core.Policy.init(f.vocabulary.descriptor), &.{}, true);
}
fn seedConfigured(store: *loam.core.Store, backend: anytype, depth: u16, policy: c.core.Policy, bounds: []const c.core.Policy.Bound, independent_target: bool) !Data {
    try store.begin();
    const owner = try c.storage.stage.createOwner(store, @fromBackingInt(81), policy, .{});
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
    var caps = try c.storage.Capabilities.init(a, store, .{});
    defer caps.deinit() catch unreachable;
    const use_descriptor = try c.descriptor(&caps, backend, owner, grant, null, false);
    const control_descriptor = try c.descriptor(&caps, backend, owner, if (independent_target) ancestor else grant, .{ .pause = true, .resume_access = true, .revoke = true, .policy_ceiling = terms }, false);
    const target_use_descriptor = try c.descriptor(&caps, backend, owner, target_grant, null, false);
    const target_control_descriptor = if (independent_target)
        try c.descriptor(&caps, backend, owner, target_grant, .{ .pause = true, .resume_access = true, .revoke = true, .policy_ceiling = terms }, false)
    else
        null;
    try store.begin();
    const content = try store.allocateId();
    const use = try access.stageEndpoint(store, a, .{ .descriptor = use_descriptor, .content = .{ .resource = resource, .object = content } }, true);
    const control = try access.stageEndpoint(store, a, .{ .descriptor = control_descriptor }, true);
    const target_control = if (target_control_descriptor) |descriptor|
        try access.stageEndpoint(store, a, .{ .descriptor = descriptor }, true)
    else
        null;
    // Edge 0 is the stored reference field the share verbs disclose. A weak
    // edge at 1 retains nothing: disclosing it must fail closed.
    const peer = try access.stageEndpoint(store, a, .{ .descriptor = target_use_descriptor, .content = .{ .resource = resource, .object = content } }, false);
    try store.putCopying(.{ .id = content, .revision = 0, .schema = 7, .payload = &@as([8]u8, @splat(0)), .edges = &.{ .{ .target = peer }, .{ .target = control, .strength = .weak } } }, null);
    try f.commit(store, backend);
    return .{ .owner = owner, .resource = resource, .grant = grant, .target_grant = if (independent_target) target_grant else null, .content = content, .use = use, .control = control, .target_control = target_control };
}

pub const Hosted = struct {
    host: driver.Host,
    caps: c.storage.Capabilities,
    service: access.Service,
    behaviors: [1]loam.hosting.Behavior,
    attached: *loam.hosting.Attachment,
    use: driver.Capability,
    control: driver.Capability,

    pub fn init(self: *Hosted, store: *loam.core.Store, backend: anytype, data: Data) !void {
        return self.initOptions(store, backend, data, .{ .sleep_policy = .every_turn });
    }
    pub fn initOptions(self: *Hosted, store: *loam.core.Store, backend: anytype, data: Data, options: loam.hosting.Options) !void {
        self.host = host_support.init(a, @splat(0x61), driver.Host.Options.withFrameCap(4096));
        self.caps = try c.storage.Capabilities.init(a, store, .{});
        self.service = .{ .capabilities = &self.caps, .contents = &contents, .record_capacity = 8 };
        self.behaviors = .{self.service.behavior()};
        self.attached = try loam.hosting.Attachment.create(a, &self.host, store, &self.behaviors, options);
        self.use = try self.restore(backend, data.use);
        self.control = try self.restore(backend, data.control);
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
    pub fn reads(self: *Hosted, backend: anytype) !?loam.core.Batch {
        while (try self.attached.nextWork()) |work| switch (work) {
            .read => |request| try self.attached.completeRead(request.ticket, backend.read(request)),
            .write => |batch| return batch,
        };
        return null;
    }
    pub fn drain(self: *Hosted, backend: anytype) !void {
        for (0..256) |_| {
            _ = try self.host.vat.driveIngressBudgeted(.local, 64);
            try self.attached.advance();
            if (try self.reads(backend)) |batch| try self.attached.completeWrite(batch.ticket, backend.commit(batch));
            if (self.attached.pending_bytes == 0) return;
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
