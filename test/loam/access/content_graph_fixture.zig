//! One managed content graph application shared by portable and LMDB outcome proofs.
const std = @import("std");
const h = @import("hosting_fixture.zig");
const graph = h.access.graph;
const a = std.testing.allocator;
const spec: graph.Spec = .{ .schemas = &.{.{ .id = 7 }}, .max_pages = 7, .max_payload_bytes = 1024, .max_edges = 32 };

fn resourceObject(store: *h.loam.core.Store, backend: anytype, data: h.Data) !h.loam.core.ObjectId {
    var read: h.c.storage.Read = undefined;
    try read.init(a, store, data.owner, 1, null);
    defer read.deinit() catch unreachable;
    _ = try h.f.pump(&read, backend);
    for (0..128) |_| {
        var view = try read.resourceView();
        _ = view.get(data.resource) catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try h.f.pump(&read, backend);
            continue;
        };
        return (try read.binding(.{ .resource = data.resource })).?.object.?;
    }
    return error.NoProgress;
}

pub fn seed(store: *h.loam.core.Store, backend: anytype) !struct { data: h.Data, resource: h.loam.core.ObjectId } {
    const data = try h.seed(store, backend);
    const resource = try resourceObject(store, backend, data);
    const lease = try h.c.load(store, backend, data.content);
    defer store.release(lease) catch unreachable;
    const view = try store.currentView(lease);
    try store.begin();
    try store.putCopying(.{ .id = view.id, .revision = 0, .schema = view.schema, .payload = view.payload, .edges = &.{.{ .target = resource }} }, view.revision);
    try h.f.commit(store, backend);
    return .{ .data = data, .resource = resource };
}

pub const App = struct {
    held: h.driver.Capability,
    invoked: usize = 0,
    references_available: bool = true,
    fn get(context: ?*anyopaque) *App {
        return @ptrCast(@alignCast(context.?));
    }
    fn requirement(_: ?*anyopaque, _: std.mem.Allocator, input: h.access.ContentInvocation) !h.c.core.Policy.Requirement {
        return .{ .permissions = if (std.mem.eql(u8, input.verb, "get")) &.{h.f.vocabulary.read} else &.{h.f.vocabulary.post} };
    }
    fn retry(_: ?*anyopaque, verb: []const u8, _: []const h.driver.Value) !h.access.RetryMode {
        return if (std.mem.eql(u8, verb, "get")) .read_only else .receipt;
    }
    fn references(context: ?*anyopaque, arena: std.mem.Allocator, input: h.access.ContentInvocation) ![]const h.loam.hosting.references.Request {
        if (!get(context).references_available) return error.ReferencesUnavailable;
        var requests: std.ArrayList(h.loam.hosting.references.Request) = .empty;
        for (input.graph.?.pages, 1..) |page, index| {
            for (1..page.view.edge_count) |field| try requests.append(arena, .{ .restore_record = .{ .record = index, .index = field } });
        }
        if (std.mem.eql(u8, input.verb, "set")) try requests.append(arena, .{ .save = .{ .capability = get(context).held } });
        return requests.items;
    }
    fn invoke(context: ?*anyopaque, call: *h.access.ContentCall, input: h.access.ContentInvocation) !h.driver.Value {
        const self = get(context);
        const snapshot = input.graph orelse return error.UnpreparedGraph;
        if (std.mem.eql(u8, input.verb, "get")) {
            for (snapshot.pages) |*page| {
                if (!(try call.pageReference(page.handle(), 0)).eql(self.held)) return error.WrongField;
                if (!std.mem.eql(u8, page.view.payload, input.content.payload)) return error.InvalidPage;
            }
            return .{ .integer = std.mem.readInt(i64, input.content.payload[0..8], .little) };
        }
        if (!std.mem.eql(u8, input.verb, "set")) return error.NoSuchMethod;
        self.invoked += 1;
        const payload = try call.allocator().alloc(u8, 8);
        std.mem.writeInt(i64, payload[0..8], input.args[0].integer, .little);
        var pages: [6]h.access.GraphPage = undefined;
        const fields = try call.allocator().alloc(h.access.GraphField, 1);
        fields[0] = .{ .held = self.held };
        for (&pages) |*page| page.* = .{ .write = .{ .schema = .{ .id = 7 }, .payload = payload, .fields = fields } };
        try call.replaceGraph(payload, &pages);
        return .{ .boolean = true };
    }
    pub fn behavior(self: *App) h.access.ContentBehavior {
        return .{ .schema = 7, .graph = spec, .context = self, .requirement = requirement, .retry = retry, .references = references, .invoke = invoke };
    }
};

pub fn stamp(store: *h.loam.core.Store, backend: anytype, resource: h.loam.core.ObjectId) !u64 {
    const lease = try h.c.load(store, backend, resource);
    defer store.release(lease) catch unreachable;
    return (try h.loam.access.records.ResourceRecord.decode(try store.currentView(lease))).content.revision;
}
