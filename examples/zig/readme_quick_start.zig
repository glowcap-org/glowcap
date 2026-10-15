//! The README's Quick Start snippet, runnable.
//!
//! The `client` function below is the exact code the README shows under
//! Quick Start, so the snippet stays machine-checked. If either side changes,
//! change both in the same diff. The host half is the minimum the snippet
//! needs to run: a greeter published by name that answers `greet` with a
//! greeting, the same greeter chapter 01 hosts.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const model = glowcap.ocapn.model;
const crypto = glowcap.foundation.crypto;

/// The published greeter: answers `greet(name)` with a greeting built in the
/// turn's arena, which outlives the reply encode and nothing more.
const Greeter = struct {
    pub fn handle(_: *Greeter, ht: *driver.HostTurn, verb: []const u8, args: driver.Args) !driver.Value {
        if (!std.mem.eql(u8, verb, "greet")) return error.NoSuchMethod;
        if ((try args.len()) != 1) return error.BadInvocation;
        return .{ .string = try std.fmt.allocPrint(ht.turn.arena, "Hello, {s}", .{try args.string(0)}) };
    }
};

/// The hosting half: publish the greeter on the server before accept, so a
/// partner that fetches as soon as the session opens cannot miss it.
fn host(server: *driver.Server) !void {
    try server.publish("greeter", Greeter, .{});
    var session = try server.accept();
    defer session.deinit();
    try session.serve();
}

/// The client half, the README's Quick Start snippet, verbatim.
fn client(io: std.Io, allocator: std.mem.Allocator, peer_key: []const u8, address: []const u8) !void {
    // Noise_XK seals the CapTP stream and proves the dialed key.
    var hint_storage: [1]glowcap.ocapn.model.HintEntry = undefined;
    const partner = glowcap.net.tcp.noise.locator(peer_key, address, &hint_storage);

    const session = try glowcap.driver.connect(
        allocator,
        io,
        .{ .symbols = &.{.noise_tcp} },
        partner,
        .ephemeral,
        // Never leave a network wait unbounded.
        .{
            .handshake = glowcap.driver.default_handshake_budget,
            .settle = glowcap.driver.default_settle_budget,
        },
    );
    defer session.deinit();

    const greeter = try session.fetch("greeter"); // a capability this peer published
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const settled = try session.call(greeter, "greet", &.{.{ .string = "world" }}, arena.allocator());
    switch (settled) {
        .fulfilled => |value| std.debug.print("{s}\n", .{value.string}),
        .broken => |reason| {
            std.debug.print("the greeter refused: {s}\n", .{reason});
            return error.GreeterRefused;
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const seed = @as([32]u8, @splat(7));
    const secret = crypto.SecretKey.fromSeed(seed);
    var server = try driver.listen(
        allocator,
        io,
        .{ .symbols = &.{.noise_tcp} },
        model.transport.noise_tcp,
        .{ .designator = "127.0.0.1:0" },
        .{ .keyed = secret },
        .{
            .handshake = driver.default_handshake_budget,
            .settle = driver.default_settle_budget,
        },
    );
    defer server.deinit();

    const advertised = try server.advertisedLocator();
    var key_buf: [crypto.PeerKey.designator_len]u8 = undefined;
    if (advertised.designator.len > key_buf.len) return error.DesignatorUnavailable;
    @memcpy(key_buf[0..advertised.designator.len], advertised.designator);
    const peer_key = key_buf[0..advertised.designator.len];
    var addr_buf: [64]u8 = undefined;
    const advertised_addr = glowcap.net.netlayer.directAddrHint(advertised.hints) orelse
        return error.MissingBoundAddress;
    if (advertised_addr.len > addr_buf.len) return error.DesignatorUnavailable;
    @memcpy(addr_buf[0..advertised_addr.len], advertised_addr);
    const address = addr_buf[0..advertised_addr.len];

    var hosting = try io.concurrent(host, .{server});
    try client(io, allocator, peer_key, address);
    try hosting.await(io);
}
