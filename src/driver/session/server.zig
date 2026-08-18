//! Owning native listener/server handle and one-call listen constructor.
//!
//! Server owns listener admission and one shared-runtime lease. Accepted
//! Sessions move their own lease into the client handle; stopping admission
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

/// The owning hosting half, bound by `listen` — the host twin of `connect`.
/// Every accepted partner shares this server's one host: one identity, one
/// live-session directory, shared routing. That directory is what lets a give
/// minted for one partner resolve its still-open gifter session when another
/// withdraws it. Each `accept` hands back a
/// `*Session` handle freed by `Session.deinit`. Closing the Server stops new
/// accepts while those yielded Sessions retain the shared Host runtime.
pub const Server = struct {
    runtime: *host_runtime.HostRuntime,
    shared: *SharedRuntime,
    listener: net.netlayer.Listener,
    allocator: std.mem.Allocator,
    closed: bool = false,
    close_failure: ?driver.OperationFailure = null,

    fn ensureOpen(self: *const Server) error{ServerClosed}!void {
        if (self.closed) return error.ServerClosed;
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
    /// sessions and in handoffs. `listen` installs a listener-derived default;
    /// deployments use this override when peers should dial an ingress, proxy,
    /// externally mapped address, or another adapter-owned route instead.
    /// Already-open sessions retain the snapshot their hello signed.
    pub fn setAdvertisedLocator(self: *Server, locator: model.PeerLocator) !void {
        try self.ensureOpen();
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        if (!std.mem.eql(u8, locator.transport, self.listener.transportName()))
            return error.TransportMismatch;
        try self.runtime.core.setAdvertisedLocator(locator);
    }

    /// Borrow the currently advertised locator. The view remains valid until
    /// `setAdvertisedLocator`, removal through the lower host tier, or close.
    pub fn advertisedLocator(self: *const Server) driver.Error!model.PeerLocator {
        try self.ensureOpen();
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        return self.runtime.core.advertisedLocator(self.listener.transportName()).?;
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
        return try self.listener.restorationState(out);
    }

    /// Accept one partner into its own `*Session` view of the shared host.
    /// The responder keyed handshake completes inside, under the handshake
    /// budget. Freed by `Session.deinit` (which leaves the siblings serving).
    /// Publish one Host-Vat actor under `name`. Any accepted Port can discover
    /// it lazily; exact gifts retain that actor independently of later name
    /// changes.
    pub fn publishGiftable(self: *Server, name: []const u8, comptime Behavior: type, initial: Behavior) !void {
        try self.ensureOpen();
        return self.runtime.publishGiftable(name, Behavior, initial);
    }

    /// Remove the Host-wide alias `name` (see `HostRuntime.unpublish`): a later
    /// fetch misses on every accepted session, while issued capabilities and
    /// deposited gifts keep the exact actor. A minted durable name is refused
    /// here; it leaves through `removeDurable` (ADR-0098).
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
    /// every mutable alias. Entropy is drawn here, at the I/O boundary; the
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
    /// the old sturdyref misses from now on, while issued capabilities and
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

    pub fn accept(self: *Server) !*Session {
        try self.ensureOpen();
        const hs = try self.runtime.acceptWire(self.listener, self.listener.transportName());
        // `acceptWire` returned this Runtime's fresh, unclaimed session. If
        // wrapper allocation refuses, retirement has no surviving direct
        // recipient, so retain its exact failure at the Runtime barrier.
        errdefer self.runtime.releaseWire(hs) catch |err| self.runtime.noteTerminalFailure(err);
        return Session.adoptRetained(self.runtime, hs, self.shared, self.allocator);
    }

    /// Wait until `accept` would make progress, up to `timeout_ms`. The
    /// stop-friendly twin of blocking accept: poll, check a latch, then
    /// `accept`.
    pub fn waitAcceptable(self: *Server, timeout_ms: i32) !bool {
        try self.ensureOpen();
        return self.listener.waitAcceptable(timeout_ms);
    }

    /// Stop accepting and release the Server's runtime lease. Sessions already
    /// yielded by `accept` retain the runtime and remain usable until their own
    /// close/deinit barrier. No pending-work policy belongs here: listener
    /// close is admission-only.
    pub fn close(self: *Server) ?driver.OperationFailure {
        if (self.closed) return self.close_failure;
        self.closed = true;
        if (self.listener.close()) |failure| {
            self.close_failure = .fromChain(failure);
            self.runtime.noteTerminalOperationFailure(self.close_failure.?);
        }
        if (self.shared.releaseOutcome()) |failure| self.close_failure = failure;
        return self.close_failure;
    }

    /// Stop admission if needed, then release the owning Server handle.
    pub fn deinit(self: *Server) void {
        const allocator = self.allocator;
        if (!self.closed) {
            self.closed = true;
            if (self.listener.close()) |failure|
                self.runtime.noteTerminalOperationFailure(.fromChain(failure));
            _ = self.shared.releaseImplicit();
        }
        allocator.destroy(self);
    }
};

/// Bind a listener on `netlayer` and return the owning `Server`, whose every
/// accept shares one host identity. `identity` is the responder signing
/// posture (`.ephemeral` fresh random, `.keyed` a caller-held key). A
/// netlayer whose transport reports no pollable fd is refused at accept
/// (`Error.TransportNotPollable`), the same poll boundary `connect` holds.
pub fn listen(
    allocator: std.mem.Allocator,
    netlayer: net.netlayer.Netlayer,
    config: net.netlayer.ListenConfig,
    identity: driver.AcceptIdentity,
    opts: SessionOptions,
) !*Server {
    // A transport with no pollable fd cannot back a multiplexed blocking wait;
    // refuse it by its own name rather than as an entropy failure.
    const io = netlayer.io() orelse return Error.TransportNotPollable;
    const shared = try allocator.create(SharedRuntime);
    errdefer allocator.destroy(shared);
    // The server's own transport is its immutable dial table: an accepted
    // session that receives a give naming a third peer redeems it there.
    shared.* = SharedRuntime.init(
        allocator,
        try host_runtime.HostRuntime.init(
            allocator,
            io,
            &.{netlayer},
            acceptToIdentity(identity),
            opts,
        ),
    );
    errdefer shared.runtime.deinit();

    var listen_config = config;
    listen_config.identity = switch (identity) {
        .ephemeral => null,
        .keyed => |secret| secret.publicKey(),
    };
    if (netlayer.designatorScheme() == .key and listen_config.identity == null)
        return Error.EphemeralIdentityOnKeyedTransport;
    var transport_listener = try shared.runtime.bindListener(
        netlayer.transportName(),
        listen_config.designator,
        listen_config.options,
    );
    var owns_transport_listener = true;
    errdefer if (owns_transport_listener) {
        if (shared.runtime.closeListener(&transport_listener)) |failure|
            shared.runtime.noteTerminalOperationFailure(failure);
    };
    var listener = shared.runtime.takeStreamListener(&transport_listener) orelse return Error.TransportNotPollable;
    owns_transport_listener = false;
    errdefer if (listener.close()) |failure|
        shared.runtime.noteTerminalOperationFailure(.fromChain(failure));

    const bound_locator = try listener.localLocator(allocator);
    defer model.freePeerLocator(allocator, bound_locator);
    if (!std.mem.eql(u8, bound_locator.transport, listener.transportName()))
        return error.ProviderContract;
    if (listen_config.identity) |expected| {
        if (listener.designatorScheme() == .key) {
            const expected_designator = expected.toDesignator();
            if (!std.mem.eql(u8, bound_locator.designator, &expected_designator))
                return Error.UnheldIdentity;
        }
    }
    try shared.runtime.core.setAdvertisedLocator(bound_locator);

    const server = try allocator.create(Server);
    server.* = .{
        .runtime = &shared.runtime,
        .shared = shared,
        .listener = listener,
        .allocator = allocator,
    };
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
