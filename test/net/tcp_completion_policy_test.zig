//! The TCP profiles on a platform completion backend refuse what they cannot
//! bind or dial exactly, instead of substituting. Key profiles publish the
//! listener identity with the bound address as a hint, and keep it.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");

const crypto = glowcap.foundation.crypto;
const net = glowcap.net;
const model = glowcap.ocapn.model;

const supported = builtin.os.tag == .linux or builtin.os.tag.isDarwin();
const Policy = if (supported) net.tcp.CompletionPolicy(net.Backend) else void;

fn identity() crypto.PeerKey {
    return crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x5c))).publicKey();
}

test "tcp completion policy binds only the backend's interface" {
    if (!supported) return error.SkipZigTest;
    var backend = try net.Backend.init(std.testing.allocator, 8, 2, 64);
    defer backend.deinit();

    try std.testing.expectEqual(@as(u16, 4242), try Policy.listenTarget(&backend, model.transport.tcp, .{ .designator = "127.0.0.1:4242" }));
    try std.testing.expectError(error.InvalidAddress, Policy.listenTarget(&backend, model.transport.tcp, .{ .designator = "0.0.0.0:4242" }));
    try std.testing.expectError(error.InvalidAddress, Policy.listenTarget(&backend, model.transport.tcp, .{ .designator = "[::1]:4242" }));
    try std.testing.expectError(error.UnknownTransport, Policy.listenTarget(&backend, model.transport.iroh, .{ .designator = "127.0.0.1:4242" }));

    // A key profile binds where its designator says and needs the identity
    // it will publish.
    try std.testing.expectEqual(@as(u16, 4243), try Policy.listenTarget(&backend, model.transport.noise_tcp, .{
        .designator = "127.0.0.1:4243",
        .identity = identity(),
    }));
    try std.testing.expectError(error.InvalidAddress, Policy.listenTarget(&backend, model.transport.keyed_tcp, .{ .designator = "127.0.0.1:4243" }));
}

test "tcp completion policy dials every TCP profile by its own grammar" {
    if (!supported) return error.SkipZigTest;
    const plain: model.PeerLocator = .{ .transport = model.transport.tcp, .designator = "127.0.0.1:1", .hints = model.Hints.emptyFalse() };
    _ = try Policy.resolve(plain);

    const designator = identity().toDesignator();
    var entries: [1]model.HintEntry = undefined;
    const sealed: model.PeerLocator = .{
        .transport = model.transport.noise_tcp,
        .designator = &designator,
        .hints = model.Hints.forDirectAddresses("127.0.0.1:1", &entries),
    };
    _ = try Policy.resolve(sealed);
    // A key profile names its address only in the hint.
    try std.testing.expectError(error.InvalidAddress, Policy.resolve(.{
        .transport = model.transport.noise_tcp,
        .designator = "127.0.0.1:1",
        .hints = model.Hints.emptyFalse(),
    }));
    try std.testing.expectError(error.UnknownTransport, Policy.resolve(.{
        .transport = model.transport.keyed_relay,
        .designator = &designator,
        .hints = model.Hints.emptyFalse(),
    }));
}

test "tcp completion policy keeps a key listener's identity in what it advertises" {
    if (!supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var backend = try net.Backend.init(allocator, 8, 2, 64);
    defer backend.deinit();

    const advertised = try Policy.canonicalizeLocator(&backend, -1, model.transport.tcp, null, allocator, .{
        .transport = model.transport.tcp,
        .designator = "203.0.113.7:9000",
        .hints = model.Hints.emptyFalse(),
    });
    defer model.freePeerLocator(allocator, advertised);
    try std.testing.expectEqualStrings("203.0.113.7:9000", advertised.designator);
    try std.testing.expectError(error.InvalidAddress, Policy.canonicalizeLocator(&backend, -1, model.transport.tcp, null, allocator, .{
        .transport = model.transport.tcp,
        .designator = "not an address",
        .hints = model.Hints.emptyFalse(),
    }));

    const designator = identity().toDesignator();
    var entries: [1]model.HintEntry = undefined;
    const forwarded = try Policy.canonicalizeLocator(&backend, -1, model.transport.noise_tcp, identity(), allocator, .{
        .transport = model.transport.noise_tcp,
        .designator = &designator,
        .hints = model.Hints.forDirectAddresses("203.0.113.7:9000", &entries),
    });
    defer model.freePeerLocator(allocator, forwarded);
    try std.testing.expectEqualStrings(&designator, forwarded.designator);

    const other = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x5d))).publicKey().toDesignator();
    try std.testing.expectError(error.InvalidAddress, Policy.canonicalizeLocator(&backend, -1, model.transport.noise_tcp, identity(), allocator, .{
        .transport = model.transport.noise_tcp,
        .designator = &other,
        .hints = model.Hints.forDirectAddresses("203.0.113.7:9000", &entries),
    }));
}
