//! Shared direct-C relay-provider fixtures. Tests above the driver use a
//! different harness; this one deliberately meets the multiplexed table at
//! its ownership boundary.

const std = @import("std");
const c = @import("c_abi_shared");
const relay_archive = @import("c_abi_net_transport_relay");

const tls_root_pem = @embedFile("../../net/fixtures/tls_root.pem");

pub fn copiedTrustConfig(relay_url: []const u8) relay_archive.GlowcapRelayConfig {
    return .{
        .relay_url = relay_url.ptr,
        .relay_url_len = relay_url.len,
        .trust = relay_archive.GLOWCAP_RELAY_TRUST_COPIED_PEM,
        .trust_pem = tls_root_pem.ptr,
        .trust_pem_len = tls_root_pem.len,
    };
}

pub fn keyedTable(provider: c.GlowcapTransportProvider) *const c.GlowcapMultiplexedTransport {
    for (provider.entries.?[0..provider.entry_count]) |entry| {
        const profile = entry.profile.?;
        const name = profile.transport_name.?[0..profile.transport_name_len];
        if (std.mem.eql(u8, name, "keyed-relay"))
            return @ptrCast(@alignCast(entry.implementation.?));
    }
    unreachable;
}

pub fn drain(
    table: *const c.GlowcapMultiplexedTransport,
    records: *[8]c.GlowcapMultiplexedReadyEvent,
) ![]c.GlowcapMultiplexedReadyEvent {
    var count: usize = 0;
    var failure = c.transport_provider.emptyProviderFailure();
    try std.testing.expectEqual(c.GLOWCAP_OK, table.drain_ready.?(
        table.ctx,
        records,
        records.len,
        &count,
        &failure,
    ));
    try std.testing.expectEqual(@as(i32, 0), failure.result);
    try std.testing.expect(count <= records.len);
    return records[0..count];
}

pub fn waitForEvent(
    io: std.Io,
    table: *const c.GlowcapMultiplexedTransport,
    subject: u64,
    mask: u32,
) !u32 {
    var records: [8]c.GlowcapMultiplexedReadyEvent = undefined;
    var observed: u32 = 0;
    var rounds: usize = 0;
    while (observed & mask == 0 and rounds < 400) : (rounds += 1) {
        for (try drain(table, &records)) |event| {
            if (event.subject == subject) observed |= event.events;
        }
        if (observed & mask == 0)
            try std.Io.sleep(io, .fromMilliseconds(5), .real);
    }
    try std.testing.expect(observed & mask != 0);
    return observed;
}

/// Wait for one published record carrying `mask`, without folding earlier
/// records into it. Use this when the atomic composition of one readiness
/// transition is the contract under test.
pub fn waitForEventRecord(
    io: std.Io,
    table: *const c.GlowcapMultiplexedTransport,
    subject: u64,
    mask: u32,
) !u32 {
    var records: [8]c.GlowcapMultiplexedReadyEvent = undefined;
    var rounds: usize = 0;
    while (rounds < 400) : (rounds += 1) {
        for (try drain(table, &records)) |event| {
            if (event.subject == subject and event.events & mask != 0)
                return event.events;
        }
        try std.Io.sleep(io, .fromMilliseconds(5), .real);
    }
    return error.EventNotReady;
}
