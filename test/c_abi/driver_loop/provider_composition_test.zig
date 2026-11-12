//! How provider packages compose on one driver: the lease each call leaves
//! held, the profiles a partly served package adds, and the packages the
//! registry refuses whole.

const std = @import("std");

const c = @import("c_abi");
const cdrv = @import("c_abi_driver");
const glowcap = @import("glowcap");

const harness = @import("harness.zig");
const typed_resident = @import("typed_resident.zig");
const TypedResident = typed_resident.TypedResident;
const expectOk = harness.expectOk;
const providerProfile = harness.providerProfile;

fn sameConfiguration(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) u8 {
    return 1;
}

/// One package over `resident`'s table serving `profiles`, leased by the
/// resident so its retain and release counters see every call. Every package
/// built here reports the same configuration.
fn package(
    resident: *TypedResident,
    table: *const cdrv.GlowcapMultiplexedTransport,
    profiles: []const cdrv.GlowcapTransportProfile,
    entries: []cdrv.GlowcapTransportProviderEntry,
) cdrv.GlowcapTransportProvider {
    for (profiles, entries) |*profile, *entry| entry.* = .{
        .profile = profile,
        .execution_model = cdrv.GLOWCAP_TRANSPORT_EXEC_MULTIPLEXED,
        .implementation = table,
    };
    return .{
        .abi_version = cdrv.GLOWCAP_TRANSPORT_PROVIDER_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.GlowcapTransportProvider),
        .entries = entries.ptr,
        .entry_count = profiles.len,
        .lease_ctx = resident,
        .same_configuration = sameConfiguration,
        .retain = TypedResident.retain,
        .release = TypedResident.release,
    };
}

fn present(loop: ?*cdrv.GlowcapDriverLoop, name: []const u8) !bool {
    var flag: u8 = 0;
    try expectOk(cdrv.glowcap_driver_has_transport(loop, name.ptr, name.len, &flag));
    return flag == 1;
}

test "a package holds a lease only while it serves a profile" {
    var first: TypedResident = .{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .opaque_hint = &.{},
    };
    defer first.wake.deinit();
    var second: TypedResident = .{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .opaque_hint = &.{},
    };
    defer second.wake.deinit();
    const owned_loop = try harness.newEmptyLoop(0x66);
    var loop_live = true;
    defer if (loop_live) {
        _ = harness.releaseLoop(owned_loop.raw);
    };
    var first_table = first.table();
    var second_table = second.table();
    const both = [_]cdrv.GlowcapTransportProfile{ providerProfile("compose-a"), providerProfile("compose-b") };
    var narrow_entries: [1]cdrv.GlowcapTransportProviderEntry = undefined;
    var wider_entries: [2]cdrv.GlowcapTransportProviderEntry = undefined;

    const narrow = package(&first, &first_table, both[0..1], &narrow_entries);
    try expectOk(harness.addProvider(owned_loop.raw, &narrow));
    try std.testing.expectEqual(@as(usize, 1), first.retains);

    // The wider package adds the one profile nothing serves and keeps its lease.
    const wider = package(&second, &second_table, &both, &wider_entries);
    try expectOk(harness.addProvider(owned_loop.raw, &wider));
    try std.testing.expect(try present(owned_loop.raw, "compose-b"));
    try std.testing.expectEqual(@as(usize, 1), second.retains);
    try std.testing.expectEqual(@as(usize, 0), second.releases);

    // A package with nothing left to serve returns its lease before the call ends.
    try expectOk(harness.addProvider(owned_loop.raw, &wider));
    try std.testing.expectEqual(@as(usize, 2), second.retains);
    try std.testing.expectEqual(@as(usize, 1), second.releases);
    try std.testing.expectEqual(@as(usize, 0), first.releases);

    try expectOk(harness.releaseLoop(owned_loop.raw));
    loop_live = false;
    try std.testing.expectEqual(@as(usize, 1), first.releases);
    try std.testing.expectEqual(@as(usize, 2), second.releases);
}

test "a package naming one profile twice is refused whether or not it is served" {
    var resident: TypedResident = .{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .opaque_hint = &.{},
    };
    defer resident.wake.deinit();
    const owned_loop = try harness.newEmptyLoop(0x67);
    defer owned_loop.deinit();
    var table = resident.table();
    const twice = [_]cdrv.GlowcapTransportProfile{ providerProfile("compose-twice"), providerProfile("compose-twice") };
    var entries: [2]cdrv.GlowcapTransportProviderEntry = undefined;
    const doubled = package(&resident, &table, &twice, &entries);

    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, harness.addProvider(owned_loop.raw, &doubled));
    try std.testing.expect(!try present(owned_loop.raw, "compose-twice"));
    try std.testing.expectEqual(@as(usize, 0), resident.retains);

    var single: [1]cdrv.GlowcapTransportProviderEntry = undefined;
    const once = package(&resident, &table, twice[0..1], &single);
    try expectOk(harness.addProvider(owned_loop.raw, &once));
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, harness.addProvider(owned_loop.raw, &doubled));
    try std.testing.expectEqual(@as(usize, 1), resident.retains);
    try std.testing.expectEqual(@as(usize, 0), resident.releases);
}

test "a malformed entry is refused even when its profile is already served" {
    var resident: TypedResident = .{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .opaque_hint = &.{},
    };
    defer resident.wake.deinit();
    const owned_loop = try harness.newEmptyLoop(0x68);
    defer owned_loop.deinit();
    var table = resident.table();
    const profiles = [_]cdrv.GlowcapTransportProfile{providerProfile("compose-valid")};
    var entries: [1]cdrv.GlowcapTransportProviderEntry = undefined;
    const valid = package(&resident, &table, &profiles, &entries);
    try expectOk(harness.addProvider(owned_loop.raw, &valid));

    var unknown_model_entries: [1]cdrv.GlowcapTransportProviderEntry = undefined;
    const unknown_model = package(&resident, &table, &profiles, &unknown_model_entries);
    unknown_model_entries[0].execution_model = 99;
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, harness.addProvider(owned_loop.raw, &unknown_model));

    var no_table_entries: [1]cdrv.GlowcapTransportProviderEntry = undefined;
    const no_table = package(&resident, &table, &profiles, &no_table_entries);
    no_table_entries[0].implementation = null;
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, harness.addProvider(owned_loop.raw, &no_table));

    // One table under two execution models, the first entry already served.
    const two_profiles = [_]cdrv.GlowcapTransportProfile{ providerProfile("compose-valid"), providerProfile("compose-other") };
    var two_model_entries: [2]cdrv.GlowcapTransportProviderEntry = undefined;
    const two_models = package(&resident, &table, &two_profiles, &two_model_entries);
    two_model_entries[1].execution_model = cdrv.GLOWCAP_TRANSPORT_EXEC_STREAM;
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, harness.addProvider(owned_loop.raw, &two_models));
    try std.testing.expect(!try present(owned_loop.raw, "compose-other"));

    var unsupported = table;
    unsupported.abi_version = 0;
    var unsupported_entries: [1]cdrv.GlowcapTransportProviderEntry = undefined;
    const unsupported_table = package(&resident, &unsupported, &profiles, &unsupported_entries);
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, harness.addProvider(owned_loop.raw, &unsupported_table));
    // No malformed package took a lease.
    try std.testing.expectEqual(@as(usize, 1), resident.retains);
    try std.testing.expectEqual(@as(usize, 0), resident.releases);
}
