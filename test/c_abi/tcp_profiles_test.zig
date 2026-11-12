//! The TCP archive's `profiles` config: the set a netlayer is created with
//! decides which profiles its provider registers, and a driver holding only
//! the noise profile refuses a plain `tcp` locator before dialing.

const std = @import("std");

const c = @import("c_abi_shared");
const cd = @import("c_abi_host");
const cdrv = @import("c_abi_driver");
const tcp = @import("c_abi_net_transport_tcp");

const harness = @import("driver_loop/harness.zig");

fn configFor(profiles: u32) tcp.GlowcapTcpConfig {
    var config = harness.default_tcp_config;
    config.profiles = profiles;
    return config;
}

fn profileNames(provider: c.GlowcapTransportProvider, out: *[3][]const u8) []const []const u8 {
    for (0..provider.entry_count) |i| {
        const profile = provider.entries.?[i].profile.?;
        out[i] = profile.transport_name.?[0..profile.transport_name_len];
    }
    return out[0..provider.entry_count];
}

test "a netlayer registers exactly the profiles its config names" {
    const cases = [_]struct { set: u32, names: []const []const u8 }{
        .{ .set = tcp.GLOWCAP_TCP_PROFILE_NOISE_TCP, .names = &.{"noise-tcp"} },
        .{ .set = tcp.GLOWCAP_TCP_PROFILE_KEYED_TCP | tcp.GLOWCAP_TCP_PROFILE_NOISE_TCP, .names = &.{ "keyed-tcp", "noise-tcp" } },
        .{ .set = tcp.GLOWCAP_TCP_PROFILES_ALL, .names = &.{ "tcp", "keyed-tcp", "noise-tcp" } },
    };
    for (cases) |case| {
        const config = configFor(case.set);
        var netlayer: ?*tcp.GlowcapTcpNetlayer = null;
        try std.testing.expectEqual(c.GLOWCAP_OK, tcp.glowcap_tcp_netlayer_new(&config, &netlayer));
        defer tcp.glowcap_tcp_netlayer_release(netlayer);
        var provider: c.GlowcapTransportProvider = undefined;
        try std.testing.expectEqual(c.GLOWCAP_OK, tcp.glowcap_tcp_transport_provider(netlayer, &provider));
        var storage: [3][]const u8 = undefined;
        const names = profileNames(provider, &storage);
        try std.testing.expectEqual(case.names.len, names.len);
        for (case.names, names) |want, got| try std.testing.expectEqualStrings(want, got);
    }
}

test "an empty or unknown profile set is refused without creating a netlayer" {
    for ([_]u32{ 0, tcp.GLOWCAP_TCP_PROFILES_ALL + 1, 0x8000_0000 | tcp.GLOWCAP_TCP_PROFILE_TCP }) |set| {
        const config = configFor(set);
        var netlayer: ?*tcp.GlowcapTcpNetlayer = null;
        c.lastErrorClear();
        try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, tcp.glowcap_tcp_netlayer_new(&config, &netlayer));
        try std.testing.expect(netlayer == null);
        try std.testing.expect(c.lastErrorRead(null, 0) > 0);
    }
}

fn newNetlayer(config: *const tcp.GlowcapTcpConfig) !?*tcp.GlowcapTcpNetlayer {
    var netlayer: ?*tcp.GlowcapTcpNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, tcp.glowcap_tcp_netlayer_new(config, &netlayer));
    return netlayer;
}

/// Install `netlayer`'s package, returning the driver's own failure record so a
/// test can tell a provider conflict from any other refusal.
fn addNetlayer(
    loop: ?*cdrv.GlowcapDriverLoop,
    netlayer: ?*tcp.GlowcapTcpNetlayer,
    failure: *cdrv.GlowcapDriverFailure,
) !i32 {
    var provider: c.GlowcapTransportProvider = undefined;
    try std.testing.expectEqual(c.GLOWCAP_OK, tcp.glowcap_tcp_transport_provider(netlayer, &provider));
    return cdrv.glowcap_driver_add_provider(loop, &provider, failure);
}

fn expectConflict(failure: cdrv.GlowcapDriverFailure) !void {
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, failure.primary_result);
    try std.testing.expectEqualStrings(
        "ProviderConfigurationConflict",
        failure.primary_name.?[0..failure.primary_name_len],
    );
}

fn hasTransport(loop: ?*cdrv.GlowcapDriverLoop, name: []const u8) !bool {
    var present: u8 = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, cdrv.glowcap_driver_has_transport(loop, name.ptr, name.len, &present));
    return present == 1;
}

test "netlayers compose per profile and a different configuration installs nothing" {
    const owned = try harness.newEmptyLoop(0x72);
    defer owned.deinit();
    const sealed_config = configFor(tcp.GLOWCAP_TCP_PROFILE_NOISE_TCP);
    const first = try newNetlayer(&sealed_config);
    defer tcp.glowcap_tcp_netlayer_release(first);
    const same = try newNetlayer(&sealed_config);
    defer tcp.glowcap_tcp_netlayer_release(same);
    const wider_config = configFor(tcp.GLOWCAP_TCP_PROFILE_NOISE_TCP | tcp.GLOWCAP_TCP_PROFILE_TCP);
    const wider = try newNetlayer(&wider_config);
    defer tcp.glowcap_tcp_netlayer_release(wider);
    var keepalive_config = configFor(tcp.GLOWCAP_TCP_PROFILES_ALL);
    keepalive_config.stream = .{ .keepalive_idle_sec = 30, .keepalive_interval_sec = 5, .keepalive_count = 3 };
    const keepalive = try newNetlayer(&keepalive_config);
    defer tcp.glowcap_tcp_netlayer_release(keepalive);

    var failure = cdrv.GlowcapDriverFailure.init();
    try std.testing.expectEqual(c.GLOWCAP_OK, try addNetlayer(owned.raw, first, &failure));
    try std.testing.expectEqual(c.GLOWCAP_OK, try addNetlayer(owned.raw, same, &failure));

    // The installed profile keeps its stream options, so a package that
    // names it under other options is refused whole: its unserved profiles
    // are not installed either.
    failure = cdrv.GlowcapDriverFailure.init();
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, try addNetlayer(owned.raw, keepalive, &failure));
    try expectConflict(failure);
    try std.testing.expect(try hasTransport(owned.raw, "noise-tcp"));
    try std.testing.expect(!try hasTransport(owned.raw, "tcp"));
    try std.testing.expect(!try hasTransport(owned.raw, "keyed-tcp"));
    var operation_id: u64 = 0;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        try harness.dialParts(owned.raw, "tcp", "127.0.0.1:1", "", &operation_id),
    );
    try expectTransportUnavailable();

    // An equal configuration adds only the profile nothing serves yet.
    failure = cdrv.GlowcapDriverFailure.init();
    try std.testing.expectEqual(c.GLOWCAP_OK, try addNetlayer(owned.raw, wider, &failure));
    try std.testing.expect(try hasTransport(owned.raw, "tcp"));
    try std.testing.expect(!try hasTransport(owned.raw, "keyed-tcp"));

    // A package whose every profile is already served installs nothing.
    const plain_config = configFor(tcp.GLOWCAP_TCP_PROFILE_TCP);
    const plain = try newNetlayer(&plain_config);
    defer tcp.glowcap_tcp_netlayer_release(plain);
    failure = cdrv.GlowcapDriverFailure.init();
    try std.testing.expectEqual(c.GLOWCAP_OK, try addNetlayer(owned.raw, plain, &failure));
}

fn expectTransportUnavailable() !void {
    var raw: c.GlowcapBreakCause = undefined;
    cdrv.glowcap_driver_last_error_cause(&raw);
    try std.testing.expectEqual(cd.BreakCause.local(.transport_unavailable), try raw.toCore());
}

test "a driver holding only the noise profile refuses a plain tcp locator" {
    const owned = try harness.newEmptyLoop(0x71);
    defer owned.deinit();
    const config = configFor(tcp.GLOWCAP_TCP_PROFILE_NOISE_TCP);
    var netlayer: ?*tcp.GlowcapTcpNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, tcp.glowcap_tcp_netlayer_new(&config, &netlayer));
    defer tcp.glowcap_tcp_netlayer_release(netlayer);
    var provider: c.GlowcapTransportProvider = undefined;
    try std.testing.expectEqual(c.GLOWCAP_OK, tcp.glowcap_tcp_transport_provider(netlayer, &provider));
    try std.testing.expectEqual(c.GLOWCAP_OK, harness.addProvider(owned.raw, &provider));

    var present: u8 = 1;
    try std.testing.expectEqual(c.GLOWCAP_OK, cdrv.glowcap_driver_has_transport(owned.raw, "tcp", 3, &present));
    try std.testing.expectEqual(@as(u8, 0), present);
    try std.testing.expectEqual(c.GLOWCAP_OK, cdrv.glowcap_driver_has_transport(owned.raw, "noise-tcp", 9, &present));
    try std.testing.expectEqual(@as(u8, 1), present);

    var operation_id: u64 = 0;
    cdrv.glowcap_driver_clear_last_error();
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        try harness.dialParts(owned.raw, "tcp", "127.0.0.1:1", "", &operation_id),
    );
    try std.testing.expect(cdrv.glowcap_driver_last_error(null, 0) > 0);
    try expectTransportUnavailable();

    // The cause belongs to the call that failed. A successful call clears it,
    // and so does a refusal that names no cause.
    try std.testing.expect(try hasTransport(owned.raw, "noise-tcp"));
    var cleared: c.GlowcapBreakCause = undefined;
    cdrv.glowcap_driver_last_error_cause(&cleared);
    try std.testing.expectEqual(cd.BreakCause{}, try cleared.toCore());

    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        cdrv.glowcap_driver_has_transport(owned.raw, "", 0, &present),
    );
    cdrv.glowcap_driver_last_error_cause(&cleared);
    try std.testing.expectEqual(cd.BreakCause{}, try cleared.toCore());
}
