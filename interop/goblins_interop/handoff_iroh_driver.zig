//! Goblins gifts a Goblins export to a glowcap recipient over iroh. Assert the
//! capability's home is the exporter, with QUIC identity evidence.
const std = @import("std");
const glowcap = @import("glowcap");
const iroh = @import("iroh");
const goblins_child = @import("goblins_child.zig");

const driver = glowcap.driver;

const opts: driver.SessionOptions = .{
    .frame_cap = 1 << 16,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

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

    var endpoint = try iroh.Resident.init(io, null, .{ .reachability = .direct });
    defer endpoint.deinit() catch |err| std.log.err("iroh teardown failed: {s}", .{@errorName(err)});
    var adapter = try iroh.MultiplexedAdapter.init(allocator, &endpoint);
    defer if (adapter.deinit()) |failure| std.log.err("iroh adapter: {s}", .{failure.primaryName()});
    const providers = [_]driver.HostRuntime.ProviderRegistration{.{ .profile = iroh.transport_profile, .resident = adapter.multiplexed() }};

    const gifter = try driver.connect(allocator, io, .{ .residents = &providers }, .{
        .transport = iroh.transport_name,
        .designator = node_id,
        .hints = .{ .entries = &.{.{ .name = iroh.hint_direct_addresses, .value = .{ .string = addresses } }} },
    }, .ephemeral, opts);
    defer gifter.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const introducer = try gifter.fetch(swiss);
    const refreshed = try expectFulfilled(try gifter.call(introducer, "refresh-exporter", &.{}, arena));
    if (refreshed != .string or std.mem.indexOf(u8, refreshed.string, ",127.0.0.1:1") == null)
        return error.AddressRefreshFailed;

    // The answer is a give naming the exporter. The call returns once this
    // runtime has dialed the exporter over iroh and withdrawn the gift.
    const greeter = switch (try expectFulfilled(try gifter.call(introducer, "get-greeter", &.{}, arena))) {
        .capability => |capability| capability,
        else => return error.NotAReference,
    };
    try expectExporterHome(gifter, greeter, exporter_id);

    const greeting = try expectFulfilled(try gifter.call(greeter, "", &.{.{ .string = "Carol" }}, arena));
    if (greeting != .string or !std.mem.eql(u8, greeting.string, "Hello Carol, I'm Bob, handed off directly from the exporter!"))
        return error.WrongGreeting;
    std.debug.print("goblins-handoff-iroh: Goblins give redeemed on the authenticated exporter session\n", .{});
}

fn expectFulfilled(reply: driver.Reply) !driver.Value {
    return switch (reply) {
        .fulfilled => |value| value,
        .broken => |reason| {
            std.debug.print("goblins-handoff-iroh: call broke: {s}\n", .{reason});
            return error.CallBroke;
        },
    };
}

/// The withdrawn capability lives on its own session to the exporter, whose
/// durable identity the QUIC channel proved, and that session carries the
/// exporter's refreshed advertisement rather than the one the give named.
fn expectExporterHome(gifter: *driver.Session, greeter: driver.Capability, exporter_id: []const u8) !void {
    const core = gifter.runtime.core;
    const target = core.capabilities.resolve(greeter) orelse return error.UnknownCapability;
    const peer_handle = switch (target) {
        .remote => |remote| remote.peer_handle,
        else => return error.MissingExporterRoute,
    };
    const home = core.sessionForPeer(peer_handle) orelse return error.MissingExporterSession;
    if (home == gifter.hs) return error.GiftWasProxied;
    const identity = try core.partnerIdentity(home);
    if (!std.mem.eql(u8, identity.designator, exporter_id)) return error.WrongExporter;
    if (identity.provenance != .authenticated_transport) return error.UnprovenExporter;
    if (std.mem.indexOf(u8, identity.locator_record, ",127.0.0.1:1") == null)
        return error.ExporterKeptOldAdvertisement;
}
