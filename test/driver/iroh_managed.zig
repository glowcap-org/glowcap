//! Zig Session and Server over real iroh endpoints. A yielded session
//! serves a named capability after its Server has stopped and been destroyed.

const std = @import("std");
const glowcap = @import("glowcap");
const iroh = @import("iroh");
const driver = glowcap.driver;
const model = glowcap.ocapn.model;
const secret_type = glowcap.foundation.crypto.SecretKey;
const opts: driver.SessionOptions = .{ .handshake = .{ .ms = 5000 }, .settle = .{ .ms = 5000 } };

const Greeter = struct {
    pub fn handle(_: *Greeter, ht: *driver.HostTurn, selector: ?[]const u8, args: driver.Args) !driver.Value {
        defer ht.releaseArguments(args);
        const verb = selector orelse return error.NoSuchMethod;
        if (!std.mem.eql(u8, verb, "greet") or (try args.len()) != 1) return error.BadInvocation;
        if (!std.mem.eql(u8, try args.string(0), "world")) return error.BadArgument;
        return .{ .string = "hello over managed iroh" };
    }
};

fn host(io: std.Io, allocator: std.mem.Allocator, endpoint: *iroh.Resident, secret: secret_type, ready: *std.atomic.Value(u8)) !void {
    errdefer ready.store(2, .release);
    var adapter = try iroh.MultiplexedAdapter.init(allocator, endpoint);
    defer if (adapter.deinit()) |failure| std.log.err("iroh adapter: {s}", .{failure.primaryName()});
    const providers = [_]driver.HostRuntime.ProviderRegistration{.{ .profile = iroh.transport_profile, .resident = adapter.multiplexed() }};
    const server = try driver.listen(allocator, io, .{ .residents = &providers }, iroh.transport_name, .{ .designator = "" }, .{ .keyed = secret }, opts);
    var owns_server = true;
    defer if (owns_server) server.deinit();
    const original = try model.clonePeerLocator(allocator, try server.advertisedLocator());
    defer model.freePeerLocator(allocator, original);
    var invalid = original;
    invalid.transport = model.transport.tcp;
    if (server.setAdvertisedLocator(invalid)) |_| return error.InvalidAdvertisementAccepted else |_| {}
    if (!std.mem.eql(u8, (try server.advertisedLocator()).transport, original.transport)) return error.AdvertisementChanged;
    ready.store(1, .release);
    if (!try server.waitAcceptable(5000)) return error.AcceptTimedOut;
    const session = try server.accept();
    defer session.deinit();
    if (server.close()) |failure| return failure.chain.cause;
    server.deinit();
    owns_server = false;
    // The client may already have coalesced its fetch with the hello. Setup
    // still precedes dispatch, even after the listener owner has disappeared.
    _ = try session.publish("greeter", Greeter, .{});
    try session.serve();
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const seed: [32]u8 = @splat(0x47);
    var server_endpoint = try iroh.Resident.init(io, &seed, .{ .reachability = .direct });
    defer server_endpoint.deinit() catch |err| std.log.err("server endpoint: {s}", .{@errorName(err)});
    var client_endpoint = try iroh.Resident.init(io, null, .{ .reachability = .direct });
    defer client_endpoint.deinit() catch |err| std.log.err("client endpoint: {s}", .{@errorName(err)});
    var ready = std.atomic.Value(u8).init(0);
    var serving = try io.concurrent(host, .{ io, allocator, &server_endpoint, secret_type.fromSeed(seed), &ready });
    const result = call(io, allocator, &client_endpoint, &server_endpoint, &ready);
    const hosted = serving.await(io);
    try result;
    try hosted;
    std.debug.print("iroh-managed: Zig dial, keyed hello, fetch and exact reply survive Server destruction\n", .{});
}

fn call(io: std.Io, allocator: std.mem.Allocator, client: *iroh.Resident, server: *iroh.Resident, ready: *std.atomic.Value(u8)) !void {
    const deadline = glowcap.net.clock.nowMs(io) + 5000;
    while (ready.load(.acquire) == 0) {
        if (glowcap.net.clock.nowMs(io) >= deadline) return error.ListenTimedOut;
        try std.Io.sleep(io, .fromMilliseconds(1), .real);
    }
    if (ready.load(.acquire) != 1) return error.ListenFailed;
    var adapter = try iroh.MultiplexedAdapter.init(allocator, client);
    defer if (adapter.deinit()) |failure| std.log.err("iroh adapter: {s}", .{failure.primaryName()});
    const providers = [_]driver.HostRuntime.ProviderRegistration{.{ .profile = iroh.transport_profile, .resident = adapter.multiplexed() }};
    var designator: [iroh.node_id_len]u8 = undefined;
    const addresses = try server.directAddrsOwned(allocator);
    defer allocator.free(addresses);
    var hints: [1]model.HintEntry = undefined;
    const locator = iroh.locatorWithDirectAddresses(server.nodeId(&designator), addresses, &hints);
    const session = try driver.connect(allocator, io, .{ .residents = &providers }, locator, .ephemeral, opts);
    defer session.deinit();
    const partner = try session.partnerIdentity();
    if (!partner.durableIdentityAuthenticated() or !std.mem.eql(u8, partner.designator, locator.designator)) return error.WrongPartner;
    const greeter = try session.fetch("greeter");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const reply = try session.call(greeter, "greet", &.{.{ .string = "world" }}, arena.allocator());
    switch (reply) {
        .fulfilled => |value| if (value != .string or !std.mem.eql(u8, value.string, "hello over managed iroh")) return error.WrongReply,
        .broken => return error.BrokenReply,
    }
}
