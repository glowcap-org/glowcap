//! A sealed `noise-tcp` pair of byte-fed hosts, wired by moving the bytes
//! one session drains into the other's `Host.feedBytes` verbatim, so a test
//! stands exactly where a byte-owning embedder stands. The sealed channel
//! tests and the driver fuzz target share it.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("core_host.zig");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const crypto = glowcap.foundation.crypto;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const noise_tcp = model.transport.noise_tcp;

pub const SealedPair = struct { ah: *Host, a: *HostSession, bh: *Host, b: *HostSession };

/// The designator a durable seed advertises: its public key.
pub fn keyedDesignator(seed: [32]u8) [crypto.PeerKey.designator_len]u8 {
    return crypto.SecretKey.fromSeed(seed).publicKey().toDesignator();
}

/// A host whose durable identity is `durable_seed`, with its session seeds
/// rooted at `root_byte` so two hosts never share one.
pub fn sealedHost(
    allocator: std.mem.Allocator,
    durable_seed: [crypto.SEED_BYTES]u8,
    root_byte: u8,
    options: Host.Options,
) Host {
    return test_host.initWithRoot(
        allocator,
        durable_seed,
        @as([crypto.SEED_BYTES]u8, @splat(root_byte)),
        options,
    );
}

pub fn noiseLocator(designator: []const u8) model.PeerLocator {
    return .{ .transport = noise_tcp, .designator = designator, .hints = model.Hints.emptyFalse() };
}

/// Move every wire byte one direction, appending to `log` when given, and
/// resume a pause boundary left by a session that opened mid-chunk. Returns
/// whether anything moved.
pub fn moveSealedWire(
    allocator: std.mem.Allocator,
    from: *HostSession,
    to_host: *Host,
    to: *HostSession,
    log: ?*std.ArrayList(u8),
) !bool {
    var moved = false;
    while (try from.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        if (log) |l| try l.appendSlice(allocator, frame.bytes());
        try to_host.feedBytes(to, frame.bytes());
        moved = true;
    }
    if (to.sealed) |channel| {
        if (channel.hasStagedInbound()) {
            const staged_before = channel.staged.len;
            try to.resumeFeed();
            if (to.sealed.?.staged.len != staged_before) moved = true;
        }
    }
    return moved;
}

/// Drain both hosts' action queues. Only flush, close, resume, and settle
/// notices are expected on a sealed pair.
pub fn drainSealedActions(hosts: []const *Host, closes: ?*usize) !bool {
    var did_work = false;
    for (hosts) |host| {
        while (try host.nextAction()) |action| {
            switch (action) {
                .close => if (closes) |count| {
                    count.* += 1;
                },
                .flush, .resume_work, .settled, .failed => {},
                else => return error.UnexpectedAction,
            }
            did_work = true;
        }
    }
    return did_work;
}

pub fn pumpSealedPair(
    allocator: std.mem.Allocator,
    pair: SealedPair,
    log_ab: ?*std.ArrayList(u8),
    log_ba: ?*std.ArrayList(u8),
) !void {
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        var moved = try moveSealedWire(allocator, pair.a, pair.bh, pair.b, log_ab);
        if (try moveSealedWire(allocator, pair.b, pair.ah, pair.a, log_ba)) moved = true;
        if (try drainSealedActions(&.{ pair.ah, pair.bh }, null)) moved = true;
        if (!moved) return;
    }
    return error.PumpDidNotQuiesce;
}

/// Open a sealed dialed/accepted pair between two hosts and pump it to
/// quiescence, capturing each direction's wire when logs are given.
pub fn openSealedPair(
    allocator: std.mem.Allocator,
    dialer: *Host,
    dialer_seed: [32]u8,
    acceptor: *Host,
    acceptor_seed: [32]u8,
    log_ab: ?*std.ArrayList(u8),
    log_ba: ?*std.ArrayList(u8),
) !SealedPair {
    const acceptor_designator = keyedDesignator(acceptor_seed);
    const dialer_designator = keyedDesignator(dialer_seed);
    try acceptor.setAdvertisedLocator(noiseLocator(&acceptor_designator));
    const accepted = try acceptor.openAcceptedAdvertised(noise_tcp);
    try dialer.setAdvertisedLocator(noiseLocator(&dialer_designator));
    const dialed = try dialer.openDialedLocator(noiseLocator(&acceptor_designator));
    const pair = SealedPair{ .ah = dialer, .a = dialed, .bh = acceptor, .b = accepted };
    try pumpSealedPair(allocator, pair, log_ab, log_ba);
    return pair;
}
