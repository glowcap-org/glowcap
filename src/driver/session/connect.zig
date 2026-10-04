//! One-call construction of an owning Session and its private HostRuntime.

const std = @import("std");

const model = @import("model");
const net = @import("net");

const driver = @import("../mod.zig");
const host_runtime = @import("../host_runtime.zig");
const client = @import("client.zig");
const SharedRuntime = @import("shared_runtime.zig").SharedRuntime;

const Error = driver.Error;
const Identity = driver.Identity;
const Session = client.Session;
const SessionOptions = client.SessionOptions;

/// Dial the peer `locator` names into one owned session: build a private
/// single-session host under `identity`, dial through whichever netlayer in
/// `netlayers` hosts the locator's transport, and pump the keyed handshake
/// under `opts.handshake`. The returned `*Session` is freed by
/// `Session.deinit`; `netlayers` (and the residents behind it) must outlive
/// the whole session because later handoff redemption reuses this same slice.
/// A netlayer without a pollable fd is refused: this face multiplexes its
/// blocking waits with poll. Multi-session applications build one
/// `driver.HostRuntime` and adopt its sessions instead.
pub fn connect(
    allocator: std.mem.Allocator,
    netlayers: []const net.netlayer.Netlayer,
    locator: model.PeerLocator,
    identity: Identity,
    opts: SessionOptions,
) !*Session {
    const nl = net.netlayer.resolve(netlayers, locator.transport) orelse return Error.UnknownTransport;
    const io = nl.io() orelse return Error.TransportNotPollable;

    const shared = try allocator.create(SharedRuntime);
    errdefer allocator.destroy(shared);
    shared.* = SharedRuntime.init(
        allocator,
        try host_runtime.HostRuntime.init(allocator, io, netlayers, identity, opts),
    );
    errdefer shared.runtime.deinit();

    return finishConnect(shared, locator);
}

/// Dial through borrowed stream or multiplexed providers. Contexts remain
/// stable until this Session and every session opened by handoff have retired.
pub fn connectProviders(
    allocator: std.mem.Allocator,
    io: std.Io,
    providers: []const host_runtime.HostRuntime.ProviderRegistration,
    locator: model.PeerLocator,
    identity: Identity,
    opts: SessionOptions,
) !*Session {
    const shared = try allocator.create(SharedRuntime);
    errdefer allocator.destroy(shared);
    shared.* = SharedRuntime.init(allocator, try host_runtime.HostRuntime.initProviders(allocator, io, providers, identity, opts));
    errdefer shared.runtime.deinit();
    return finishConnect(shared, locator);
}

fn finishConnect(shared: *SharedRuntime, locator: model.PeerLocator) !*Session {
    const hs = try shared.runtime.connectLocator(locator, .inherit);
    errdefer shared.runtime.releaseWire(hs) catch |err| shared.runtime.noteTerminalFailure(err);
    const session = try Session.adoptRetained(&shared.runtime, hs, shared, shared.allocator);
    std.debug.assert(!shared.releaseImplicit());
    return session;
}

/// Parse an `ocapn://` URI, then dial it through `connect`.
pub fn connectUriOwned(
    allocator: std.mem.Allocator,
    netlayers: []const net.netlayer.Netlayer,
    uri_str: []const u8,
    identity: Identity,
    opts: SessionOptions,
) !*Session {
    const locator = try model.uri.parsePeer(allocator, uri_str);
    defer model.freePeerLocator(allocator, locator);
    return connect(allocator, netlayers, locator, identity, opts);
}
