//! One-call construction of an owning Session and its private HostRuntime.

const std = @import("std");

const model = @import("model");

const driver = @import("../mod.zig");
const host_runtime = @import("../host_runtime.zig");
const client = @import("client.zig");
const SharedRuntime = @import("shared_runtime.zig").SharedRuntime;

const Identity = driver.Identity;
const Session = client.Session;
const SessionOptions = client.SessionOptions;

/// Dial the peer `locator` names into one owned session: build a private
/// single-session host under `identity` over the transports `transports`
/// names, dial, and pump the keyed handshake under `opts.handshake`. The
/// returned `*Session` is freed by `Session.deinit`; whatever `transports`
/// borrows must outlive the whole session, because later handoff redemption
/// dials through the same runtime. Multi-session applications build one
/// `driver.HostRuntime` and adopt its sessions instead.
pub fn connect(
    allocator: std.mem.Allocator,
    io: std.Io,
    transports: host_runtime.HostRuntime.Transports,
    locator: model.PeerLocator,
    identity: Identity,
    opts: SessionOptions,
) !*Session {
    const shared = try allocator.create(SharedRuntime);
    errdefer allocator.destroy(shared);
    shared.* = SharedRuntime.init(allocator, try host_runtime.HostRuntime.init(allocator, io, transports, identity, opts));
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
    io: std.Io,
    transports: host_runtime.HostRuntime.Transports,
    uri_str: []const u8,
    identity: Identity,
    opts: SessionOptions,
) !*Session {
    const locator = try model.uri.parsePeer(allocator, uri_str);
    defer model.freePeerLocator(allocator, locator);
    return connect(allocator, io, transports, locator, identity, opts);
}
