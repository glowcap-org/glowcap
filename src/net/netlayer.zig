//! The stream netlayer contract: the one shape every per-connection stream
//! transport realizes.
//!
//! OCapN addresses a peer by a locator, a value with three parts: a `transport`
//! symbol that selects how to reach it (`"tcp"`, `"iroh"`, etc.), a `designator`
//! that names the specific peer (a `host:port` string for TCP, a hex-encoded
//! Ed25519 key for keyed-TCP and iroh), and optional `hints` for transport-specific
//! metadata like direct socket addresses. A netlayer is a stream transport: it
//! may dial a locator to a `Connection`, bind a `Listener` that accepts
//! connections, or support both. `resolve` dispatches a transport symbol
//! against a `[]const Netlayer` at runtime.
//!
//! The contract is "produce a `Connection` over a stream," nothing more. Every
//! transport funnels through the same `Connection` (a `*std.Io.Reader` /
//! `*std.Io.Writer` pair plus a close handle), so a resident reuses the one
//! framing core in `pumpOver` rather than reframing bytes. `tcp`, `inproc`,
//! `onion`, the relay profiles, and the sidecar-backed `iroh` resident all
//! live behind this contract, each as its own files under `transport/`.
//!
//! `driver.HostRuntime` does not dispatch on this vtable (ADR-0193). It
//! realizes every first-party stream symbol through the completion adapters
//! composed in `stream_resident.zig` and selects them by `driver.Transports`,
//! so no product path dials or listens through `Netlayer`. The vtable stays
//! as this layer's internal composition seam, for three reasons. `test/net`
//! proves each stream resident through one dial and listen shape instead of
//! a transport-specific one. The residents' typed verbs behind it carry the
//! C provider archives under `c_abi/net_transport`. The listener vocabulary
//! below (`ListenConfig`, `ListenResult`, `ListenFailure`,
//! `DesignatorScheme`) is shared with the runtime's own listeners. Deleting
//! the vtable would make every resident's proof bespoke and open no product
//! path.
//!
//! Dispatch is a runtime vtable, not a comptime parameter, because the transport
//! symbol is a runtime value parsed from a URI or read off an inbound
//! `op:start-session`. A comptime contract would re-privilege whichever
//! transports were known at build time, the boundary this contract exists to
//! remove.
//!
//! A multiplexed transport with one readiness descriptor and many
//! connection ids uses the sibling `MultiplexedResident` contract, whose explicit
//! listener lifecycle and accept-claim operations preserve the same ownership
//! guarantees without pretending it is a per-connection stream vtable.
//! High-fan-out completion backends are a third I/O realization under
//! `completion.Loop`. They share transport and locator semantics without
//! pretending these ownership models are one vtable.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const connection = @import("connection.zig");
const failure_contract = @import("netlayer/failure.zig");
const support = @import("netlayer_support.zig");

pub const Connection = connection.Connection;

/// Caller-owned read/write buffers handed to a dial/accept.
pub const Buffers = support.Buffers;

/// Borrowed provider configuration. The selected provider owns validation.
pub const OperationOptions = support.OperationOptions;

/// Pinned shim reader/writer storage for userspace byte transports.
pub const PinnedStream = support.PinnedStream;

/// Pinned storage for a raw socket connection that carries its own std
/// reader and writer (`tcp`, `onion`).
pub const PinnedRawStream = support.PinnedRawStream;

/// The contract listener vtable and its accessor stubs, emitted once from a
/// resident's typed listener verbs.
pub const ListenerShell = support.ListenerShell;

/// Borrowed listener bind configuration.
pub const ListenConfig = support.ListenConfig;

/// What a transport's locator designator *is*, declared on the vtable so the
/// driver dispatches identity behavior without naming transports. `address`
/// means the designator is where to dial (a `host:port`) and the listener owns
/// it. `key` means the designator is the peer's Ed25519 public key in canonical
/// lowercase hex (`foundation.crypto.PeerKey.toDesignator`), dial addresses
/// ride the `hint_direct_addresses` hint, and the signed designator derives
/// from the identity key, never the socket. That is what lets a partner
/// re-dial the same designator across a process restart. A dial records that
/// target key. A partner that selects a key-designator acceptable route must
/// claim the same key. An address route is independent of the current channel
/// (ADR-0109). This is target matching, not authentication. Each connection's
/// `session_pubkey` is a separate identity.
pub const DesignatorScheme = support.DesignatorScheme;

/// The locator hint carrying a partner's comma-separated direct socket
/// addresses, the transport-neutral dial-address channel a `key`-scheme
/// designator needs, since the designator itself no longer says where to dial.
/// The iroh resident re-exports this name. Keyed TCP requires the hint on every
/// dial (TCP has no discovery).
pub const hint_direct_addresses = support.hint_direct_addresses;

/// The locator's `hint_direct_addresses` string hint, or null when the hint is
/// missing or carries a non-string value.
pub const directAddrHint = support.directAddrHint;

/// Size-query/copy contract shared by listener restoration-state callbacks. The return
/// value is always the complete byte count. `out` is written only when it can
/// hold the whole value. An empty buffer therefore asks for the exact size
/// without allocating or accepting a truncated locator component.
pub const writeListenerRestorationState = support.writeListenerRestorationState;

pub const RestorationStateError = failure_contract.RestorationStateError;
pub const DialError = failure_contract.DialError;
pub const DialFailure = failure_contract.DialFailure;
pub const RawConnectionDialOutcome = failure_contract.RawConnectionDialOutcome;
pub const ListenError = failure_contract.ListenError;
pub const AcceptError = failure_contract.AcceptError;
pub const AcceptFailure = failure_contract.AcceptFailure;
pub const AcceptOutcome = failure_contract.AcceptOutcome;
pub const AcceptReadinessOutcome = failure_contract.AcceptReadinessOutcome;
pub const ListenerCloseFailure = failure_contract.ListenerCloseFailure;
pub const ListenFailure = failure_contract.ListenFailure;
pub const ListenerLocatorOutcome = failure_contract.ListenerLocatorOutcome;
pub const ListenerRestorationOutcome = failure_contract.ListenerRestorationOutcome;
pub const DialOutcome = failure_contract.DialOutcome;
pub const projectListenError = failure_contract.projectListenError;
pub const adaptBlockingDial = failure_contract.adaptBlockingDial;
pub const adaptAccept = failure_contract.adaptAccept;
pub const adaptAcceptReadiness = failure_contract.adaptAcceptReadiness;
pub const adaptListenerLocator = failure_contract.adaptListenerLocator;
pub const adaptListenerCanonicalize = failure_contract.adaptListenerCanonicalize;
pub const adaptRestorationState = failure_contract.adaptRestorationState;

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
        const attempt = self.attempt orelse
            return .{ .failed = .init(error.InvalidOptions) };
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
/// implementation receives the peer and final wire buffers immediately. A
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
    ) DialOutcome,
    staged: *const fn (
        ctx: *anyopaque,
        locator: model.PeerLocator,
        options: OperationOptions,
    ) DialStartOutcome,
};

/// A stream-provider listener setup that may wait on external progress. The
/// transport owns the task and readiness descriptor. The driver owns exactly
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
        const attempt = self.attempt orelse
            return .{ .failed = .init(error.ProviderContract) };
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

    /// Consume an immediate listener for an embedding that does
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

/// Present a fallible listener constructor as the vtable's `listen` callback,
/// for a resident whose setup has no cleanup consequence to attach beyond the
/// refusal itself. A resident that does carry one builds the outcome directly.
pub fn adaptListen(
    comptime callback: fn (*anyopaque, std.mem.Allocator, ListenConfig) ListenError!ListenResult,
) *const fn (*anyopaque, std.mem.Allocator, ListenConfig) ListenStartOutcome {
    return struct {
        fn call(ctx: *anyopaque, allocator: std.mem.Allocator, config: ListenConfig) ListenStartOutcome {
            return .{ .admitted = callback(ctx, allocator, config) catch |err|
                return .{ .failed = .init(err) } };
        }
    }.call;
}

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
        /// What this listener's designator is (see `DesignatorScheme`).
        /// Matches its netlayer's declaration.
        designator_scheme: DesignatorScheme = .address,
        /// Whether the Host must seal this listener's byte channel before any
        /// CapTP bytes move. Kept beside the listener execution callbacks so
        /// extension transports receive the same fail-closed admission as
        /// first-party symbols.
        sealed_channel: bool = false,
        accept: *const fn (ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) AcceptOutcome,
        /// Wait until `accept` would make progress, up to `timeout_ms`.
        /// Returns false on timeout (caller may re-check a stop latch), true
        /// when the next `accept` should proceed. The one poll-guard that lets
        /// a blocking host exit without closing the listen FD from another
        /// thread (Zig Threaded Io panics on that BADF).
        wait_acceptable: *const fn (ctx: *anyopaque, timeout_ms: i32) AcceptReadinessOutcome,
        /// Materialize this listener's complete locator. The caller owns the
        /// returned value and frees it with `model.freePeerLocator`.
        local_locator: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) ListenerLocatorOutcome,
        /// Validate and canonicalize a caller-proposed replacement through
        /// the transport implementation that owns this listener's grammar.
        canonicalize_locator: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            locator: model.PeerLocator,
        ) ListenerLocatorOutcome,
        /// Write opaque transport-owned bytes sufficient to restore this
        /// listener's local address, when the transport has such state. The
        /// return value is the complete size. A short `out` is not modified.
        restoration_state: ?*const fn (ctx: *anyopaque, out: []u8) ListenerRestorationOutcome = null,
        /// The listener's OS-pollable accept descriptor, borrowed, for a
        /// host face that mirrors accept readiness into an aggregate set
        /// (ADR-0112). Left null by a transport whose accept has no single
        /// descriptor. `waitAcceptable` then stays the only readiness verb.
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
        return switch (self.acceptOutcome(peer, bufs)) {
            .accepted => |conn| conn,
            .failed => |failure| failure.classification,
        };
    }
    pub fn acceptOutcome(self: Listener, peer: *engine.Peer, bufs: Buffers) AcceptOutcome {
        return self.vtable.accept(self.ctx, peer, bufs);
    }
    pub fn waitAcceptable(self: Listener, timeout_ms: i32) AcceptError!bool {
        return switch (self.waitAcceptableOutcome(timeout_ms)) {
            .ready => |ready| ready,
            .failed => |failure| failure.classification,
        };
    }
    pub fn waitAcceptableOutcome(self: Listener, timeout_ms: i32) AcceptReadinessOutcome {
        return self.vtable.wait_acceptable(self.ctx, timeout_ms);
    }
    /// The pollable accept descriptor, or null when the transport reports
    /// accept readiness only through `waitAcceptable`.
    pub fn readinessFd(self: Listener) ?i32 {
        const f = self.vtable.readiness_fd orelse return null;
        return f(self.ctx);
    }
    pub fn localLocator(self: Listener, allocator: std.mem.Allocator) ListenError!model.PeerLocator {
        return switch (self.localLocatorOutcome(allocator)) {
            .locator => |locator| locator,
            .failed => |failure| projectListenError(failure),
        };
    }
    pub fn localLocatorOutcome(self: Listener, allocator: std.mem.Allocator) ListenerLocatorOutcome {
        return self.vtable.local_locator(self.ctx, allocator);
    }
    pub fn canonicalizeLocator(
        self: Listener,
        allocator: std.mem.Allocator,
        locator: model.PeerLocator,
    ) ListenError!model.PeerLocator {
        return switch (self.canonicalizeLocatorOutcome(allocator, locator)) {
            .locator => |canonical| canonical,
            .failed => |failure| projectListenError(failure),
        };
    }
    pub fn canonicalizeLocatorOutcome(
        self: Listener,
        allocator: std.mem.Allocator,
        locator: model.PeerLocator,
    ) ListenerLocatorOutcome {
        return self.vtable.canonicalize_locator(self.ctx, allocator, locator);
    }
    pub fn restorationState(self: Listener, out: []u8) RestorationStateError!?usize {
        return switch (self.restorationStateOutcome(out)) {
            .unsupported => null,
            .size => |needed| needed,
            .failed => error.ProviderFailure,
        };
    }
    pub fn restorationStateOutcome(self: Listener, out: []u8) ListenerRestorationOutcome {
        const f = self.vtable.restoration_state orelse return .unsupported;
        return f(self.ctx, out);
    }
    pub fn close(self: Listener) ?ListenerCloseFailure {
        return self.vtable.close(self.ctx);
    }
};

/// Canonicalize a locator for a listener with immutable transport identity.
pub fn canonicalizeFixedLocator(
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
    expected_transport: []const u8,
    expected_designator: []const u8,
) ListenError!model.PeerLocator {
    return support.canonicalizeFixedLocator(allocator, locator, expected_transport, expected_designator);
}

/// One transport, behind a runtime vtable, a netlayer, reached as
/// `net.netlayer.Netlayer`. `dial` turns a locator into a live `Connection`.
/// `listen` binds a `Listener`. `profile.symbol` is both the dispatch key
/// (`resolve` matches on it) and the symbol signed into the locator (so it must
/// match what the partner matches on, Goblins' `^tcp-netlayer` keys on `tcp`).
/// `ctx` is the resident's own state (its `std.Io`, or a userspace endpoint),
/// which the caller keeps alive for as long as any slice holds the netlayer.
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
        /// implementations return `.ready`. Externally paced implementations
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
        return switch (self.dialOutcome(peer, locator, bufs, options)) {
            .connected => |conn| conn,
            .failed => |value| value.classification,
        };
    }
    pub fn dialOutcome(
        self: Netlayer,
        peer: *engine.Peer,
        locator: model.PeerLocator,
        bufs: Buffers,
        options: OperationOptions,
    ) DialOutcome {
        const operation = self.vtable.dial orelse
            return .{ .failed = .init(error.InvalidOptions) };
        return switch (operation) {
            .blocking => |dial_fn| dial_fn(self.ctx, peer, locator, bufs, options),
            .staged => .{ .failed = .init(error.InvalidOptions) },
        };
    }
    pub fn startDial(self: Netlayer, locator: model.PeerLocator, options: OperationOptions) DialStartOutcome {
        const operation = self.vtable.dial orelse
            return .{ .failed = .init(error.InvalidOptions) };
        return switch (operation) {
            .blocking => .{ .failed = .init(error.InvalidOptions) },
            .staged => |start| start(self.ctx, locator, options),
        };
    }
    pub fn listen(self: Netlayer, allocator: std.mem.Allocator, config: ListenConfig) ListenStartOutcome {
        const listen_fn = self.vtable.listen orelse
            return .{ .failed = .init(error.InvalidOptions) };
        return listen_fn(self.ctx, allocator, config);
    }

    /// The resident's host `std.Io`, or null (see `VTable.io`).
    pub fn io(self: Netlayer) ?std.Io {
        return self.vtable.io(self.ctx);
    }
};

/// Shared context recovery for a resident with an `io` field.
pub const ResidentContext = support.ResidentContext;

/// Find the resident for `transport`, failing closed with null when absent.
pub fn resolve(netlayers: []const Netlayer, transport: []const u8) ?Netlayer {
    return support.resolve(Netlayer, netlayers, transport);
}
