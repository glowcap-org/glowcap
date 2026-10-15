//! A managed tree served to a real CapTP caller: hosted calls create a child,
//! share a listed node, and move a node between two others in one batch.
const std = @import("std");
pub const s = @import("sharing_fixture.zig");
pub const h = s.h;
pub const c = h.c;
pub const f = h.f;
const access = h.access;
const driver = h.driver;

/// Every node is schema 7: an 8-byte counter plus one strong field per child.
pub const contents = [_]access.ContentBehavior{.{ .schema = 7, .requirement = requirement, .retry = retry, .participants = participants, .resource = resource, .create = create, .invoke = invoke }};

pub const Tree = struct {
    server: h.Hosted,
    client: s.Client,
    contents: [contents.len]access.ContentBehavior = contents,
    /// The owner's canonical use descriptor, which every created child's
    /// endpoint is stored under.
    descriptor: h.loam.core.ObjectId,

    pub fn init(self: *Tree, store: *h.loam.core.Store, backend: anytype, data: h.Data) !void {
        const lease = try c.load(store, backend, data.use);
        self.descriptor = (try h.loam.access.records.EndpointRecord.decode(try store.currentView(lease))).descriptor;
        try store.release(lease);
        try self.server.init(store, backend, data);
        errdefer self.server.deinit();
        self.contents = contents;
        self.server.service.contents = &self.contents;
        self.server.service.context = self;
        self.server.service.child_descriptor = childDescriptor;
        try self.client.init(&self.server);
    }

    pub fn deinit(self: *Tree) void {
        self.client.deinit();
        self.server.deinit();
    }

    pub fn call(self: *Tree, backend: anytype, target: s.model.Reference, verb: []const u8, args: []const s.model.Argument, capture: anytype) !void {
        try self.client.send(target, verb, args, capture);
        try self.server.drain(backend);
        try self.client.pump();
    }

    pub fn mutate(self: *Tree, backend: anytype, target: s.model.Reference, sequence: i64, verb: []const u8, args: []const s.model.Argument, capture: anytype) !void {
        var wrapped: [4]s.model.Argument = undefined;
        wrapped[0] = .{ .integer = sequence };
        wrapped[1] = .{ .string = verb };
        @memcpy(wrapped[2 .. 2 + args.len], args);
        try self.call(backend, target, "mutate", wrapped[0 .. 2 + args.len], capture);
    }

    /// Create a child under `target` and return the facet the call replies with.
    pub fn add(self: *Tree, backend: anytype, target: s.model.Reference, sequence: i64) !s.model.Reference {
        var answer: s.captures.CapturedRef = .{};
        try self.mutate(backend, target, sequence, "add", &.{}, &answer);
        return answer.require();
    }

    /// The listed node at field `index`, as the dependent facet a reader holds.
    pub fn open(self: *Tree, backend: anytype, target: s.model.Reference, index: i64) !s.model.Reference {
        var answer: s.captures.CapturedRef = .{};
        try self.call(backend, target, "open", &.{.{ .integer = index }}, &answer);
        return answer.require();
    }

    pub fn count(self: *Tree, backend: anytype, target: s.model.Reference) !i64 {
        var answer: s.captures.CapturedInt = .{};
        try self.call(backend, target, "count", &.{}, &answer);
        return answer.value orelse error.VowDidNotSettle;
    }
};

/// The resources the owner's latest change batch names, in effect order.
pub const Latest = struct {
    moved: usize = 0,
    created: usize = 0,
    content: usize = 0,
};

pub fn latest(store: *h.loam.core.Store, backend: anytype, owner: h.loam.core.ObjectId) !Latest {
    var read = try c.storage.Read.init(store.allocator, store, owner, 4);
    defer read.deinit() catch unreachable;
    read.history_requested = true;
    _ = try f.pump(&read, backend);
    if (read.history.count == 0) return error.MissingHistory;
    const lease = try c.load(store, backend, read.history.batches[read.history.count - 1]);
    defer store.release(lease) catch unreachable;
    var batch = try h.loam.access.records.ChangeBatchRecord.decodeOwned(store.allocator, try store.currentView(lease));
    defer batch.deinit(store.allocator);
    var result: Latest = .{};
    for (batch.value.effects) |effect| switch (effect) {
        .resource => |change| switch (change.kind) {
            .moved => result.moved += 1,
            .created => result.created += 1,
            .deleted => {},
        },
        .content => result.content += 1,
        else => {},
    };
    return result;
}

/// An integer reply, or the reason the call broke.
pub const Outcome = struct {
    value: ?i64 = null,
    reason_buf: [64]u8 = undefined,
    reason_len: usize = 0,

    pub fn record(ctx: ?*anyopaque, resolution: h.actors.Resolution) void {
        const self: *Outcome = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .fulfilled => |value| if (value == .integer) {
                self.value = value.integer;
            },
            .broken => |text| {
                self.reason_len = @min(text.len, self.reason_buf.len);
                @memcpy(self.reason_buf[0..self.reason_len], text[0..self.reason_len]);
            },
            .give => {},
        }
    }

    pub fn reason(self: *const Outcome) []const u8 {
        return self.reason_buf[0..self.reason_len];
    }
};

fn childDescriptor(context: ?*anyopaque, _: c.core.OwnerId) ?h.loam.core.ObjectId {
    const self: *Tree = @ptrCast(@alignCast(context.?));
    return self.descriptor;
}

fn requirement(_: ?*anyopaque, _: std.mem.Allocator, input: access.ContentInvocation) !c.core.Policy.Requirement {
    if (std.mem.eql(u8, input.verb, "count") or std.mem.eql(u8, input.verb, "open")) return .{ .permissions = &.{f.vocabulary.read} };
    if (std.mem.eql(u8, input.verb, "add") or std.mem.startsWith(u8, input.verb, "move") or std.mem.eql(u8, input.verb, "bump-both")) return .{ .permissions = &.{f.vocabulary.post} };
    return error.NoSuchMethod;
}

fn retry(_: ?*anyopaque, verb: []const u8, _: []const driver.Value) !access.RetryMode {
    return if (std.mem.eql(u8, verb, "count") or std.mem.eql(u8, verb, "open")) .read_only else .receipt;
}

fn fieldArgument(args: []const driver.Value) !usize {
    if (args.len == 0 or args[0] != .integer) return error.InvalidArguments;
    return std.math.cast(usize, args[0].integer) orelse error.InvalidArguments;
}

/// `move node destination` names the moved node and the destination by
/// capability arguments, and the node must be one of this node's fields.
/// `bump-both index` changes two content records.
fn participants(_: ?*anyopaque, arena: std.mem.Allocator, input: access.ContentInvocation) ![]const access.Participant {
    const post: c.core.Policy.Requirement = .{ .permissions = &.{f.vocabulary.post} };
    if (std.mem.startsWith(u8, input.verb, "move")) {
        const declared = try arena.alloc(access.Participant, 2);
        declared[0] = .{ .source = .{ .argument = 0 }, .requirement = post };
        declared[1] = .{ .source = .{ .argument = 1 }, .requirement = post };
        return declared;
    }
    if (std.mem.eql(u8, input.verb, "bump-both")) {
        const declared = try arena.alloc(access.Participant, 1);
        declared[0] = .{ .source = .{ .field = try fieldArgument(input.args) }, .requirement = post };
        return declared;
    }
    return &.{};
}

fn resource(_: ?*anyopaque, _: std.mem.Allocator, input: access.ContentInvocation) !?access.ResourceEffect {
    if (!std.mem.startsWith(u8, input.verb, "move")) return null;
    return .{ .target = .{ .participant = 0 }, .action = .{ .move = input.participants[1].resource.id } };
}

fn create(_: ?*anyopaque, _: std.mem.Allocator, input: access.ContentInvocation) !?access.Creation {
    if (!std.mem.eql(u8, input.verb, "add")) return null;
    return .{ .kind = f.vocabulary.kind, .schema = 7 };
}

fn counter(call: *access.ContentCall, view: h.loam.core.RecordView) !void {
    if (view.payload.len != 8) return error.InvalidRecord;
    const bytes = try call.allocator().alloc(u8, 8);
    std.mem.writeInt(i64, bytes[0..8], std.mem.readInt(i64, view.payload[0..8], .little) + 1, .little);
    call.replace(bytes);
}

fn invoke(_: ?*anyopaque, call: *access.ContentCall, input: access.ContentInvocation) !driver.Value {
    const verb = input.verb;
    if (std.mem.eql(u8, verb, "count")) return .{ .integer = @intCast(input.content.edge_count) };
    if (std.mem.eql(u8, verb, "open")) return call.discloseDependent(try fieldArgument(input.args));
    if (std.mem.eql(u8, verb, "add")) {
        try call.createChild(&@as([8]u8, @splat(0)));
        return .void;
    }
    if (std.mem.eql(u8, verb, "bump-both")) {
        try counter(call, input.content);
        try counter(try call.participant(0), input.participants[0].content);
        return .{ .integer = 1 };
    }
    // The moved node leaves this node's fields and joins the destination's.
    const index = input.participants[0].field orelse return error.NotListed;
    try call.removeReference(index);
    try (try call.participant(1)).appendReference(try call.reference(index));
    if (std.mem.eql(u8, verb, "move-fail")) return error.Refused;
    return .{ .integer = @intCast(input.participants[1].content.edge_count + 1) };
}
