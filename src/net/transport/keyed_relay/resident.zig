//! The relay transport's blocking resident: RFC 6455 WebSocket client legs
//! over TCP sockets, so a native peer dials — and is dialed through — a relay's
//! rendezvous (ADR-0088). The resident owns both byte-channel profiles:
//! clear `keyed-relay` and Host-sealed `noise-relay`.
//!
//! A `keyed-relay` locator names a peer by its Ed25519 key designator and may
//! carry a provider-owned `rendezvous-relay` hint. Without that hint, a dialer
//! uses its deployment relay; with it, the provider asks the named relay for
//! the same designator. The relay carries bytes and parses nothing; the keyed
//! CapTP handshake carries the claimed designator end to end with the same
//! unauthenticated posture as `keyed-tcp` (the channel is cleartext `ws://`;
//! see `docs/boundaries.md`).
//!
//! Both halves live here. `dial` opens `relay_url` with `?rendezvous=<key>`
//! and yields a `Connection` over the socket. `listen` registers the host's
//! own key at `register_url` (`?id=<key>`) and parks a registration task. That
//! task answers relay pings away from the caller's reactor and wakes
//! `waitAcceptable` only when dialer bytes arrive; `accept` hands over that
//! registered socket and immediately starts its replacement. This is the
//! rendezvous shape of a TCP accept loop without network I/O hidden in a
//! readiness query.
//!
//! The WebSocket layer is a client-side RFC 6455 subset: the HTTP/1.1 upgrade
//! with `Sec-WebSocket-Accept` verification, masked outbound binary frames,
//! and inbound binary/continuation streaming with ping/pong and close
//! handling. Text frames, extensions (non-zero RSV bits), masked server
//! frames, and oversized control frames are refused — every inbound byte is
//! attacker-influenced until the CapTP session validates it, so the codec
//! fails closed. Inbound payload lengths are streamed, never allocated from.
//!
//! Costs, named: masking is a per-byte transform RFC 6455 requires of clients,
//! paid as one copy into the socket writer's buffer (there is no in-place
//! spelling — the caller's bytes are borrowed). The blocking resident copies
//! inbound payload from its socket reader into the CapTP reader. The completion
//! path instead lends ordinary payload directly from the wrapped backend's
//! shared buffer; only split headers, control frames, upgrade residue, and a
//! coalesced next-frame tail copy into a bounded per-connection spill, whose
//! burst capacity is released after drain. Each blocking connection pins one
//! `RelayStream` (the ADR-0043 stable-address pin) carrying the socket
//! reader/writer stores; that is an application-tier cost, not the loop tier's.
//!
//! The native scale path is the sibling `completion.zig` adapter, which wraps
//! the host platform completion backend and keeps TCP plus outbound relay dials
//! in one `completion.Loop`. Registration accept remains resident-owned; when
//! the profile is `noise-relay`, `driver_core.Host` seals that byte pipe.

const std = @import("std");
const blocking_frame = @import("blocking_frame.zig");
const carrier_runtime = @import("carrier/runtime.zig");
const relay_configuration = @import("configuration.zig");
const pollable_carrier = @import("carrier/pollable.zig");
const relay_profile = @import("profile.zig");
const raw_connection = @import("raw_connection.zig");
const listener_state = @import("listener.zig");
const relay_stream = @import("stream.zig");
const route = @import("route.zig");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const connection = @import("../../connection.zig");
const netlayer = @import("../../netlayer.zig");
const clock = @import("../../clock.zig");
const operation_owner = @import("../../operation_owner.zig");
const poll = @import("../../poll.zig");
const sync = @import("../../sync.zig");
const wake_channel = @import("../../wake_channel.zig");
const tls_runtime = @import("../../tls/runtime.zig");

const crypto = foundation.crypto;
const Io = std.Io;

const Netlayer = netlayer.Netlayer;
const NetLayerListener = netlayer.Listener;
const Buffers = netlayer.Buffers;
const Connection = connection.Connection;
const DialError = netlayer.DialError;
const RawConnectionDialOutcome = netlayer.RawConnectionDialOutcome;
const ListenError = netlayer.ListenError;
const ListenConfig = netlayer.ListenConfig;

/// The relay package's default clear profile. A resident or listener carries
/// its selected profile when ownership-sensitive code needs the distinction.
pub const transport_name = model.transport.keyed_relay;
pub const FrameError = blocking_frame.FrameError;
const RelayUrl = route.RelayUrl;
pub const ChannelProfile = relay_profile.Channel;
pub const rendezvous_relay_hint = route.rendezvous_relay_hint;
pub const max_rendezvous_relay_hint_bytes = route.max_rendezvous_relay_hint_bytes;

const RelayStream = relay_stream.RelayStream;
pub const RawConnection = raw_connection.Connection;
const openLegOutcome = pollable_carrier.openOutcome;
const listener_poll_slice_ms: i32 = 50;
const registration_retry_delay_ms: i64 = 100;
// --- The keyed-relay netlayer resident -------------------------------------

/// The relay netlayer's state: the selected channel profile, host `std.Io`, the
/// relay's rendezvous URL a dial opens, and — for a host that registers to be
/// cold-dialed — the registration URL and identity key it registers under. The resident owns
/// one configuration block that both parsed URLs view, so a netlayer can safely
/// outlive the caller's argv, environment, or request buffer. A listener copies
/// its registration URL when it is minted; its replacement-registration task
/// therefore depends on the listener, not this resident.
pub const Resident = struct {
    pub const InitError = error{ InvalidRelayUrl, OutOfMemory };

    allocator: std.mem.Allocator,
    config: relay_configuration.Lease,
    carrier: carrier_runtime.Lease,
    profile: ChannelProfile,

    /// Copy and parse `url` into a dial-only resident.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, url: []const u8) InitError!Resident {
        return initProfile(allocator, io, url, .keyed);
    }

    /// Copy and parse `url` into a dial-only resident for `profile`.
    pub fn initProfile(
        allocator: std.mem.Allocator,
        io: std.Io,
        url: []const u8,
        profile: ChannelProfile,
    ) InitError!Resident {
        return finishInit(allocator, io, try relay_configuration.Lease.dialOnly(allocator, url), profile, null);
    }

    pub fn initProfileWithTls(
        allocator: std.mem.Allocator,
        io: std.Io,
        url: []const u8,
        profile: ChannelProfile,
        tls: *tls_runtime.Runtime,
    ) InitError!Resident {
        return finishInit(
            allocator,
            io,
            try relay_configuration.Lease.dialOnly(allocator, url),
            profile,
            tls,
        );
    }

    /// Parse a resident that can both dial through `relay_url` and register a
    /// listener at `register_url`. The caller derives `public_key` from the Host
    /// identity used to sign accepted sessions.
    pub fn initRegistered(
        allocator: std.mem.Allocator,
        io: std.Io,
        relay_url: []const u8,
        register_url: []const u8,
        public_key: crypto.PeerKey,
    ) InitError!Resident {
        return initRegisteredProfile(allocator, io, relay_url, register_url, public_key, .keyed);
    }

    /// Parse a resident that dials and registers the selected relay profile.
    pub fn initRegisteredProfile(
        allocator: std.mem.Allocator,
        io: std.Io,
        relay_url: []const u8,
        register_url: []const u8,
        public_key: crypto.PeerKey,
        profile: ChannelProfile,
    ) InitError!Resident {
        return finishInit(
            allocator,
            io,
            try relay_configuration.Lease.registered(allocator, relay_url, register_url, public_key),
            profile,
            null,
        );
    }

    /// Parse a resident whose listener identity is supplied by the owning Host
    /// at listen time. This is the provider-package posture: deployment owns
    /// relay URLs, while the Host remains the sole identity authority.
    pub fn initProviderProfile(
        allocator: std.mem.Allocator,
        io: std.Io,
        relay_url: []const u8,
        register_url: []const u8,
        profile: ChannelProfile,
        tls: ?*tls_runtime.Runtime,
    ) InitError!Resident {
        return finishInit(
            allocator,
            io,
            try relay_configuration.Lease.registered(allocator, relay_url, register_url, null),
            profile,
            tls,
        );
    }

    /// Deterministic runtime release. A refusal consumes nothing, so
    /// the process owner may finish outstanding channel barriers and retry.
    pub fn deinit(self: *Resident) ?foundation.FailureChain {
        const failure = self.carrier.releaseOwnerOutcome();
        if (failure != null) return failure;
        self.config.release();
        self.* = undefined;
        return null;
    }

    /// Whether two resident packages express the same deployment policy.
    /// Runtime state and Host identity are deliberately outside this comparison.
    pub fn sameConfiguration(self: *const Resident, other: *const Resident) bool {
        return self.profile == other.profile and
            self.config.same(other.config) and
            self.carrier.sameConfiguration(other.carrier);
    }

    /// Create another profile view over this resident's one immutable route
    /// configuration and carrier runtime.
    pub fn profileView(self: *const Resident, profile: ChannelProfile) Resident {
        return .{
            .allocator = self.allocator,
            .config = self.config.retain(),
            .carrier = self.carrier.retainOwner(),
            .profile = profile,
        };
    }

    pub fn configuration(self: *const Resident) *const relay_configuration.Config {
        return self.config.view();
    }

    /// This resident as a `Netlayer`. `self` must outlive every dial/listen call
    /// through the returned vtable. Minted connections and listeners own the
    /// state their later I/O needs.
    pub fn netlayer(self: *Resident) Netlayer {
        return .{ .ctx = self, .vtable = switch (self.profile) {
            .keyed => &keyed_resident_vtable,
            .noise => &noise_resident_vtable,
        } };
    }

    /// Open the relay leg without attaching it to a protocol peer. Provider
    /// archives use this byte seam; the Host above them owns framing and any
    /// sealed channel selected by the profile.
    pub fn dialRaw(self: *Resident, locator: model.PeerLocator) DialError!RawConnection {
        return switch (self.dialRawOutcome(locator)) {
            .connected => |raw| raw,
            .failed => |failure| failure.classification,
        };
    }

    /// Provider-worker form of `dialRaw`. The task's `std.Io` cancellation
    /// interrupts socket operations; `stop_requested` also bounds the raw-poll
    /// upgrade loop, which is not a `std.Io` cancellation point.
    pub fn dialRawCancelable(
        self: *Resident,
        locator: model.PeerLocator,
        stop_requested: *const std.atomic.Value(bool),
    ) DialError!RawConnection {
        return switch (self.dialRawOutcomeWithCancellation(locator, stop_requested)) {
            .connected => |raw| raw,
            .failed => |failure| failure.classification,
        };
    }

    pub fn dialRawOutcome(self: *Resident, locator: model.PeerLocator) RawConnectionDialOutcome(RawConnection) {
        return self.dialRawOutcomeWithCancellation(locator, null);
    }

    /// Provider-worker form that retains the exact transport cause beside the
    /// retry classification. The C archive projects this value without trying
    /// to recover identity from a status code.
    pub fn dialRawOutcomeCancelable(
        self: *Resident,
        locator: model.PeerLocator,
        stop_requested: *const std.atomic.Value(bool),
    ) RawConnectionDialOutcome(RawConnection) {
        return self.dialRawOutcomeWithCancellation(locator, stop_requested);
    }

    fn dialRawOutcomeWithCancellation(
        self: *Resident,
        locator: model.PeerLocator,
        stop_requested: ?*const std.atomic.Value(bool),
    ) RawConnectionDialOutcome(RawConnection) {
        if (!std.mem.eql(u8, locator.transport, self.profile.transportName()) or
            crypto.PeerKey.fromDesignator(locator.designator) == null)
            return .{ .failed = .init(error.InvalidAddress) };
        const relay = relayForDial(self, locator) catch
            return .{ .failed = .init(error.InvalidAddress) };
        return switch (openLegOutcome(
            self.carrier,
            self.allocator,
            relay.openRequest(.rendezvous, locator.designator),
            stop_requested,
        )) {
            .connected => |stream| .{ .connected = .{ .stream = stream } },
            .failed => |failure| .{ .failed = failure },
        };
    }

    /// Start one profile listener. The listener copies all runtime state it
    /// needs, so it remains valid until closed even if the resident's package
    /// lease is the only reference keeping this runtime alive.
    pub fn listenRaw(
        self: *Resident,
        allocator: std.mem.Allocator,
        config: ListenConfig,
    ) ListenError!RawListener {
        return .{ .box = try listener_state.open(
            allocator,
            self.config.view(),
            self.carrier,
            self.profile,
            config,
        ) };
    }
};

fn finishInit(
    allocator: std.mem.Allocator,
    io: std.Io,
    initial: relay_configuration.Lease,
    profile: ChannelProfile,
    tls: ?*tls_runtime.Runtime,
) Resident.InitError!Resident {
    var config = initial;
    errdefer config.release();
    const carrier = if (tls) |owner|
        try carrier_runtime.Lease.initSecure(allocator, io, owner)
    else
        try carrier_runtime.Lease.init(allocator, io);
    return .{ .allocator = allocator, .config = config, .carrier = carrier, .profile = profile };
}

/// Select the relay for one provider dial. A keyed-relay locator's designator
/// remains the target identity; this hint only tells the provider which relay
/// to ask for that identity. The deployment URL remains the default so
/// existing locators retain shared-relay behavior.
fn relayForDial(self: *const Resident, locator: model.PeerLocator) error{InvalidAddress}!RelayUrl {
    model.validatePeerLocator(locator) catch return error.InvalidAddress;
    return (route.relayHint(locator.hints) catch return error.InvalidAddress) orelse self.config.view().relay_url;
}

/// One raw registered relay listener. Registration and replacement work is
/// background-owned; these methods only observe its wake descriptor or claim a
/// stream that is already acceptable.
pub const RawListener = struct {
    box: *listener_state.Box,

    pub fn waitEstablished(self: RawListener, timeout_ms: i32) netlayer.AcceptError!bool {
        return listener_state.wait(self.box, timeout_ms, .established);
    }

    pub fn waitAcceptable(self: RawListener, timeout_ms: i32) netlayer.AcceptError!bool {
        return listener_state.wait(self.box, timeout_ms, .acceptable);
    }

    pub fn readinessFd(self: RawListener) i32 {
        return listener_state.readinessFd(self.box);
    }

    pub fn takeFailure(self: RawListener) ?foundation.FailureChain {
        return listener_state.claimFailure(self.box);
    }

    pub fn localLocator(self: RawListener, allocator: std.mem.Allocator) netlayer.ListenError!model.PeerLocator {
        return listener_state.localLocator(self.box, allocator);
    }

    pub fn canonicalizeLocator(self: RawListener, allocator: std.mem.Allocator, locator: model.PeerLocator) netlayer.ListenError!model.PeerLocator {
        return listener_state.canonicalizeLocator(self.box, allocator, locator);
    }

    pub fn accept(self: RawListener, allocator: std.mem.Allocator) netlayer.AcceptError!RawConnection {
        return .{ .stream = try listener_state.accept(self.box, allocator) };
    }

    pub fn close(self: RawListener) ?netlayer.ListenerCloseFailure {
        return listener_state.close(self.box);
    }
};

const keyed_resident_vtable: Netlayer.VTable = residentVtable(.keyed);
const noise_resident_vtable: Netlayer.VTable = residentVtable(.noise);

fn residentVtable(comptime profile: ChannelProfile) Netlayer.VTable {
    return .{
        .profile = profile.known().metadata(),
        .dial = .{ .blocking = residentDial },
        .listen = residentListen,
        .io = residentIo,
    };
}

fn residentOf(ctx: *anyopaque) *Resident {
    return @ptrCast(@alignCast(ctx));
}

fn residentIo(ctx: *anyopaque) ?std.Io {
    return residentOf(ctx).carrier.io();
}

fn residentDial(
    ctx: *anyopaque,
    peer: *engine.Peer,
    loc: model.PeerLocator,
    bufs: Buffers,
    options: netlayer.OperationOptions,
) netlayer.DialOutcome {
    options.requireInherited() catch |err| return .{ .failed = .init(err) };
    const self = residentOf(ctx);
    var raw = switch (self.dialRawOutcome(loc)) {
        .connected => |value| value,
        .failed => |failure| return .{ .failed = failure },
    };
    raw.stream = raw.stream.moveToAllocator(peer.allocator) catch |err| {
        var failure = netlayer.DialFailure.init(err);
        if (raw.close()) |cleanup| failure.chain.noteChain(cleanup);
        return .{ .failed = failure };
    };
    const conn = raw.stream.intoConnection(peer, bufs) catch |err| {
        var failure = netlayer.DialFailure.init(err);
        if (raw.close()) |cleanup| failure.chain.noteChain(cleanup);
        return .{ .failed = failure };
    };
    return .{ .connected = conn };
}

fn residentListen(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    config: netlayer.ListenConfig,
) netlayer.ListenStartOutcome {
    return .{ .admitted = residentListenFallible(ctx, allocator, config) catch |err|
        return .{ .failed = .init(err) } };
}

fn residentListenFallible(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    config: netlayer.ListenConfig,
) netlayer.ListenError!netlayer.ListenResult {
    try config.options.requireInherited();
    const self = residentOf(ctx);
    const raw = try self.listenRaw(allocator, config);
    return .{ .pending = .{
        .owner = self,
        .attempt = raw.box,
        .finish_fn = finishListen,
        .cancel_fn = cancelListen,
        .readiness_fd = raw.readinessFd(),
    } };
}

fn finishListen(
    owner: *anyopaque,
    attempt: *anyopaque,
    allocator: std.mem.Allocator,
) netlayer.ListenFinishOutcome {
    _ = allocator;
    const self: *Resident = @ptrCast(@alignCast(owner));
    const box: *listener_state.Box = @ptrCast(@alignCast(attempt));
    const ready = switch (listener_state.waitOutcome(box, 0, .established)) {
        .ready => |ready| ready,
        .failed => |failure| return failedFinishedListenFailure(attempt, failure.chain),
    };
    if (!ready) return failedFinishedListen(attempt, error.BindFailed);
    return .{ .ready = .{ .ctx = attempt, .vtable = switch (self.profile) {
        .keyed => &listener_state.keyed_vtable,
        .noise => &listener_state.noise_vtable,
    } } };
}

fn failedFinishedListen(attempt: *anyopaque, cause: anyerror) netlayer.ListenFinishOutcome {
    var failure = foundation.FailureChain.init(cause);
    if (listener_state.close(@ptrCast(@alignCast(attempt)))) |cleanup| failure.noteChain(cleanup);
    return .{ .failed = failure };
}

fn failedFinishedListenFailure(attempt: *anyopaque, primary: foundation.FailureChain) netlayer.ListenFinishOutcome {
    var failure = primary;
    if (listener_state.close(@ptrCast(@alignCast(attempt)))) |cleanup| failure.noteChain(cleanup);
    return .{ .failed = failure };
}

fn cancelListen(_: *anyopaque, attempt: *anyopaque) ?netlayer.ListenerCloseFailure {
    return listener_state.close(@ptrCast(@alignCast(attempt)));
}
