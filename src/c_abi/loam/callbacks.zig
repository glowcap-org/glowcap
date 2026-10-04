//! Foreign callbacks borrow views; copied effects remain in the retained call arena.
const std = @import("std");
const common = @import("common.zig");
const c = common.c;
const core = common.core;
const access = common.access;
const driver = common.driver;
const shared = common.shared;

/// Registration copies the bounded declaration inventory once. Contexts remain
/// borrowed until successful attachment release. Projection child arrays use
/// the existing retained call arena; payload and argument leaves stay borrowed.
pub const Content = struct {
    allocator: std.mem.Allocator,
    declaration: c.GlowcapLoamContent,
    methods: []c.GlowcapLoamMethod,
    host: *driver.Host = undefined,
    /// Copy names because foreign declaration buffers may die after attach.
    /// At most 64 methods of 256 bytes belong to this registration and are
    /// freed on refused construction or successful detach; contexts stay borrowed.
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
        return .{ .allocator = gpa, .declaration = raw, .methods = methods };
    }
    pub fn deinit(self: *Content) void {
        const gpa = self.allocator;
        for (self.methods) |method| gpa.free(method.verb.?[0..method.verb_len]);
        gpa.free(self.methods);
    }
    pub fn behavior(self: *Content) access.hosting.ContentBehavior {
        return .{ .schema = self.declaration.schema, .version = self.declaration.version, .context = self, .requirement = requirement, .retry = retry, .invoke = invoke, .references = if (self.declaration.references != null) @import("reference_callbacks.zig").declare else null, .dependent_requirement = if (self.declaration.dependent_requirement != null) dependentRequirement else null };
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
/// borrow the retained invocation; direct layout aliasing is impossible because
/// C tags and Host Values differ. No new heap arena or inbound frame pin exists.
pub fn input(arena: std.mem.Allocator, view: core.RecordView, verb: []const u8, args: []const driver.Value) !c.GlowcapLoamInvocation {
    // C resource creation reserves the first strong edge for the managed row.
    // Application field indices omit that binding, so edits cannot replace it.
    const binding = try common.hosting.references.edgeAt(view, 0);
    if (binding.restoration != .object) return error.InvalidRecord;
    const projected = try arena.alloc(shared.GlowcapArgument, args.len);
    for (args, projected) |value, *target| target.* = try common.host.embedding.valueToC(arena, value);
    return .{ .payload = view.payload.ptr, .payload_len = view.payload.len, .verb = verb.ptr, .verb_len = verb.len, .args = projected.ptr, .args_len = projected.len, .field_count = view.edge_count - 1 };
}
fn requirement(ctx: ?*anyopaque, arena: std.mem.Allocator, view: core.RecordView, verb: []const u8, args: []const driver.Value) !access.core.Policy.Requirement {
    const registration = content(ctx);
    _ = try registration.find(verb);
    return requirementWith(registration, registration.declaration.requirement.?, arena, view, verb, args);
}
fn dependentRequirement(ctx: ?*anyopaque, arena: std.mem.Allocator, view: core.RecordView, verb: []const u8, args: []const driver.Value) !access.core.Policy.Requirement {
    const registration = content(ctx);
    return requirementWith(registration, registration.declaration.dependent_requirement.?, arena, view, verb, args);
}
/// Copy fixed callback output into retained arena keys/facts. Admission revisits
/// it after a read, when the callback's output stack is already gone.
fn requirementWith(registration: *Content, callback: c.GlowcapLoamRequirementFn, arena: std.mem.Allocator, view: core.RecordView, verb: []const u8, args: []const driver.Value) !access.core.Policy.Requirement {
    const call = try input(arena, view, verb, args);
    var out: c.GlowcapLoamRequirement = std.mem.zeroes(c.GlowcapLoamRequirement);
    const was_in_callback = registration.host.in_callback;
    registration.host.in_callback = true;
    defer registration.host.in_callback = was_in_callback;
    if (callback(registration.declaration.context, &call, &out) != shared.GLOWCAP_OK) return error.ApplicationRefused;
    if (out.permission_count > 64 or out.fact_count > 16) return error.PolicyLimit;
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
    reply: ?driver.Value = null,
    active: bool = true,
};
fn invoke(ctx: ?*anyopaque, content_call: *access.hosting.ContentCall, view: core.RecordView, verb: []const u8, args: []const driver.Value) !driver.Value {
    const registration = content(ctx);
    const call_input = try input(content_call.allocator(), view, verb, args);
    // The synchronous callback token is borrowed only during this invocation.
    // Replacement and reply setters copy into the retained arena before return.
    var call: Call = .{ .content_call = content_call, .host = registration.host };
    const was_in_callback = registration.host.in_callback;
    registration.host.in_callback = true;
    defer registration.host.in_callback = was_in_callback;
    defer call.active = false;
    if (registration.declaration.invoke.?(registration.declaration.context, @ptrCast(&call), &call_input) != shared.GLOWCAP_OK) return error.ApplicationRefused;
    return call.reply orelse error.MissingReply;
}
fn decodeCapability(call: *Call, ref: shared.GlowcapReference) !driver.Capability {
    return call.host.capabilityFromRaw(ref.id);
}
/// Foreign reply spines and bytes die at callback return. Copy once into the
/// already bounded call arena; capability identities remain Host-owned and
/// shared disclosure validation runs before the reply escapes.
pub fn reply(raw: ?*c.GlowcapLoamCall, value: ?*const shared.GlowcapArgument) !void {
    const call: *Call = @ptrCast(@alignCast(raw orelse return error.NullPointer));
    if (!call.active or call.reply != null) return error.WrongPhase;
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
