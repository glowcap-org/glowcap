//! The keyed TCP transport: TCP sockets under a durable, key-derived
//! designator — the restart-stable listening identity (ADR-0075).
//!
//! A plain `tcp` locator's designator is a `host:port`: it names where to dial,
//! and it changes when the process rebinds. A `keyed-tcp` locator's designator
//! is the listener's Ed25519 public key in canonical lowercase hex
//! (`foundation.crypto.PeerKey.toDesignator`) — the same key-as-designator
//! posture iroh's node id ships — and the socket address rides the locator's
//! `direct-addresses` hint instead. The key outlives the process, so a partner
//! re-dials the same designator across a restart with only the hint updated,
//! and the driver's dial-side pin (`engine.Peer.expectPartnerKey`) verifies at
//! the handshake that whoever answered actually holds that key.
//!
//! The wire underneath is the plain TCP resident's: this file owns no sockets,
//! streams, or pinned wrappers of its own. It reuses `tcp.connectAddress`,
//! `tcp.Listener`, and `tcp.parseDesignator`, and adds only the designator
//! grammar (key in the locator, address in the hint). The channel is therefore
//! exactly as cleartext as `tcp` — the key authenticates the identity, it does
//! not encrypt the bytes; see the boundary in `docs/boundaries.md`.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const connection = @import("../connection.zig");
const netlayer = @import("../netlayer.zig");
const tcp = @import("tcp.zig");

const crypto = foundation.crypto;

const Netlayer = netlayer.Netlayer;
const NetLayerListener = netlayer.Listener;
const Buffers = netlayer.Buffers;
const Connection = connection.Connection;

/// The transport symbol carried in a `model.PeerLocator`. A separate symbol
/// from `tcp`, not a designator sniff on it: the two postures dispatch by
/// symbol, so a plain `tcp` locator's grammar and signed bytes never change.
pub const transport_name = model.transport.keyed_tcp;

/// The keyed-tcp netlayer's state: the host `std.Io` it dials and binds with,
/// plus the public half of the identity key its listeners advertise as their
/// designator. The caller — who holds the matching secret and signs accepts
/// with it (`driver.acceptVia` with a `.keyed` identity) — owns a `Resident` at
/// a stable address for as long as the transport slice holds the netlayer.
pub const Resident = struct {
    io: std.Io,
    /// The identity key listeners bound from this resident advertise:
    /// `localDesignator` is its canonical hex. Derive it from the accept
    /// identity's secret (`secret.publicKey()`) so designator and signing key
    /// cannot disagree.
    public_key: crypto.PeerKey,

    /// This resident as a `Netlayer`. `self` must outlive every connection the
    /// netlayer mints.
    pub fn netlayer(self: *Resident) Netlayer {
        return .{ .ctx = self, .vtable = &resident_vtable };
    }
};

const resident_vtable: Netlayer.VTable = .{
    .transport_name = transport_name,
    // The designator is the listener's Ed25519 key, so a driver dial pins the
    // partner's session identity to it (`net.netlayer.DesignatorScheme`).
    .designator_scheme = .key,
    .dial = residentDial,
    .listen = residentListen,
    .io = residentIo,
};

fn residentIo(ctx: *anyopaque) ?std.Io {
    const self: *Resident = @ptrCast(@alignCast(ctx));
    return self.io;
}

fn residentDial(
    ctx: *anyopaque,
    peer: *engine.Peer,
    loc: model.PeerLocator,
    bufs: Buffers,
) netlayer.DialError!Connection {
    const self: *Resident = @ptrCast(@alignCast(ctx));
    // Same admission as the completion loop: `tcp.DialResolver.resolve` owns key
    // shape + required hint + hostport parse.
    const direct = netlayer.directAddrHint(loc.hints) orelse &.{};
    const address = tcp.DialResolver.resolve(loc.transport, loc.designator, direct) catch return error.InvalidAddress;
    return tcp.connectAddress(self.io, peer, address, bufs.read, bufs.write, .{}) catch |err| tcp.classifyConnect(err);
}

fn residentListen(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    config: netlayer.ListenConfig,
) netlayer.ListenError!NetLayerListener {
    const self: *Resident = @ptrCast(@alignCast(ctx));
    // The bind address is ordinary tcp (`host:port`, port 0 for
    // kernel-chosen); the key plays no part in where the socket lives.
    const address = tcp.parseDesignator(config.designator) catch return error.InvalidAddress;
    const box = allocator.create(ListenerBox) catch return error.OutOfMemory;
    errdefer allocator.destroy(box);
    box.* = .{
        .listener = tcp.Listener.bind(self.io, address) catch return error.BindFailed,
        .public_key = self.public_key,
        .allocator = allocator,
    };
    return .{ .ctx = box, .vtable = &listener_vtable };
}

/// A heap-pinned `tcp.Listener` plus the identity key it advertises, behind a
/// contract `NetLayerListener`, freed by the contract listener's `close`.
const ListenerBox = struct {
    listener: tcp.Listener,
    public_key: crypto.PeerKey,
    allocator: std.mem.Allocator,
};

const listener_vtable: NetLayerListener.VTable = .{
    .transport_name = transport_name,
    .designator_scheme = .key,
    .accept = listenerAccept,
    .waitAcceptable = listenerWaitAcceptable,
    .localDesignator = listenerLocalDesignator,
    .localHint = listenerLocalHint,
    .close = listenerClose,
};

fn listenerAccept(ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) netlayer.AcceptError!Connection {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    return tcp.acceptOnListener(&box.listener, peer, bufs);
}

fn listenerWaitAcceptable(ctx: *anyopaque, timeout_ms: i32) netlayer.AcceptError!bool {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    return tcp.waitAcceptableOnListener(&box.listener, timeout_ms);
}

/// The dialable designator is the identity key's canonical hex — durable
/// across rebinds, which is the point. The bound socket address is `localHint`.
fn listenerLocalDesignator(ctx: *anyopaque, out: []u8) []const u8 {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    const hex = box.public_key.toDesignator();
    return netlayer.writeDesignator(out, hex[0..]);
}

/// The bound `host:port` (with the kernel-chosen port when bound to port 0):
/// the `direct-addresses` hint value a partner dials this listener with.
fn listenerLocalHint(ctx: *anyopaque, out: []u8) []const u8 {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    return tcp.designatorOnListener(&box.listener, out);
}

fn listenerClose(ctx: *anyopaque) void {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    box.listener.deinit();
    box.allocator.destroy(box);
}
