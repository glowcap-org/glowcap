//! Copy foreign graph candidates into the existing bounded retained call.
const std = @import("std");
const common = @import("common.zig");
const callbacks = @import("callbacks.zig");
const c = common.c;
const graph = common.access.hosting.graph;

/// Graph contribution to call_bytes, including this seam's candidate and
/// payload copies and prepared requirement/reference/invocation projections. Other call
/// owners remain separate. The query allocates nothing and admits no work.
pub fn glowcap_loam_graph_call_size_bound(pages: usize, payload_bytes: usize, fields: usize, out_bytes: ?*usize) callconv(.c) i32 {
    common.shared.lastErrorClear();
    const out = out_bytes orelse return common.shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = 0;
    out.* = callSizeBound(pages, payload_bytes, fields) catch |err| return common.code(err);
    return common.shared.GLOWCAP_OK;
}

fn callSizeBound(pages: usize, payload_bytes: usize, fields: usize) !usize {
    var bound = try common.access.hosting.graphAllocationBound(pages, payload_bytes, fields);
    try bound.include(try std.math.mul(usize, pages, @sizeOf(common.access.hosting.GraphPage)), @alignOf(common.access.hosting.GraphPage), 1);
    try bound.includeTotal(try std.math.mul(usize, fields, @sizeOf(common.access.hosting.GraphField)), @alignOf(common.access.hosting.GraphField), pages);
    try bound.includeTotal(payload_bytes, 1, try std.math.add(usize, pages, 1));
    try bound.merge(try projectionAllocationBound(pages));
    return bound.physicalBytes();
}

pub fn projectionAllocationBound(pages: usize) !common.hosting.references.AllocationBound {
    var bound: common.hosting.references.AllocationBound = .{};
    try bound.include(try std.math.mul(usize, pages, @sizeOf(c.GlowcapLoamPage)), @alignOf(c.GlowcapLoamPage), 3);
    return bound;
}

pub fn copySpec(gpa: std.mem.Allocator, raw: c.GlowcapLoamGraph) !graph.Spec {
    if (raw.schema_count == 0 or raw.schema_count > graph.Spec.max_schemas or raw.max_pages == 0 or raw.max_payload_bytes == 0 or raw.max_edges == 0) return error.InvalidGraphLimits;
    const input = try common.slice(c.GlowcapLoamGraphSchema, raw.schemas, raw.schema_count);
    const schemas = try gpa.alloc(graph.Schema, input.len);
    errdefer gpa.free(schemas);
    for (input, schemas) |schema, *target| target.* = .{ .id = schema.id, .version = schema.version };
    if (raw.requirement_verb_count > graph.Spec.max_requirement_verbs) return error.InvalidGraphLimits;
    const declared = try common.slice(c.GlowcapLoamGraphVerb, raw.requirement_verbs, raw.requirement_verb_count);
    const verbs = try gpa.alloc([]const u8, declared.len);
    errdefer gpa.free(verbs);
    var copied: usize = 0;
    errdefer for (verbs[0..copied]) |verb| gpa.free(verb);
    for (declared, verbs) |source, *target| {
        if (source.verb_len == 0 or source.verb_len > graph.Spec.max_requirement_verb_bytes) return error.InvalidGraphMethod;
        target.* = try gpa.dupe(u8, try common.slice(u8, source.verb, source.verb_len));
        copied += 1;
    }
    return .{ .schemas = schemas, .max_pages = raw.max_pages, .max_payload_bytes = raw.max_payload_bytes, .max_edges = raw.max_edges, .requirement_verbs = verbs };
}

pub fn freeSpec(gpa: std.mem.Allocator, spec: graph.Spec) void {
    gpa.free(spec.schemas);
    for (spec.requirement_verbs) |verb| gpa.free(verb);
    gpa.free(spec.requirement_verbs);
}

/// POD child descriptors copy into the retained arena. Payloads borrow its
/// already prepared snapshot. No page bytes are duplicated at projection.
pub fn project(arena: std.mem.Allocator, snapshot: ?graph.Snapshot) ![]const c.GlowcapLoamPage {
    const prepared = snapshot orelse return &.{};
    const pages = try arena.alloc(c.GlowcapLoamPage, prepared.pages.len);
    for (prepared.pages, pages) |*source, *target| {
        const view = source.view;
        target.* = .{ .handle = @ptrCast(source.handle()), .schema = view.schema, .version = view.schema_version, .payload = view.payload.ptr, .payload_len = view.payload.len, .field_count = view.edge_count - 1 };
    }
    return pages;
}

pub fn reference(raw: ?*c.GlowcapLoamCall, page: ?*const c.GlowcapLoamPageHandle, index: usize, out: ?*common.shared.GlowcapReference) !void {
    const call = try callbacks.active(raw);
    const target = out orelse return error.NullPointer;
    const held = try call.content_call.pageReference(@ptrCast(page orelse return error.NullPointer), index);
    target.* = .{ .id = held.raw() };
}

pub fn savedUri(raw: ?*c.GlowcapLoamCall, page: ?*const c.GlowcapLoamPageHandle, index: usize) !?[]const u8 {
    const call = try callbacks.active(raw);
    return call.content_call.pageSavedUri(@ptrCast(page orelse return error.NullPointer), index);
}

pub fn disclose(raw: ?*c.GlowcapLoamCall, page: ?*const c.GlowcapLoamPageHandle, index: usize, dependent: bool, out: ?*common.shared.GlowcapArgument) !void {
    const call = try callbacks.active(raw);
    const target = out orelse return error.NullPointer;
    const value = try call.content_call.disclosePage(@ptrCast(page orelse return error.NullPointer), index, dependent);
    target.* = try common.host.embedding.valueToC(call.content_call.allocator(), value);
}

/// Foreign payloads and field buffers die at callback return. This one copy
/// charges both payloads and candidate spines to the retained call arena. Shared
/// shape validation and capture remain the authority. No second heap owner or
/// transaction engine is introduced at the ABI boundary.
pub fn replaceCopying(raw: ?*c.GlowcapLoamCall, bytes: ?[*]const u8, len: usize, input: ?[*]const c.GlowcapLoamPageReplacement, count: usize) !void {
    const call = try callbacks.active(raw);
    const limits = call.content_call.graphLimits() orelse return error.NotContentGraph;
    if (count > limits.max_pages or len > limits.max_payload_bytes) return error.GraphCapacity;
    const source = try common.slice(c.GlowcapLoamPageReplacement, input, count);
    const arena = call.content_call.allocator();
    const pages = try arena.alloc(common.access.hosting.GraphPage, count);
    var payload_bytes = len;
    var edge_count = try std.math.add(usize, count, 1);
    for (source, pages) |page, *target| {
        if (page.keep) |handle| {
            if (page.schema != 0 or page.version != 0 or page.field_count != 0 or page.fields != null) return error.InvalidArgument;
            if (page.payload) |body| {
                payload_bytes = try std.math.add(usize, payload_bytes, page.payload_len);
                if (payload_bytes > limits.max_payload_bytes) return error.GraphCapacity;
                target.* = .{ .update = .{ .page = @ptrCast(handle), .payload = body[0..page.payload_len] } };
            } else {
                if (page.payload_len != 0) return error.InvalidArgument;
                target.* = .{ .keep = @ptrCast(handle) };
            }
        } else {
            payload_bytes = try std.math.add(usize, payload_bytes, page.payload_len);
            edge_count = try std.math.add(usize, edge_count, try std.math.add(usize, page.field_count, 1));
            if (payload_bytes > limits.max_payload_bytes or edge_count > limits.max_edges) return error.GraphCapacity;
            const fields = try arena.alloc(common.access.hosting.GraphField, page.field_count);
            const references = try common.slice(c.GlowcapLoamGraphField, page.fields, page.field_count);
            for (references, fields) |reference_field, *field| {
                if (reference_field.page) |retained| {
                    if (reference_field.reference.id != 0) return error.InvalidArgument;
                    field.* = .{ .retained = .{ .page = @ptrCast(retained), .index = reference_field.index } };
                } else {
                    if (reference_field.index != 0) return error.InvalidArgument;
                    field.* = .{ .held = call.host.capabilityFromRaw(reference_field.reference.id) };
                }
            }
            target.* = .{ .write = .{ .schema = .{ .id = page.schema, .version = page.version }, .payload = try common.shared.sliceFromC(page.payload, page.payload_len), .fields = fields } };
        }
    }
    const root_payload = try common.shared.sliceFromC(bytes, len);
    try call.content_call.validateGraph(root_payload, pages);
    const root_copy = try arena.dupe(u8, root_payload);
    for (pages) |*page| switch (page.*) {
        .keep => {},
        .update => |*update| update.payload = try arena.dupe(u8, update.payload),
        .write => |*write| write.payload = try arena.dupe(u8, write.payload),
    };
    try call.content_call.replaceGraph(root_copy, pages);
}
