//! Foreign callbacks borrow views. Copied effects remain in the retained call arena.
const std = @import("std");
const common = @import("common.zig");
const c = common.c;
const access = common.access;
const driver = common.driver;
const shared = common.shared;

/// Registration copies the bounded declaration inventory once. Contexts remain
/// borrowed until successful attachment release. Projection child arrays use
/// the existing retained call arena. Payload and argument leaves stay borrowed.
pub const Content = struct {
    allocator: std.mem.Allocator,
    declaration: c.GlowcapLoamContent,
    methods: []c.GlowcapLoamMethod,
    graph: ?access.hosting.graph.Spec = null,
    host: *driver.Host = undefined,
    attachment: *@import("attachment.zig").Attachment = undefined,
    /// Copy names because foreign declaration buffers may die after attach.
    /// At most 64 methods of 256 bytes belong to this registration and are
    /// freed on refused construction or successful detach. Contexts stay borrowed.
    pub fn init(gpa: std.mem.Allocator, raw: c.GlowcapLoamContent) !Content {
        if (raw.requirement == null or raw.invoke == null or raw.method_count == 0 or raw.method_count > 64) return error.InvalidArgument;
        const methods = try gpa.dupe(c.GlowcapLoamMethod, try common.slice(c.GlowcapLoamMethod, raw.methods, raw.method_count));
        var count: usize = 0;
        errdefer {
            for (methods[0..count]) |method| gpa.free(method.verb.?[0..method.verb_len]);
            gpa.free(methods);
        }
        for (methods, 0..) |*method, i| {
            if (method.retry > 2 or method.verb_len == 0 or method.verb_len > 256) return error.InvalidArgument;
            const name = try shared.sliceFromC(method.verb, method.verb_len);
            for (methods[0..i]) |prior| if (std.mem.eql(u8, prior.verb.?[0..prior.verb_len], name)) return error.DuplicateMethod;
            const copy = try gpa.dupe(u8, name);
            method.verb = copy.ptr;
            count += 1;
        }
        const graph = if (raw.graph) |spec| try @import("graph_callbacks.zig").copySpec(gpa, spec.*) else null;
        errdefer if (graph) |spec| @import("graph_callbacks.zig").freeSpec(gpa, spec);
        if (graph) |spec| for (spec.requirement_verbs) |verb| {
            const declared = for (methods) |method| {
                if (std.mem.eql(u8, method.verb.?[0..method.verb_len], verb)) break true;
            } else false;
            if (!declared) return error.UnknownGraphMethod;
        };
        return .{ .allocator = gpa, .declaration = raw, .methods = methods, .graph = graph };
    }
    pub fn deinit(self: *Content) void {
        const gpa = self.allocator;
        for (self.methods) |method| gpa.free(method.verb.?[0..method.verb_len]);
        gpa.free(self.methods);
        if (self.graph) |spec| @import("graph_callbacks.zig").freeSpec(gpa, spec);
    }
    pub fn behavior(self: *Content) access.hosting.ContentBehavior {
        return .{ .schema = self.declaration.schema, .version = self.declaration.version, .graph = self.graph, .context = self, .requirement = requirement, .retry = retry, .invoke = invoke, .references = if (self.declaration.references != null) @import("reference_callbacks.zig").declare else null, .dependent_requirement = if (self.declaration.dependent_requirement != null) dependentRequirement else null, .admit_forward = if (self.declaration.admit_forward != null) admitForward else null };
    }
    fn find(self: *Content, verb: []const u8) !c.GlowcapLoamMethod {
        for (self.methods) |method| if (std.mem.eql(u8, method.verb.?[0..method.verb_len], verb)) return method;
        return error.NoSuchMethod;
    }
};
fn content(ctx: ?*anyopaque) *Content {
    return @ptrCast(@alignCast(ctx.?));
}
/// C child spines occupy the existing bounded retained call arena. Leaves
/// borrow the retained invocation. Direct layout aliasing is impossible because
/// C tags and Host Values differ. No new heap arena or inbound frame pin exists.
pub fn input(arena: std.mem.Allocator, invocation: access.hosting.ContentInvocation, graph: bool) !c.GlowcapLoamInvocation {
    const view = invocation.content;
    const verb = invocation.verb;
    const args = invocation.args;
    const resource = invocation.bound_resource;
    // C resource creation reserves the first strong edge for the managed row.
    // Application field indices omit that binding, so edits cannot replace it.
    const binding = try common.hosting.references.edgeAt(view, 0);
    if (binding.restoration != .object or binding.strength != .strong or !binding.target.eql(resource.object)) return error.InvalidRecord;
    const projected = try arena.alloc(shared.GlowcapArgument, args.len);
    for (args, projected) |value, *target| target.* = try common.host.embedding.valueToC(arena, value);
    var owner: [16]u8 = undefined;
    std.mem.writeInt(u128, &owner, @backingInt(resource.id.owner), .big);
    const pages = try @import("graph_callbacks.zig").project(arena, invocation.graph);
    return .{ .bound_resource = .{ .id = .{ .owner = owner, .slot = resource.id.slot, .generation = resource.id.generation }, .kind = @backingInt(resource.kind), .object = common.objectToC(resource.object), .revision = @backingInt(resource.revision) }, .delivery = if (invocation.delivery == .local) 0 else 1, .content = common.objectToC(view.id), .content_revision = view.revision, .payload = view.payload.ptr, .payload_len = view.payload.len, .verb = verb.ptr, .verb_len = verb.len, .args = projected.ptr, .args_len = projected.len, .field_count = if (graph) 0 else view.edge_count - 1, .graph_prepared = @intFromBool(invocation.graph != null), .pages = pages.ptr, .page_count = pages.len };
}
fn requirement(ctx: ?*anyopaque, arena: std.mem.Allocator, invocation: access.hosting.ContentInvocation) !access.core.Policy.Requirement {
    const registration = content(ctx);
    _ = try registration.find(invocation.verb);
    return requirementWith(registration, registration.declaration.requirement.?, arena, invocation);
}
fn dependentRequirement(ctx: ?*anyopaque, arena: std.mem.Allocator, invocation: access.hosting.ContentInvocation) !access.core.Policy.Requirement {
    const registration = content(ctx);
    return requirementWith(registration, registration.declaration.dependent_requirement.?, arena, invocation);
}
/// Copy fixed callback output into retained arena keys/facts. Admission revisits
/// it after a read, when the callback's output stack is already gone.
fn requirementWith(registration: *Content, callback: c.GlowcapLoamRequirementFn, arena: std.mem.Allocator, invocation: access.hosting.ContentInvocation) !access.core.Policy.Requirement {
    const call = try input(arena, invocation, registration.graph != null);
    var out: c.GlowcapLoamRequirement = std.mem.zeroes(c.GlowcapLoamRequirement);
    const was_in_callback = registration.host.in_callback;
    registration.host.in_callback = true;
    defer registration.host.in_callback = was_in_callback;
    if (callback(registration.declaration.context, &call, &out) != shared.GLOWCAP_OK) return error.ApplicationRefused;
    if (out.permission_count > access.core.Policy.max_permissions or out.fact_count > access.core.Policy.max_constraints) return error.PolicyLimit;
    const permissions = try arena.alloc(access.core.Policy.Key, out.permission_count);
    for (out.permissions[0..out.permission_count], permissions) |key, *target| target.* = @fromBackingInt(key);
    const facts = try arena.alloc(access.core.Policy.Bound, out.fact_count);
    for (out.facts[0..out.fact_count], facts) |fact, *target| target.* = .{ .key = @fromBackingInt(fact.key), .value = fact.value };
    return .{ .permissions = permissions, .facts = facts };
}
fn retry(ctx: ?*anyopaque, verb: []const u8, _: []const driver.Value) !access.hosting.RetryMode {
    return switch ((try content(ctx).find(verb)).retry) {
        0 => .read_only,
        1 => .idempotent,
        2 => .receipt,
        else => unreachable,
    };
}
pub const Call = struct {
    content_call: *access.hosting.ContentCall,
    host: *driver.Host,
    attachment: *@import("attachment.zig").Attachment,
    reply: ?driver.Value = null,
    refused: bool = false,
    active: bool = true,
};
fn invoke(ctx: ?*anyopaque, content_call: *access.hosting.ContentCall, invocation: access.hosting.ContentInvocation) !driver.Value {
    const registration = content(ctx);
    const call_input = try input(content_call.allocator(), invocation, registration.graph != null);
    // The synchronous callback token is borrowed only during this invocation.
    // Replacement and reply setters copy into the retained arena before return.
    var call: Call = .{ .content_call = content_call, .host = registration.host, .attachment = registration.attachment };
    const was_in_callback = registration.host.in_callback;
    registration.host.in_callback = true;
    defer registration.host.in_callback = was_in_callback;
    defer call.active = false;
    if (registration.declaration.invoke.?(registration.declaration.context, @ptrCast(&call), &call_input) != shared.GLOWCAP_OK) return error.ApplicationRefused;
    if (call.refused) return error.ApplicationRefused;
    return call.reply orelse error.MissingReply;
}

fn admitForward(ctx: ?*anyopaque, content_call: *access.hosting.ContentCall, work: access.hosting.ForwardWork) !void {
    const registration = content(ctx);
    var call: Call = .{ .content_call = content_call, .host = registration.host, .attachment = registration.attachment };
    const was_in_callback = registration.host.in_callback;
    registration.host.in_callback = true;
    defer registration.host.in_callback = was_in_callback;
    defer call.active = false;
    if (registration.declaration.admit_forward.?(registration.declaration.context, @ptrCast(&call), work.selector.ptr, work.selector.len, work.method.ptr, work.method.len, work.material_bytes) != shared.GLOWCAP_OK or call.refused) return error.ApplicationRefused;
    if (call.reply != null) return error.InvalidForwarding;
}
fn decodeCapability(call: *Call, ref: shared.GlowcapReference) !driver.Capability {
    return call.host.capabilityFromRaw(ref.id);
}
/// Foreign reply spines and bytes die at callback return. Copy once into the
/// already bounded call arena. Capability identities remain Host-owned and
/// shared disclosure validation runs before the reply escapes.
pub fn reply(raw: ?*c.GlowcapLoamCall, value: ?*const shared.GlowcapArgument) !void {
    const call: *Call = @ptrCast(@alignCast(raw orelse return error.NullPointer));
    if (!call.active or call.reply != null or call.refused) return error.WrongPhase;
    const source = value orelse return error.NullPointer;
    const values = try shared.valuesFromCWith(driver.Value, anyerror, call, decodeCapability, call.content_call.allocator(), @as([*]const shared.GlowcapArgument, @ptrCast(source)), 1, 0, true);
    call.reply = values[0];
}
pub fn replace(raw: ?*c.GlowcapLoamCall, bytes: ?[*]const u8, len: usize) !void {
    const call: *Call = @ptrCast(@alignCast(raw orelse return error.NullPointer));
    if (!call.active) return error.WrongPhase;
    // Content replacement borrows through persistence. Foreign stack/Vec bytes
    // cannot satisfy that lifetime, so this boundary makes its one owned copy.
    const copy = try call.content_call.allocator().dupe(u8, try shared.sliceFromC(bytes, len));
    call.content_call.replace(copy);
}

pub fn disclose(raw: ?*c.GlowcapLoamCall, index: usize, dependent: bool, out: ?*shared.GlowcapArgument) !void {
    const call: *Call = @ptrCast(@alignCast(raw orelse return error.NullPointer));
    if (!call.active) return error.WrongPhase;
    const target = out orelse return error.NullPointer;
    const field = try std.math.add(usize, index, 1);
    const value = if (dependent) try call.content_call.discloseDependent(field) else try call.content_call.discloseExact(field);
    target.* = try common.host.embedding.valueToC(call.content_call.allocator(), value);
}

pub fn editReference(raw: ?*c.GlowcapLoamCall, index: ?usize, replacement: ?shared.GlowcapReference) !void {
    const call: *Call = @ptrCast(@alignCast(raw orelse return error.NullPointer));
    if (!call.active) return error.WrongPhase;
    if (replacement) |ref| {
        const capability = call.host.capabilityFromRaw(ref.id);
        if (index) |field| try call.content_call.replaceReference(try std.math.add(usize, field, 1), capability) else try call.content_call.appendReference(capability);
    } else try call.content_call.removeReference(try std.math.add(usize, index.?, 1));
}
