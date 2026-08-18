//! The multiplexed-resident contract: how a transport that multiplexes many
//! connections behind one readiness descriptor joins `driver.HostRuntime`
//! (ADR-0112).
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
//! operations; an accept readiness bit never appears without an ownership path.

const std = @import("std");

const foundation = @import("foundation");
const netlayer = @import("netlayer.zig");
const model = @import("model");
const crypto = foundation.crypto;

/// `try_read` and `try_write` return this when the operation cannot make
/// progress without blocking. Distinct from 0 (clean end of stream on read; a
/// full window's zero-byte write) and -1 (a dead connection). The iroh
/// sidecar's `PANCAKE_IROH_WOULD_BLOCK` is the same value, so its trampolines
/// pass results through unchanged.
pub const would_block: isize = -2;
pub const ContractError = error{ProviderContract};

/// Readiness bits in `ReadyEvent.events`. One drained record may carry
/// several at once.
pub const ev_readable: u32 = 1;
pub const ev_writable: u32 = 2;
pub const ev_closed: u32 = 4;
pub const ev_accept: u32 = 8;
pub const ev_connect: u32 = 16;
pub const ev_listen: u32 = 32;

/// One drained readiness record. `subject` is the connection id for
/// connection events, the caller's request id for `ev_connect`, and the
/// driver-minted listener route id for `ev_listen` / `ev_accept`. Provider-owned connection
/// ids are stable and never reused for the resident's lifetime; request and
/// listener ids belong to the caller's namespace within this runtime.
pub const ReadyEvent = struct {
    subject: usize,
    events: u32,
};

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

/// A resident dial request between admission and connection claim. The value
/// owns cancellation. `finish` consumes the request on both success and
/// refusal and returns the next ownership state only on success.
pub const DialAttempt = struct {
    dialer: MultiplexedResident.Dialer,
    request_id: ?usize,

    pub fn deinit(self: *DialAttempt) ?foundation.FailureChain {
        const request_id = self.request_id orelse return null;
        self.request_id = null;
        return self.dialer.cancelDial(request_id);
    }

    pub fn id(self: DialAttempt) ?usize {
        return self.request_id;
    }

    pub fn take(self: *DialAttempt) DialAttempt {
        const owned = self.*;
        self.request_id = null;
        return owned;
    }

    pub fn finish(self: *DialAttempt) DialFinishOutcome {
        const request_id = self.request_id orelse
            return .{ .failed = .init(error.InvalidOptions) };
        self.request_id = null;
        return switch (self.dialer.finishDial(request_id)) {
            .connected => |conn| .{ .connected = .{ .resident = self.dialer.resident, .id = conn } },
            .failed => |failure| .{ .failed = failure },
        };
    }
};

pub const DialStartOutcome = union(enum) {
    admitted: DialAttempt,
    failed: netlayer.DialFailure,
};

pub const DialFinishOutcome = union(enum) {
    connected: ClaimedConnection,
    failed: netlayer.DialFailure,
};

pub const RawDialStartOutcome = union(enum) {
    admitted,
    failed: netlayer.DialFailure,
};

pub const RawDialFinishOutcome = union(enum) {
    connected: usize,
    failed: netlayer.DialFailure,
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
pub const MultiplexedResident = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The resident's one OS-pollable readiness descriptor. Level-shaped
        /// by contract: it reads ready while drained records are pending.
        readiness_fd: *const fn (ctx: *anyopaque) i32,
        /// Drain pending ready records into `out`, clearing the descriptor's
        /// coalesced wake. Returns how many records were written.
        drain_ready: *const fn (ctx: *anyopaque, out: []ReadyEvent) ContractError!usize,
        /// Dial and listen are complete operation groups: absent means the
        /// runtime does not implement that capability; present means every
        /// callback in the group is callable. Profiles routed through this
        /// runtime do not carry a second, fallible copy of that fact.
        dial: ?DialVTable = null,
        external_claim: ?ExternalClaimVTable = null,
        listen: ?ListenVTable = null,
        /// Read into `buf`: bytes read, 0 on clean end of stream, -1 on a
        /// dead connection, `would_block` when nothing is pending.
        try_read: *const fn (ctx: *anyopaque, conn: usize, buf: []u8) isize,
        /// Write from `bytes`: bytes consumed (the resident owns them once
        /// counted), -1 on a dead connection, `would_block` or 0 when the
        /// window is full. An `ev_writable` record follows either refusal.
        try_write: *const fn (ctx: *anyopaque, conn: usize, bytes: []const u8) isize,
        /// Claim one exact connection-local read/write failure. Null is clean
        /// EOF or no retained failure; a claimed value cannot reappear.
        take_failure: ?*const fn (ctx: *anyopaque, conn: usize) ?foundation.FailureChain = null,
        /// Close and release one connection. Later records naming the id
        /// drain to nothing.
        conn_close: *const fn (ctx: *anyopaque, conn: usize) ?foundation.FailureChain,
        /// The channel-authenticated remote durable key, when this transport
        /// proves one (iroh's remote node id). Null on a transport whose
        /// channel proves nothing; the realizer seam then stays silent.
        conn_remote_key: *const fn (ctx: *anyopaque, conn: usize) ContractError!?crypto.PeerKey,
    };

    pub const DialVTable = struct {
        /// Begin a dial toward the complete locator. Transport-specific hint
        /// interpretation belongs to the resident. Completion arrives as an
        /// `ev_connect` record carrying `request_id`. An error admits no
        /// operation; the provider has already cleaned any partial work.
        start_connect: *const fn (
            ctx: *anyopaque,
            request_id: usize,
            locator: model.PeerLocator,
            options: netlayer.OperationOptions,
        ) RawDialStartOutcome,
        /// Claim the connection a completed `ev_connect` announced. The raw
        /// id immediately enters `ClaimedConnection` ownership in the wrapper;
        /// a failed dial surfaces its typed reason here. The request is consumed
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
        /// `requested_designator` is the caller's expected identity/address;
        /// empty asks the resident to use its canonical designator.
        /// Immediate completion returns the listener handle; externally paced
        /// setup returns pending and later emits `ev_listen` for `route_id`. An
        /// error admits no operation; the provider has already cleaned partial
        /// work.
        listen: *const fn (
            ctx: *anyopaque,
            route_id: usize,
            transport: []const u8,
            requested_designator: []const u8,
            options: netlayer.OperationOptions,
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
        /// Stop accepting. An asynchronously retiring resident returns null,
        /// emits `ev_listen` for this listener's route after its barrier joins,
        /// then makes the cleanup chain claimable through the completion
        /// cancel callback. Later accept records drain to no owned connection.
        stop_listen: *const fn (ctx: *anyopaque, listener_ctx: *anyopaque) ?foundation.FailureChain,
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
        ) DialStartOutcome {
            return switch (self.operations().start_connect(self.resident.ctx, request_id, locator, options)) {
                .admitted => .{ .admitted = .{ .dialer = self, .request_id = request_id } },
                .failed => |failure| .{ .failed = failure },
            };
        }

        pub fn cancelDial(self: Dialer, request_id: usize) ?foundation.FailureChain {
            return self.operations().cancel_connect(self.resident.ctx, request_id);
        }

        fn finishDial(self: Dialer, request_id: usize) RawDialFinishOutcome {
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

        fn operations(self: Acceptor) *const ListenVTable {
            return self.ops;
        }

        pub fn listen(
            self: Acceptor,
            route_id: usize,
            transport: []const u8,
            requested_designator: []const u8,
            options: netlayer.OperationOptions,
        ) ListenStartOutcome {
            const outcome = self.operations().listen(
                self.resident.ctx,
                route_id,
                transport,
                requested_designator,
                options,
            );
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

    pub const ListenAttempt = struct {
        acceptor: Acceptor,
        route_id: ?usize,
        transport: []const u8,
        completion: ListenCompletionVTable,

        pub fn id(self: ListenAttempt) ?usize {
            return self.route_id;
        }

        pub fn deinit(self: *ListenAttempt) ?foundation.FailureChain {
            const route_id = self.route_id orelse return null;
            self.route_id = null;
            return self.completion.cancel(self.acceptor.resident.ctx, route_id);
        }

        pub fn finish(self: *ListenAttempt) ListenFinishOutcome {
            const route_id = self.route_id orelse
                return .{ .failed = .init(error.ProviderContract) };
            self.route_id = null;
            return switch (self.completion.finish(
                self.acceptor.resident.ctx,
                route_id,
            )) {
                .failed => |failure| .{ .failed = failure },
                .listener => |ctx| .{ .ready = .{
                    .acceptor = self.acceptor,
                    .ctx = ctx,
                    .route_id = route_id,
                    .transport = self.transport,
                } },
            };
        }
    };

    pub const ListenStartOutcome = union(enum) {
        admitted: ListenResult,
        failed: netlayer.ListenFailure,
    };

    pub const ListenFinishOutcome = union(enum) {
        ready: Listener,
        failed: netlayer.ListenFailure,
    };

    pub const ListenResult = union(enum) {
        ready: Listener,
        pending: ListenAttempt,

        pub fn deinit(self: *ListenResult) ?foundation.FailureChain {
            const failure = switch (self.*) {
                .ready => |listener| listener.stopListen(),
                .pending => |*attempt| attempt.deinit(),
            };
            self.* = undefined;
            return failure;
        }
    };

    /// One profile-scoped listener owned by a multiplexed runtime. Its opaque
    /// provider handle owns listener state; `route_id` is the caller's stable
    /// readiness identity and is what `ev_accept` records carry.
    pub const Listener = struct {
        acceptor: Acceptor,
        ctx: *anyopaque,
        route_id: usize,
        transport: []const u8,

        pub fn localLocator(
            self: Listener,
            allocator: std.mem.Allocator,
        ) netlayer.ListenError!model.PeerLocator {
            return switch (self.localLocatorOutcome(allocator)) {
                .locator => |locator| locator,
                .failed => |failure| netlayer.projectListenError(failure),
            };
        }

        pub fn localLocatorOutcome(
            self: Listener,
            allocator: std.mem.Allocator,
        ) netlayer.ListenerLocatorOutcome {
            return self.acceptor.operations().local_locator(
                self.acceptor.resident.ctx,
                self.ctx,
                self.transport,
                allocator,
            );
        }

        pub fn canonicalizeLocator(
            self: Listener,
            allocator: std.mem.Allocator,
            locator: model.PeerLocator,
        ) netlayer.ListenError!model.PeerLocator {
            return switch (self.canonicalizeLocatorOutcome(allocator, locator)) {
                .locator => |canonical| canonical,
                .failed => |failure| netlayer.projectListenError(failure),
            };
        }

        pub fn canonicalizeLocatorOutcome(
            self: Listener,
            allocator: std.mem.Allocator,
            locator: model.PeerLocator,
        ) netlayer.ListenerLocatorOutcome {
            return self.acceptor.operations().canonicalize_locator(
                self.acceptor.resident.ctx,
                self.ctx,
                self.transport,
                allocator,
                locator,
            );
        }

        pub fn restorationState(self: Listener, out: []u8) netlayer.RestorationStateError!?usize {
            return switch (self.restorationStateOutcome(out)) {
                .unsupported => null,
                .size => |needed| needed,
                .failed => error.ProviderFailure,
            };
        }

        pub fn restorationStateOutcome(self: Listener, out: []u8) netlayer.ListenerRestorationOutcome {
            const f = self.acceptor.operations().restoration_state orelse return .unsupported;
            return f(self.acceptor.resident.ctx, self.ctx, out);
        }

        pub fn finishAccept(self: Listener) netlayer.AcceptError!?ClaimedConnection {
            return switch (self.finishAcceptOutcome()) {
                .connection => |connection| connection,
                .failed => |failure| failure.classification,
            };
        }

        pub fn finishAcceptOutcome(self: Listener) FinishAcceptOutcome {
            const result = self.acceptor.operations().finish_accept(self.acceptor.resident.ctx, self.ctx);
            return switch (result) {
                .connection => |id| .{ .connection = if (id) |value| .{ .resident = self.acceptor.resident, .id = value } else null },
                .failed => |failure| .{ .failed = failure },
            };
        }

        pub fn stopListen(self: Listener) ?foundation.FailureChain {
            return self.acceptor.operations().stop_listen(self.acceptor.resident.ctx, self.ctx);
        }
    };

    pub const FinishAcceptOutcome = union(enum) {
        connection: ?ClaimedConnection,
        failed: netlayer.AcceptFailure,
    };

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

    pub fn connClose(self: MultiplexedResident, conn: usize) ?foundation.FailureChain {
        return self.vtable.conn_close(self.ctx, conn);
    }

    pub fn takeFailure(self: MultiplexedResident, conn: usize) ?foundation.FailureChain {
        const take = self.vtable.take_failure orelse return null;
        return take(self.ctx, conn);
    }

    pub fn connRemoteKey(self: MultiplexedResident, conn: usize) ContractError!?crypto.PeerKey {
        return self.vtable.conn_remote_key(self.ctx, conn);
    }
};
