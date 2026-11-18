//! The multiplexed-resident contract: how a transport that multiplexes many
//! connections behind one readiness descriptor joins `driver.HostRuntime`
//! (ADR-0024).
//!
//! A stream netlayer hands the runtime one pollable descriptor per connection.
//! iroh and WebRTC cannot: their connections live inside a foreign runtime,
//! and what the runtime exposes is one shared readiness descriptor,
//! a queue of drained ready events over stable integer connection ids, and
//! non-blocking per-connection try-I/O. This vtable is that shape, made a
//! contract, so `driver.HostRuntime` can host such a transport beside its
//! per-descriptor wires, and so a resident living behind a compulsory
//! artifact boundary (a sidecar) can cross it as function pointers.
//!
//! It is a runtime vtable for the same reason `Netlayer` is: which transport
//! carries a session is a runtime value off a locator or an inbound hello.
//!
//! `driver.HostRuntime` consumes the same contract for dialing and accepting.
//! Listener start, locator publication, accepted-connection claim, and stop are explicit
//! operations. An accept readiness bit never appears without an ownership path.

const std = @import("std");

const foundation = @import("foundation");
const netlayer = @import("netlayer.zig");
const carrier_failure = @import("carrier_failure.zig");
const model = @import("model");
const crypto = foundation.crypto;
const readiness = @import("multiplexed_resident/readiness.zig");
const dial = @import("multiplexed_resident/dial.zig");
const listening = @import("multiplexed_resident/listen.zig");

pub const would_block = readiness.would_block;
pub const ContractError = readiness.ContractError;
pub const DialAttempt = dial.DialAttempt;
pub const DialStartOutcome = dial.DialStartOutcome;
pub const DialFinishOutcome = dial.DialFinishOutcome;
pub const RawDialStartOutcome = dial.RawDialStartOutcome;
pub const RawDialFinishOutcome = dial.RawDialFinishOutcome;

pub const TeardownOutcome = @import("multiplexed_resident/teardown.zig").Outcome;
pub const borrowed_read = @import("multiplexed_resident/borrowed_read.zig");
pub const ReadyEvent = readiness.ReadyEvent;
pub const ev_readable = readiness.ev_readable;
pub const ev_writable = readiness.ev_writable;
/// See `readiness.ev_closed` for the readable-and-closed reading.
pub const ev_closed = readiness.ev_closed;
pub const ev_accept = readiness.ev_accept;
pub const ev_connect = readiness.ev_connect;
pub const ev_listen = readiness.ev_listen;

/// Provider-side result before the resident wrapper attaches profile and route
/// ownership to the public listener or attempt value.
pub const RawListenResult = union(enum) {
    ready: *anyopaque,
    pending,
};

/// A connection claimed from a resident but not yet adopted by a HostRuntime wire.
/// It owns close immediately after `finish_connect` / `finish_accept` and is
/// consumed only after every fallible adoption step has committed.
pub const ClaimedConnection = struct {
    resident: MultiplexedResident,
    id: ?usize,

    pub fn deinit(self: *ClaimedConnection) ?foundation.FailureChain {
        const id = self.id orelse return null;
        self.id = null;
        return self.resident.connClose(id);
    }

    pub fn borrow(self: ClaimedConnection) ?usize {
        return self.id;
    }

    pub fn take(self: *ClaimedConnection) ?usize {
        const id = self.id;
        self.id = null;
        return id;
    }
};

pub const RawExternalClaimOutcome = union(enum) {
    claimed: usize,
    failed: netlayer.DialFailure,
};

pub const ExternalClaimOutcome = union(enum) {
    claimed: ClaimedConnection,
    failed: netlayer.DialFailure,
};

/// One multiplexed transport, as a HostRuntime holds it.
///
/// Threading and lifetime: every call is made from the one thread that drives
/// the HostRuntime, and `ctx` must outlive its registration. Nothing allocates
/// on the wire path: events drain into the caller's array, reads land in the
/// caller's buffer, and writes are consumed (possibly partially) before the
/// call returns. Listener locator materialization is setup-only owned state.
/// What runs after a turn ends (`before_wait`): the runtime or its embedder
/// parks, so every effect must be in the kernel, or the caller runs and may
/// stay away.
pub const AfterTurn = enum { park, caller };

pub const MultiplexedResident = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The resident's one OS-pollable readiness descriptor: it reads
        /// ready while the kernel holds a completion `drain_ready` would turn
        /// into a record.
        readiness_fd: *const fn (ctx: *anyopaque) i32,
        /// Whether records already taken from the kernel wait in the resident
        /// now, where no descriptor reports them, or the resident holds
        /// backend work its next drain can advance or surface (a send
        /// completion a short write queued, a deferred poll error), which may
        /// end in no public record. Neither is a descriptor event. A resident
        /// that reaps completions at the end of its own verbs holds such
        /// records between a verb and the next service. The runtime services the resident
        /// before it parks, and raises a stepped embedder's readiness
        /// descriptor when a verb leaves them behind. Absent means the
        /// descriptor reports every record.
        ready_pending: ?*const fn (ctx: *anyopaque) bool = null,
        /// The turn is ending, and `after` says what runs next. A resident
        /// that holds staged sends or queued submissions hands them to the
        /// kernel here, so a turn's writes leave in one batch instead of one
        /// syscall per verb. Before a park every re-armed receive leaves
        /// too. Before the caller runs, a re-armed receive may wait for the
        /// park: nothing outside the thread can tell an unarmed receive from
        /// one the kernel has not yet completed, and the park arms it before
        /// it waits. Absent means every verb completes its own effects.
        before_wait: ?*const fn (ctx: *anyopaque, after: AfterTurn) void = null,
        /// Take what the kernel has completed since the last reap and turn
        /// it into held records, submitting nothing. A runtime that spins
        /// before it parks asks this on every pass and then `ready_pending`,
        /// so a reply that lands inside its window is serviced without a
        /// descriptor wake. Absent means only the descriptor reports new
        /// completions, and a spinning runtime learns nothing from passing
        /// this resident.
        reap: ?*const fn (ctx: *anyopaque) void = null,
        /// The longest the runtime may wait, given `requested_ms` (negative
        /// for no limit), before this resident has timed work that no
        /// descriptor will report. The runtime services the resident when a
        /// wait ends on this bound. Absent means it has none.
        wait_bound_ms: ?*const fn (ctx: *anyopaque, requested_ms: i32) i32 = null,
        /// Wait in the resident's own kernel queue until a completion lands,
        /// a watched descriptor reads ready, or `timeout_ms` passes (negative
        /// for no limit), and turn what arrived into held records. The
        /// runtime parks here, not on the readiness descriptor, when every
        /// resident it has offers it, so the work the kernel owes this thread
        /// for a completion runs inside the one wake. A resident that cannot
        /// install a watch it owes the park answers `.unavailable` before it
        /// waits, and the runtime polls every readiness descriptor, this
        /// resident's included, in its place, so one call never waits twice. A
        /// resident that cannot decline answers only `.woke` or `.timeout`.
        /// Absent means the runtime polls the descriptor.
        park: ?*const fn (ctx: *anyopaque, timeout_ms: i32) Park = null,
        /// Wake `park` when `fd` reads ready, consuming nothing from it, from
        /// the next park on. The runtime hands the resident that
        /// parks it the descriptors it would otherwise poll beside that one:
        /// its settle mailbox, a stepped ready set's wake, and its other
        /// residents. `error.OutOfMemory` means nothing was installed: the
        /// runtime skips the park for this call and polls every readiness
        /// descriptor instead (each resident's, the mailbox's, and a stepped
        /// ready set's wake), then offers this one again at the next call.
        /// Present exactly when `park` is.
        watch: ?*const fn (ctx: *anyopaque, fd: i32) error{OutOfMemory}!void = null,
        /// Drain pending ready records into `out`. Returns how many records
        /// were written.
        drain_ready: *const fn (ctx: *anyopaque, out: []ReadyEvent) ContractError!usize,
        /// Dial and listen are complete operation groups: absent means the
        /// runtime does not implement that capability. Present means every
        /// callback in the group is callable. Profiles routed through this
        /// runtime do not carry a second, fallible copy of that fact.
        dial: ?DialVTable = null,
        external_claim: ?ExternalClaimVTable = null,
        listen: ?ListenVTable = null,
        /// Paced retry of work the resident's allocator refused. Absent means
        /// the resident owes none.
        memory_retry: ?MemoryRetryVTable = null,
        /// Read into `buf`: bytes read, 0 on clean end of stream, -1 on a
        /// dead connection, `would_block` when nothing is pending.
        try_read: *const fn (ctx: *anyopaque, conn: usize, buf: []u8) isize,
        /// Present when the resident can lend received bytes instead.
        borrowed_read: ?borrowed_read.VTable = null,
        /// Write from `bytes`: bytes consumed (the resident owns them once
        /// counted), -1 on a dead connection, `would_block` or 0 when the
        /// window is full. An `ev_writable` record follows either refusal.
        try_write: *const fn (ctx: *anyopaque, conn: usize, bytes: []const u8) isize,
        /// The caller finished one batch of writes on `conn`. A resident that
        /// declares it may hold consumed bytes until this call, so a frame
        /// and its length prefix leave in one send, and one that declares
        /// `before_wait` may hold them until the runtime parks, so every
        /// batch of the turn leaves in one send. One without either sends as
        /// each write arrives.
        flush_writes: ?*const fn (ctx: *anyopaque, conn: usize) void = null,
        /// Claim one exact connection-local read/write failure, with the
        /// carrier phase the resident named. Null is clean EOF or no retained
        /// failure. A claimed value cannot reappear.
        take_failure: ?*const fn (ctx: *anyopaque, conn: usize) ?carrier_failure.Report = null,
        /// Close and release one connection. Later records naming the id
        /// drain to nothing.
        conn_close: *const fn (ctx: *anyopaque, conn: usize) TeardownOutcome,
        /// Drop one connection now, discarding what a pending `conn_close`
        /// was still sending, and release it. A resident whose pending close
        /// waits on the partner reading declares this, so that wait ends at
        /// the runtime's deadline instead of holding the socket and its read
        /// buffer. One whose pending close is its own asynchronous
        /// retirement, reported through `ev_closed`, leaves it null and the
        /// runtime joins that close at release. It never reports `.pending`.
        conn_abort: ?*const fn (ctx: *anyopaque, conn: usize) TeardownOutcome = null,
        /// The channel-authenticated remote durable key, when this transport
        /// proves one (iroh's remote node id). Null on a transport whose
        /// channel proves nothing. The realizer seam then stays silent.
        conn_remote_key: *const fn (ctx: *anyopaque, conn: usize) ContractError!?crypto.PeerKey,
    };

    /// A complete group: both callbacks are callable or the group is absent.
    /// The runtime paces the retry (`HostRuntime.resident_retry_due_ms`) and
    /// never reads the resident's own failure state.
    const MemoryRetryVTable = struct {
        /// Whether the resident owes a retry. Synchronous and side-effect
        /// free: it does not allocate, mutate, or call the runtime.
        owes: *const fn (ctx: *anyopaque) bool,
        /// Retry every owed operation once. It may submit backend work, update
        /// the resident's own state, and latch the resident's own failure,
        /// which reaches the runtime through `ready_pending` and
        /// `drain_ready` (a latch makes `ready_pending` true). It calls no
        /// runtime verb, may run inside a driver turn while a received chunk
        /// is loaned, never touches lent buffers or other residents, and does
        /// not block.
        retry: *const fn (ctx: *anyopaque) void,
    };

    pub const DialVTable = struct {
        /// Begin a dial toward the complete locator. Transport-specific hint
        /// interpretation belongs to the resident. `origin` names the session
        /// that introduced a handoff dial, borrowed for this call, and a
        /// resident that needs no outside party reads nothing from it.
        /// Completion arrives as an `ev_connect` record carrying
        /// `request_id`. An error admits no operation. The provider has
        /// already cleaned any partial work.
        start_connect: *const fn (
            ctx: *anyopaque,
            request_id: usize,
            locator: model.PeerLocator,
            options: netlayer.OperationOptions,
            origin: netlayer.DialOrigin,
        ) RawDialStartOutcome,
        /// Claim the connection a completed `ev_connect` announced. The raw
        /// id immediately enters `ClaimedConnection` ownership in the wrapper.
        /// A failed dial surfaces its typed reason here. The request is consumed
        /// on every return path.
        finish_connect: *const fn (ctx: *anyopaque, request_id: usize) RawDialFinishOutcome,
        /// Abandon a dial. Idempotent, and valid after its `ev_connect` was
        /// announced but before `finish_connect` claimed it. A resident whose
        /// retirement is asynchronous returns null after transferring the
        /// request, emits `ev_connect` when retirement has joined, and returns
        /// the claim-once cleanup chain when called again for that id.
        cancel_connect: *const fn (ctx: *anyopaque, request_id: usize) ?foundation.FailureChain,
    };

    pub const ExternalClaimVTable = struct {
        /// Claim one provider-scoped externally established connection. The
        /// provider returns only when the channel is open and transfers one
        /// connection ownership edge on success.
        claim_external: *const fn (ctx: *anyopaque, subject: usize) RawExternalClaimOutcome,
    };

    pub const RawFinishAcceptOutcome = union(enum) {
        connection: ?usize,
        failed: netlayer.AcceptFailure,
    };

    pub const RawListenStartOutcome = union(enum) {
        admitted: RawListenResult,
        failed: netlayer.ListenFailure,
    };

    pub const RawListenFinishOutcome = union(enum) {
        listener: *anyopaque,
        failed: netlayer.ListenFailure,
    };

    pub const ListenVTable = struct {
        /// Begin accepting the selected transport profile through this resident.
        /// `config` is the stream listen's own: `designator` is the caller's
        /// expected identity or address, empty asking for the canonical one,
        /// and `identity` is the durable key of the Host the listener serves,
        /// which a key-designated profile publishes. Immediate completion
        /// returns the listener handle. Externally paced setup returns pending
        /// and later emits `ev_listen` for `route_id`. An error admits no
        /// operation. The provider has already cleaned partial work.
        listen: *const fn (
            ctx: *anyopaque,
            route_id: usize,
            transport: []const u8,
            config: netlayer.ListenConfig,
        ) RawListenStartOutcome,
        /// Present only when `listen` may return pending. Immediate-only
        /// residents carry no fabricated completion capability.
        completion: ?ListenCompletionVTable = null,
        /// Materialize the complete locator. The caller owns the result and
        /// frees it with `model.freePeerLocator`.
        local_locator: *const fn (
            ctx: *anyopaque,
            listener_ctx: *anyopaque,
            transport: []const u8,
            allocator: std.mem.Allocator,
        ) netlayer.ListenerLocatorOutcome,
        /// Validate and canonicalize a replacement listener locator.
        canonicalize_locator: *const fn (
            ctx: *anyopaque,
            listener_ctx: *anyopaque,
            transport: []const u8,
            allocator: std.mem.Allocator,
            locator: model.PeerLocator,
        ) netlayer.ListenerLocatorOutcome,
        restoration_state: ?*const fn (
            ctx: *anyopaque,
            listener_ctx: *anyopaque,
            out: []u8,
        ) netlayer.ListenerRestorationOutcome = null,
        /// Claim one ready inbound connection. Null means the coalesced accept
        /// queue has drained. The raw id immediately enters
        /// `ClaimedConnection` ownership in the wrapper and shares
        /// `finish_connect`'s connection namespace.
        finish_accept: *const fn (ctx: *anyopaque, listener_ctx: *anyopaque) RawFinishAcceptOutcome,
        /// Stop accepting. An asynchronously retiring resident returns
        /// `pending`, emits `ev_listen` for this listener's route after its
        /// barrier joins, then returns the claim-once terminal outcome when
        /// called again. Later accept records drain to no owned connection.
        stop_listen: *const fn (ctx: *anyopaque, listener_ctx: *anyopaque) TeardownOutcome,
    };

    pub const ListenCompletionVTable = struct {
        /// Claim a listener after `ev_listen`. The route is consumed on every
        /// return path.
        finish: *const fn (ctx: *anyopaque, route_id: usize) RawListenFinishOutcome,
        /// Abandon pending setup. A resident whose retirement is asynchronous
        /// returns null, emits `ev_listen` after the barrier joins, and returns
        /// the claim-once cleanup chain when called again for the route. The
        /// same callback claims an active listener's asynchronous stop result.
        cancel: *const fn (ctx: *anyopaque, route_id: usize) ?foundation.FailureChain,
    };

    pub fn adaptListenerLocator(comptime callback: fn (*anyopaque, *anyopaque, []const u8, std.mem.Allocator) netlayer.ListenError!model.PeerLocator) *const fn (*anyopaque, *anyopaque, []const u8, std.mem.Allocator) netlayer.ListenerLocatorOutcome {
        return struct {
            fn call(ctx: *anyopaque, listener_ctx: *anyopaque, transport: []const u8, allocator: std.mem.Allocator) netlayer.ListenerLocatorOutcome {
                return .{ .locator = callback(ctx, listener_ctx, transport, allocator) catch |err|
                    return .{ .failed = .init(err) } };
            }
        }.call;
    }

    pub fn adaptListenerCanonicalize(comptime callback: fn (*anyopaque, *anyopaque, []const u8, std.mem.Allocator, model.PeerLocator) netlayer.ListenError!model.PeerLocator) *const fn (*anyopaque, *anyopaque, []const u8, std.mem.Allocator, model.PeerLocator) netlayer.ListenerLocatorOutcome {
        return struct {
            fn call(ctx: *anyopaque, listener_ctx: *anyopaque, transport: []const u8, allocator: std.mem.Allocator, locator: model.PeerLocator) netlayer.ListenerLocatorOutcome {
                return .{ .locator = callback(ctx, listener_ctx, transport, allocator, locator) catch |err|
                    return .{ .failed = .init(err) } };
            }
        }.call;
    }

    pub fn adaptRestorationState(comptime callback: fn (*anyopaque, *anyopaque, []u8) netlayer.RestorationStateError!usize) *const fn (*anyopaque, *anyopaque, []u8) netlayer.ListenerRestorationOutcome {
        return struct {
            fn call(ctx: *anyopaque, listener_ctx: *anyopaque, out: []u8) netlayer.ListenerRestorationOutcome {
                return .{ .size = callback(ctx, listener_ctx, out) catch |err|
                    return .{ .failed = .init(err) } };
            }
        }.call;
    }

    pub fn adaptFinishAccept(comptime callback: fn (*anyopaque, *anyopaque) netlayer.AcceptError!?usize) *const fn (*anyopaque, *anyopaque) RawFinishAcceptOutcome {
        return struct {
            fn call(ctx: *anyopaque, listener_ctx: *anyopaque) RawFinishAcceptOutcome {
                return .{ .connection = callback(ctx, listener_ctx) catch |err|
                    return .{ .failed = .init(err) } };
            }
        }.call;
    }

    pub const Dialer = struct {
        resident: MultiplexedResident,
        ops: *const DialVTable,

        fn operations(self: Dialer) *const DialVTable {
            return self.ops;
        }

        pub fn startDial(
            self: Dialer,
            request_id: usize,
            locator: model.PeerLocator,
            options: netlayer.OperationOptions,
            origin: netlayer.DialOrigin,
        ) DialStartOutcome {
            return switch (self.operations().start_connect(self.resident.ctx, request_id, locator, options, origin)) {
                .admitted => .{ .admitted = .{ .dialer = self, .request_id = request_id } },
                .failed => |failure| .{ .failed = failure },
            };
        }

        pub fn cancelDial(self: Dialer, request_id: usize) ?foundation.FailureChain {
            return self.operations().cancel_connect(self.resident.ctx, request_id);
        }

        /// Consume an admitted request. `DialAttempt.finish` is the caller,
        /// because the attempt owns the request's one consumption.
        pub fn finishDial(self: Dialer, request_id: usize) RawDialFinishOutcome {
            return self.operations().finish_connect(self.resident.ctx, request_id);
        }
    };

    pub const ExternalClaimer = struct {
        resident: MultiplexedResident,

        pub fn claimExternal(self: ExternalClaimer, subject: usize) ExternalClaimOutcome {
            return switch (self.resident.vtable.external_claim.?.claim_external(self.resident.ctx, subject)) {
                .claimed => |id| .{ .claimed = .{ .resident = self.resident, .id = id } },
                .failed => |failure| .{ .failed = failure },
            };
        }
    };

    pub const Acceptor = struct {
        resident: MultiplexedResident,
        ops: *const ListenVTable,

        /// The listen operations a `Listener` of this acceptor calls.
        pub fn operations(self: Acceptor) *const ListenVTable {
            return self.ops;
        }

        pub fn listen(
            self: Acceptor,
            route_id: usize,
            transport: []const u8,
            config: netlayer.ListenConfig,
        ) ListenStartOutcome {
            const outcome = self.operations().listen(self.resident.ctx, route_id, transport, config);
            return switch (outcome) {
                .failed => |failure| .{ .failed = failure },
                .admitted => |listener_ctx| switch (listener_ctx) {
                    .ready => |ctx| .{ .admitted = .{ .ready = .{
                        .acceptor = self,
                        .ctx = ctx,
                        .route_id = route_id,
                        .transport = transport,
                    } } },
                    .pending => blk: {
                        const completion = self.operations().completion orelse
                            return .{ .failed = .init(error.ProviderContract) };
                        break :blk .{ .admitted = .{ .pending = .{
                            .acceptor = self,
                            .route_id = route_id,
                            .transport = transport,
                            .completion = completion,
                        } } };
                    },
                },
            };
        }

        pub fn cancelListen(self: Acceptor, route_id: usize) ?foundation.FailureChain {
            return self.operations().completion.?.cancel(self.resident.ctx, route_id);
        }
    };

    pub const ListenAttempt = listening.ListenAttempt;
    pub const ListenStartOutcome = listening.ListenStartOutcome;
    pub const ListenFinishOutcome = listening.ListenFinishOutcome;
    pub const ListenResult = listening.ListenResult;
    pub const Listener = listening.Listener;
    pub const FinishAcceptOutcome = listening.FinishAcceptOutcome;

    /// Runtime identity, independent of the transport profiles routed through
    /// it. Provider packages use this to share one runtime and readiness
    /// descriptor across several profile entries.
    pub fn eql(self: MultiplexedResident, other: MultiplexedResident) bool {
        return self.ctx == other.ctx and self.vtable == other.vtable;
    }

    pub fn dialer(self: MultiplexedResident) ?Dialer {
        const ops = if (self.vtable.dial) |*value| value else return null;
        return .{ .resident = self, .ops = ops };
    }

    const MemoryRetry = struct {
        resident: MultiplexedResident,
        ops: *const MemoryRetryVTable,

        pub fn owes(self: MemoryRetry) bool {
            return self.ops.owes(self.resident.ctx);
        }

        pub fn retry(self: MemoryRetry) void {
            self.ops.retry(self.resident.ctx);
        }
    };

    pub fn memoryRetry(self: MultiplexedResident) ?MemoryRetry {
        const ops = if (self.vtable.memory_retry) |*value| value else return null;
        return .{ .resident = self, .ops = ops };
    }

    pub fn externalClaimer(self: MultiplexedResident) ?ExternalClaimer {
        if (self.vtable.external_claim == null) return null;
        return .{ .resident = self };
    }

    pub fn acceptor(self: MultiplexedResident) ?Acceptor {
        const ops = if (self.vtable.listen) |*value| value else return null;
        return .{ .resident = self, .ops = ops };
    }

    pub fn readinessFd(self: MultiplexedResident) i32 {
        return self.vtable.readiness_fd(self.ctx);
    }

    pub fn readyPending(self: MultiplexedResident) bool {
        const pending = self.vtable.ready_pending orelse return false;
        return pending(self.ctx);
    }

    pub fn beforeWait(self: MultiplexedResident, after: AfterTurn) void {
        const before = self.vtable.before_wait orelse return;
        before(self.ctx, after);
    }

    pub fn reap(self: MultiplexedResident) void {
        const take = self.vtable.reap orelse return;
        take(self.ctx);
    }

    /// How a `park` ended. `.woke` is a completion or watched descriptor, or a
    /// failure `ready_pending` now reports. `.timeout` is the bound passing
    /// with nothing arrived. `.unavailable` is a park that did not wait because
    /// an optional watch could not be installed for lack of memory or kernel
    /// watch capacity: nothing waited, watches already armed stay armed, and
    /// the next park offers only the rest.
    pub const Park = enum { woke, timeout, unavailable };

    /// Whether the runtime may park inside this resident.
    pub fn parks(self: MultiplexedResident) bool {
        return self.vtable.park != null and self.vtable.watch != null;
    }

    /// Requires `parks`.
    pub fn park(self: MultiplexedResident, timeout_ms: i32) Park {
        return self.vtable.park.?(self.ctx, timeout_ms);
    }

    /// Requires `parks`.
    pub fn watch(self: MultiplexedResident, fd: i32) error{OutOfMemory}!void {
        return self.vtable.watch.?(self.ctx, fd);
    }

    pub fn waitBoundMs(self: MultiplexedResident, requested_ms: i32) i32 {
        const bound = self.vtable.wait_bound_ms orelse return requested_ms;
        return bound(self.ctx, requested_ms);
    }

    pub fn drainReady(self: MultiplexedResident, out: []ReadyEvent) ContractError![]ReadyEvent {
        const count = try self.vtable.drain_ready(self.ctx, out);
        if (count > out.len) return error.ProviderContract;
        return out[0..count];
    }

    pub fn tryRead(self: MultiplexedResident, conn: usize, buf: []u8) isize {
        return self.vtable.try_read(self.ctx, conn, buf);
    }

    pub fn tryWrite(self: MultiplexedResident, conn: usize, bytes: []const u8) isize {
        return self.vtable.try_write(self.ctx, conn, bytes);
    }

    pub fn flushWrites(self: MultiplexedResident, conn: usize) void {
        if (self.vtable.flush_writes) |flush| flush(self.ctx, conn);
    }

    pub fn connClose(self: MultiplexedResident, conn: usize) ?foundation.FailureChain {
        return self.connCloseOutcome(conn).requireComplete();
    }

    pub fn connCloseOutcome(self: MultiplexedResident, conn: usize) TeardownOutcome {
        return self.vtable.conn_close(self.ctx, conn);
    }

    /// Null when the resident declares no abort, so its close completes on
    /// its own terms.
    pub fn connAbortOutcome(self: MultiplexedResident, conn: usize) ?TeardownOutcome {
        const abort = self.vtable.conn_abort orelse return null;
        return abort(self.ctx, conn);
    }

    pub fn takeFailure(self: MultiplexedResident, conn: usize) ?carrier_failure.Report {
        const take = self.vtable.take_failure orelse return null;
        return take(self.ctx, conn);
    }

    pub fn connRemoteKey(self: MultiplexedResident, conn: usize) ContractError!?crypto.PeerKey {
        return self.vtable.conn_remote_key(self.ctx, conn);
    }
};
