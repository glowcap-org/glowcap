//! The netlayer contract: a transport the driver dials and hosts against, never
//! a privileged built-in.
//!
//! OCapN addresses a peer by a locator whose `transport` symbol (`tcp`,
//! `inproc`, or `iroh`) selects how to reach it. A netlayer is the thing that turns
//! that symbol into bytes on a wire: it dials a locator to a `Connection` and
//! binds a `Listener` that accepts connections. The driver holds a
//! `[]const Netlayer` (the transport set) and dispatches on the locator's
//! transport symbol at runtime through `resolve` — so adding a transport is
//! putting one more netlayer in the slice, not editing the driver or the core.
//!
//! The contract is "produce a `Connection` over a stream," nothing more. Every
//! transport funnels through the same `Connection` (a `*std.Io.Reader` /
//! `*std.Io.Writer` pair plus a close handle), so a resident reuses the one
//! framing core in `pumpOver` rather than reframing bytes. `tcp`, `inproc`,
//! and the sidecar-backed `iroh` resident all live behind this contract; each
//! registers as new files without touching the driver or the core.
//!
//! Dispatch is a runtime vtable, not a comptime parameter, because the transport
//! symbol is a runtime value parsed from a URI or read off an inbound
//! `op:start-session`. A comptime contract would re-privilege whichever
//! transports were known at build time — the boundary this contract exists to
//! remove.
//!
//! The high-fan-out completion `Loop` is deliberately *outside* this contract.
//! It multiplexes raw kernel fds and cannot drive a userspace UDP transport, so
//! it is a tcp affordance beside the contract, not part of it. A userspace
//! transport scales through its own loop source instead: iroh's `LoopHost`
//! (ADR-0057) multiplexes many QUIC connections over the sidecar's one
//! readiness fd, the userspace-QUIC sibling of the kernel-fd `Loop`.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const connection = @import("connection.zig");

pub const Connection = connection.Connection;

/// Caller-owned read/write buffers handed to a dial/accept. `read` sizes the
/// steady per-connection memory, not the largest admissible frame (a larger
/// frame spills, bounded by the session's `max_frame_bytes`).
pub const Buffers = struct {
    read: []u8,
    write: []u8,
};

/// What to bind a `Listener` to. `designator` is the transport's address form
/// (a `host:port` for tcp; a node default for a userspace transport).
pub const ListenConfig = struct {
    designator: []const u8,
    hints: model.Hints = model.Hints.emptyFalse(),
};

/// A dial could not produce a connection. The transport's private errors are
/// projected onto this shared set so the driver dispatches without knowing them.
pub const DialError = error{ InvalidAddress, ConnectionLost } || std.mem.Allocator.Error;
/// Binding a listener failed: the designator did not parse (`InvalidAddress`),
/// or the bind/listen syscall failed, e.g. the port is in use (`BindFailed`).
pub const ListenError = error{ InvalidAddress, BindFailed } || std.mem.Allocator.Error;
/// Accepting a partner failed.
pub const AcceptError = error{ConnectionLost} || std.mem.Allocator.Error;

/// A bound listener for one transport: accept partners into caller-owned peers,
/// and report the dialable designator to sign into `op:start-session`. A runtime
/// vtable over a transport's concrete listener (e.g. a `tcp.Listener`).
pub const Listener = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The transport this listener hosts — the symbol signed into the
        /// responder's `op:start-session`, matching its netlayer's name.
        transport_name: []const u8,
        accept: *const fn (ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) AcceptError!Connection,
        /// Write this listener's dialable designator (the address a partner can
        /// reconnect to) into `out` and return the written slice. Returns an
        /// empty slice when `out` cannot hold the designator or the transport
        /// faulted; callers must treat empty as a defect, never sign it.
        localDesignator: *const fn (ctx: *anyopaque, out: []u8) []const u8,
        close: *const fn (ctx: *anyopaque) void,
    };

    pub fn transportName(self: Listener) []const u8 {
        return self.vtable.transport_name;
    }
    pub fn accept(self: Listener, peer: *engine.Peer, bufs: Buffers) AcceptError!Connection {
        return self.vtable.accept(self.ctx, peer, bufs);
    }
    pub fn localDesignator(self: Listener, out: []u8) []const u8 {
        return self.vtable.localDesignator(self.ctx, out);
    }
    pub fn close(self: Listener) void {
        self.vtable.close(self.ctx);
    }
};

/// One transport, behind a runtime vtable — a netlayer, reached as
/// `net.netlayer.Netlayer`. `dial` turns a locator into a live `Connection`;
/// `listen` binds a `Listener`. `transport_name` is both the dispatch key
/// (`resolve` matches on it) and the symbol signed into the locator (so it must
/// match what the partner matches on — Goblins' `^tcp-netlayer` keys on `tcp`).
/// `ctx` is the resident's own state (its `std.Io`, or a userspace endpoint),
/// which the caller keeps alive for as long as the transport slice holds the
/// netlayer.
pub const Netlayer = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        transport_name: []const u8,
        dial: *const fn (ctx: *anyopaque, peer: *engine.Peer, locator: model.PeerLocator, bufs: Buffers) DialError!Connection,
        listen: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, config: ListenConfig) ListenError!Listener,
    };

    pub fn transportName(self: Netlayer) []const u8 {
        return self.vtable.transport_name;
    }
    pub fn dial(self: Netlayer, peer: *engine.Peer, locator: model.PeerLocator, bufs: Buffers) DialError!Connection {
        return self.vtable.dial(self.ctx, peer, locator, bufs);
    }
    pub fn listen(self: Netlayer, allocator: std.mem.Allocator, config: ListenConfig) ListenError!Listener {
        return self.vtable.listen(self.ctx, allocator, config);
    }
};

/// Find the netlayer in `netlayers` that hosts `transport`, or null when none
/// does. The transport set is a bare `[]const Netlayer` the host owns and keeps
/// alive for every `Connection` minted from it (the residents behind it own the
/// live streams). A handful of netlayers, so a linear scan is the right
/// structure — no hash map for N≈2. The driver dials and hosts by resolving the
/// locator's transport symbol against this slice, failing closed when it finds
/// nothing rather than defaulting to any transport.
pub fn resolve(netlayers: []const Netlayer, transport: []const u8) ?Netlayer {
    for (netlayers) |nl| {
        if (std.mem.eql(u8, nl.transportName(), transport)) return nl;
    }
    return null;
}
