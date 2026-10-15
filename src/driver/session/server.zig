//! Owning Zig listener/server handle and one-call listen constructor.
//!
//! Server owns listener admission and one shared-runtime lease. Accepted
//! Sessions move their own lease into the client handle. Stopping admission
//! never tears down sessions already yielded to the application.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const net = @import("net");
const driver_core = @import("driver_core");

const driver = @import("../mod.zig");
const host_runtime = @import("../host_runtime.zig");
const Error = driver.Error;
const Identity = driver.Identity;
const Session = @import("client.zig").Session;
const SessionOptions = @import("client.zig").SessionOptions;
const SharedRuntime = @import("shared_runtime.zig").SharedRuntime;

/// The owning hosting half, bound by `listen`. It is the host twin of `connect`.
/// Every accepted partner shares this server's one host: one identity, one
/// live-session directory, shared routing. That directory is what lets a give
/// minted for one partner resolve its still-open gifter session when another
/// withdraws it. Each `accept` hands back a
/// `*Session` handle freed by `Session.deinit`. Closing the Server stops new
/// accepts while those yielded Sessions retain the shared Host runtime.
pub const Server = struct {
    runtime: *host_runtime.HostRuntime,
    shared: *SharedRuntime,
    /// The runtime owns the listener under this stable tag. Observer callbacks
    /// borrow this heap-stable Server until close joins physical retirement.
    listener_tag: u64 = 1,
    listener_active: bool = false,
    admission_sealed: bool = false,
    /// Fixed at construction: finished sessions and handshake reservations
    /// share one bound. The ring moves pointers only, never wire payloads.
    accepted: []*Session,
    accepted_head: usize = 0,
    accepted_count: usize = 0,
    reserved: usize = 0,
    accept_failure: ?driver.OperationFailure = null,
    allocator: std.mem.Allocator,
    closed: bool = false,
    close_failure: ?driver.OperationFailure = null,

    fn ensureOpen(self: *const Server) error{ServerClosed}!void {
        if (self.closed or self.admission_sealed) return error.ServerClosed;
    }

    /// Write the bound dialable designator (with the kernel-chosen port when
    /// `listen` bound port 0) into `out` and return the written slice.
    ///
    /// An error rather than an empty slice: this is the public surface a
    /// caller signs from, and an empty designator published as a locator is a
    /// locator nobody can dial.
    pub fn localDesignator(self: *const Server, out: []u8) driver.Error![]const u8 {
        const designator = (try self.advertisedLocator()).designator;
        if (designator.len == 0 or designator.len > out.len) return driver.Error.DesignatorUnavailable;
        @memcpy(out[0..designator.len], designator);
        return out[0..designator.len];
    }

    /// Replace the complete locator this server advertises on subsequent
    /// sessions and in handoffs. `listen` installs a listener-derived default.
    /// Deployments use this override when peers should dial an ingress, proxy,
    /// externally mapped address, or another adapter-owned route instead.
    /// Already-open sessions retain the snapshot their hello signed.
    pub fn setAdvertisedLocator(self: *Server, locator: model.PeerLocator) !void {
        try self.ensureOpen();
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        var prepared = switch (self.runtime.prepareOwnedListenerAdvertisementOutcome(self.listener_tag, locator)) {
            .ready => |value| value,
            .failed => |failure| return failure.cause,
        };
        var owns_prepared = true;
        defer if (owns_prepared) prepared.deinit(self.allocator);
        try self.runtime.commitOwnedListenerAdvertisement(self.listener_tag, &prepared);
        owns_prepared = false;
    }

    /// Borrow the currently advertised locator. The view remains valid until
    /// `setAdvertisedLocator`, removal through the lower host tier, or close.
    pub fn advertisedLocator(self: *const Server) driver.Error!model.PeerLocator {
        try self.ensureOpen();
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        return self.runtime.ownedListenerLocator(self.listener_tag) orelse return error.ServerClosed;
    }

    /// Query or copy opaque transport-owned state that restores this
    /// listener's local address. Null means this transport has no restoration
    /// state. The complete size is returned and a short output is untouched.
    pub fn restorationState(
        self: *const Server,
        out: []u8,
    ) (driver.Error || net.netlayer.RestorationStateError)!?usize {
        try self.ensureOpen();
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        return switch (self.runtime.ownedListenerRestorationStateOutcome(self.listener_tag, out)) {
            .unsupported => null,
            .size => |size| size,
            .failed => return error.ProviderFailure,
        };
    }

    /// Publish one Host-Vat actor under `name`. Any accepted Port can discover
    /// it lazily. Exact gifts retain that actor independently of later name
    /// changes.
    pub fn publish(self: *Server, name: []const u8, comptime Behavior: type, initial: Behavior) !void {
        try self.ensureOpen();
        return self.runtime.publish(name, Behavior, initial);
    }

    /// Remove the Host-wide alias `name` (see `HostRuntime.unpublish`): a later
    /// fetch misses on every accepted session, while issued capabilities and
    /// deposited gifts keep the exact actor. A minted durable name is refused
    /// here. It leaves through `removeDurable` (ADR-0098).
    pub fn unpublish(
        self: *Server,
        name: []const u8,
    ) error{ ServerClosed, HostClosing, ReenteredHost, WrongThread, UnknownPublication, ReservedDurableNamespace }!void {
        try self.ensureOpen();
        return self.runtime.unpublish(name);
    }

    /// Publish `initial` under a freshly minted durable swiss name and return
    /// the complete sturdyref URI (`ocapn://…`), allocated with `allocator`
    /// and owned by the caller (ADR-0098): unpredictable, never reassigned,
    /// removable only through `removeDurable`, structurally disjoint from
    /// every mutable alias. Entropy is drawn here, at the I/O boundary. The
    /// sans-io core only ever sees the bytes. `Behavior` is Value-shaped like
    /// every owning-tier behavior.
    pub fn publishDurable(self: *Server, allocator: std.mem.Allocator, comptime Behavior: type, initial: Behavior) ![]u8 {
        try self.ensureOpen();
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        var entropy: [engine.durable_swiss_entropy_len]u8 = undefined;
        self.runtime.io.randomSecure(&entropy) catch return driver.Error.MintEntropyFailed;
        const swiss = try self.runtime.core.publishDurable(entropy, driver_core.Hosting(Behavior), .{ .inner = initial });
        const advertised = self.runtime.core.acceptableLocator() orelse
            return error.MissingAdvertisedLocator;
        return model.uri.writeSturdyrefForProfile(allocator, self.runtime.opts.captp_version, .{
            .peer = advertised,
            .swissnum = swiss.slice(),
        });
    }

    /// Remove a minted durable publication (see `driver_core.Host.removeDurable`):
    /// the old sturdyref misses afterward, while issued capabilities and
    /// deposited gifts keep the exact actor.
    pub fn removeDurable(
        self: *Server,
        swiss: []const u8,
    ) error{ ServerClosed, HostClosing, ReenteredHost, WrongThread, UnknownPublication, NotDurableName }!void {
        try self.ensureOpen();
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        return self.runtime.core.removeDurable(swiss);
    }

    /// Accept one partner into its own `*Session` view of the shared host.
    /// The responder keyed handshake completes inside, under the handshake
    /// budget. Freed by `Session.deinit` (which leaves the siblings serving).
    /// Inbound delivery waits for Session receive-driving operations or an
    /// explicit `Session.attend` after root setup when another pump serves it.
    pub fn accept(self: *Server) !*Session {
        try self.ensureOpen();
        _ = try self.waitAcceptable(-1);
        if (self.popAccepted()) |session| return session;
        if (self.accept_failure) |failure| {
            self.accept_failure = null;
            return failure.cause;
        }
        return error.ServerClosed;
    }

    fn popAccepted(self: *Server) ?*Session {
        if (self.accepted_count == 0) return null;
        const session = self.accepted[self.accepted_head];
        self.accepted_head = (self.accepted_head + 1) % self.accepted.len;
        self.accepted_count -= 1;
        return session;
    }

    fn ready(ctx: *const anyopaque) bool {
        const self: *const Server = @ptrCast(@alignCast(ctx));
        return self.accepted_count != 0 or self.accept_failure != null or !self.listener_active;
    }

    /// Drive the shared runtime until a completed accept or refusal is ready.
    /// Accepted sessions stay unattended until the caller has published roots
    /// and starts a Session receive-driving operation.
    pub fn waitAcceptable(self: *Server, timeout_ms: i32) !bool {
        try self.ensureOpen();
        try self.runtime.refuseReentry();
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        var now_ms = self.runtime.nowMs();
        const deadline = if (timeout_ms < 0) null else now_ms + @as(i64, timeout_ms);
        while (!ready(self)) {
            const remaining: i32 = if (deadline) |end| @intCast(@max(0, end - now_ms)) else -1;
            _ = try self.runtime.stepAnyToward(remaining, .{ .condition = .{ .ctx = self, .reached_fn = ready } });
            if (deadline) |end| {
                now_ms = self.runtime.nowMs();
                if (now_ms >= end) break;
            }
        }
        return ready(self);
    }

    /// Stop admission, join listener retirement and discard unclaimed accepts.
    /// Yielded Sessions retain independent runtime leases. A callback or wrong
    /// thread refusal preserves Server ownership so the caller can retry.
    pub fn close(self: *Server) ?driver.OperationFailure {
        if (self.closed) return self.close_failure;
        self.runtime.refuseReentry() catch |err| return .fromError(err);
        self.runtime.enterDriver();
        var owns_guard = true;
        defer if (owns_guard) self.runtime.leaveDriver();
        self.admission_sealed = true;
        self.claimAcceptFailure();
        while (self.runtime.ownedListenerLocator(self.listener_tag) != null) {
            const outcome = self.runtime.stopOwnedListener(self.listener_tag);
            if (outcome.failure) |failure| self.noteCloseFailure(failure);
            if (!outcome.pending) break;
            _ = self.runtime.stepAnyToward(-1, .{ .listener_stop = self.listener_tag }) catch |err| return .fromError(err);
        }
        // A pending stop can fail through the observer while the join runs.
        self.claimAcceptFailure();
        while (self.popAccepted()) |session| session.deinit();
        std.debug.assert(self.reserved == 0);
        self.closed = true;
        self.runtime.leaveDriver();
        owns_guard = false;
        if (self.shared.releaseOutcome()) |failure| self.noteCloseFailure(failure);
        return self.close_failure;
    }

    fn noteCloseFailure(self: *Server, failure: driver.OperationFailure) void {
        if (self.close_failure) |*first| first.noteFailure(failure) else self.close_failure = failure;
    }

    fn claimAcceptFailure(self: *Server) void {
        if (self.accept_failure) |failure| {
            self.accept_failure = null;
            self.noteCloseFailure(failure);
        }
    }

    /// Join admission retirement before freeing callback storage. If close
    /// refuses before its barrier, ownership remains with the caller.
    pub fn deinit(self: *Server) void {
        const was_closed = self.closed;
        const failure_observer = if (was_closed) null else self.runtime.opts.unhandled_failure;
        if (self.close()) |failure| {
            if (!self.closed) {
                self.runtime.reportUnhandledFailure(failure);
                return;
            }
            if (!was_closed) {
                if (failure_observer) |recipient| recipient.report(recipient.ctx, failure);
            }
        }
        self.allocator.free(self.accepted);
        self.allocator.destroy(self);
    }

    fn from(ctx: *anyopaque) *Server {
        return @ptrCast(@alignCast(ctx));
    }
    fn canAccept(ctx: *anyopaque) bool {
        const self = from(ctx);
        return !self.admission_sealed and self.accepted_count + self.reserved < self.accepted.len;
    }
    fn reserve(ctx: *anyopaque, _: u64) !void {
        const self = from(ctx);
        // Activation reserves a listener seat; arrivals reserve queue slots.
        if (!self.listener_active) return;
        std.debug.assert(canAccept(ctx));
        self.reserved += 1;
    }
    fn releaseReservation(ctx: *anyopaque, _: u64) void {
        const self = from(ctx);
        if (!self.listener_active) return;
        std.debug.assert(self.reserved != 0);
        self.reserved -= 1;
    }
    fn opened(ctx: *anyopaque, _: u64, hs: *driver_core.HostSession) !void {
        const self = from(ctx);
        defer self.reserved -= 1;
        const session = try Session.adoptRetained(self.runtime, hs, self.shared, self.allocator);
        self.runtime.markSessionUnattended(hs);
        const tail = (self.accepted_head + self.accepted_count) % self.accepted.len;
        self.accepted[tail] = session;
        self.accepted_count += 1;
    }
    fn retired(ctx: *anyopaque, _: u64) void {
        from(ctx).listener_active = false;
    }
    fn arrivalFailed(ctx: *anyopaque, _: u64, failure: driver.OperationFailure) void {
        const self = from(ctx);
        if (!self.admission_sealed and self.accept_failure == null) self.accept_failure = failure;
    }
    fn failed(ctx: *anyopaque, _: u64, failure: driver.OperationFailure) void {
        const self = from(ctx);
        if (self.accept_failure == null) self.accept_failure = failure;
        if (self.runtime.ownedListenerLocator(self.listener_tag) == null) self.listener_active = false;
    }
    fn observer(self: *Server) host_runtime.HostRuntime.SessionAcceptObserver {
        return .{ .ctx = self, .can_accept = canAccept, .reserve = reserve, .release = releaseReservation, .abandoned = releaseReservation, .opened = opened, .retired = retired, .failed = failed, .arrival_failed = arrivalFailed };
    }
};

/// Bind a listener for `transport` over the transports `transports` names
/// and return the owning `Server`, whose every accept shares one host
/// identity. `identity` is the responder signing posture (`.ephemeral` fresh
/// random, `.keyed` a caller-held key). The same runtime redeems a give an
/// accepted session receives, so whatever `transports` borrows outlives the
/// Server and every Session it yields.
pub fn listen(
    allocator: std.mem.Allocator,
    io: std.Io,
    transports: host_runtime.HostRuntime.Transports,
    transport: []const u8,
    config: net.netlayer.ListenConfig,
    identity: driver.AcceptIdentity,
    opts: SessionOptions,
) !*Server {
    const shared = try allocator.create(SharedRuntime);
    errdefer allocator.destroy(shared);
    shared.* = SharedRuntime.init(allocator, try host_runtime.HostRuntime.init(allocator, io, transports, acceptToIdentity(identity), opts));
    errdefer shared.runtime.deinit();
    return finishListen(shared, transport, config, identity);
}

fn finishListen(shared: *SharedRuntime, transport: []const u8, config: net.netlayer.ListenConfig, identity: driver.AcceptIdentity) !*Server {
    shared.runtime.enterDriver();
    defer shared.runtime.leaveDriver();
    const allocator = shared.allocator;
    var transport_listener = try shared.runtime.bindListener(transport, config.designator, config.options);
    var owns_listener = true;
    errdefer if (owns_listener) {
        if (shared.runtime.closeListener(&transport_listener)) |failure| shared.runtime.noteTerminalOperationFailure(failure);
    };
    var prepared = switch (shared.runtime.prepareListenerLocatorOutcome(&transport_listener)) {
        .ready => |value| value,
        .failed => |failure| return failure.cause,
    };
    var owns_prepared = true;
    defer if (owns_prepared) prepared.deinit(allocator);
    if (transport_listener.designatorScheme() == .key) {
        const secret = switch (identity) {
            .ephemeral => return Error.EphemeralIdentityOnKeyedTransport,
            .keyed => |secret| secret,
        };
        const expected = secret.publicKey().toDesignator();
        if (!std.mem.eql(u8, prepared.value.designator, &expected)) return Error.UnheldIdentity;
    }
    const server = try allocator.create(Server);
    errdefer allocator.destroy(server);
    // One setup allocation bounds both queued wrappers and in-flight arrivals;
    // acceptance itself adds no queue allocation or payload copy.
    const accepted = try allocator.alloc(*Session, shared.runtime.opts.max_pending_opens);
    errdefer allocator.free(accepted);
    server.* = .{ .runtime = &shared.runtime, .shared = shared, .allocator = allocator, .accepted = accepted };
    try shared.runtime.activateOwnedListener(&transport_listener, &prepared, server.listener_tag, server.observer());
    owns_listener = false;
    owns_prepared = false;
    server.listener_active = true;
    // This fresh runtime has no application callbacks, sessions or close
    // request. Activation already admitted the constructor's owner, so route
    // selection cannot refuse and must find the locator just committed.
    const selected = shared.runtime.selectOwnedListener(server.listener_tag) catch unreachable;
    std.debug.assert(selected);
    return server;
}

/// Map the responder signing posture onto the dialer-shaped `Identity` the
/// host face takes: an accepting host's designator is the listener's bound
/// address (set after bind), so the keyed arm carries only the secret here.
fn acceptToIdentity(identity: driver.AcceptIdentity) Identity {
    return switch (identity) {
        .ephemeral => .ephemeral,
        .keyed => |secret| .{ .keyed = .{ .secret = secret, .designator = driver.unreachable_client_designator } },
    };
}
