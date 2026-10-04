//! Reference declarations copy into the retained call before callback return.
const std = @import("std");
const common = @import("common.zig");
const callbacks = @import("callbacks.zig");
const c = common.c;
const refs = common.hosting.references;

const Declaration = struct {
    arena: std.mem.Allocator,
    host: *common.driver.Host,
    field_count: usize,
    requests: std.ArrayList(refs.Request) = .empty,
};

pub fn declare(ctx: ?*anyopaque, arena: std.mem.Allocator, view: common.core.RecordView, verb: []const u8, args: []const common.driver.Value) ![]const refs.Request {
    const registration: *callbacks.Content = @ptrCast(@alignCast(ctx.?));
    const input = try callbacks.input(arena, view, verb, args);
    var declaration: Declaration = .{ .arena = arena, .host = registration.host, .field_count = input.field_count };
    const prior = registration.host.in_callback;
    registration.host.in_callback = true;
    defer registration.host.in_callback = prior;
    if (registration.declaration.references.?(registration.declaration.context, @ptrCast(&declaration), &input) != common.shared.GLOWCAP_OK) return error.ApplicationRefused;
    return declaration.requests.items;
}

/// The synchronous declaration borrows C buffers. The retained preparation
/// owns its request spine and at most 514 URI copies of at most 4096 bytes;
/// Host save quotas bound active enlivenment. No callback borrow survives.
pub fn save(raw: ?*c.GlowcapLoamReferences, reference: common.shared.GlowcapReference, uri: ?[*]const u8, uri_len: usize) !void {
    const declaration: *Declaration = @ptrCast(@alignCast(raw orelse return error.NullPointer));
    if (declaration.requests.items.len >= common.max_content_fields or uri_len > 4096) return error.ReferenceCapacity;
    const capability = declaration.host.capabilityFromRaw(reference.id);
    const copied = if (uri != null) try declaration.arena.dupe(u8, try common.shared.sliceFromC(uri, uri_len)) else if (uri_len == 0) null else return error.NullPointer;
    try declaration.requests.append(declaration.arena, .{ .save = .{ .capability = capability, .uri = copied } });
}

pub fn restore(raw: ?*c.GlowcapLoamReferences, index: usize) !void {
    const declaration: *Declaration = @ptrCast(@alignCast(raw orelse return error.NullPointer));
    if (index >= declaration.field_count) return error.NoSuchEdge;
    if (declaration.requests.items.len >= common.max_content_fields) return error.ReferenceCapacity;
    const field = index + 1;
    for (declaration.requests.items) |request| if (request == .restore and request.restore == field) return error.DuplicateReferenceEdit;
    try declaration.requests.append(declaration.arena, .{ .restore = field });
}
