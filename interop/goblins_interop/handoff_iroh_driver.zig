//! Goblins gifts a Goblins export to the completion-loop recipient over iroh.
//! Assert the capability's home is the exporter, with QUIC identity evidence.
const std = @import("std");
const glowcap = @import("glowcap");
const iroh = @import("iroh");
const goblins_child = @import("goblins_child.zig");
const driver = glowcap.driver;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const ready = try goblins_child.spawnHostAwaitReadiness(io, allocator, init.environ_map, "goblins-handoff-iroh", "introducer", goblins_child.swiss_field, &.{
        "conformance/goblins-peer/racket/handoff-introducer-host.rkt", "--iroh",
    }, .inherit);
    defer allocator.free(ready.block);
    var child = ready.child;
    defer child.kill(io);
    errdefer goblins_child.dumpChildStderr(io, "goblins-handoff-iroh", &child);
    const node_id = goblins_child.extractField(ready.block, "\"node-id\":\"") orelse return error.MissingNodeId;
    const exporter_id = goblins_child.extractField(ready.block, "\"exporter-id\":\"") orelse return error.MissingExporterId;
    const addresses = goblins_child.extractField(ready.block, "\"direct-addresses\":\"") orelse return error.MissingAddresses;
    const swiss = goblins_child.extractField(ready.block, goblins_child.swiss_field) orelse return error.MissingSwiss;

    const seed: [32]u8 = @splat(0xc7);
    var endpoint = try iroh.Resident.init(io, &seed, .{ .reachability = .direct });
    defer endpoint.deinit() catch |err| std.log.err("iroh teardown failed: {s}", .{@errorName(err)});
    var session_root: [32]u8 = undefined;
    try io.randomSecure(&session_root);
    var host = try driver.core.Host.init(allocator, seed, session_root, driver.core.Host.Options.withFrameCap(1 << 16));
    defer host.deinit();
    var state = Recipient{ .host = &host, .swiss = swiss, .exporter_id = exporter_id };
    var loop: Loop = undefined;
    var bridge = Bridge.init(allocator, &host, io, &loop, .{ .on_open = Recipient.onOpen, .on_open_ctx = &state });
    defer bridge.deinit();
    const backend = try iroh.Backend.initBound(allocator, &endpoint, 256, 256, 16 * 1024);
    loop = try Loop.initWithBackend(allocator, backend, Bridge.makePeer, &bridge, Bridge.hookOptions(.{ .max_conns = 4, .listen = 0 }));
    defer loop.deinit();
    defer loop.closeAndDrain() catch |err| std.debug.panic("iroh drain failed: {s}", .{@errorName(err)});
    var id_buf: [iroh.node_id_len]u8 = undefined;
    const own_addresses = try endpoint.directAddrsOwned(allocator);
    defer allocator.free(own_addresses);
    try bridge.attach(model.transport.Known.iroh.metadata(), endpoint.nodeId(&id_buf), own_addresses);
    try bridge.dialOutbound(.{
        .transport = iroh.transport_name,
        .designator = node_id,
        .hints = .{ .entries = &.{.{ .name = iroh.hint_direct_addresses, .value = .{ .string = addresses } }} },
    });
    try loop.runUntil(&state.done, 10_000);
    if (state.failure) |err| return err;
    std.debug.print("goblins-handoff-iroh: Goblins give redeemed on the authenticated exporter session\n", .{});
}

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const Loop = glowcap.net.completion.Loop(iroh.Backend, iroh.DialResolver);
const Bridge = driver.Bridge(Loop);

const Recipient = struct {
    host: *driver.core.Host,
    swiss: []const u8,
    exporter_id: []const u8,
    gifter: ?*driver.core.HostSession = null,
    phase: enum { fetch, refresh, gift, greet } = .fetch,
    introducer: ?model.Reference = null,
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,

    fn onOpen(ctx: ?*anyopaque, bridge: *Bridge, slot: *Bridge.Slot) anyerror!void {
        const self: *Recipient = @ptrCast(@alignCast(ctx.?));
        if (slot.leg != .app_dial) return;
        self.gifter = slot.session;
        const vow = try self.host.fetch(slot.session, self.swiss);
        try self.host.vowOn(vow, .{ .ctx = self, .func = onResolution });
        try bridge.drainActions();
    }

    fn onResolution(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *Recipient = @ptrCast(@alignCast(ctx.?));
        self.advance(resolution) catch |err| {
            self.failure = err;
            self.done.store(true, .release);
        };
    }

    fn advance(self: *Recipient, resolution: actors.Resolution) !void {
        const value = switch (resolution) {
            .fulfilled => |value| value,
            .broken => |reason| {
                std.debug.print("goblins-handoff-iroh: call broke: {s}\n", .{reason});
                return error.CallBroke;
            },
            .give => return error.UnredeemedGive,
        };
        if (self.phase == .greet) {
            if (value != .string or !std.mem.eql(u8, value.string, "Hello Carol, I'm Bob, handed off directly from the exporter!"))
                return error.WrongGreeting;
            self.done.store(true, .release);
            return;
        }
        const gifter = self.gifter orelse return error.MissingGifter;
        if (self.phase == .refresh) {
            if (value != .string or std.mem.indexOf(u8, value.string, ",127.0.0.1:1") == null)
                return error.AddressRefreshFailed;
            const vow = try self.host.send(gifter, self.introducer.?, .{ .verb = "get-greeter", .args = &.{} });
            self.phase = .gift;
            try self.host.vowOn(vow, .{ .ctx = self, .func = onResolution });
            return;
        }
        if (value != .reference) return error.NotAReference;
        if (self.phase == .gift) {
            const route = self.host.node.routeReference(gifter.peer_handle, value.reference) orelse return error.MissingExporterRoute;
            const home = self.host.sessionForPeer(route.peer_handle) orelse return error.MissingExporterSession;
            if (home == gifter) return error.GiftWasProxied;
            const identity = try self.host.partnerIdentity(home);
            if (!std.mem.eql(u8, identity.designator, self.exporter_id)) return error.WrongExporter;
            if (identity.provenance != .authenticated_transport) return error.UnprovenExporter;
            if (std.mem.indexOf(u8, identity.locator_record, ",127.0.0.1:1") == null)
                return error.ExporterKeptOldAdvertisement;
        }
        if (self.phase == .fetch) self.introducer = value.reference;
        const vow = try self.host.send(gifter, value.reference, if (self.phase == .fetch)
            .{ .verb = "refresh-exporter", .args = &.{} }
        else
            .{ .verb = "", .args = &.{.{ .string = "Carol" }} });
        self.phase = if (self.phase == .fetch) .refresh else .greet;
        try self.host.vowOn(vow, .{ .ctx = self, .func = onResolution });
    }
};
