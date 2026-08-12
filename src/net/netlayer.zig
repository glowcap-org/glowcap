//! The netlayer contract: a transport the driver dials and hosts against, never
//! a privileged built-in.
//!
//! OCapN addresses a peer by a locator — a value with three parts: a `transport`
//! symbol that selects how to reach it (`"tcp"`, `"iroh"`, etc.), a `designator`
//! that names the specific peer (a `host:port` string for TCP, a hex-encoded
//! Ed25519 key for keyed-TCP and iroh), and optional `hints` for transport-specific
//! metadata like direct socket addresses. A netlayer is a listener-capable
//! stream transport: it dials a locator to a `Connection` and binds a `Listener`
//! that accepts connections. The driver holds a `[]const Netlayer` and
//! dispatches on the locator's transport symbol at runtime through `resolve`.
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
//! A multiplexed transport with one readiness descriptor and many
//! connection ids uses the sibling `MultiplexedResident` contract, whose explicit
//! listener lifecycle and accept-claim operations preserve the same ownership
//! guarantees without pretending it is a per-connection stream vtable.
//! High-fan-out completion backends are a third I/O realization under
//! `completion.Loop`; they share transport and locator semantics without
//! pretending these ownership models are one vtable.

const std = @import("std");

const crypto = @import("foundation").crypto;
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
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(Context, "socketHandle")) return self.context.socketHandle();
            return null;
        }
    };
}

/// What to bind a `Listener` to. `designator` is the transport's address form
/// (a `host:port` for tcp; a node default for a userspace transport).
/// `identity` is the Host's durable public key. A key-designator transport
/// either uses it as the listener designator (TCP) or verifies its own
/// endpoint identity agrees (the driver enforces the latter generically).
pub const ListenConfig = struct {
    designator: []const u8,
    hints: model.Hints = model.Hints.emptyFalse(),
    identity: ?crypto.PeerKey = null,
};

/// What a transport's locator designator *is*, declared on the vtable so the
/// driver dispatches identity behavior without naming transports. `address`
/// means the designator is where to dial (a `host:port`) and the listener owns
/// it. `key` means the designator is the peer's Ed25519 public key in canonical
/// lowercase hex (`foundation.crypto.PeerKey.toDesignator`), dial addresses
/// ride the `hint_direct_addresses` hint, and the signed designator derives
/// from the identity key, never the socket. That is what lets a partner
/// re-dial the same designator across a process restart. A dial records that
/// target key; a partner that selects a key-designator acceptable route must
/// claim the same key. An address route is independent of the current channel
/// (ADR-0109). This is target matching, not authentication; each connection's
/// `session_pubkey` is a separate identity.
pub const DesignatorScheme = model.transport.DesignatorScheme;

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

/// Size-query/copy contract shared by listener metadata callbacks. The return
/// value is always the complete byte count; `out` is written only when it can
/// hold the whole value. An empty buffer therefore asks for the exact size
/// without allocating or accepting a truncated locator component.
pub fn writeListenerMetadata(out: []u8, value: []const u8) isize {
    if (out.len >= value.len) @memcpy(out[0..value.len], value);
    return @intCast(value.len);
}

/// A dial could not produce a connection. The transport's private errors are
/// projected onto this shared set so the driver dispatches without knowing them.
/// The arms form a retry axis (ADR-0081 / ADR-0082): `InvalidAddress` and
/// `ConnectionRefused` are permanent (bad designator/hint, or an active peer
/// refusal — never retry); `NetworkUnreachable` / `TimedOut` / `ConnectionLost`
/// are transient (retry with backoff under `driver.DialRetry`);
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

/// A stream-provider dial between admission and connection claim. Unlike an
/// multiplexed resident, each attempt has its own pollable descriptor and yields
/// an ordinary per-connection stream. The value owns cancellation until
/// `finish` consumes it on either success or refusal.
pub const ConnectAttempt = struct {
    owner: *anyopaque,
    attempt: ?*anyopaque,
    vtable: *const VTable,
    readiness_fd: i32,

    pub const VTable = struct {
        finish: *const fn (
            owner: *anyopaque,
            attempt: *anyopaque,
            peer: *engine.Peer,
            bufs: Buffers,
        ) DialError!Connection,
        cancel: *const fn (owner: *anyopaque, attempt: *anyopaque) void,
    };

    pub fn readinessFd(self: ConnectAttempt) i32 {
        return self.readiness_fd;
    }

    pub fn take(self: *ConnectAttempt) ConnectAttempt {
        const owned = self.*;
        self.attempt = null;
        return owned;
    }

    pub fn deinit(self: *ConnectAttempt) void {
        const attempt = self.attempt orelse return;
        self.attempt = null;
        self.vtable.cancel(self.owner, attempt);
    }

    pub fn finish(self: *ConnectAttempt, peer: *engine.Peer, bufs: Buffers) DialError!Connection {
        const attempt = self.attempt orelse unreachable;
        self.attempt = null;
        return self.vtable.finish(self.owner, attempt, peer, bufs);
    }
};

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
        /// Whether the Host must seal this listener's byte channel before any
        /// CapTP bytes move. Kept beside the listener execution callbacks so
        /// extension transports receive the same fail-closed admission as
        /// first-party symbols.
        sealed_channel: bool = false,
        accept: *const fn (ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) AcceptError!Connection,
        /// Wait until `accept` would make progress, up to `timeout_ms`.
        /// Returns false on timeout (caller may re-check a stop latch), true
        /// when the next `accept` should proceed. The one poll-guard that lets
        /// a blocking host exit without closing the listen FD from another
        /// thread (Zig Threaded Io panics on that BADF).
        waitAcceptable: *const fn (ctx: *anyopaque, timeout_ms: i32) AcceptError!bool,
        /// Wait until this listener's advertised locator is reachable. Most
        /// transports are ready when `listen` returns and leave this null.
        /// A rendezvous transport whose registration is background-owned uses
        /// this distinct edge so callers never confuse "registered" with
        /// "an inbound connection is acceptable". Negative waits forever;
        /// zero only observes current state; positive values are milliseconds.
        waitReady: ?*const fn (ctx: *anyopaque, timeout_ms: i32) AcceptError!bool = null,
        /// Materialize this listener's complete locator. The caller owns the
        /// returned value and frees it with `model.freePeerLocator`.
        localLocator: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) ListenError!model.PeerLocator,
        /// Validate and canonicalize a caller-proposed replacement through
        /// the transport implementation that owns this listener's grammar.
        canonicalizeLocator: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            locator: model.PeerLocator,
        ) ListenError!model.PeerLocator,
        /// The listener's OS-pollable accept descriptor, borrowed, for a
        /// host face that mirrors accept readiness into an aggregate set
        /// (ADR-0112). Left null by a transport whose accept has no single
        /// descriptor; `waitAcceptable` then stays the only readiness verb.
        readiness_fd: ?*const fn (ctx: *anyopaque) i32 = null,
        close: *const fn (ctx: *anyopaque) void,
    };

    pub fn transportName(self: Listener) []const u8 {
        return self.vtable.transport_name;
    }
    pub fn designatorScheme(self: Listener) DesignatorScheme {
        return self.vtable.designator_scheme;
    }
    pub fn sealedChannel(self: Listener) bool {
        return self.vtable.sealed_channel;
    }
    pub fn accept(self: Listener, peer: *engine.Peer, bufs: Buffers) AcceptError!Connection {
        return self.vtable.accept(self.ctx, peer, bufs);
    }
    pub fn waitAcceptable(self: Listener, timeout_ms: i32) AcceptError!bool {
        return self.vtable.waitAcceptable(self.ctx, timeout_ms);
    }
    /// The pollable accept descriptor, or null when the transport reports
    /// accept readiness only through `waitAcceptable`.
    pub fn readinessFd(self: Listener) ?i32 {
        const f = self.vtable.readiness_fd orelse return null;
        return f(self.ctx);
    }
    pub fn waitReady(self: Listener, timeout_ms: i32) AcceptError!bool {
        const f = self.vtable.waitReady orelse return true;
        return f(self.ctx, timeout_ms);
    }
    pub fn localLocator(self: Listener, allocator: std.mem.Allocator) ListenError!model.PeerLocator {
        return self.vtable.localLocator(self.ctx, allocator);
    }
    pub fn canonicalizeLocator(
        self: Listener,
        allocator: std.mem.Allocator,
        locator: model.PeerLocator,
    ) ListenError!model.PeerLocator {
        return self.vtable.canonicalizeLocator(self.ctx, allocator, locator);
    }
    pub fn close(self: Listener) void {
        self.vtable.close(self.ctx);
    }
};

/// Canonicalization for a listener whose dialable transport and designator are
/// immutable after bind. Transport implementations opt into this explicitly;
/// address-rewriting transports must provide their own policy.
pub fn canonicalizeFixedLocator(
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
    expected_transport: []const u8,
    expected_designator: []const u8,
) ListenError!model.PeerLocator {
    model.validatePeerLocator(locator) catch return error.InvalidAddress;
    if (!std.mem.eql(u8, locator.transport, expected_transport) or
        !std.mem.eql(u8, locator.designator, expected_designator))
        return error.InvalidAddress;
    return model.clonePeerLocator(allocator, locator);
}

/// One transport, behind a runtime vtable — a netlayer, reached as
/// `net.netlayer.Netlayer`. `dial` turns a locator into a live `Connection`;
/// `listen` binds a `Listener`. `profile.symbol` is both the dispatch key
/// (`resolve` matches on it) and the symbol signed into the locator (so it must
/// match what the partner matches on — Goblins' `^tcp-netlayer` keys on `tcp`).
/// `ctx` is the resident's own state (its `std.Io`, or a userspace endpoint),
/// which the caller keeps alive for as long as the transport slice holds the
/// netlayer.
pub const Netlayer = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Complete locator and channel semantics for the symbol this
        /// implementation realizes. Provider registration moves this value as
        /// one unit so dial planning and session protection cannot drift.
        profile: model.transport.Metadata,
        dial: ?*const fn (ctx: *anyopaque, peer: *engine.Peer, locator: model.PeerLocator, bufs: Buffers) DialError!Connection,
        /// Begin a stream dial without parking the caller. The returned
        /// attempt owns one readiness descriptor until finish or cancel.
        start_dial: ?*const fn (ctx: *anyopaque, locator: model.PeerLocator) DialError!ConnectAttempt = null,
        listen: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, config: ListenConfig) ListenError!Listener,
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
        return self.vtable.profile.symbol;
    }
    pub fn designatorScheme(self: Netlayer) DesignatorScheme {
        return self.vtable.profile.designator_scheme;
    }
    pub fn transportProfile(self: Netlayer) model.transport.Metadata {
        return self.vtable.profile;
    }
    pub fn supportsDial(self: Netlayer) bool {
        return self.vtable.dial != null or self.vtable.start_dial != null;
    }
    pub fn supportsBlockingDial(self: Netlayer) bool {
        return self.vtable.dial != null;
    }
    pub fn supportsStagedDial(self: Netlayer) bool {
        return self.vtable.start_dial != null;
    }
    pub fn supportsListen(self: Netlayer) bool {
        return self.vtable.listen != null;
    }
    pub fn dial(self: Netlayer, peer: *engine.Peer, locator: model.PeerLocator, bufs: Buffers) DialError!Connection {
        const dial_fn = self.vtable.dial orelse unreachable;
        return dial_fn(self.ctx, peer, locator, bufs);
    }
    pub fn startDial(self: Netlayer, locator: model.PeerLocator) DialError!ConnectAttempt {
        const start = self.vtable.start_dial orelse unreachable;
        return start(self.ctx, locator);
    }
    pub fn listen(self: Netlayer, allocator: std.mem.Allocator, config: ListenConfig) ListenError!Listener {
        const listen_fn = self.vtable.listen orelse unreachable;
        return listen_fn(self.ctx, allocator, config);
    }

    /// The resident's host `std.Io`, or null (see `VTable.io`).
    pub fn io(self: Netlayer) ?std.Io {
        return self.vtable.io(self.ctx);
    }
};

/// The part of a resident that every transport writes the same way.
///
/// A `VTable` hands each entry point the resident as `*anyopaque`, so every
/// transport recovers its own type the same way and answers `io` from the same
/// field. Those spellings carry no transport-specific decision, and four
/// residents held four identical copies of them. A transport keeps what differs
/// -- its name, its designator scheme, and the bodies of `dial` and `listen` --
/// and takes the rest from here, so a new transport starts with the glue
/// already correct.
///
/// Available to a resident that keeps its host `std.Io` in a field named `io`.
/// A resident with no `std.Io` at all leaves `VTable.io` at its default instead
/// of using this.
pub fn ResidentContext(comptime R: type) type {
    return struct {
        /// Recover the resident from the context a `VTable` entry point is given.
        pub inline fn of(ctx: *anyopaque) *R {
            return @ptrCast(@alignCast(ctx));
        }

        /// `VTable.io` for a resident that holds its `std.Io` in `io`.
        pub fn io(ctx: *anyopaque) ?std.Io {
            return of(ctx).io;
        }
    };
}

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
