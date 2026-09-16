//! A real CapTP caller driving the same derivation path on either backend.
const std = @import("std");
pub const h = @import("hosting_fixture.zig");
pub const captures = @import("../../support/capture.zig");
pub const pairs = @import("../../support/host_pair.zig");
pub const model = h.f.glowcap.ocapn.model;

pub const Client = struct {
    host: h.driver.Host,
    pair: pairs.Pair,
    parent: model.Reference,
    entropy_counter: u64 = 100,

    pub fn init(self: *Client, server: *h.Hosted) !void {
        server.service.decode_derive = decode;
        server.service.entropy = .{ .context = &self.entropy_counter, .fill = entropy };
        self.host = h.host_support.init(h.a, @splat(0x63), h.driver.Host.Options.withFrameCap(4096));
        self.pair = try pairs.openPair(&self.host, &server.host, "127.0.0.1:9731");
        const swiss = try server.host.publishDurableCapability(@splat(0x53), server.use);
        var capture: captures.CapturedRef = .{};
        try self.host.vowOn(try self.host.fetch(self.pair.a, swiss.slice()), .{ .ctx = &capture, .func = captures.CapturedRef.record });
        try self.pump();
        self.parent = try capture.require();
    }
    pub fn deinit(self: *Client) void {
        self.host.deinit();
    }
    pub fn pump(self: *Client) !void {
        try pairs.pumpToQuiescence(&.{self.pair});
    }
    pub fn send(self: *Client, target: model.Reference, verb: []const u8, args: []const model.Argument, capture: anytype) !void {
        try self.host.vowOn(try self.host.send(self.pair.a, target, .{ .verb = verb, .args = args }), .{ .ctx = capture, .func = @TypeOf(capture.*).record });
        try self.pump();
    }
    pub fn derive(self: *Client, server: *h.Hosted, backend: anytype, sequence: i64, permissions: i64, depth: i64) !model.Reference {
        var answer: captures.CapturedRef = .{};
        try self.send(self.parent, "derive", &.{ .{ .integer = sequence }, .{ .integer = permissions }, .{ .integer = depth } }, &answer);
        try server.drain(backend);
        try self.pump();
        return answer.require();
    }
};

fn decode(_: std.mem.Allocator, resource: h.c.core.ResourceId, args: []const h.driver.Value) !h.c.core.GrantLedger.Issue {
    if ((args.len != 2 and args.len != 3) or args[0] != .integer or args[1] != .integer) return error.InvalidArguments;
    const permissions: []const h.c.core.Policy.Key = if (args[0].integer == 0) &.{h.f.vocabulary.read} else &.{ h.f.vocabulary.read, h.f.vocabulary.post };
    const terms = try h.f.vocabulary.terms(.{ .object = resource }, permissions, null);
    var request = h.f.vocabulary.issue(terms, std.math.cast(u16, args[1].integer) orelse return error.InvalidArguments);
    if (args.len == 3) {
        if (args[2] != .boolean) return error.InvalidArguments;
        request.initial_status = if (args[2].boolean) .paused else .active;
    }
    return request;
}

/// Trusted owner inspection, solely to mutate the exact returned child's grant.
pub fn publishedGrant(server: *h.Hosted, backend: anytype, session: *h.driver.HostSession, name: []const u8) !h.c.core.GrantId {
    const ref = (try server.host.publishedCapability(session, name)) orelse return error.NotPublished;
    defer server.host.releaseCapability(ref, 1) catch unreachable;
    const store = server.caps.store;
    const edge = try server.attached.capture(ref);
    const endpoint_lease = try h.c.load(store, backend, edge.target);
    defer store.release(endpoint_lease) catch unreachable;
    const endpoint = try h.loam.access.records.EndpointRecord.decode(try store.currentView(endpoint_lease));
    const descriptor_lease = try h.c.load(store, backend, endpoint.descriptor);
    defer store.release(descriptor_lease) catch unreachable;
    var descriptor = try h.loam.access.records.CapabilityRecord.decodeOwned(h.a, try store.currentView(descriptor_lease));
    defer descriptor.deinit(h.a);
    return descriptor.value.grant;
}
fn entropy(context: ?*anyopaque, bytes: *h.driver.Host.DurableSwiss.Entropy) !void {
    const counter: *u64 = @ptrCast(@alignCast(context.?));
    counter.* += 1;
    @memset(bytes, 0);
    std.mem.writeInt(u64, bytes[0..8], counter.*, .big);
}
