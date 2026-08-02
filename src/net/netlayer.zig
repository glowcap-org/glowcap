//! The netlayer contract: a transport the driver dials and hosts against, never
//! a privileged built-in.
//!
//! OCapN addresses a peer by a locator — a value with three parts: a `transport`
//! symbol that selects how to reach it (`"tcp"`, `"iroh"`, etc.), a `designator`
//! that names the specific peer (a `host:port` string for TCP, a hex-encoded
//! Ed25519 key for keyed-TCP and iroh), and optional `hints` for transport-specific
//! metadata like direct socket addresses. A netlayer is the thing that turns that
//! locator into bytes on a wire: it dials a locator to a `Connection` and binds
//! a `Listener` that accepts connections. The driver holds a `[]const Netlayer`
//! (the transport set) and dispatches on the locator's transport symbol at
//! runtime through `resolve` — so adding a transport is putting one more netlayer
//! in the slice, not editing the driver or the core.
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
//! transport scales through a completion `Backend` instead: iroh's
//! `iroh.Backend` under `completion.Loop`
//! (ADR-0057) multiplexes many QUIC connections over the sidecar's one
//! readiness fd, the userspace-QUIC sibling of the kernel-fd `Loop`.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const connection = @import("connection.zig");
const stream_shim = @import("stream_shim.zig");

const Io = std.Io;

pub const Connection = connection.Connection;

/// Caller-owned read/write buffers handed to a dial/accept. `read` sizes the
/// steady per-connection memory, not the largest admissible frame (a larger
/// frame assembles across multiple reads in the connection's bounded overflow
/// buffer, its `foundation.Spill`, bounded by the session's
/// `max_frame_bytes`).
pub const Buffers = struct {
    read: []u8,
    write: []u8,
};

/// One pinned byte-source stream: a `stream_shim.Shim(Source)` reader/writer pair
/// plus the one per-connection allocation the userspace transports need, so the
/// vtable can recover the concrete reader and writer from `&interface` by field
/// offset (the same pin tcp's `TcpStream` holds, ADR-0043). A transport supplies
/// its `Source` (the Shim byte source) and a `Context` that owns the transport
/// handle and declares `fn closeStream(Context) void`, run once inside `close`
/// before the allocation is freed. Allocated at connect/accept, freed by the
/// connection's transport handle on `close`. tcp does not ride this: its stream
/// is `std.Io.net.Stream`, which carries its own reader/writer and a real fd.
pub fn PinnedStream(comptime Source: type, comptime Context: type) type {
    return struct {
        const Self = @This();
        const ShimT = stream_shim.Shim(Source);

        reader: ShimT.Reader,
        writer: ShimT.Writer,
        allocator: std.mem.Allocator,
        context: Context,

        /// Pin a stream on `allocator`. `read_source` and `write_source` are the
        /// Shim byte sources for each direction — the same value both ways when a
        /// transport reads and writes one handle, distinct channels when it does
        /// not. `context` owns the transport handle `close` releases.
        pub fn create(
            allocator: std.mem.Allocator,
            read_source: Source,
            write_source: Source,
            bufs: Buffers,
            context: Context,
        ) std.mem.Allocator.Error!*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .reader = ShimT.Reader.init(read_source, bufs.read),
                .writer = ShimT.Writer.init(write_source, bufs.write),
                .allocator = allocator,
                .context = context,
            };
            return self;
        }

        pub fn intoConnection(self: *Self, io: Io, peer: *engine.Peer) Connection {
            return Connection.init(io, peer, &self.reader.interface, &self.writer.interface, .{
                .ctx = self,
                .close_fn = close,
                .socket_handle_fn = socketHandle,
            });
        }

        /// Release the transport handle through the context hook, then free the
        /// pinned allocation. The hook runs before the free, so a source whose
        /// bytes live in the handle (an in-process pipe) is closed while it is
        /// still valid.
        pub fn close(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.context.closeStream();
            self.allocator.destroy(self);
        }

        fn socketHandle(ctx: *anyopaque) ?Io.net.Socket.Handle {
            _ = ctx;
            return null; // No fd: a userspace stream is not pollable.
        }
    };
}

/// What to bind a `Listener` to. `designator` is the transport's address form
/// (a `host:port` for tcp; a node default for a userspace transport).
pub const ListenConfig = struct {
    designator: []const u8,
    hints: model.Hints = model.Hints.emptyFalse(),
};

/// What a transport's locator designator *is*, declared on the vtable so the
/// driver dispatches identity behavior without naming transports. `address`
/// means the designator is where to dial (a `host:port`) and the listener owns
/// it. `key` means the designator is the peer's Ed25519 public key in canonical
/// lowercase hex (`foundation.crypto.PeerKey.toDesignator`), dial addresses
/// ride the `hint_direct_addresses` hint, and the signed designator derives
/// from the identity key, never the socket. That is what lets a partner
/// re-dial the same designator across a process restart and lets the dial-side
/// pin (`engine.Peer.expectPartnerKey`) verify the session key against the
/// designator it dialed.
pub const DesignatorScheme = enum { address, key };

/// How a transport authenticates the durable identity its key designator
/// names (ADR-0097), the netlayer half of the byte-fed
/// `driver_core.vocab.AuthenticationMechanism` mirror. Designator grammar and
/// authentication mechanism are separate contracts: `key` says what the
/// designator *is*, this says what *proves* it. `authenticated_transport`
/// means the transport layer itself proves the remote's durable key (iroh's
/// QUIC handshake, WebRTC's capability-authorized DTLS). `durable_key_attestation`
/// means no lower layer can, so the keyed hello carries a
/// `session-key-attestation` credential signed by the durable key and the
/// driver installs `engine.Peer.requirePartnerAttestation` before the
/// handshake. `none` is the address posture: connection provenance only.
pub const AuthenticationMechanism = enum { authenticated_transport, durable_key_attestation, none };

/// The locator hint carrying a partner's comma-separated direct socket
/// addresses — the transport-neutral dial-address channel a `key`-scheme
/// designator needs, since the designator itself no longer says where to dial.
/// The iroh resident re-exports this name; keyed TCP requires the hint on every
/// dial (TCP has no discovery).
pub const hint_direct_addresses = model.transport.hint_direct_addresses;

/// The locator's `hint_direct_addresses` string hint, or null when the hint is
/// missing or carries a non-string value.
pub fn directAddrHint(hints: model.Hints) ?[]const u8 {
    for (hints.entries) |entry| {
        if (!std.mem.eql(u8, entry.name, hint_direct_addresses)) continue;
        switch (entry.value) {
            .string => |s| return s,
            else => return null,
        }
    }
    return null;
}

/// Write a listener's designator into the caller's `out` under the netlayer
/// contract that a designator never truncates: an `out` too small for the whole
/// designator yields the empty defect slice, never a partial address a partner
/// could not dial. Returns the written prefix of `out`. Every resident whose
/// designator is a stored byte run (a key hex, an inproc name) fills its
/// `localDesignator` arm through here so the no-truncation rule lives in one
/// place; a resident that writes its designator straight into `out` honors the
/// same rule inline.
pub fn writeDesignator(out: []u8, designator: []const u8) []const u8 {
    if (out.len < designator.len) return out[0..0];
    @memcpy(out[0..designator.len], designator);
    return out[0..designator.len];
}

/// A dial could not produce a connection. The transport's private errors are
/// projected onto this shared set so the driver dispatches without knowing them.
/// The arms form a retry axis (ADR-0081 / ADR-0082): `InvalidAddress` and
/// `ConnectionRefused` are permanent (bad designator/hint, or an active peer
/// refusal — never retry); `NetworkUnreachable` / `TimedOut` / `ConnectionLost`
/// are transient (retry with backoff under `driver.ResilientClient`);
/// `OutOfMemory` is permanent local pressure (not a network transient).
pub const DialError = error{
    InvalidAddress,
    ConnectionRefused,
    NetworkUnreachable,
    TimedOut,
    ConnectionLost,
} || std.mem.Allocator.Error;
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
        /// The transport this listener hosts, the symbol signed into the
        /// responder's `op:start-session`, matching its netlayer's name.
        transport_name: []const u8,
        /// What this listener's designator is (see `DesignatorScheme`);
        /// matches its netlayer's declaration.
        designator_scheme: DesignatorScheme = .address,
        /// How the designator is authenticated (see `AuthenticationMechanism`);
        /// matches its netlayer's declaration.
        authentication: AuthenticationMechanism = .none,
        accept: *const fn (ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) AcceptError!Connection,
        /// Wait until `accept` would make progress, up to `timeout_ms`.
        /// Returns false on timeout (caller may re-check a stop latch), true
        /// when the next `accept` should proceed. The one poll-guard that lets
        /// a blocking host exit without closing the listen FD from another
        /// thread (Zig Threaded Io panics on that BADF).
        waitAcceptable: *const fn (ctx: *anyopaque, timeout_ms: i32) AcceptError!bool,
        /// Write this listener's dialable designator (the address a partner can
        /// reconnect to — for a `key` scheme, the identity key's canonical hex)
        /// into `out` and return the written slice. Returns an
        /// empty slice when `out` cannot hold the designator or the transport
        /// faulted; callers must treat empty as a defect, never sign it.
        localDesignator: *const fn (ctx: *anyopaque, out: []u8) []const u8,
        /// Write the `hint_direct_addresses` value a partner dials this
        /// listener with (the bound `host:port` for keyed TCP) into `out` and
        /// return the written slice, or leave this null when the transport
        /// carries no dial hint (an address-scheme listener, whose designator
        /// already says where to dial; or iroh, whose accept half signs
        /// hint-less). Empty on a short buffer, like `localDesignator`.
        localHint: ?*const fn (ctx: *anyopaque, out: []u8) []const u8 = null,
        close: *const fn (ctx: *anyopaque) void,
    };

    pub fn transportName(self: Listener) []const u8 {
        return self.vtable.transport_name;
    }
    pub fn designatorScheme(self: Listener) DesignatorScheme {
        return self.vtable.designator_scheme;
    }
    pub fn authentication(self: Listener) AuthenticationMechanism {
        return self.vtable.authentication;
    }
    pub fn accept(self: Listener, peer: *engine.Peer, bufs: Buffers) AcceptError!Connection {
        return self.vtable.accept(self.ctx, peer, bufs);
    }
    pub fn waitAcceptable(self: Listener, timeout_ms: i32) AcceptError!bool {
        return self.vtable.waitAcceptable(self.ctx, timeout_ms);
    }
    pub fn localDesignator(self: Listener, out: []u8) []const u8 {
        return self.vtable.localDesignator(self.ctx, out);
    }
    /// The `hint_direct_addresses` value a partner dials this listener with, or
    /// empty when the transport has none (or `out` cannot hold it).
    pub fn localHint(self: Listener, out: []u8) []const u8 {
        const f = self.vtable.localHint orelse return out[0..0];
        return f(self.ctx, out);
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
        /// What this transport's locator designator is (see
        /// `DesignatorScheme`). Defaults to `address`; a transport whose
        /// designator is the peer's key (iroh, keyed TCP) declares `key`, which
        /// is what arms the driver's dial-side identity pin.
        designator_scheme: DesignatorScheme = .address,
        /// How the designator is authenticated (see `AuthenticationMechanism`).
        /// Every `key`-scheme resident declares a non-`none` mechanism; the
        /// driver installs the matching engine contract before the handshake.
        authentication: AuthenticationMechanism = .none,
        dial: *const fn (ctx: *anyopaque, peer: *engine.Peer, locator: model.PeerLocator, bufs: Buffers) DialError!Connection,
        listen: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, config: ListenConfig) ListenError!Listener,
        /// The host `std.Io` this resident runs on, or null for a resident
        /// with none (an in-memory pipe network). The owning driver draws
        /// identity entropy at this boundary before any connection exists,
        /// which is why the vtable exposes it rather than the connection
        /// alone.
        io: *const fn (ctx: *anyopaque) ?std.Io = &noIo,
    };

    fn noIo(ctx: *anyopaque) ?std.Io {
        _ = ctx;
        return null;
    }

    pub fn transportName(self: Netlayer) []const u8 {
        return self.vtable.transport_name;
    }
    pub fn designatorScheme(self: Netlayer) DesignatorScheme {
        return self.vtable.designator_scheme;
    }
    pub fn authentication(self: Netlayer) AuthenticationMechanism {
        return self.vtable.authentication;
    }
    pub fn dial(self: Netlayer, peer: *engine.Peer, locator: model.PeerLocator, bufs: Buffers) DialError!Connection {
        return self.vtable.dial(self.ctx, peer, locator, bufs);
    }
    pub fn listen(self: Netlayer, allocator: std.mem.Allocator, config: ListenConfig) ListenError!Listener {
        return self.vtable.listen(self.ctx, allocator, config);
    }

    /// The resident's host `std.Io`, or null (see `VTable.io`).
    pub fn io(self: Netlayer) ?std.Io {
        return self.vtable.io(self.ctx);
    }
};

/// Find the netlayer in `netlayers` that hosts `transport`, or null when none
/// does. The transport set is a bare `[]const Netlayer` the host owns and keeps
/// alive for every `Connection` minted from it (the residents behind it own the
/// live streams). A handful of netlayers, so a linear scan is the right
/// structure, no hash map for N≈2. The driver dials and hosts by resolving the
/// locator's transport symbol against this slice, failing closed when it finds
/// nothing rather than defaulting to any transport.
pub fn resolve(netlayers: []const Netlayer, transport: []const u8) ?Netlayer {
    for (netlayers) |nl| {
        if (std.mem.eql(u8, nl.transportName(), transport)) return nl;
    }
    return null;
}
