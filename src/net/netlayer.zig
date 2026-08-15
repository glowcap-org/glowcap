//! The netlayer contract: a transport the driver dials and hosts against, never
//! a privileged built-in.
//!
//! OCapN addresses a peer by a locator — a value with three parts: a `transport`
//! symbol that selects how to reach it (`"tcp"`, `"iroh"`, etc.), a `designator`
//! that names the specific peer (a `host:port` string for TCP, a hex-encoded
//! Ed25519 key for keyed-TCP and iroh), and optional `hints` for transport-specific
//! metadata like direct socket addresses. A netlayer is a stream transport: it
//! may dial a locator to a `Connection`, bind a `Listener` that accepts
//! connections, or support both. The driver holds a `[]const Netlayer` and
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

const foundation = @import("foundation");
const crypto = foundation.crypto;
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

/// Borrowed provider-owned configuration for one dial or listener operation.
/// The generic runtime forwards this view without interpreting it. The selected
/// provider validates the exact payload type and must copy any values retained
/// after the starting call returns. `.inherit` asks the provider to use its
/// configured defaults; an explicit payload may still encode "disabled".
pub const OperationOptions = struct {
    data: ?*const anyopaque = null,
    size: usize = 0,

    pub const inherit: OperationOptions = .{};

    pub fn borrow(comptime T: type, value: *const T) OperationOptions {
        return .{ .data = value, .size = @sizeOf(T) };
    }

    /// Decode the provider's exact payload type. Absence means inherit; a
    /// non-null payload with the wrong size or alignment is rejected before a
    /// provider reads it.
    pub fn decode(self: OperationOptions, comptime T: type) error{InvalidOptions}!?*const T {
        const data = self.data orelse {
            if (self.size != 0) return error.InvalidOptions;
            return null;
        };
        if (self.size != @sizeOf(T) or @intFromPtr(data) % @alignOf(T) != 0)
            return error.InvalidOptions;
        return @ptrCast(@alignCast(data));
    }

    pub fn requireInherited(self: OperationOptions) error{InvalidOptions}!void {
        if (self.data != null or self.size != 0) return error.InvalidOptions;
    }
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
                .take_failure_fn = takeFailure,
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

        fn takeFailure(ctx: *anyopaque) ?foundation.FailureChain {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(Context, "takeFailure")) return self.context.takeFailure();
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
    identity: ?crypto.PeerKey = null,
    options: OperationOptions = .inherit,
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

/// Size-query/copy contract shared by listener restoration-state callbacks. The return
/// value is always the complete byte count; `out` is written only when it can
/// hold the whole value. An empty buffer therefore asks for the exact size
/// without allocating or accepting a truncated locator component.
pub fn writeListenerRestorationState(out: []u8, value: []const u8) usize {
    if (out.len >= value.len) @memcpy(out[0..value.len], value);
    return value.len;
}

/// A provider that advertises restoration state failed to query or copy it.
/// Absence is represented by the optional callback, not by this error set.
pub const RestorationStateError = error{ProviderFailure};

/// A dial could not produce a connection. The transport's private errors are
/// projected onto this shared set so the driver dispatches without knowing them.
/// The arms form a retry axis (ADR-0081 / ADR-0082): `InvalidAddress` and
/// `ConnectionRefused` are permanent (bad designator/hint, or an active peer
/// refusal — never retry); `NetworkUnreachable` / `TimedOut` / `ConnectionLost`
/// are transient (retry with backoff under `driver.DialRetry`);
/// `OutOfMemory` is permanent local pressure (not a network transient).
pub const DialError = error{
    InvalidAddress,
    InvalidOptions,
    ConnectionRefused,
    NetworkUnreachable,
    TimedOut,
    ConnectionLost,
    SocketConfigurationFailed,
    WakeNudgeFailed,
} || std.mem.Allocator.Error;
pub const DialFailure = struct {
    classification: DialError,
    chain: foundation.FailureChain,

    pub fn init(cause: DialError) DialFailure {
        return .{ .classification = cause, .chain = .init(cause) };
    }

    pub fn fromChain(classification: DialError, chain: foundation.FailureChain) DialFailure {
        return .{ .classification = classification, .chain = chain };
    }
};
/// Binding a listener failed: the designator did not parse (`InvalidAddress`),
/// or the bind/listen syscall failed, e.g. the port is in use (`BindFailed`).
pub const ListenError = error{ InvalidAddress, InvalidOptions, BindFailed } || std.mem.Allocator.Error;
/// Accepting a partner failed.
pub const AcceptError = error{
    ConnectionLost,
    SocketConfigurationFailed,
    WakeNudgeFailed,
    WakeDrainFailed,
} || std.mem.Allocator.Error;

/// A rejected accept keeps its control-flow classification and its exact,
/// bounded provider-owned cause chain together.  The classification decides
/// runtime policy; the chain is the fact projected to the listener owner.
pub const AcceptFailure = struct {
    classification: AcceptError,
    chain: foundation.FailureChain,

    pub fn init(classification: AcceptError) AcceptFailure {
        return .{ .classification = classification, .chain = .init(classification) };
    }

    pub fn fromChain(classification: AcceptError, chain: foundation.FailureChain) AcceptFailure {
        return .{ .classification = classification, .chain = chain };
    }
};

pub const AcceptOutcome = union(enum) {
    accepted: Connection,
    failed: AcceptFailure,
};

pub const AcceptReadinessOutcome = union(enum) {
    ready: bool,
    failed: AcceptFailure,
};

/// A listener is always retired before close returns. Null means every cleanup
/// effect succeeded; a value retains the first cleanup failure and bounded
/// later consequences without making logging or runtime terminality netlayer
/// policy.
pub const ListenerCloseFailure = foundation.FailureChain;
pub const ListenFailure = foundation.FailureChain;

/// A stream-provider dial between admission and connection claim. Unlike an
/// multiplexed resident, each attempt has its own pollable descriptor and yields
/// an ordinary per-connection stream. The value owns cancellation until
/// `finish` consumes it on either success or refusal.
pub const DialAttempt = struct {
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
        ) DialFinishOutcome,
        cancel: *const fn (owner: *anyopaque, attempt: *anyopaque) ?foundation.FailureChain,
    };

    pub fn readinessFd(self: DialAttempt) i32 {
        return self.readiness_fd;
    }

    pub fn take(self: *DialAttempt) DialAttempt {
        const owned = self.*;
        self.attempt = null;
        return owned;
    }

    pub fn deinit(self: *DialAttempt) ?foundation.FailureChain {
        const attempt = self.attempt orelse return null;
        self.attempt = null;
        return self.vtable.cancel(self.owner, attempt);
    }

    pub fn finish(self: *DialAttempt, peer: *engine.Peer, bufs: Buffers) DialFinishOutcome {
        const attempt = self.attempt orelse unreachable;
        self.attempt = null;
        return self.vtable.finish(self.owner, attempt, peer, bufs);
    }
};

pub const DialStartOutcome = union(enum) {
    admitted: DialAttempt,
    failed: DialFailure,
};

pub const DialFinishOutcome = union(enum) {
    connected: Connection,
    failed: DialFailure,
};

/// Exactly one execution form for a stream netlayer dial. A blocking
/// implementation receives the peer and final wire buffers immediately; a
/// staged implementation returns a pollable attempt and receives them only
/// when completion is claimed. The tagged shape prevents one transport from
/// publishing two divergent dial authorities.
pub const DialOperation = union(enum) {
    blocking: *const fn (
        ctx: *anyopaque,
        peer: *engine.Peer,
        locator: model.PeerLocator,
        bufs: Buffers,
        options: OperationOptions,
    ) DialError!Connection,
    staged: *const fn (
        ctx: *anyopaque,
        locator: model.PeerLocator,
        options: OperationOptions,
    ) DialStartOutcome,
};

/// A stream-provider listener setup that may wait on external progress. The
/// transport owns the task and readiness descriptor; the driver owns exactly
/// one finish-or-cancel edge. Bounded listener setup uses `Netlayer.listen`
/// directly and allocates no attempt.
pub const ListenAttempt = struct {
    owner: *anyopaque,
    attempt: ?*anyopaque,
    finish_fn: *const fn (
        owner: *anyopaque,
        attempt: *anyopaque,
        allocator: std.mem.Allocator,
    ) ListenFinishOutcome,
    cancel_fn: *const fn (owner: *anyopaque, attempt: *anyopaque) ?ListenerCloseFailure,
    readiness_fd: i32,

    pub fn readinessFd(self: ListenAttempt) i32 {
        return self.readiness_fd;
    }

    pub fn take(self: *ListenAttempt) ListenAttempt {
        const owned = self.*;
        self.attempt = null;
        return owned;
    }

    pub fn deinit(self: *ListenAttempt) ?ListenerCloseFailure {
        const attempt = self.attempt orelse return null;
        self.attempt = null;
        return self.cancel_fn(self.owner, attempt);
    }

    pub fn finish(self: *ListenAttempt, allocator: std.mem.Allocator) ListenFinishOutcome {
        const attempt = self.attempt orelse unreachable;
        self.attempt = null;
        return self.finish_fn(self.owner, attempt, allocator);
    }
};

/// Completion of an admitted listener setup. Failure is a value so cleanup
/// consequences remain attached to the setup error that caused them.
pub const ListenFinishOutcome = union(enum) {
    ready: Listener,
    failed: ListenFailure,
};

/// The ownership result of one listener-construction call. Immediate
/// completion and externally paced completion are states of the same
/// operation, not separate provider capabilities.
pub const ListenResult = union(enum) {
    ready: Listener,
    pending: ListenAttempt,

    /// Consume an immediate listener for an embedding that deliberately does
    /// not drive asynchronous setup. A pending attempt is canceled before the
    /// refusal returns, so narrowing the sum cannot leak provider work.
    pub fn requireReady(self: *ListenResult) ListenFinishOutcome {
        const outcome: ListenFinishOutcome = switch (self.*) {
            .ready => |listener| blk: {
                break :blk .{ .ready = listener };
            },
            .pending => |*attempt| blk: {
                var failure = ListenFailure.init(error.SetupPending);
                if (attempt.deinit()) |cleanup| failure.noteChain(cleanup);
                break :blk .{ .failed = failure };
            },
        };
        self.* = undefined;
        return outcome;
    }

    pub fn deinit(self: *ListenResult) ?ListenerCloseFailure {
        const failure = switch (self.*) {
            .ready => |listener| listener.close(),
            .pending => |*attempt| blk: {
                break :blk attempt.deinit();
            },
        };
        self.* = undefined;
        return failure;
    }
};

/// Admission result for listener construction. Unlike a Zig error union, the
/// failed arm can retain cleanup that ran after the primary setup refusal.
pub const ListenStartOutcome = union(enum) {
    admitted: ListenResult,
    failed: ListenFailure,
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
        accept_detailed: ?*const fn (ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) AcceptOutcome = null,
        /// Wait until `accept` would make progress, up to `timeout_ms`.
        /// Returns false on timeout (caller may re-check a stop latch), true
        /// when the next `accept` should proceed. The one poll-guard that lets
        /// a blocking host exit without closing the listen FD from another
        /// thread (Zig Threaded Io panics on that BADF).
        waitAcceptable: *const fn (ctx: *anyopaque, timeout_ms: i32) AcceptError!bool,
        wait_acceptable_detailed: ?*const fn (ctx: *anyopaque, timeout_ms: i32) AcceptReadinessOutcome = null,
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
        /// Write opaque transport-owned bytes sufficient to restore this
        /// listener's local address, when the transport has such state. The
        /// return value is the complete size; a short `out` is not modified.
        restoration_state: ?*const fn (ctx: *anyopaque, out: []u8) RestorationStateError!usize = null,
        /// The listener's OS-pollable accept descriptor, borrowed, for a
        /// host face that mirrors accept readiness into an aggregate set
        /// (ADR-0112). Left null by a transport whose accept has no single
        /// descriptor; `waitAcceptable` then stays the only readiness verb.
        readiness_fd: ?*const fn (ctx: *anyopaque) i32 = null,
        close: *const fn (ctx: *anyopaque) ?ListenerCloseFailure,
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
    pub fn acceptDetailed(self: Listener, peer: *engine.Peer, bufs: Buffers) AcceptOutcome {
        if (self.vtable.accept_detailed) |accept_detailed| return accept_detailed(self.ctx, peer, bufs);
        return .{ .accepted = self.accept(peer, bufs) catch |err| return .{ .failed = .init(err) } };
    }
    pub fn waitAcceptable(self: Listener, timeout_ms: i32) AcceptError!bool {
        return self.vtable.waitAcceptable(self.ctx, timeout_ms);
    }
    pub fn waitAcceptableDetailed(self: Listener, timeout_ms: i32) AcceptReadinessOutcome {
        if (self.vtable.wait_acceptable_detailed) |wait_detailed| return wait_detailed(self.ctx, timeout_ms);
        return .{ .ready = self.waitAcceptable(timeout_ms) catch |err| return .{ .failed = .init(err) } };
    }
    /// The pollable accept descriptor, or null when the transport reports
    /// accept readiness only through `waitAcceptable`.
    pub fn readinessFd(self: Listener) ?i32 {
        const f = self.vtable.readiness_fd orelse return null;
        return f(self.ctx);
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
    pub fn restorationState(self: Listener, out: []u8) RestorationStateError!?usize {
        const f = self.vtable.restoration_state orelse return null;
        return try f(self.ctx, out);
    }
    pub fn close(self: Listener) ?ListenerCloseFailure {
        return self.vtable.close(self.ctx);
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
        /// The one execution form this stream netlayer implements. Blocking
        /// and staged dial are mutually exclusive capabilities, not fallback
        /// implementations of the same fact.
        dial: ?DialOperation,
        /// Begin listener construction without parking the caller. Bounded
        /// implementations return `.ready`; externally paced implementations
        /// return a pollable `.pending` attempt.
        listen: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, config: ListenConfig) ListenStartOutcome,
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
        return self.vtable.dial != null;
    }
    pub fn supportsBlockingDial(self: Netlayer) bool {
        const operation = self.vtable.dial orelse return false;
        return switch (operation) {
            .blocking => true,
            .staged => false,
        };
    }
    pub fn supportsStagedDial(self: Netlayer) bool {
        const operation = self.vtable.dial orelse return false;
        return switch (operation) {
            .blocking => false,
            .staged => true,
        };
    }
    pub fn supportsListen(self: Netlayer) bool {
        return self.vtable.listen != null;
    }
    pub fn dial(
        self: Netlayer,
        peer: *engine.Peer,
        locator: model.PeerLocator,
        bufs: Buffers,
        options: OperationOptions,
    ) DialError!Connection {
        const dial_fn = (self.vtable.dial orelse unreachable).blocking;
        return dial_fn(self.ctx, peer, locator, bufs, options);
    }
    pub fn startDial(self: Netlayer, locator: model.PeerLocator, options: OperationOptions) DialStartOutcome {
        const start = (self.vtable.dial orelse unreachable).staged;
        return start(self.ctx, locator, options);
    }
    pub fn listen(self: Netlayer, allocator: std.mem.Allocator, config: ListenConfig) ListenStartOutcome {
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
