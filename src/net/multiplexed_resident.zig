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

const netlayer = @import("netlayer.zig");
const model = @import("model");
const crypto = @import("foundation").crypto;

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

/// One drained readiness record. `subject` is the connection id for
/// connection events, the caller's request id for `ev_connect`, and the
/// driver-minted listener route id for `ev_accept`. Provider-owned connection
/// ids are stable and never reused for the resident's lifetime; request and
/// listener ids belong to the caller's namespace within this runtime.
pub const ReadyEvent = struct {
    subject: usize,
    events: u32,
};

/// A connection claimed from a resident but not yet adopted by a HostRuntime wire.
/// It owns close immediately after `finish_connect` / `finish_accept` and is
/// consumed only after every fallible adoption step has committed.
pub const ClaimedConnection = struct {
    resident: MultiplexedResident,
    id: ?usize,

    pub fn deinit(self: *ClaimedConnection) void {
        const id = self.id orelse return;
        self.resident.connClose(id);
        self.id = null;
    }

    pub fn borrow(self: ClaimedConnection) usize {
        return self.id orelse unreachable;
    }

    pub fn take(self: *ClaimedConnection) usize {
        const id = self.borrow();
        self.id = null;
        return id;
    }
};

/// A resident dial request between admission and connection claim. The value
/// owns cancellation. `finish` consumes the request on both success and
/// refusal and returns the next ownership state only on success.
pub const ConnectAttempt = struct {
    dialer: MultiplexedResident.Dialer,
    request_id: ?usize,

    pub fn deinit(self: *ConnectAttempt) void {
        const request_id = self.request_id orelse return;
        self.dialer.cancelConnect(request_id);
        self.request_id = null;
    }

    pub fn id(self: ConnectAttempt) usize {
        return self.request_id orelse unreachable;
    }

    pub fn take(self: *ConnectAttempt) ConnectAttempt {
        const owned = self.*;
        self.request_id = null;
        return owned;
    }

    pub fn finish(self: *ConnectAttempt) netlayer.DialError!ClaimedConnection {
        const request_id = self.id();
        self.request_id = null;
        const conn = self.dialer.finishConnect(request_id) catch |err| {
            // `cancel_connect` is idempotent, including after a failed finish;
            // this makes provider cleanup part of the adapter contract rather
            // than an assumption every Host caller must repeat.
            self.dialer.cancelConnect(request_id);
            return err;
        };
        return .{ .resident = self.dialer.resident, .id = conn };
    }
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
        /// Close and release one connection. Later records naming the id
        /// drain to nothing.
        conn_close: *const fn (ctx: *anyopaque, conn: usize) void,
        /// The channel-authenticated remote durable key, when this transport
        /// proves one (iroh's remote node id). Null on a transport whose
        /// channel proves nothing; the realizer seam then stays silent.
        conn_remote_key: *const fn (ctx: *anyopaque, conn: usize) ContractError!?crypto.PeerKey,
    };

    pub const DialVTable = struct {
        /// Begin a dial toward the complete locator. Transport-specific hint
        /// interpretation belongs to the resident. Completion arrives as an
        /// `ev_connect` record carrying `request_id`.
        start_connect: *const fn (
            ctx: *anyopaque,
            request_id: usize,
            locator: model.PeerLocator,
        ) netlayer.DialError!void,
        /// Claim the connection a completed `ev_connect` announced. The raw
        /// id immediately enters `ClaimedConnection` ownership in the wrapper;
        /// a failed dial surfaces its typed reason here.
        finish_connect: *const fn (ctx: *anyopaque, request_id: usize) netlayer.DialError!usize,
        /// Abandon a dial. Idempotent, and valid after its `ev_connect` was
        /// announced but before `finish_connect` claimed it — the resident
        /// releases the unclaimed connection; a later record for the id
        /// drains to nothing.
        cancel_connect: *const fn (ctx: *anyopaque, request_id: usize) void,
    };

    pub const ExternalClaimVTable = struct {
        /// Claim one provider-scoped externally established connection. The
        /// provider returns only when the channel is open and transfers one
        /// connection ownership edge on success.
        claim_external: *const fn (ctx: *anyopaque, subject: usize) netlayer.DialError!usize,
    };

    pub const ListenVTable = struct {
        /// Begin accepting the selected transport profile through this resident.
        /// `requested_designator` is the caller's expected identity/address;
        /// empty asks the resident to use its canonical designator.
        /// The complete published locator is read through `listener_locator`.
        start_listen: *const fn (
            ctx: *anyopaque,
            route_id: usize,
            transport: []const u8,
            requested_designator: []const u8,
        ) netlayer.ListenError!*anyopaque,
        /// Materialize the complete locator. The caller owns the result and
        /// frees it with `model.freePeerLocator`.
        listener_locator: *const fn (
            ctx: *anyopaque,
            listener_ctx: *anyopaque,
            transport: []const u8,
            allocator: std.mem.Allocator,
        ) netlayer.ListenError!model.PeerLocator,
        /// Validate and canonicalize a replacement listener locator.
        listener_advertise: *const fn (
            ctx: *anyopaque,
            listener_ctx: *anyopaque,
            transport: []const u8,
            allocator: std.mem.Allocator,
            locator: model.PeerLocator,
        ) netlayer.ListenError!model.PeerLocator,
        /// Claim one ready inbound connection. Null means the coalesced accept
        /// queue has drained. The raw id immediately enters
        /// `ClaimedConnection` ownership in the wrapper and shares
        /// `finish_connect`'s connection namespace.
        finish_accept: *const fn (ctx: *anyopaque, listener_ctx: *anyopaque) netlayer.AcceptError!?usize,
        /// Stop accepting. Idempotent; later accept records drain to no owned
        /// connection and the resident rejects new inbound channels.
        stop_listen: *const fn (ctx: *anyopaque, listener_ctx: *anyopaque) void,
    };

    pub const Dialer = struct {
        resident: MultiplexedResident,

        fn operations(self: Dialer) *const DialVTable {
            return if (self.resident.vtable.dial) |*ops| ops else unreachable;
        }

        pub fn startConnect(
            self: Dialer,
            request_id: usize,
            locator: model.PeerLocator,
        ) netlayer.DialError!ConnectAttempt {
            self.operations().start_connect(self.resident.ctx, request_id, locator) catch |err| {
                self.cancelConnect(request_id);
                return err;
            };
            return .{ .dialer = self, .request_id = request_id };
        }

        pub fn cancelConnect(self: Dialer, request_id: usize) void {
            self.operations().cancel_connect(self.resident.ctx, request_id);
        }

        fn finishConnect(self: Dialer, request_id: usize) netlayer.DialError!usize {
            return self.operations().finish_connect(self.resident.ctx, request_id);
        }
    };

    pub const ExternalClaimer = struct {
        resident: MultiplexedResident,

        pub fn claimExternal(self: ExternalClaimer, subject: usize) netlayer.DialError!ClaimedConnection {
            const id = try self.resident.vtable.external_claim.?.claim_external(self.resident.ctx, subject);
            return .{ .resident = self.resident, .id = id };
        }
    };

    pub const Acceptor = struct {
        resident: MultiplexedResident,

        fn operations(self: Acceptor) *const ListenVTable {
            return if (self.resident.vtable.listen) |*ops| ops else unreachable;
        }

        pub fn startListen(
            self: Acceptor,
            route_id: usize,
            transport: []const u8,
            requested_designator: []const u8,
        ) netlayer.ListenError!Listener {
            const listener_ctx = try self.operations().start_listen(
                self.resident.ctx,
                route_id,
                transport,
                requested_designator,
            );
            return .{
                .acceptor = self,
                .ctx = listener_ctx,
                .route_id = route_id,
                .transport = transport,
            };
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

        pub fn listenerLocator(
            self: Listener,
            allocator: std.mem.Allocator,
        ) netlayer.ListenError!model.PeerLocator {
            return self.acceptor.operations().listener_locator(
                self.acceptor.resident.ctx,
                self.ctx,
                self.transport,
                allocator,
            );
        }

        pub fn listenerAdvertise(
            self: Listener,
            allocator: std.mem.Allocator,
            locator: model.PeerLocator,
        ) netlayer.ListenError!model.PeerLocator {
            return self.acceptor.operations().listener_advertise(
                self.acceptor.resident.ctx,
                self.ctx,
                self.transport,
                allocator,
                locator,
            );
        }

        pub fn finishAccept(self: Listener) netlayer.AcceptError!?ClaimedConnection {
            const id = try self.acceptor.operations().finish_accept(
                self.acceptor.resident.ctx,
                self.ctx,
            ) orelse return null;
            return .{ .resident = self.acceptor.resident, .id = id };
        }

        pub fn stopListen(self: Listener) void {
            self.acceptor.operations().stop_listen(self.acceptor.resident.ctx, self.ctx);
        }
    };

    /// Runtime identity, independent of the transport profiles routed through
    /// it. Provider packages use this to share one runtime and readiness
    /// descriptor across several profile entries.
    pub fn eql(self: MultiplexedResident, other: MultiplexedResident) bool {
        return self.ctx == other.ctx and self.vtable == other.vtable;
    }

    pub fn dialer(self: MultiplexedResident) ?Dialer {
        if (self.vtable.dial == null) return null;
        return .{ .resident = self };
    }

    pub fn externalClaimer(self: MultiplexedResident) ?ExternalClaimer {
        if (self.vtable.external_claim == null) return null;
        return .{ .resident = self };
    }

    pub fn acceptor(self: MultiplexedResident) ?Acceptor {
        if (self.vtable.listen == null) return null;
        return .{ .resident = self };
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

    pub fn connClose(self: MultiplexedResident, conn: usize) void {
        self.vtable.conn_close(self.ctx, conn);
    }

    pub fn connRemoteKey(self: MultiplexedResident, conn: usize) ContractError!?crypto.PeerKey {
        return self.vtable.conn_remote_key(self.ctx, conn);
    }
};
