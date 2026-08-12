//! The owning host face (ADR-0090): a blocking, poll-multiplexed embedding of
//! the sans-io `driver_core.Host`, the native sibling of the byte-fed pump
//! every binding runs on its own event loop.
//!
//! `driver.HostRuntime` owns the composition — the core Host, one transport
//! wire per live session, and the pump — and `session.zig`'s owning
//! `Session`/`Server` are views over it. Every blocking wait runs one loop:
//! drain the core's action queue (write flushes, answer redeem dials, draw
//! gift-id entropy), wait for any live wire to become readable under the
//! caller's `Budget`, feed those outer-framed bytes through `Host.feedBytes`,
//! and repeat until the wait's capture fires. Because the wait spans every
//! live wire, a sibling session's inbound (a deposit arriving while this
//! session waits on a withdraw) is served inside the same wait, which is what
//! makes same-Host gifter and exporter roles work on one fiber with no thread.
//!
//! The wires are `net.Connection`s used through their byte-stream face only —
//! raw reads off `conn.r` into the core's outer framer, and
//! `takeOutbound` frames wrapped onto `conn.w`; the parse-into-peer
//! half (`pump`, the spill) stays the borrowing tier's vocabulary. Multiplexed
//! blocking waits need readiness. A stream netlayer supplies one descriptor
//! per connection, while a `MultiplexedResident` supplies one descriptor for
//! its runtime and routes drained readiness by stable connection id. A
//! transport that can do neither is refused at open
//! (`Error.TransportNotPollable`).

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");
const net = @import("net");
const driver_core = @import("driver_core");

pub const default_wire_buffer_bytes: usize = 16 << 10;
pub const default_max_pending_opens: usize = 256;
const settle_mailbox = @import("settle_mailbox.zig");

const crypto = foundation.crypto;

const Budget = driver_core.Budget;
const Error = driver_core.Error;
const Identity = driver_core.Identity;

/// The owning face over one `driver_core.Host`: the core, the netlayer slice
/// it dials through, and one wire per live session. One thread drives one
/// `HostRuntime` and its core `Host`; every blocking verb on a view pumps through
/// here.
pub const HostRuntime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// The sans-io host, behind one stable pointer. `init` allocates it and
    /// `deinit` frees it, so this face stays the owner; the pointer shape is
    /// what lets an embedding owner hold the core elsewhere (ADR-0112).
    core: *driver_core.Host,
    /// One provider registry for dial and listen dispatch. Entries carry the
    /// Host-owned canonical symbol and point at either a stream vtable copy or
    /// a multiplexed-resident index. Concrete provider contexts remain borrowed
    /// and must outlive the HostRuntime; selection itself has no second authority.
    providers: std.ArrayListUnmanaged(Provider) = .empty,
    opts: Options,
    wires: std.AutoHashMapUnmanaged(engine.PeerId, *Wire) = .{},
    /// The multiplexed runtimes this host dials and accepts through (ADR-0112),
    /// beside the stream netlayers above. Each runtime handle is borrowed and
    /// its `ctx` and vtable must outlive registration.
    residents: std.ArrayListUnmanaged(RegisteredResident) = .empty,
    /// Active profile listeners routed by the multiplexed runtime's accept-event
    /// subject. The runtime owns readiness; each row owns one profile's
    /// listener handle and observation independently.
    resident_listeners: std.AutoHashMapUnmanaged(ResidentListenerKey, ResidentListener) = .empty,
    /// Live resident connections routed by drained ready records.
    resident_wires: std.AutoHashMapUnmanaged(ResidentConnKey, *Wire) = .empty,
    /// Resident dials awaiting `ev_connect`, keyed by runtime and its
    /// host-minted request id.
    pending_resident_dials: std.AutoHashMapUnmanaged(ResidentRequestKey, *ResidentDialWait) = .{},
    /// Scratch a resident's ready records drain into; batch-sized, so a drain
    /// pass allocates nothing.
    event_scratch: [resident_event_batch]net.multiplexed_resident.ReadyEvent = undefined,
    /// Scratch for the multi-wire readiness wait, sized to the live wires; the
    /// wait itself allocates nothing.
    poll_scratch: std.ArrayListUnmanaged(std.posix.pollfd) = .empty,
    conn_scratch: std.ArrayListUnmanaged(*Wire) = .empty,
    /// Staged stream dials mirrored into each wait. Pending rows are
    /// heap-pinned, so these pointers survive list growth and callbacks that
    /// stage another open.
    connect_scratch: std.ArrayListUnmanaged(*PendingOpen) = .empty,
    borrow_scratch: std.ArrayListUnmanaged(*net.Connection) = .empty,
    /// The trailing poll rows: resident readiness descriptors, then the
    /// mailbox wake.
    extra_fd_scratch: std.ArrayListUnmanaged(std.posix.fd_t) = .empty,
    /// Listener descriptors registered through `activateListener`. Kept even
    /// before the aggregate ready set is armed so readiness construction and
    /// later listener activation have one lifecycle path.
    listener_fds: std.ArrayListUnmanaged(i32) = .empty,
    /// The off-turn settle mailbox (ADR-0102 stage 4), minted on first
    /// request; its wake fd rides every readiness wait beside the wires.
    mailbox: ?*settle_mailbox.SettleMailbox = null,
    /// Where the next readiness scan starts. `net.waitAnyReadable` reports the
    /// *first* ready wire, so a fixed order lets one always-readable partner
    /// starve every sibling — unbounded on `serve`/`step`, which carry no
    /// budget at all, and a misattributed `WaitTimedOut` on the budgeted
    /// waits (the timeout would name the innocent caller, not the flooder).
    /// Rotating one position per wait bounds a live wire's turn by the
    /// live-wire count instead of by a partner's send rate.
    wait_cursor: usize = 0,
    /// Outstanding accepted views (`Server.accept` mints one, a non-owning
    /// `Session.deinit` retires one). `Server.close` asserts it is zero in
    /// safe builds: a view outliving its server's host is a dangle, and the
    /// wire count cannot stand in — redeem-dialed sessions have no view.
    accepted_views: usize = 0,
    /// One vow whose synchronously settled completion the next action drain
    /// hands back instead of dropping: the select-or-dial enliven's
    /// cache-hit arm settles inside the verb, before any listener can
    /// register. Every other wait on this face registers first, so this is
    /// the only claimer.
    awaited_completion: ?u64 = null,
    claimed_completion: ?driver_core.HostAction = null,
    /// The aggregate readiness set (ADR-0112), armed by
    /// `readinessDescriptor`. While armed, every stream wire fd, resident
    /// readiness fd, mailbox wake fd, and watched extra fd is mirrored into
    /// it, so an embedder parks on one descriptor instead of re-tracking the
    /// set per language.
    ready_set: ?net.ReadySet = null,
    /// Where an application-visible completion (`settled` / `failed`) with no
    /// in-process claimer goes instead of being freed (ADR-0112): the loop
    /// archive queues it for its C event queue. Null on the native face,
    /// whose waits observe vows in-process through captures.
    completion_sink: ?CompletionSink = null,
    /// Told when a wire closes inside the pump (EOF, fault, or dispatch
    /// refusal), so a step-driven embedder learns of the closure without
    /// polling every session. The close-and-release split stands: the wire
    /// stays owned until `releaseWire`. A session still staged in
    /// `pending_opens` reports through the dial path instead — the
    /// embedder has never seen it, so a close event would name a stranger.
    close_observer: ?CloseObserver = null,
    /// Session opens advancing across pump iterations instead of blocking one
    /// (ADR-0112): embedder dials, redeem dials, and accepts share the same
    /// handshake lifecycle. Heap rows stay stable when an outcome callback
    /// stages another open during the sweep. Admission lives separately
    /// because blocking opens consume the same bound without owning a row.
    pending_opens: std.ArrayListUnmanaged(*PendingOpen) = .empty,
    /// One authority for every transport connect and CapTP handshake not yet
    /// open, including synchronous constructors that pump pending actions.
    open_admissions: usize = 0,
    /// Whether `deinit` tears the core down. False for a host adopted over an
    /// embedding owner's core (`initWithCore`), whose owner frees it.
    owns_core: bool = true,
    /// Nesting of native-face calls on the current driver thread. The outer
    /// call owns the unsynchronized core for its whole operation; returning
    /// from it is the explicit quiescent boundary where another joined thread
    /// may take over. Compiled out with the debug thread-affinity checks.
    driver_depth: if (std.debug.runtime_safety) usize else void = if (std.debug.runtime_safety) 0 else {},

    /// Options for the owning face and its `connect`/`listen` views.
    /// `frame_cap` is protocol admission; `wire_buffer_bytes` is steady-state
    /// transport staging. A frame larger than the read buffer assembles once
    /// in bounded spill, and a larger write streams through, so admission does
    /// not force every live wire to retain maximum-frame storage. `codec` is
    /// the wire grammar the negotiating peer encodes in. There is deliberately
    /// no `verify_partner` knob: the application tier always verifies.
    ///
    /// The two wait budgets are `driver.Budget` and have no default: every
    /// other option has a wrong value that costs memory or speed, but a wait
    /// budget has a wrong value that costs the process, so the question is
    /// asked where it cannot be skipped. A caller that genuinely means
    /// forever — an in-process pair, a harness driving both ends — spells
    /// `.unbounded`.
    pub const Options = struct {
        frame_cap: usize = 1 << 16,
        /// Bytes retained for each stream read and write buffer, and for an
        /// multiplexed resident's read staging. Independent of `frame_cap`.
        wire_buffer_bytes: usize = default_wire_buffer_bytes,
        /// Maximum transport connects and CapTP handshakes admitted at once.
        /// This bounds pre-open session and wire memory across dial, accept,
        /// external adoption, and redeem through one shared authority.
        max_pending_opens: usize = default_max_pending_opens,
        codec: model.CodecId = model.Preference.baseline.codec,
        /// The CapTP profile this host offers in `op:start-session`, beside
        /// the codec above. The two fields name one offered profile, and a
        /// host normally sets them together, but they are negotiated as
        /// independent axes: `engine.negotiation` settles the version and the
        /// codec separately, so a partner can follow this host on one axis and
        /// not the other (ADR-0003). Both default to
        /// `model.Preference.baseline`, the profile every conforming peer
        /// speaks. A pancake-to-pancake fleet sets `.next` here and `.capnp`
        /// above; a partner that cannot follow settles each axis back to the
        /// baseline on its own session (ADR-0103).
        captp_version: model.CaptpVersion = model.Preference.baseline.captp_version,
        /// Per-read deadline for the keyed handshake, and for each redeem
        /// dial's handshake inside a wait. Breaks with
        /// `Error.HandshakeTimedOut` when a partner connects then goes
        /// silent (ADR-0081).
        handshake: Budget,
        /// Wall-clock deadline for blocking answer-waits after the session
        /// is open (`settle` / `call` / `fetch`).
        settle: Budget,
    };

    /// One session's transport binding — a per-descriptor byte stream or an
    /// multiplexed-resident connection — and the core shell it feeds. Owned by
    /// the host map; freed by `releaseWire` (or `deinit`).
    pub const Wire = struct {
        link: Link,
        session: *driver_core.HostSession,
        /// The transport reported closure (EOF or fault); the wire stays in
        /// the map until `releaseWire` so a view holding it can observe the
        /// close instead of dangling.
        closed: bool = false,

        pub const Link = union(enum) {
            stream: StreamLink,
            resident: ResidentLink,
        };

        /// A stream transport's binding: the connection and the buffers
        /// behind its reader and writer.
        pub const StreamLink = struct {
            conn: net.Connection,
            read_buf: []u8,
            write_buf: []u8,
        };

        /// A multiplexed-resident connection (ADR-0112): the resident's index
        /// in the host table, the resident-minted connection id, one read
        /// staging buffer, and the outbound frame a full write window left
        /// behind. The retained frame is owned transfer, not a copy: the
        /// core's `takeOutbound` handed it over, and an `ev_writable` record
        /// resumes it from `offset`.
        pub const ResidentLink = struct {
            index: usize,
            conn: usize,
            read_buf: []u8,
            pending: ?PendingOut = null,

            pub const PendingOut = struct {
                frame: foundation.Frame,
                prefix: [foundation.stream_framing.prefix_buffer_bytes]u8,
                prefix_len: usize,
                offset: usize,
            };
        };
    };

    /// One host-minted resident dial in flight: the awaiting frame's flag,
    /// set when the resident's `ev_connect` record for its request id drains.
    const ResidentDialWait = struct { ready: bool = false };

    /// A connect request is minted and echoed within one multiplexed runtime.
    /// The owner dimension prevents equal provider-local ids from colliding.
    const ResidentRequestKey = struct { resident: usize, request: usize };

    /// One resident connection's routing key. A composite on purpose: conn
    /// ids are each resident's own namespace, so the resident index is the
    /// owner dimension that keeps two residents' equal ids apart.
    const ResidentConnKey = struct { resident: usize, conn: usize };

    const Provider = struct {
        transport: []const u8,
        designator_scheme: net.netlayer.DesignatorScheme,
        source: Source,

        const Source = union(enum) {
            stream: net.netlayer.Netlayer,
            resident: usize,
        };
    };

    /// One multiplexed runtime, stored once no matter how many profiles it
    /// realizes. Registration validates and caches the readiness descriptor;
    /// profile listener state is keyed separately by this runtime's index and
    /// the driver-minted accept route id.
    const RegisteredResident = struct {
        resident: net.MultiplexedResident,
        readiness_fd: i32,
        next_request: usize = 1,
        next_listener_route: usize = 1,
    };

    const ResidentListenerKey = struct { resident: usize, route: usize };

    const ResidentListener = struct {
        listener: net.MultiplexedResident.Listener,
        transport: []const u8,
        observation: SessionOpenObservation,
    };

    /// One bound listener, independent of the provider's execution model.
    /// The caller owns this value and closes it through `closeListener` before
    /// the HostRuntime. `tag` is set only after the caller has reserved its own
    /// listener row, making activation the publication boundary.
    pub const TransportListener = struct {
        transport: []const u8,
        designator_scheme: net.netlayer.DesignatorScheme,
        source: Source,

        const Source = union(enum) {
            stream: StreamListener,
            resident: ResidentSource,
        };

        const StreamListener = struct {
            handle: net.netlayer.Listener,
            observation: ?SessionOpenObservation = null,
        };

        const ResidentSource = struct {
            runtime: usize,
            listener: net.MultiplexedResident.Listener,
        };

        pub fn transportName(self: *const TransportListener) []const u8 {
            return self.transport;
        }

        pub fn designatorScheme(self: *const TransportListener) net.netlayer.DesignatorScheme {
            return self.designator_scheme;
        }
    };

    pub const MultiplexedRegistration = struct {
        profile: model.transport.Metadata,
        resident: net.MultiplexedResident,
    };

    pub const ProviderRegistration = union(enum) {
        stream: net.netlayer.Netlayer,
        multiplexed: MultiplexedRegistration,

        fn profile(self: ProviderRegistration) model.transport.Metadata {
            return switch (self) {
                .stream => |value| value.transportProfile(),
                .multiplexed => |value| value.profile,
            };
        }
    };

    /// How many ready records one drain pass claims before looping.
    const resident_event_batch = 32;

    /// Where a readiness wait's report came from: a stream wire's own
    /// descriptor, or one multiplexed resident's descriptor (whose drained
    /// records the caller services).
    const ReadySource = union(enum) {
        wire: *Wire,
        resident: usize,
        stream_connect: *PendingOpen,
    };

    /// A taker for application-visible completions the native face would
    /// otherwise free (ADR-0112). `take` returns true when it took ownership
    /// of the action — payload and all, freed later through
    /// `Host.freeAction` — and false to leave the free to the drain. Called
    /// on the driving thread, inside the action drain; it must not re-enter
    /// the host.
    pub const CompletionSink = struct {
        ctx: *anyopaque,
        take: *const fn (ctx: *anyopaque, action: driver_core.HostAction) bool,
    };

    /// Told once per wire, on the driving thread, at the moment the pump
    /// marks it closed. The session pointer stays valid: closing breaks vows
    /// but frees nothing until `releaseWire`.
    pub const CloseObserver = struct {
        ctx: *anyopaque,
        closed: *const fn (ctx: *anyopaque, session: *driver_core.HostSession) void,
    };

    /// A staged session-open outcome seam (ADR-0112). Before committing an
    /// open, the host calls `reserve`; a synchronous refusal calls `release`,
    /// while successful admission transfers that reservation to exactly one
    /// `opened` or `failed` callback. The default admission callbacks are
    /// no-ops for in-process observers; queue-backed embeddings override them
    /// so outcome publication cannot allocate after commitment.
    ///
    /// `opened` hands the caller its now-open session; `failed` reports the
    /// refusal after the session was already unwound. Callbacks run on the
    /// driving thread, inside the pump, and must not re-enter the host. The
    /// context and functions must outlive the operation or active listener
    /// that retains them.
    pub const SessionOpenObserver = struct {
        ctx: *anyopaque,
        reserve: *const fn (ctx: *anyopaque, tag: u64) anyerror!void = reserveNoop,
        release: *const fn (ctx: *anyopaque, tag: u64) void = releaseNoop,
        opened: *const fn (ctx: *anyopaque, tag: u64, session: *driver_core.HostSession) void,
        failed: *const fn (ctx: *anyopaque, tag: u64, err: anyerror) void,

        fn reserveNoop(_: *anyopaque, _: u64) anyerror!void {}
        fn releaseNoop(_: *anyopaque, _: u64) void {}
    };

    /// Which Host half an externally established channel supplies. This is a
    /// driver concern, not a transport concern: signaling owners may hand the
    /// driver either an outbound or an inbound WebRTC channel, while the
    /// provider exposes only one claim operation.
    pub const ExternalAdoptionRole = enum { dialed, accepted };

    const SessionOpenObservation = struct {
        observer: SessionOpenObserver,
        tag: u64,
    };

    const OpenAdmission = struct {
        runtime: *HostRuntime,

        fn release(self: *OpenAdmission) void {
            std.debug.assert(self.runtime.open_admissions != 0);
            self.runtime.open_admissions -= 1;
            self.* = undefined;
        }
    };

    /// One staged session open (ADR-0112): the minted session, where its
    /// transport connect or handshake stands, its deadline, and the owner of
    /// the outcome.
    const PendingOpen = struct {
        admission: OpenAdmission,
        session: *driver_core.HostSession,
        stage: Stage,
        deadline_ms: ?i64,
        outcome: Outcome,

        const Stage = union(enum) {
            /// Per-stream connect in flight, awaiting its own readiness fd.
            stream_connect: net.netlayer.ConnectAttempt,
            /// Resident connect in flight, awaiting its `ev_connect` record.
            resident_connect: struct {
                resident: usize,
                attempt: net.multiplexed_resident.ConnectAttempt,
            },
            /// Wire bound; the CapTP handshake advancing through the pump.
            handshake,
        };
        const Outcome = union(enum) {
            /// An embedder-staged dial: report through the dial observer,
            /// carrying this tag.
            dial: SessionOpenObservation,
            /// A redeem dial answering a core `dial` action: report through
            /// `exporterDialed` / `dialFailed`.
            redeem: engine.Node.PendingId,
            /// A staged accept: report through the accept observer,
            /// carrying the caller's listener tag.
            accept: SessionOpenObservation,
        };
    };

    /// A host bound to `identity`: `.keyed` reuses the caller's seed (one
    /// durable identity across hosts), `.ephemeral` draws a fresh one at the
    /// I/O boundary. `io` is the host `std.Io` entropy and the poll clock ride.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        netlayers: []const net.netlayer.Netlayer,
        identity: Identity,
        opts: Options,
    ) (std.mem.Allocator.Error || Error)!HostRuntime {
        if (opts.frame_cap == 0 or opts.wire_buffer_bytes == 0 or opts.max_pending_opens == 0)
            return Error.InvalidBufferConfiguration;
        const seed: [foundation.crypto.SEED_BYTES]u8 = switch (identity) {
            .keyed => |k| k.secret.seed(),
            .ephemeral => blk: {
                var s: [foundation.crypto.SEED_BYTES]u8 = undefined;
                io.randomSecure(&s) catch return Error.HandshakeEntropyFailed;
                break :blk s;
            },
        };
        // Every session on this host signs with its own key (ADR-0097). The
        // root is drawn here, at the driver's entropy boundary, because the
        // sans-io core draws none; it is fresh per process, so a restarted
        // host cannot recreate a prior session's handoff names.
        var session_root: [foundation.crypto.SEED_BYTES]u8 = undefined;
        io.randomSecure(&session_root) catch return Error.HandshakeEntropyFailed;
        const core = try allocator.create(driver_core.Host);
        core.* = driver_core.Host.init(allocator, seed, session_root, .{
            .codec = opts.codec,
            .captp_version = opts.captp_version,
        });
        var runtime = HostRuntime{
            .allocator = allocator,
            .io = io,
            .core = core,
            .opts = opts,
        };
        errdefer runtime.deinit();
        try runtime.registerNetlayers(netlayers);
        runtime.core.setSessionLimits(opts.frame_cap, null, null);
        return runtime;
    }

    /// A host face over a core an embedding owner already built and seeded
    /// (ADR-0112): the driver archive's `Instance` embeds the core and this
    /// face polls, pumps, and dials for it. The owner keeps identity,
    /// limits, and teardown; `deinit` here frees the wires and scratch but
    /// never the core.
    pub fn initWithCore(
        allocator: std.mem.Allocator,
        io: std.Io,
        core: *driver_core.Host,
        netlayers: []const net.netlayer.Netlayer,
        opts: Options,
    ) (std.mem.Allocator.Error || Error)!HostRuntime {
        if (opts.frame_cap == 0 or opts.wire_buffer_bytes == 0 or opts.max_pending_opens == 0)
            return Error.InvalidBufferConfiguration;
        var runtime = HostRuntime{
            .allocator = allocator,
            .io = io,
            .core = core,
            .opts = opts,
            .owns_core = false,
        };
        errdefer runtime.deinit();
        try runtime.registerNetlayers(netlayers);
        return runtime;
    }

    fn registerNetlayers(self: *HostRuntime, netlayers: []const net.netlayer.Netlayer) !void {
        if (netlayers.len == 0) return;
        const registrations = try self.allocator.alloc(ProviderRegistration, netlayers.len);
        defer self.allocator.free(registrations);
        const resident_indices = try self.allocator.alloc(?usize, netlayers.len);
        defer self.allocator.free(resident_indices);
        for (netlayers, registrations) |netlayer, *registration| {
            registration.* = .{ .stream = netlayer };
        }
        self.addProviders(registrations, resident_indices) catch |err| switch (err) {
            // A fresh HostRuntime has no armed readiness set, and the non-empty
            // netlayer slice satisfies the package shape by construction.
            error.InvalidProviderPackage,
            error.ReadinessDescriptorConflict,
            error.ReadinessUnavailable,
            => unreachable,
            else => |e| return e,
        };
    }

    /// Register one listener-capable stream provider. The vtable is copied;
    /// its context remains borrowed for the HostRuntime lifetime.
    pub fn addNetlayer(self: *HostRuntime, nl: net.netlayer.Netlayer) !void {
        var index: [1]?usize = undefined;
        try self.addProviders(&.{.{ .stream = nl }}, &index);
    }

    /// Initialize `out` with one stream provider. Kept as the construction
    /// spelling used by `Server`; provider dispatch itself is the same registry
    /// entry used by `init` and `addNetlayer`.
    pub fn initWithOwnNetlayer(
        out: *HostRuntime,
        allocator: std.mem.Allocator,
        io: std.Io,
        nl: net.netlayer.Netlayer,
        identity: Identity,
        opts: Options,
    ) !void {
        out.* = try init(allocator, io, &.{}, identity, opts);
        errdefer out.deinit();
        try out.addNetlayer(nl);
    }

    /// Adopt one profile realized by a multiplexed runtime (ADR-0112). Several
    /// calls may name the same resident with different profiles; it is stored
    /// once and all entries share its readiness and connection namespace.
    pub fn addResident(
        self: *HostRuntime,
        profile: model.transport.Metadata,
        resident: net.MultiplexedResident,
    ) !usize {
        var index: [1]?usize = undefined;
        try self.addProviders(&.{.{ .multiplexed = .{
            .profile = profile,
            .resident = resident,
        } }}, &index);
        return index[0].?;
    }

    /// Install a provider package as one transaction. Validation, collection
    /// capacity, and readiness membership complete before Host semantics are
    /// committed. Provider occupancy and caller outputs then publish through
    /// infallible operations, so failure changes no transport authority.
    pub fn addProviders(self: *HostRuntime, registrations: []const ProviderRegistration, resident_indices: []?usize) !void {
        if (registrations.len == 0 or resident_indices.len != registrations.len) return error.InvalidProviderPackage;
        const PreparedRegistration = struct {
            profile: model.transport.Metadata,
            source: Source,

            const Source = union(enum) {
                stream,
                resident: usize,
                new_resident: struct { index: usize, readiness_fd: i32 },
            };

            fn residentIndex(plan: @This()) ?usize {
                return switch (plan.source) {
                    .stream => null,
                    .resident => |index| index,
                    .new_resident => |value| value.index,
                };
            }
        };
        const prepared = try self.allocator.alloc(PreparedRegistration, registrations.len);
        defer self.allocator.free(prepared);
        const profiles = try self.allocator.alloc(model.transport.Metadata, registrations.len);
        defer self.allocator.free(profiles);
        var new_resident_count: usize = 0;
        for (registrations, prepared, 0..) |registration, *plan, i| {
            const profile = registration.profile();
            if (self.hasTransport(profile.symbol)) return error.TransportAlreadyRegistered;
            for (prepared[0..i]) |prior| {
                if (std.mem.eql(u8, prior.profile.symbol, profile.symbol)) return error.TransportAlreadyRegistered;
            }
            switch (registration) {
                .stream => plan.* = .{ .profile = profile, .source = .stream },
                .multiplexed => |multiplexed| {
                    var index: ?usize = null;
                    for (self.residents.items, 0..) |existing, existing_index| {
                        if (existing.resident.eql(multiplexed.resident)) {
                            index = existing_index;
                            break;
                        }
                    }
                    if (index == null) for (registrations[0..i], 0..) |prior, prior_index| switch (prior) {
                        .stream => {},
                        .multiplexed => |prior_multiplexed| if (prior_multiplexed.resident.eql(multiplexed.resident)) {
                            index = prepared[prior_index].residentIndex().?;
                            break;
                        },
                    };
                    if (index) |existing_index| {
                        plan.* = .{ .profile = profile, .source = .{ .resident = existing_index } };
                        continue;
                    }

                    const readiness_fd = multiplexed.resident.readinessFd();
                    if (readiness_fd < 0) return error.ReadinessUnavailable;
                    if (self.descriptorInUse(readiness_fd)) return error.ReadinessDescriptorConflict;
                    for (prepared[0..i]) |prior| switch (prior.source) {
                        .new_resident => |value| if (value.readiness_fd == readiness_fd)
                            return error.ReadinessDescriptorConflict,
                        else => {},
                    };
                    const new_index = self.residents.items.len + new_resident_count;
                    new_resident_count += 1;
                    plan.* = .{
                        .profile = profile,
                        .source = .{ .new_resident = .{
                            .index = new_index,
                            .readiness_fd = readiness_fd,
                        } },
                    };
                },
            }
        }
        for (prepared, profiles) |plan, *profile| profile.* = plan.profile;

        const canonical = try self.allocator.alloc([]const u8, registrations.len);
        defer self.allocator.free(canonical);
        const readiness_fds = try self.allocator.alloc(i32, new_resident_count);
        defer self.allocator.free(readiness_fds);
        try self.providers.ensureUnusedCapacity(self.allocator, registrations.len);
        try self.residents.ensureUnusedCapacity(self.allocator, new_resident_count);

        var readiness_added: usize = 0;
        errdefer if (self.ready_set) |*rs| {
            for (readiness_fds[0..readiness_added]) |fd| rs.remove(fd);
        };
        if (self.ready_set) |*rs| for (prepared) |plan| {
            const fd = switch (plan.source) {
                .new_resident => |value| value.readiness_fd,
                else => continue,
            };
            try rs.add(fd);
            readiness_fds[readiness_added] = fd;
            readiness_added += 1;
        };

        try self.core.defineTransports(profiles, canonical);
        for (registrations, prepared, canonical, resident_indices) |registration, plan, transport, *out_index| switch (registration) {
            .stream => |stream| {
                self.providers.appendAssumeCapacity(.{
                    .transport = transport,
                    .designator_scheme = stream.designatorScheme(),
                    .source = .{ .stream = stream },
                });
                out_index.* = null;
            },
            .multiplexed => |multiplexed| {
                const index = plan.residentIndex().?;
                switch (plan.source) {
                    .new_resident => |value| {
                        std.debug.assert(value.index == self.residents.items.len);
                        self.residents.appendAssumeCapacity(.{
                            .resident = multiplexed.resident,
                            .readiness_fd = value.readiness_fd,
                        });
                    },
                    .resident => {},
                    .stream => unreachable,
                }
                self.providers.appendAssumeCapacity(.{
                    .transport = transport,
                    .designator_scheme = multiplexed.profile.designator_scheme,
                    .source = .{ .resident = index },
                });
                out_index.* = index;
            },
        };
    }

    /// Resolve and bind one listener through the provider registry. Provider
    /// selection, readiness, and multiplexed start-up belong here; callers see one
    /// value regardless of stream or multiplexed execution.
    pub fn bindListener(self: *HostRuntime, transport: []const u8, requested_designator: []const u8) !TransportListener {
        const provider = self.providerFor(transport) orelse return Error.UnknownTransport;
        return switch (provider.source) {
            .stream => |nl| blk: {
                if (!nl.supportsListen()) return Error.UnknownTransport;
                var listener = try nl.listen(self.allocator, .{
                    .designator = requested_designator,
                    .identity = self.core.node.publicKey(),
                });
                errdefer listener.close();
                const timeout: i32 = switch (self.opts.handshake) {
                    .unbounded => std.math.maxInt(i32),
                    .ms => |milliseconds| @intCast(@min(@max(milliseconds, 0), std.math.maxInt(i32))),
                };
                if (!try listener.waitReady(timeout)) return Error.HandshakeTimedOut;
                break :blk .{
                    .transport = provider.transport,
                    .designator_scheme = nl.designatorScheme(),
                    .source = .{ .stream = .{ .handle = listener } },
                };
            },
            .resident => |index| blk: {
                const runtime = &self.residents.items[index];
                const acceptor = runtime.resident.acceptor() orelse return Error.UnknownTransport;
                const route_id = try mintRuntimeId(&runtime.next_listener_route);
                const host_designator = self.core.node.publicKey().toDesignator();
                const effective_designator: []const u8 = if (requested_designator.len == 0 and
                    provider.designator_scheme == .key)
                    &host_designator
                else
                    requested_designator;
                const multiplexed_listener = try acceptor.startListen(
                    route_id,
                    provider.transport,
                    effective_designator,
                );
                break :blk .{
                    .transport = provider.transport,
                    .designator_scheme = provider.designator_scheme,
                    .source = .{ .resident = .{ .runtime = index, .listener = multiplexed_listener } },
                };
            },
        };
    }

    /// Materialize the complete locator an active listener publishes. The
    /// provider owns transport-specific hints; the driver validates the
    /// dispatch symbol and takes ownership of the returned model value.
    pub fn listenerLocator(self: *const HostRuntime, listener: *const TransportListener) !model.PeerLocator {
        const locator = switch (listener.source) {
            .stream => |stream| try stream.handle.localLocator(self.allocator),
            .resident => |resident| try resident.listener.listenerLocator(self.allocator),
        };
        errdefer model.freePeerLocator(self.allocator, locator);
        if (!std.mem.eql(u8, locator.transport, listener.transportName()) or locator.designator.len == 0)
            return error.ProviderContract;
        return locator;
    }

    /// Validate and canonicalize a replacement locator through the provider
    /// that owns this active listener. The caller owns the returned value.
    pub fn canonicalizeListenerLocator(
        self: *const HostRuntime,
        listener: *const TransportListener,
        locator: model.PeerLocator,
    ) !model.PeerLocator {
        const canonical = switch (listener.source) {
            .stream => |stream| try stream.handle.canonicalizeLocator(self.allocator, locator),
            .resident => |resident| try resident.listener.listenerAdvertise(self.allocator, locator),
        };
        errdefer model.freePeerLocator(self.allocator, canonical);
        if (!std.mem.eql(u8, canonical.transport, listener.transportName()) or canonical.designator.len == 0)
            return error.ProviderContract;
        return canonical;
    }

    /// Publish the caller's listener observation after all fallible
    /// caller-owned state has been reserved. From here every admitted accept
    /// retains the exact callback that owns its outcome.
    pub fn activateListener(
        self: *HostRuntime,
        listener: *TransportListener,
        tag: u64,
        observer: SessionOpenObserver,
    ) !void {
        const observation = SessionOpenObservation{ .observer = observer, .tag = tag };
        switch (listener.source) {
            .stream => |*stream| {
                std.debug.assert(stream.observation == null);
                if (stream.handle.readinessFd()) |fd| try self.watchFd(fd);
                stream.observation = observation;
            },
            .resident => |index| {
                const key = ResidentListenerKey{
                    .resident = index.runtime,
                    .route = index.listener.route_id,
                };
                if (self.resident_listeners.contains(key)) return error.ListenerAlreadyActive;
                try self.resident_listeners.ensureUnusedCapacity(self.allocator, 1);
                self.resident_listeners.putAssumeCapacity(key, .{
                    .listener = index.listener,
                    .transport = listener.transport,
                    .observation = observation,
                });
            },
        }
    }

    /// Stage every stream accept currently ready. Multiplexed accepts are drained
    /// by `serviceResident` and therefore require no caller-side branch.
    pub fn acceptReady(self: *HostRuntime, listener: *TransportListener) !usize {
        const stream = switch (listener.source) {
            .stream => |value| value,
            .resident => return 0,
        };
        const observation = stream.observation orelse return error.ListenerNotActive;
        if (!self.pendingOpenSlotAvailable()) return 0;
        if (!try stream.handle.waitAcceptable(0)) return 0;
        try self.startAcceptWire(stream.handle, listener.transport, observation.tag, observation.observer);
        return 1;
    }

    pub fn closeListener(self: *HostRuntime, listener: *TransportListener) void {
        switch (listener.source) {
            .stream => |stream| {
                if (stream.observation) |observation| self.cancelAccepts(observation.tag);
                if (stream.handle.readinessFd()) |fd| self.unwatchFd(fd);
                stream.handle.close();
            },
            .resident => |resident| {
                const key = ResidentListenerKey{
                    .resident = resident.runtime,
                    .route = resident.listener.route_id,
                };
                if (self.resident_listeners.fetchRemove(key)) |removed| {
                    std.debug.assert(std.mem.eql(u8, removed.value.transport, listener.transport));
                    self.cancelAccepts(removed.value.observation.tag);
                }
                resident.listener.stopListen();
            },
        }
    }

    /// Arm the aggregate readiness set (ADR-0112) and return its one
    /// pollable descriptor. Idempotent. From arming on, every stream wire
    /// fd, resident readiness fd, and mailbox wake fd is mirrored into the
    /// set as it comes and goes, so an embedder parks on this descriptor and
    /// calls `stepAny` when it reads ready. The descriptor is owned by this
    /// host and dies with it.
    pub fn readinessDescriptor(self: *HostRuntime) !i32 {
        if (self.ready_set) |*rs| return rs.descriptor();
        var rs = try net.ReadySet.init();
        errdefer rs.deinit();
        var it = self.wires.valueIterator();
        while (it.next()) |wire| {
            if (wire.*.closed) continue;
            switch (wire.*.link) {
                .stream => |*sl| if (sl.conn.socketHandle()) |fd| try rs.add(fd),
                .resident => {},
            }
        }
        for (self.residents.items) |runtime| try rs.add(runtime.readiness_fd);
        for (self.listener_fds.items) |fd| try rs.add(fd);
        for (self.pending_opens.items) |row| switch (row.stage) {
            .stream_connect => |attempt| try rs.add(attempt.readinessFd()),
            .resident_connect, .handshake => {},
        };
        if (self.mailbox) |mb| try rs.add(mb.wakeFd());
        self.ready_set = rs;
        return rs.descriptor();
    }

    /// Mirror an embedder-owned descriptor (a listener's accept fd) into the
    /// armed readiness set. No-op while the set is unarmed; the caller owns
    /// the fd and pairs this with `unwatchFd` before closing it.
    pub fn watchFd(self: *HostRuntime, fd: i32) !void {
        if (fd < 0) return error.ReadinessUnavailable;
        if (self.descriptorInUse(fd)) return error.ReadinessDescriptorConflict;
        try self.listener_fds.ensureUnusedCapacity(self.allocator, 1);
        if (self.ready_set) |*rs| try rs.add(fd);
        self.listener_fds.appendAssumeCapacity(fd);
    }

    pub fn unwatchFd(self: *HostRuntime, fd: i32) void {
        if (self.ready_set) |*rs| rs.remove(fd);
        for (self.listener_fds.items, 0..) |existing, i| {
            if (existing == fd) {
                const removed = self.listener_fds.swapRemove(i);
                std.debug.assert(removed == fd);
                return;
            }
        }
    }

    /// Whether `fd` already names a live readiness owner in this HostRuntime. Integer
    /// descriptor aliasing is never used as identity: duplicate rows make poll
    /// routing ambiguous, and removing either owner would silence the other.
    fn descriptorInUse(self: *const HostRuntime, fd: i32) bool {
        for (self.residents.items) |runtime| {
            if (runtime.readiness_fd == fd) return true;
        }
        for (self.listener_fds.items) |listener_fd| {
            if (listener_fd == fd) return true;
        }
        var wire_it = self.wires.valueIterator();
        while (wire_it.next()) |wire| switch (wire.*.link) {
            .stream => |*stream| if (stream.conn.socketHandle() == fd) return true,
            .resident => {},
        };
        for (self.pending_opens.items) |row| switch (row.stage) {
            .stream_connect => |attempt| if (attempt.readinessFd() == fd) return true,
            .resident_connect, .handshake => {},
        };
        if (self.mailbox) |mailbox| if (mailbox.wakeFd() == fd) return true;
        if (self.ready_set) |*ready_set| {
            if (ready_set.descriptor() == fd or ready_set.wakeFd() == fd) return true;
        }
        return false;
    }

    /// Make an armed readiness set readable from any thread, so a parked
    /// embedder returns and re-enters `stepAny`. The one HostRuntime verb with
    /// cross-thread permission, and only because it touches nothing but the
    /// wake channel.
    pub fn wakeReadiness(self: *const HostRuntime) void {
        if (self.ready_set) |*rs| rs.postWake();
    }

    /// Route application-visible completions (`settled` / `failed`) that no
    /// in-process wait claims to `sink` instead of freeing them (ADR-0112).
    pub fn setCompletionSink(self: *HostRuntime, sink: ?CompletionSink) void {
        self.completion_sink = sink;
    }

    /// Observe wires the pump closes (EOF, fault, dispatch refusal).
    pub fn setCloseObserver(self: *HostRuntime, observer: ?CloseObserver) void {
        self.close_observer = observer;
    }

    fn providerFor(self: *const HostRuntime, transport: []const u8) ?Provider {
        for (self.providers.items) |provider| {
            if (std.mem.eql(u8, provider.transport, transport)) return provider;
        }
        return null;
    }

    fn mintRuntimeId(next: *usize) !usize {
        const id = next.*;
        if (id == 0 or id == std.math.maxInt(usize)) return error.IdentifierExhausted;
        next.* = id + 1;
        return id;
    }

    /// Whether one registered provider owns `transport`. This registry is the
    /// occupancy authority; adapters query it instead of keeping shadow flags.
    pub fn hasTransport(self: *const HostRuntime, transport: []const u8) bool {
        return self.providerFor(transport) != null;
    }

    /// Enter one native driver operation. Public only for the sibling Session
    /// face; this is not an embedder-facing synchronization primitive.
    pub fn enterDriver(self: *HostRuntime) void {
        if (comptime !std.debug.runtime_safety) return;
        self.core.assertOwner();
        self.driver_depth += 1;
    }

    /// Leave one native driver operation, transferring the core only when the
    /// outermost call has stopped dispatching work.
    pub fn leaveDriver(self: *HostRuntime) void {
        if (comptime !std.debug.runtime_safety) return;
        std.debug.assert(self.driver_depth > 0);
        self.driver_depth -= 1;
        if (self.driver_depth == 0) self.core.releaseDriverOwnership();
    }

    /// Tear down every wire, then the core (which breaks every parked vow).
    pub fn deinit(self: *HostRuntime) void {
        if (comptime std.debug.runtime_safety) std.debug.assert(self.driver_depth == 0);
        // Resident connects without a wire own a session only through their
        // pending row. Handshake rows own a wire and fall through the wire
        // sweep below, so each core session is released exactly once.
        for (self.pending_opens.items) |row| switch (row.stage) {
            .stream_connect => {
                row.stage.stream_connect.deinit();
                self.core.releaseSession(row.session) catch {};
            },
            .resident_connect => {
                row.stage.resident_connect.attempt.deinit();
                self.core.releaseSession(row.session) catch {};
            },
            .handshake => {},
        };
        var it = self.wires.valueIterator();
        while (it.next()) |wire_slot| {
            const wire = wire_slot.*;
            const session = wire.session;
            self.freeWire(wire);
            self.core.releaseSession(session) catch {};
        }
        self.wires.deinit(self.allocator);
        self.resident_wires.deinit(self.allocator);
        // A pending dial cannot outlive the stack frame awaiting it, so the
        // map is empty here; only its capacity is released.
        self.pending_resident_dials.deinit(self.allocator);
        // The ownership sweep above retired every row's resident connect,
        // wire, and core session. Only row storage remains here.
        for (self.pending_opens.items) |row| {
            switch (row.outcome) {
                .dial, .accept => |observation| {
                    const observer = observation.observer;
                    observer.release(observer.ctx, observation.tag);
                },
                .redeem => {},
            }
            row.admission.release();
            self.allocator.destroy(row);
        }
        self.pending_opens.deinit(self.allocator);
        std.debug.assert(self.open_admissions == 0);
        var listener_it = self.resident_listeners.valueIterator();
        while (listener_it.next()) |listener| listener.listener.stopListen();
        self.resident_listeners.deinit(self.allocator);
        self.residents.deinit(self.allocator);
        self.providers.deinit(self.allocator);
        self.poll_scratch.deinit(self.allocator);
        self.conn_scratch.deinit(self.allocator);
        self.connect_scratch.deinit(self.allocator);
        self.borrow_scratch.deinit(self.allocator);
        self.extra_fd_scratch.deinit(self.allocator);
        self.listener_fds.deinit(self.allocator);
        if (self.mailbox) |mb| mb.deinit();
        if (self.ready_set) |*rs| rs.deinit();
        if (self.owns_core) {
            self.core.deinit();
            self.allocator.destroy(self.core);
        }
    }

    /// Dial `locator` into an open session: mint the dialed half (the core
    /// registers crossed hellos and encodes the signed hello), bind the
    /// transport wire, and pump the keyed handshake under the handshake
    /// budget. On any failure the wire, the shell, and the hello registration
    /// unwind together.
    pub fn connectLocator(self: *HostRuntime, locator: model.PeerLocator) !*driver_core.HostSession {
        self.enterDriver();
        defer self.leaveDriver();
        var admission = try self.acquireOpenAdmission();
        defer admission.release();
        try self.core.ensureAdvertisedLocator(locator.transport);
        const session = try self.core.openDialedLocator(locator);
        errdefer {
            self.dropWire(session.peer_id);
            self.core.releaseSession(session) catch {};
        }
        try self.bindWire(session, locator);
        try self.pumpHandshake(session, self.opts.handshake);
        return session;
    }

    /// Stage a dial toward `locator` without pumping it (ADR-0112): mint the
    /// dialed session, start its transport connect, and return. The
    /// handshake advances through whichever pump runs next; `observer` hears
    /// `opened` with `tag` when the session opens, or
    /// `failed` when the wire closes or the handshake budget expires.
    /// Provider-backed stream starts are nonblocking; a native Zig netlayer
    /// without staged dial support retains the blocking fallback. In either
    /// case, the handshake advances through later pumps, which lets a dial
    /// complete against a partner stepped by the same thread.
    pub fn startConnectLocator(
        self: *HostRuntime,
        locator: model.PeerLocator,
        tag: u64,
        observer: SessionOpenObserver,
    ) !void {
        self.enterDriver();
        defer self.leaveDriver();
        try observer.reserve(observer.ctx, tag);
        errdefer observer.release(observer.ctx, tag);
        try self.stageConnect(locator, .{ .dial = .{ .observer = observer, .tag = tag } });
    }

    /// Begin adopting one externally established provider connection without
    /// pumping its handshake. The provider owns the subject namespace and
    /// supplies the authenticated durable key; this face owns only the
    /// resulting wire.
    /// No locator is supplied by the caller. A dialed adoption uses the
    /// provider's proved key as its target, while an accepted adoption uses
    /// the Host's selected advertised location.
    pub fn startAdoptExternal(
        self: *HostRuntime,
        transport: []const u8,
        subject: usize,
        role: ExternalAdoptionRole,
        tag: u64,
        observer: SessionOpenObserver,
    ) !void {
        self.enterDriver();
        defer self.leaveDriver();
        const provider = self.providerFor(transport) orelse return Error.UnknownTransport;
        const resident_index = switch (provider.source) {
            .stream => return Error.UnknownTransport,
            .resident => |index| index,
        };
        const runtime = self.residents.items[resident_index].resident;
        const claimer = runtime.externalClaimer() orelse return Error.UnknownTransport;
        var admission = try self.acquireOpenAdmission();
        errdefer admission.release();
        try observer.reserve(observer.ctx, tag);
        errdefer observer.release(observer.ctx, tag);
        var claimed = claimer.claimExternal(subject) catch |err| return err;
        defer claimed.deinit();
        const key = try runtime.connRemoteKey(claimed.borrow()) orelse return error.InvalidAddress;

        var designator_storage: [crypto.PeerKey.designator_len]u8 = undefined;
        const session = switch (role) {
            .dialed => blk: {
                try self.core.ensureAdvertisedLocator(transport);
                designator_storage = key.toDesignator();
                break :blk try self.core.openDialedLocator(.{
                    .transport = transport,
                    .designator = &designator_storage,
                    .hints = model.Hints.emptyFalse(),
                });
            },
            .accepted => try self.core.openAcceptedAdvertised(transport),
        };
        errdefer {
            self.dropWire(session.peer_id);
            self.core.releaseSession(session) catch {};
        }
        session.served.port.peer.bindVerifiedChannelKey(key);
        try self.adoptResidentConn(session, resident_index, &claimed);
        const row = try self.allocator.create(PendingOpen);
        errdefer self.allocator.destroy(row);
        try self.pending_opens.ensureUnusedCapacity(self.allocator, 1);
        row.* = .{
            .admission = admission,
            .session = session,
            .stage = .handshake,
            .deadline_ms = self.handshakeDeadline(),
            .outcome = switch (role) {
                .dialed => .{ .dial = .{ .observer = observer, .tag = tag } },
                .accepted => .{ .accept = .{ .observer = observer, .tag = tag } },
            },
        };
        // Publish the ownership row before bytes move. A synchronous EOF must
        // settle through this operation's observer, never the close observer
        // for application-owned sessions.
        self.pending_opens.appendAssumeCapacity(row);
        const wire = self.wires.get(session.peer_id).?;
        self.writeOutbound(wire) catch self.closeWire(wire);
        if (!wire.closed) _ = self.feedReadable(wire, null) catch self.closeWire(wire);
    }

    /// The shared staged-dial mint behind `startConnectLocator` and the
    /// redeem drain: open the dialed half, start the transport connect, and
    /// park a `PendingOpen` row for the pump to settle. `locator` is
    /// borrowed for the call; nothing of it is retained.
    fn stageConnect(self: *HostRuntime, locator: model.PeerLocator, outcome: PendingOpen.Outcome) !void {
        var admission = try self.acquireOpenAdmission();
        errdefer admission.release();
        try self.core.ensureAdvertisedLocator(locator.transport);
        const session = try self.core.openDialedLocator(locator);
        errdefer {
            self.dropWire(session.peer_id);
            self.core.releaseSession(session) catch {};
        }
        const row = try self.allocator.create(PendingOpen);
        errdefer self.allocator.destroy(row);
        try self.pending_opens.ensureUnusedCapacity(self.allocator, 1);
        const deadline_ms = self.handshakeDeadline();
        const provider = self.providerFor(locator.transport) orelse return Error.UnknownTransport;
        switch (provider.source) {
            .resident => |resident_index| {
                const runtime = &self.residents.items[resident_index];
                const resident = runtime.resident;
                const dialer = resident.dialer() orelse return Error.UnknownTransport;
                const request_id = try mintRuntimeId(&runtime.next_request);
                var attempt = try dialer.startConnect(
                    request_id,
                    locator,
                );
                defer attempt.deinit();
                row.* = .{
                    .admission = admission,
                    .session = session,
                    .stage = .{ .resident_connect = .{
                        .resident = resident_index,
                        .attempt = attempt.take(),
                    } },
                    .deadline_ms = deadline_ms,
                    .outcome = outcome,
                };
            },
            .stream => |nl| {
                if (!nl.supportsDial()) return Error.UnknownTransport;
                if (nl.supportsStagedDial()) {
                    var attempt = try nl.startDial(locator);
                    errdefer attempt.deinit();
                    const fd = attempt.readinessFd();
                    if (fd < 0) return Error.TransportNotPollable;
                    if (self.descriptorInUse(fd)) return error.ReadinessDescriptorConflict;
                    if (self.ready_set) |*rs| try rs.add(fd);
                    errdefer if (self.ready_set) |*rs| rs.remove(fd);
                    row.* = .{
                        .admission = admission,
                        .session = session,
                        .stage = .{ .stream_connect = attempt.take() },
                        .deadline_ms = deadline_ms,
                        .outcome = outcome,
                    };
                } else {
                    try self.bindStreamWire(session, locator, nl);
                    row.* = .{
                        .admission = admission,
                        .session = session,
                        .stage = .handshake,
                        .deadline_ms = deadline_ms,
                        .outcome = outcome,
                    };
                }
            },
        }
        self.pending_opens.appendAssumeCapacity(row);
    }

    fn handshakeDeadline(self: *const HostRuntime) ?i64 {
        return switch (self.opts.handshake) {
            .unbounded => null,
            .ms => |v| net.clock.nowMs(self.io) + v,
        };
    }

    /// Accept one ready connection from `listener` without pumping its
    /// handshake (ADR-0112): mint the accepted half, bind the wire, and park
    /// a staged row beside the dials. The accept observer hears `opened`
    /// with `tag` when the partner's hello completes the handshake, or
    /// `failed` when the wire closes or the budget expires — so one silent
    /// connector can no longer park the step for its whole handshake budget
    /// while sibling sessions wait. Call after the listener reported
    /// acceptable, so the accept syscall itself does not block.
    pub fn startAcceptWire(
        self: *HostRuntime,
        listener: net.netlayer.Listener,
        transport: []const u8,
        tag: u64,
        observer: SessionOpenObserver,
    ) !void {
        self.enterDriver();
        defer self.leaveDriver();
        var admission = try self.acquireOpenAdmission();
        errdefer admission.release();
        try observer.reserve(observer.ctx, tag);
        errdefer observer.release(observer.ctx, tag);
        const session = try self.core.openAcceptedAdvertised(transport);
        errdefer {
            self.dropWire(session.peer_id);
            self.core.releaseSession(session) catch {};
        }
        const row = try self.allocator.create(PendingOpen);
        errdefer self.allocator.destroy(row);
        try self.pending_opens.ensureUnusedCapacity(self.allocator, 1);
        try self.bindAcceptedWire(session, listener);
        row.* = .{
            .admission = admission,
            .session = session,
            .stage = .handshake,
            .deadline_ms = self.handshakeDeadline(),
            .outcome = .{ .accept = .{ .observer = observer, .tag = tag } },
        };
        self.pending_opens.appendAssumeCapacity(row);
    }

    /// Cancel every accepted connection still handshaking for `tag`. A
    /// listener owner calls this before closing the listener, establishing
    /// that no later accept-observer event can name the closed listener.
    pub fn cancelAccepts(self: *HostRuntime, tag: u64) void {
        self.enterDriver();
        defer self.leaveDriver();
        var i: usize = 0;
        while (i < self.pending_opens.items.len) {
            const row = self.pending_opens.items[i];
            const observation = switch (row.outcome) {
                .accept => |value| if (value.tag == tag) value else null,
                else => null,
            };
            if (observation == null) {
                i += 1;
                continue;
            }
            std.debug.assert(self.pending_opens.swapRemove(i) == row);
            self.discardPendingOpen(row);
            const obs = observation.?.observer;
            obs.failed(obs.ctx, tag, error.ConnectionClosed);
        }
    }

    /// Settle every pending open the pump has decided: a session whose
    /// handshake opened reports opened, a closed wire or an expired deadline
    /// reports failed. Runs after every action drain in the pump loops, so a
    /// open advances no matter which wait is driving the host. Rows
    /// are removed before their notification runs, because a notification
    /// may drain actions and stage further dials.
    fn advancePendingOpens(self: *HostRuntime) !void {
        var i: usize = 0;
        while (i < self.pending_opens.items.len) {
            const row = self.pending_opens.items[i];
            if (row.stage == .handshake) {
                const wire = self.wires.get(row.session.peer_id);
                if (wire == null or wire.?.closed) {
                    std.debug.assert(self.pending_opens.swapRemove(i) == row);
                    try self.failPendingOpen(row, Error.ConnectionClosed);
                    continue;
                }
                if (row.session.sessionOpen()) {
                    std.debug.assert(self.pending_opens.swapRemove(i) == row);
                    try self.completePendingOpen(row);
                    continue;
                }
            }
            if (row.deadline_ms) |deadline| {
                if (net.clock.nowMs(self.io) >= deadline) {
                    std.debug.assert(self.pending_opens.swapRemove(i) == row);
                    try self.failPendingOpen(row, Error.HandshakeTimedOut);
                    continue;
                }
            }
            i += 1;
        }
    }

    /// Report one completed session open. For a redeem row, a refused
    /// `exporterDialed` fails closed: the ticket's action was consumed at
    /// stage time, so there is no drain retry to lean on — the session
    /// unwinds and the waiting redeems break rather than strand.
    fn completePendingOpen(self: *HostRuntime, row: *PendingOpen) !void {
        defer self.allocator.destroy(row);
        row.admission.release();
        switch (row.outcome) {
            .dial => |observation| {
                const obs = observation.observer;
                obs.opened(obs.ctx, observation.tag, row.session);
            },
            .redeem => |ticket| {
                self.core.exporterDialed(ticket, row.session) catch |err| {
                    self.releaseWire(row.session);
                    self.core.dialFailed(ticket, @errorName(err)) catch {};
                    return err;
                };
            },
            .accept => |observation| {
                const obs = observation.observer;
                obs.opened(obs.ctx, observation.tag, row.session);
            },
        }
        // The settle queued post-open work (withdraws, parked enlivens, the
        // observer's own effects); answer it before the next row's verdict.
        try self.drainActions();
    }

    /// Unwind and report one failed session open. The still-parked
    /// resident connect is canceled; a bound wire drops with its session.
    fn failPendingOpen(self: *HostRuntime, row: *PendingOpen, err: anyerror) !void {
        const outcome = row.outcome;
        self.discardPendingOpen(row);
        switch (outcome) {
            .dial => |observation| {
                const obs = observation.observer;
                obs.failed(obs.ctx, observation.tag, err);
            },
            .redeem => |ticket| try self.core.dialFailed(ticket, @errorName(err)),
            .accept => |observation| {
                const obs = observation.observer;
                obs.failed(obs.ctx, observation.tag, err);
            },
        }
        try self.drainActions();
    }

    /// Infallibly retire the transport and session owned by a failed pending
    /// open. Outcome notification and action draining stay with the caller:
    /// listener close uses this after admission is sealed and must not become
    /// half-closed because an unrelated queued action failed to drain.
    fn discardPendingOpen(self: *HostRuntime, row: *PendingOpen) void {
        defer self.allocator.destroy(row);
        row.admission.release();
        switch (row.stage) {
            .stream_connect => |*attempt| {
                if (self.ready_set) |*rs| rs.remove(attempt.readinessFd());
                attempt.deinit();
            },
            .resident_connect => row.stage.resident_connect.attempt.deinit(),
            .handshake => {},
        }
        self.dropWire(row.session.peer_id);
        self.core.releaseSession(row.session) catch {};
    }

    fn pendingOpenByRequest(self: *HostRuntime, resident_index: usize, request_id: usize) ?*PendingOpen {
        for (self.pending_opens.items) |row| switch (row.stage) {
            .stream_connect => {},
            .resident_connect => |rc| if (rc.resident == resident_index and rc.attempt.id() == request_id) return row,
            .handshake => {},
        };
        return null;
    }

    fn pendingOpenFor(self: *const HostRuntime, session: *driver_core.HostSession) ?*PendingOpen {
        for (self.pending_opens.items) |row| {
            if (row.session == session) return row;
        }
        return null;
    }

    fn pendingOpenSlotAvailable(self: *const HostRuntime) bool {
        return self.open_admissions < self.opts.max_pending_opens;
    }

    fn acquireOpenAdmission(self: *HostRuntime) Error!OpenAdmission {
        if (!self.pendingOpenSlotAvailable()) return Error.PendingOpenLimitReached;
        self.open_admissions += 1;
        return .{ .runtime = self };
    }

    fn removePendingRow(self: *HostRuntime, row: *PendingOpen) void {
        for (self.pending_opens.items, 0..) |candidate, i| {
            if (candidate == row) {
                std.debug.assert(self.pending_opens.swapRemove(i) == row);
                return;
            }
        }
        unreachable; // the caller found the row in this list
    }

    /// Claim a staged dial's completed resident connect: finish it, bind the
    /// channel-proved key and the wire, push the queued hello, and move the
    /// row to the handshake stage. The request is consumed by
    /// `finishConnect` on both arms, so a failure settles the row failed
    /// with nothing left to cancel.
    fn adoptPendingResidentConnect(self: *HostRuntime, resident_index: usize, row: *PendingOpen) !void {
        std.debug.assert(row.stage.resident_connect.resident == resident_index);
        const resident = self.residents.items[resident_index].resident;
        var conn = row.stage.resident_connect.attempt.finish() catch |err| {
            self.removePendingRow(row);
            return self.failPendingOpen(row, err);
        };
        defer conn.deinit();
        row.stage = .handshake;
        if (try resident.connRemoteKey(conn.borrow())) |key| {
            row.session.served.port.peer.bindVerifiedChannelKey(key);
        }
        self.adoptResidentConn(row.session, resident_index, &conn) catch |err| {
            self.removePendingRow(row);
            return self.failPendingOpen(row, err);
        };
        // The hello's flush action drained to a no-op while the wire did not
        // exist yet; push the queued frame now that it does.
        const wire = self.wires.get(row.session.peer_id).?;
        self.writeOutbound(wire) catch self.closeWire(wire);
    }

    /// Claim a ready per-stream connect, transfer it into an ordinary wire,
    /// and advance the row to the shared CapTP handshake stage.
    fn adoptPendingStreamConnect(self: *HostRuntime, row: *PendingOpen) !void {
        std.debug.assert(row.stage == .stream_connect);
        if (self.ready_set) |*rs| rs.remove(row.stage.stream_connect.readinessFd());
        const bufs = self.allocBufs() catch |err| {
            self.removePendingRow(row);
            return self.failPendingOpen(row, err);
        };
        var owns_bufs = true;
        defer if (owns_bufs) self.freeBufs(bufs);
        const conn = row.stage.stream_connect.finish(row.session.served.port.peer, .{
            .read = bufs.read,
            .write = bufs.write,
        }) catch |err| {
            row.stage = .handshake;
            self.removePendingRow(row);
            return self.failPendingOpen(row, err);
        };
        row.stage = .handshake;
        self.adoptConn(row.session, conn, bufs) catch |err| {
            self.removePendingRow(row);
            return self.failPendingOpen(row, err);
        };
        owns_bufs = false;
        // The hello flush drained before the wire existed. Push it now.
        const wire = self.wires.get(row.session.peer_id).?;
        self.writeOutbound(wire) catch self.closeWire(wire);
    }

    /// Bound a park by the nearest pending-open deadline, so an expiry is
    /// noticed by the wait that spans it rather than the next external event.
    fn clampTimeoutToPendingOpens(self: *const HostRuntime, timeout_ms: i32) i32 {
        var nearest: ?i64 = null;
        for (self.pending_opens.items) |row| {
            const deadline = row.deadline_ms orelse continue;
            if (nearest == null or deadline < nearest.?) nearest = deadline;
        }
        const deadline = nearest orelse return timeout_ms;
        const remaining_i64 = @max(deadline - net.clock.nowMs(self.io), 0);
        const remaining = std.math.cast(i32, remaining_i64) orelse std.math.maxInt(i32);
        if (timeout_ms < 0) return remaining;
        return @min(timeout_ms, remaining);
    }

    /// Bind an accepted transport connection produced by `listener` to a
    /// fresh accepted-half session. The mint happens after `waitAcceptable`
    /// reported readiness but before the accept itself, because the accept
    /// needs the minted peer; the shell's exposure is one accept syscall, not
    /// the listener's park.
    pub fn acceptWire(
        self: *HostRuntime,
        listener: net.netlayer.Listener,
        transport: []const u8,
    ) !*driver_core.HostSession {
        self.enterDriver();
        defer self.leaveDriver();
        var admission = try self.acquireOpenAdmission();
        defer admission.release();
        const session = try self.core.openAcceptedAdvertised(transport);
        errdefer {
            self.dropWire(session.peer_id);
            self.core.releaseSession(session) catch {};
        }
        try self.bindAcceptedWire(session, listener);
        try self.pumpHandshake(session, self.opts.handshake);
        return session;
    }

    /// The accept half of `bindWire`, in its own frame so buffer ownership
    /// transfers atomically: once `adoptConn` succeeds the wire owns the
    /// buffers, and a later handshake failure must unwind through `dropWire`
    /// alone — a still-armed buffer errdefer there was a double free.
    fn bindAcceptedWire(self: *HostRuntime, session: *driver_core.HostSession, listener: net.netlayer.Listener) !void {
        const bufs = try self.allocBufs();
        errdefer self.freeBufs(bufs);
        const conn = try listener.accept(session.served.port.peer, .{ .read = bufs.read, .write = bufs.write });
        try self.adoptConn(session, conn, bufs);
    }

    const Bufs = struct { read: []u8, write: []u8 };

    fn allocBufs(self: *HostRuntime) !Bufs {
        const read = try self.allocator.alloc(u8, self.opts.wire_buffer_bytes);
        errdefer self.allocator.free(read);
        const write = try self.allocator.alloc(u8, self.opts.wire_buffer_bytes);
        return .{ .read = read, .write = write };
    }

    fn freeBufs(self: *HostRuntime, bufs: Bufs) void {
        self.allocator.free(bufs.read);
        self.allocator.free(bufs.write);
    }

    /// Resolve and dial `locator` through the one provider registry, then adopt
    /// the connection as its wire. A stream transport with no pollable fd is
    /// refused because the multiplexed wait cannot block on it.
    fn bindWire(self: *HostRuntime, session: *driver_core.HostSession, locator: model.PeerLocator) !void {
        const provider = self.providerFor(locator.transport) orelse return Error.UnknownTransport;
        switch (provider.source) {
            .stream => |nl| {
                if (!nl.supportsDial()) return Error.UnknownTransport;
                try self.bindStreamWire(session, locator, nl);
            },
            .resident => |resident_index| {
                const dialer = self.residents.items[resident_index].resident.dialer() orelse
                    return Error.UnknownTransport;
                try self.bindResidentWire(session, resident_index, dialer, locator);
            },
        }
    }

    /// The stream arm of `bindWire`, on its own for the staged dial path,
    /// whose resident arm binds later, at the `ev_connect` record.
    fn bindStreamWire(
        self: *HostRuntime,
        session: *driver_core.HostSession,
        locator: model.PeerLocator,
        nl: net.netlayer.Netlayer,
    ) !void {
        const bufs = try self.allocBufs();
        errdefer self.freeBufs(bufs);
        const conn = try nl.dial(session.served.port.peer, locator, .{ .read = bufs.read, .write = bufs.write });
        try self.adoptConn(session, conn, bufs);
    }

    /// The resident half of `bindWire`: begin the dial, pump readiness until
    /// its `ev_connect` answers under the handshake budget, claim the
    /// connection, then bind the channel-proved key (when the transport
    /// carries one) before the CapTP handshake pumps — the same order the
    /// blocking iroh netlayer keeps, so the hello already speaks to a proved
    /// peer.
    fn bindResidentWire(
        self: *HostRuntime,
        session: *driver_core.HostSession,
        resident_index: usize,
        dialer: net.MultiplexedResident.Dialer,
        locator: model.PeerLocator,
    ) !void {
        const runtime = &self.residents.items[resident_index];
        const resident = runtime.resident;
        const request_id = try mintRuntimeId(&runtime.next_request);
        var attempt = try dialer.startConnect(
            request_id,
            locator,
        );
        defer attempt.deinit();
        var conn = try self.awaitResidentConnect(resident_index, &attempt, self.opts.handshake);
        defer conn.deinit();
        if (try resident.connRemoteKey(conn.borrow())) |key| {
            session.served.port.peer.bindVerifiedChannelKey(key);
        }
        try self.adoptResidentConn(session, resident_index, &conn);
    }

    /// Park until the resident's `ev_connect` for `request_id` drains,
    /// servicing every other ready source meanwhile (sibling wires keep
    /// being fed, and a nested redeem dial gets its own wait row). The
    /// budget maps expiry to `HandshakeTimedOut`: to the caller, a connect
    /// that never completes and a partner that never speaks are one refusal.
    fn awaitResidentConnect(
        self: *HostRuntime,
        resident_index: usize,
        attempt: *net.multiplexed_resident.ConnectAttempt,
        budget: Budget,
    ) !net.multiplexed_resident.ClaimedConnection {
        const request_id = attempt.id();
        const key = ResidentRequestKey{ .resident = resident_index, .request = request_id };
        var wait = ResidentDialWait{};
        try self.pending_resident_dials.put(self.allocator, key, &wait);
        defer std.debug.assert(self.pending_resident_dials.remove(key));
        const deadline_ms: ?i64 = switch (budget) {
            .unbounded => null,
            .ms => |v| net.clock.nowMs(self.io) + v,
        };
        while (true) {
            try self.applySettleMailbox();
            try self.drainActions();
            try self.advancePendingOpens();
            if (wait.ready) return attempt.finish();
            const timeout: i32 = if (deadline_ms) |d| blk: {
                const remaining = d - net.clock.nowMs(self.io);
                if (remaining <= 0) return Error.HandshakeTimedOut;
                break :blk std.math.cast(i32, remaining) orelse std.math.maxInt(i32);
            } else -1;
            const source = try self.waitAnySource(timeout, false) orelse continue;
            switch (source) {
                .wire => |wire| _ = try self.feedReadable(wire, null),
                .resident => |index| _ = try self.serviceResident(index, null),
                .stream_connect => |row| try self.adoptPendingStreamConnect(row),
            }
        }
    }

    fn adoptConn(self: *HostRuntime, session: *driver_core.HostSession, conn: net.Connection, bufs: Bufs) !void {
        var owned_conn = conn;
        errdefer owned_conn.deinit();
        const handle = owned_conn.socketHandle() orelse return Error.TransportNotPollable;
        if (handle < 0) return Error.TransportNotPollable;
        if (self.descriptorInUse(handle)) return error.ReadinessDescriptorConflict;
        if (self.ready_set) |*rs| try rs.add(handle);
        errdefer if (self.ready_set) |*rs| rs.remove(handle);
        try self.wires.ensureUnusedCapacity(self.allocator, 1);
        const wire = try self.allocator.create(Wire);
        wire.* = .{
            .link = .{ .stream = .{ .conn = owned_conn, .read_buf = bufs.read, .write_buf = bufs.write } },
            .session = session,
        };
        self.wires.putAssumeCapacity(session.peer_id, wire);
    }

    /// Bind a claimed resident connection as `session`'s wire.
    fn adoptResidentConn(
        self: *HostRuntime,
        session: *driver_core.HostSession,
        resident_index: usize,
        claimed: *net.multiplexed_resident.ClaimedConnection,
    ) !void {
        const conn = claimed.borrow();
        const read_buf = try self.allocator.alloc(u8, self.opts.wire_buffer_bytes);
        errdefer self.allocator.free(read_buf);
        try self.wires.ensureUnusedCapacity(self.allocator, 1);
        try self.resident_wires.ensureUnusedCapacity(self.allocator, 1);
        const wire = try self.allocator.create(Wire);
        wire.* = .{
            .link = .{ .resident = .{ .index = resident_index, .conn = conn, .read_buf = read_buf } },
            .session = session,
        };
        self.wires.putAssumeCapacity(session.peer_id, wire);
        self.resident_wires.putAssumeCapacity(
            .{ .resident = resident_index, .conn = conn },
            wire,
        );
        _ = claimed.take();
    }

    /// Free one wire's transport and buffers. The caller owns the `wires`
    /// row; the resident routing row leaves here, with the link it routes.
    fn freeWire(self: *HostRuntime, wire: *Wire) void {
        switch (wire.link) {
            .stream => |*stream| {
                // Tolerant re-remove: `closeWire` already swept a closed
                // wire's fd, but a release without a close comes here first.
                if (self.ready_set) |*rs| if (stream.conn.socketHandle()) |fd| rs.remove(fd);
                stream.conn.deinit();
                self.allocator.free(stream.read_buf);
                self.allocator.free(stream.write_buf);
            },
            .resident => |*rl| {
                std.debug.assert(self.resident_wires.remove(.{ .resident = rl.index, .conn = rl.conn }));
                self.residents.items[rl.index].resident.connClose(rl.conn);
                if (rl.pending) |*pending| pending.frame.deinit();
                self.allocator.free(rl.read_buf);
            },
        }
        self.allocator.destroy(wire);
    }

    fn dropWire(self: *HostRuntime, peer_id: engine.PeerId) void {
        if (self.wires.fetchRemove(peer_id)) |kv| self.freeWire(kv.value);
    }

    /// Mark `wire` closed and break its session's far vows so every waiter
    /// hears the closure — without freeing anything. The shell and wire stay
    /// parked until their owner releases them (the view's deinit, or host
    /// teardown), because a view still holds the session pointer; freeing here
    /// is the double-release this split exists to prevent.
    fn closeWire(self: *HostRuntime, wire: *Wire) void {
        if (wire.closed) return;
        wire.closed = true;
        // A closed stream wire leaves every wait immediately: its fd would
        // otherwise hold the armed readiness set readable forever while
        // `waitAnySource` skips it.
        if (self.ready_set) |*rs| switch (wire.link) {
            .stream => |*sl| if (sl.conn.socketHandle()) |fd| rs.remove(fd),
            .resident => {},
        };
        wire.session.served.port.breakFarVows(wire.session.served.closeReason("connection lost"));
        // A staged dial's session reports through the dial path when the
        // sweep sees the closed wire; the embedder has never held it, so a
        // close event here would name a session it cannot know.
        if (self.close_observer) |obs| {
            if (self.pendingOpenFor(wire.session) == null) obs.closed(obs.ctx, wire.session);
        }
    }

    /// Spawn `initial` once in the Host Vat and bind `name` as a Host-wide
    /// alias. Fetching the name lazily projects that actor onto the requesting
    /// Port; exact gifts retain the actor target and do not consult this name
    /// again. `Behavior` is Value-shaped (`driver_core.Hosting`), like every
    /// owning-tier behavior.
    pub fn publishGiftable(
        self: *HostRuntime,
        name: []const u8,
        comptime Behavior: type,
        initial: Behavior,
    ) !void {
        self.enterDriver();
        defer self.leaveDriver();
        _ = try self.core.publishGiftable(name, driver_core.Hosting(Behavior), .{ .inner = initial });
    }

    /// Remove the host-wide alias `name` (see `driver_core.Host.unpublish`):
    /// a later fetch misses on every session, while issued capabilities and
    /// deposited gifts keep the exact actor.
    pub fn unpublish(self: *HostRuntime, name: []const u8) error{ UnknownPublication, ReservedDurableNamespace }!void {
        self.enterDriver();
        defer self.leaveDriver();
        return self.core.unpublish(name);
    }

    /// Adopt a settled/failed completion the enliven wait below is waiting
    /// for; ownership moves to `claimed_completion` and the wait frees it.
    fn claimCompletion(self: *HostRuntime, action: driver_core.HostAction) bool {
        const wanted = self.awaited_completion orelse return false;
        const vow_id = switch (action) {
            .settled => |settled| settled.vow_id,
            .failed => |failed| failed.vow_id,
            else => return false,
        };
        if (vow_id != wanted or self.claimed_completion != null) return false;
        self.claimed_completion = action;
        return true;
    }

    /// Host-level select-or-dial enlivenment (ADR-0098 step 4): resolve the
    /// sturdyref's peer to the live dialed session it names, or dial it
    /// through this host's netlayers, then enliven — under the same complete
    /// peer check every enliven path shares — and lift the settled
    /// capability. The caller never picks a session; the peer named in the
    /// sturdyref does.
    pub fn enliven(self: *HostRuntime, sturdy: model.SturdyRef) !driver_core.Capability {
        self.enterDriver();
        defer self.leaveDriver();
        const hs = self.core.dialedSessionFor(sturdy.peer.transport, sturdy.peer.designator) orelse
            try self.connectLocator(sturdy.peer);
        const vow_id = try self.core.enliven(hs, sturdy);
        var capture = driver_core.FetchCapture{};
        var flag = driver_core.SettleFlag{ .inner = .{ .ctx = &capture, .func = driver_core.FetchCapture.record } };
        self.core.vowOn(vow_id, .{ .ctx = &flag, .func = driver_core.SettleFlag.fire }) catch |err| switch (err) {
            // The enliven settled inside the verb (a session-cache hit): its
            // completion is parked on the action queue with no listener to
            // fire. Claim it from the drain instead of dropping it.
            error.NoSuchVow => {
                self.awaited_completion = vow_id;
                defer self.awaited_completion = null;
                try self.drainActions();
                const action = self.claimed_completion orelse return driver_core.Error.ConnectionClosed;
                self.claimed_completion = null;
                defer self.core.freeAction(action);
                return switch (action) {
                    .settled => |settled| switch (settled.value) {
                        .reference => |reference| self.core.liftCapability(hs, reference),
                        else => driver_core.Error.FetchNotACapability,
                    },
                    .failed => driver_core.Error.FetchBroken,
                    else => unreachable,
                };
            },
            else => return err,
        };
        self.pumpUntilFlag(hs, &flag.done, self.opts.settle) catch |err| {
            hs.served.port.breakFarVows(hs.served.closeReason("wait failed"));
            return err;
        };
        return switch (capture.outcome orelse return driver_core.Error.ConnectionClosed) {
            .capability => |far_ref| self.core.liftCapability(hs, .{ .far = far_ref }),
            .broken => driver_core.Error.FetchBroken,
            .not_a_capability => driver_core.Error.FetchNotACapability,
        };
    }

    /// Release one session and its wire: outbound the core already queued for
    /// it is written best-effort first (a condemned session's abort must reach
    /// the partner), then the core breaks its vows and fail-closes sibling
    /// answers, then the transport closes.
    pub fn releaseWire(self: *HostRuntime, session: *driver_core.HostSession) void {
        self.enterDriver();
        defer self.leaveDriver();
        if (self.wires.get(session.peer_id)) |wire| {
            if (!wire.closed) self.writeOutbound(wire) catch {};
        }
        self.dropWire(session.peer_id);
        self.core.releaseSession(session) catch {};
        self.drainActions() catch {};
    }

    /// Write every transport-ready stream vector the core queued for `wire`.
    /// The core owns whether the prefix is present, so this I/O tier never
    /// interprets transport names or channel state.
    fn writeOutbound(self: *HostRuntime, wire: *Wire) !void {
        switch (wire.link) {
            .stream => |*stream| {
                while (try wire.session.takeStreamOutbound()) |value| {
                    var outbound = value;
                    defer outbound.payload.deinit();
                    try stream.conn.w.writeAll(outbound.prefixBytes());
                    try stream.conn.w.writeAll(outbound.payload.bytes());
                }
                try stream.conn.w.flush();
            },
            .resident => try self.writeResidentOutbound(wire),
        }
    }

    /// The resident spelling of the outbound drain: the retained frame first,
    /// then the core's queue, each through `try_write` until the window
    /// refuses. A partial frame is retained with its offset — the window will
    /// announce `ev_writable` and the drain resumes exactly there, so frame
    /// bytes are never resent and never reordered.
    fn writeResidentOutbound(self: *HostRuntime, wire: *Wire) !void {
        const rl = &wire.link.resident;
        const resident = self.residents.items[rl.index].resident;
        if (rl.pending != null) {
            if (!try self.pushPendingResident(resident, rl)) return;
        }
        while (try wire.session.takeStreamOutbound()) |value| {
            var outbound = value;
            var pending = Wire.ResidentLink.PendingOut{
                .frame = outbound.payload,
                .prefix = undefined,
                .prefix_len = outbound.prefix_len,
                .offset = 0,
            };
            @memcpy(pending.prefix[0..pending.prefix_len], outbound.prefixBytes());
            rl.pending = pending;
            if (!try self.pushPendingResident(resident, rl)) return;
        }
    }

    /// Push the retained frame as far as the window allows. True when it was
    /// fully consumed (and freed); false when the window refused and the
    /// remainder stays retained for `ev_writable`.
    fn pushPendingResident(self: *HostRuntime, resident: net.MultiplexedResident, rl: *Wire.ResidentLink) !bool {
        _ = self;
        const pending = &rl.pending.?;
        const body = pending.frame.bytes();
        const total = pending.prefix_len + body.len;
        while (pending.offset < total) {
            const span = if (pending.offset < pending.prefix_len)
                pending.prefix[pending.offset..pending.prefix_len]
            else
                body[pending.offset - pending.prefix_len ..];
            const wrote = resident.tryWrite(rl.conn, span);
            if (wrote == net.multiplexed_resident.would_block) return false;
            if (wrote < 0) return error.ConnectionLost;
            // Zero is a full non-blocking window, not progress. The resident
            // retains the frame and re-arms writable readiness just as for the
            // explicit would-block sentinel.
            if (wrote == 0) return false;
            if (@as(usize, @intCast(wrote)) > span.len) return error.ConnectionLost;
            pending.offset += @intCast(wrote);
        }
        pending.frame.deinit();
        rl.pending = null;
        return true;
    }

    /// Drain the core's action queue to quiescence: writes, redeem dials,
    /// entropy draws, closes, and unobserved completions. The one place every
    /// action is answered; every pump iteration starts here.
    pub fn drainActions(self: *HostRuntime) !void {
        self.enterDriver();
        defer self.leaveDriver();
        // HostRuntime is the explicitly blocking front: unlike Bridge, it owns no
        // shared reactor turn to yield to. Preserve its to-quiescence contract
        // while the shared drain still exposes each finite core slice.
        while (try driver_core.drainActions(
            self.core,
            EntropySource{ .io = self.io },
            Exec{ .runtime = self },
        ) == .yielded) {}
    }

    /// The entropy boundary the shared drain draws gift ids at, mapping the
    /// OS failure onto this tier's typed reason.
    const EntropySource = struct {
        io: std.Io,
        pub fn randomSecure(self: EntropySource, buf: []u8) !void {
            self.io.randomSecure(buf) catch return Error.HandshakeEntropyFailed;
        }
    };

    /// The arms this embedding supplies to the shared drain skeleton: write a
    /// flush to its wire, answer a redeem dial by dialing and handshaking, and
    /// free an unobserved completion (the Zig face observes vows in-process
    /// through captures, so a queued one has no waiter to route it to).
    const Exec = struct {
        runtime: *HostRuntime,

        pub fn flush(self: Exec, peer_id: engine.PeerId) !void {
            const wire = self.runtime.wires.get(peer_id) orelse return;
            if (wire.closed) return;
            self.runtime.writeOutbound(wire) catch self.runtime.closeWire(wire);
        }

        pub fn close(self: Exec, peer_id: engine.PeerId) !void {
            const wire = self.runtime.wires.get(peer_id) orelse return;
            if (!wire.closed) self.runtime.writeOutbound(wire) catch {};
            self.runtime.closeWire(wire);
        }

        pub fn dial(self: Exec, d: @FieldType(driver_core.HostAction, "dial")) !void {
            try self.runtime.answerDial(d.ticket);
        }

        pub fn complete(self: Exec, action: driver_core.HostAction) !void {
            if (self.runtime.claimCompletion(action)) return;
            if (self.runtime.completion_sink) |sink| {
                if (sink.take(sink.ctx, action)) return;
            }
            self.runtime.core.freeAction(action);
        }
    };

    /// Answer a redeem `dial` action: mint the dialed session against the
    /// pending locator and stage it (ADR-0112) — the handshake advances
    /// through whichever pump is running, and the sweep reports the outcome
    /// through `exporterDialed` / `dialFailed` when it settles. Staging
    /// rather than pumping here is what lets a redeem complete when the
    /// exporter is served by this same thread. A staging failure settles
    /// every waiting redeem broken through `dialFailed` instead of surfacing
    /// — the caller's wait hears the break, not the dial's plumbing.
    fn answerDial(self: *HostRuntime, ticket: engine.Node.PendingId) anyerror!void {
        // `anyerror` keeps this call out of inferred-error recursion: it runs
        // inside the action drain, and its failure reporting drains again.
        const pending = self.core.pendingDial(ticket) orelse return;
        // The hint is load-bearing on keyed transports: keyed-tcp dials the
        // bound `host:port` the exporter advertised, and a locator without it
        // fails the dial outright. `forDirectAddresses` keeps the empty-to-#f
        // The pending row owns every locator slice until this ticket settles;
        // stageConnect borrows the complete active route for this call.
        self.stageConnect(pending, .{ .redeem = ticket }) catch |err| {
            try self.core.dialFailed(ticket, @errorName(err));
            return;
        };
    }

    /// Pump until `session`'s keyed handshake opens, under `budget`.
    fn pumpHandshake(self: *HostRuntime, session: *driver_core.HostSession, budget: Budget) !void {
        var open = session.sessionOpen();
        var probe = SessionOpenProbe{ .session = session, .open = &open };
        self.pumpUntilProbe(&probe, budget) catch |err| switch (err) {
            Error.WaitTimedOut => return Error.HandshakeTimedOut,
            else => |e| return e,
        };
    }

    const SessionOpenProbe = struct {
        session: *driver_core.HostSession,
        open: *bool,
        fn done(self: *SessionOpenProbe) bool {
            self.open.* = self.session.sessionOpen();
            return self.open.*;
        }
        fn resumeSkip(self: *SessionOpenProbe) ?*driver_core.HostSession {
            return self.session;
        }
    };

    /// Resume any session whose `feed_tail` holds paused frames: the core
    /// stops consuming at the frame that opens a session, so frames that
    /// coalesced behind the handshake hello wait in the tail — and no poll
    /// will ever report them, because they already left the kernel. Every
    /// binding's serve loop empty-feeds before parking for exactly this
    /// reason; this is the owning face's spelling of that contract. A refusal
    /// closes that wire like any dispatch refusal.
    ///
    /// `skip` is the session a handshake pump is itself opening: its paused
    /// frames must keep waiting, because the pause exists so the embedder can
    /// finish post-open setup (publish, spawn) before the partner's coalesced
    /// first frames dispatch. Resuming it here would answer a pipelined fetch
    /// before the object it names exists.
    fn resumeFeedTails(self: *HostRuntime, skip: ?*driver_core.HostSession) !void {
        var it = self.wires.valueIterator();
        while (it.next()) |entry| {
            const wire = entry.*;
            if (wire.closed) continue;
            if (wire.session == skip) continue;
            if (wire.session.pausedInboundPending()) {
                self.core.feedBytes(wire.session, &.{}) catch {
                    self.drainActions() catch {};
                    self.closeWire(wire);
                    continue;
                };
            }
        }
    }

    /// The blocking pump: drain actions, check `probe.done()`, wait for any
    /// live wire's readable progress under what remains of `budget`, read and
    /// feed, repeat. `Error.WaitTimedOut` on deadline; `Error.ConnectionClosed`
    /// when the probe's own session closes first.
    fn pumpUntilProbe(self: *HostRuntime, probe: anytype, budget: Budget) !void {
        const deadline_ms: ?i64 = switch (budget) {
            .unbounded => null,
            .ms => |v| net.clock.nowMs(self.io) + v,
        };
        while (true) {
            // Apply posted settles before anything else can consume the
            // iteration. The wake fd rides the poll set too, but a poll
            // reports the first ready row and a busy wire always precedes
            // it, so relying on that alone would starve the mailbox exactly
            // under the sustained traffic it exists for. This is one
            // uncontended lock and a count check, next to nothing beside the
            // poll below.
            try self.applySettleMailbox();
            try self.resumeFeedTails(probe.resumeSkip());
            try self.drainActions();
            try self.advancePendingOpens();
            if (probe.done()) return;
            if (self.wireClosed(probe)) return Error.ConnectionClosed;

            const timeout: i32 = if (deadline_ms) |d| blk: {
                const remaining = d - net.clock.nowMs(self.io);
                if (remaining <= 0) return Error.WaitTimedOut;
                break :blk std.math.cast(i32, remaining) orelse std.math.maxInt(i32);
            } else -1;

            const source = try self.waitAnySource(timeout, false) orelse continue;
            switch (source) {
                .wire => |wire| switch (try self.feedReadable(wire, probeSession(probe))) {
                    .fed => {},
                    .closed => if (wire.session == probeSession(probe)) return Error.ConnectionClosed,
                },
                // A probe wire closed in here surfaces at the loop top's
                // `wireClosed` check.
                .resident => |index| _ = try self.serviceResident(index, probeSession(probe)),
                .stream_connect => |row| try self.adoptPendingStreamConnect(row),
            }
        }
    }

    const FeedOutcome = union(enum) { fed: usize, closed };

    /// One readable wire's read-feed-react cycle, the one reaction every pump
    /// spelling shares so their closure semantics cannot diverge. EOF and
    /// transport faults close the wire here (vows break; the release stays
    /// with the owner). A dispatch refusal already closed the offending wire
    /// inside the read-and-feed arm; it propagates only when the misbehaving
    /// session is `own` — a sibling's protocol violation is that session's
    /// closure, not a reason to abort an innocent caller's wait. A null `own`
    /// (a pre-wire resident dial wait) treats every wire as a sibling.
    fn feedReadable(self: *HostRuntime, wire: *Wire, own: ?*driver_core.HostSession) !FeedOutcome {
        const read_arm = switch (wire.link) {
            .stream => self.readAndFeed(wire),
            .resident => self.residentReadAndFeed(wire),
        };
        const fed = read_arm catch |err| switch (err) {
            error.ConnectionLost, error.EndOfStream, error.TruncatedFrame => {
                self.closeWire(wire);
                return .closed;
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => |e| {
                if (own != null and wire.session == own.?) return e;
                return .closed;
            },
        };
        return .{ .fed = fed };
    }

    fn probeSession(probe: anytype) *driver_core.HostSession {
        return probe.session;
    }

    fn wireClosed(self: *HostRuntime, probe: anytype) bool {
        const session = probeSession(probe);
        const wire = self.wires.get(session.peer_id) orelse return true;
        return wire.closed;
    }

    /// The off-turn settle mailbox (ADR-0102 stage 4), minted on the owning
    /// thread the first time it is asked for. Hand the returned pointer (and
    /// resolver ids) to worker threads; their `post` calls wake this host's
    /// readiness wait and the settles apply here, on the owning thread. The
    /// mailbox lives until the host's own teardown.
    pub fn settleMailbox(self: *HostRuntime) !*settle_mailbox.SettleMailbox {
        self.enterDriver();
        defer self.leaveDriver();
        if (self.mailbox) |mb| return mb;
        const mb = try settle_mailbox.SettleMailbox.init(self.allocator, settle_mailbox.default_slots);
        errdefer mb.deinit();
        if (self.ready_set) |*rs| try rs.add(mb.wakeFd());
        self.mailbox = mb;
        return mb;
    }

    /// Apply whatever a worker thread posted, on this owning thread. Cheap
    /// and unconditional: the mailbox is empty in the ordinary case, and the
    /// check is one lock acquisition.
    fn applySettleMailbox(self: *HostRuntime) !void {
        const mb = self.mailbox orelse return;
        mb.drainWake();
        mb.apply(self.io, self.core);
        try self.drainActions();
    }

    /// Fill the scratch lists with the live stream wires and every resident's
    /// readiness descriptor, and wait for the first ready source. Null on
    /// timeout, and on the mailbox wake (applying is the loop top's job,
    /// which runs whether or not the poll happened to select that row).
    fn waitAnySource(self: *HostRuntime, timeout_ms: i32, empty_ok: bool) !?ReadySource {
        if (self.ready_set) |*rs| rs.drainWake();
        self.conn_scratch.clearRetainingCapacity();
        var it = self.wires.valueIterator();
        while (it.next()) |wire| {
            if (!wire.*.closed and wire.*.link == .stream) {
                try self.conn_scratch.append(self.allocator, wire.*);
            }
        }
        const n = self.conn_scratch.items.len;
        // A blocking verb with no source left has nothing that can ever wake
        // it; `stepAny` passes `empty_ok` because a step-driven host with no
        // session yet is parked on its own budget, not stranded.
        var staged_stream_connects: usize = 0;
        for (self.pending_opens.items) |row| if (row.stage == .stream_connect) {
            staged_stream_connects += 1;
        };
        if (n == 0 and self.residents.items.len == 0 and staged_stream_connects == 0 and !empty_ok)
            return Error.ConnectionClosed;
        if (n > 0) {
            std.mem.rotate(*Wire, self.conn_scratch.items, self.wait_cursor % n);
            self.wait_cursor +%= 1;
        }
        self.extra_fd_scratch.clearRetainingCapacity();
        for (self.residents.items) |runtime| {
            try self.extra_fd_scratch.append(self.allocator, runtime.readiness_fd);
        }
        self.connect_scratch.clearRetainingCapacity();
        for (self.pending_opens.items) |row| switch (row.stage) {
            .stream_connect => |attempt| {
                try self.connect_scratch.append(self.allocator, row);
                try self.extra_fd_scratch.append(self.allocator, attempt.readinessFd());
            },
            .resident_connect, .handshake => {},
        };
        if (self.mailbox) |mb| try self.extra_fd_scratch.append(self.allocator, mb.wakeFd());
        // The readiness wake polls as its own row, so a cross-thread
        // `wakeReadiness` interrupts a blocking wait here, not only an
        // embedder parked outside on the set descriptor.
        if (self.ready_set) |*rs| try self.extra_fd_scratch.append(self.allocator, rs.wakeFd());
        try self.poll_scratch.resize(self.allocator, n + self.extra_fd_scratch.items.len);
        // Borrow the connections for the wait through retained scratch; net
        // polls, we route by index, and the wait itself allocates nothing
        // once the lists have grown to the live-wire count.
        try self.borrow_scratch.resize(self.allocator, n);
        for (self.conn_scratch.items, 0..) |wire, i| self.borrow_scratch.items[i] = &wire.link.stream.conn;
        const idx = try net.waitAnyReadable(
            self.borrow_scratch.items,
            self.poll_scratch.items,
            self.clampTimeoutToPendingOpens(timeout_ms),
            self.extra_fd_scratch.items,
        ) orelse return null;
        if (idx < n) return .{ .wire = self.conn_scratch.items[idx] };
        const extra = idx - n;
        if (extra < self.residents.items.len) return .{ .resident = extra };
        const connect_index = extra - self.residents.items.len;
        if (connect_index < self.connect_scratch.items.len)
            return .{ .stream_connect = self.connect_scratch.items[connect_index] };
        return null;
    }

    /// Drain and answer one resident's ready records: connects release their
    /// awaiting dials, readable connections feed the core, writable ones
    /// resume their retained outbound, and closed ones close their wires.
    /// `own` carries the calling wait's session so a sibling's
    /// dispatch refusal closes the sibling instead of aborting the caller,
    /// exactly as `feedReadable` holds for stream wires.
    fn serviceResident(self: *HostRuntime, resident_index: usize, own: ?*driver_core.HostSession) !usize {
        const resident = self.residents.items[resident_index].resident;
        var own_fed: usize = 0;
        const events = try resident.drainReady(&self.event_scratch);
        for (events) |event| own_fed += try self.handleResidentEvent(resident_index, event, own);
        return own_fed;
    }

    fn handleResidentEvent(
        self: *HostRuntime,
        resident_index: usize,
        event: net.multiplexed_resident.ReadyEvent,
        own: ?*driver_core.HostSession,
    ) !usize {
        const er = net.multiplexed_resident;
        if (event.events & er.ev_accept != 0) {
            const listener = self.resident_listeners.get(.{
                .resident = resident_index,
                .route = event.subject,
            }) orelse return 0;
            var conn = try listener.listener.finishAccept() orelse return 0;
            defer conn.deinit();
            // The provider already removed this connection from its accept
            // queue. An over-limit arrival closes here without a session or
            // retained wire buffers. Level-shaped readiness brings the next
            // queued accept back through a later step, preserving fairness.
            if (!self.pendingOpenSlotAvailable()) return 0;
            try self.startAcceptedResidentConn(
                resident_index,
                &conn,
                listener.transport,
                listener.observation,
            );
            return 0;
        }
        if (event.events & er.ev_connect != 0) {
            const dialer = self.residents.items[resident_index].resident.dialer() orelse return error.ProviderContract;
            const request_key = ResidentRequestKey{ .resident = resident_index, .request = event.subject };
            if (self.pending_resident_dials.get(request_key)) |wait| {
                wait.ready = true;
            } else if (self.pendingOpenByRequest(resident_index, event.subject)) |row| {
                try self.adoptPendingResidentConnect(resident_index, row);
            } else {
                // The awaiting frame unwound (budget expiry, caller error)
                // before the connect completed; release the resident's half.
                dialer.cancelConnect(event.subject);
            }
            return 0;
        }
        const wire = self.resident_wires.get(.{
            .resident = resident_index,
            .conn = event.subject,
        }) orelse return 0;
        if (wire.closed) return 0;
        if (event.events & er.ev_writable != 0) {
            self.writeOutbound(wire) catch self.closeWire(wire);
            if (wire.closed) return 0;
        }
        var own_fed: usize = 0;
        if (event.events & er.ev_readable != 0) {
            const for_own = own != null and wire.session == own.?;
            switch (try self.feedReadable(wire, own)) {
                .fed => |fed| own_fed = if (for_own) fed else 0,
                .closed => return 0,
            }
        }
        if (event.events & er.ev_closed != 0) self.closeWire(wire);
        return own_fed;
    }

    /// Adopt one connection claimed from a resident accept queue and park its
    /// CapTP handshake under the same observer path as a stream listener.
    fn startAcceptedResidentConn(
        self: *HostRuntime,
        resident_index: usize,
        conn: *net.multiplexed_resident.ClaimedConnection,
        transport: []const u8,
        observation: SessionOpenObservation,
    ) !void {
        var admission = try self.acquireOpenAdmission();
        errdefer admission.release();
        const observer = observation.observer;
        try observer.reserve(observer.ctx, observation.tag);
        errdefer observer.release(observer.ctx, observation.tag);
        const resident = self.residents.items[resident_index].resident;
        const session = try self.core.openAcceptedAdvertised(transport);
        errdefer {
            self.dropWire(session.peer_id);
            self.core.releaseSession(session) catch {};
        }
        const row = try self.allocator.create(PendingOpen);
        errdefer self.allocator.destroy(row);
        try self.pending_opens.ensureUnusedCapacity(self.allocator, 1);
        if (try resident.connRemoteKey(conn.borrow())) |key| {
            session.served.port.peer.bindVerifiedChannelKey(key);
        }
        try self.adoptResidentConn(session, resident_index, conn);
        row.* = .{
            .admission = admission,
            .session = session,
            .stage = .handshake,
            .deadline_ms = self.handshakeDeadline(),
            .outcome = .{ .accept = observation },
        };
        self.pending_opens.appendAssumeCapacity(row);
        const wire = self.wires.get(session.peer_id).?;
        self.writeOutbound(wire) catch self.closeWire(wire);
    }

    /// The resident spelling of `readAndFeed`: drain `try_read` until the
    /// window refuses, feeding each chunk. Looping to `would_block` matters —
    /// a drained ready record is consumed, so bytes left unread here would
    /// wait for the *next* transition instead of the next wait.
    fn residentReadAndFeed(self: *HostRuntime, wire: *Wire) !usize {
        const rl = &wire.link.resident;
        const resident = self.residents.items[rl.index].resident;
        var total: usize = 0;
        while (true) {
            const got = resident.tryRead(rl.conn, rl.read_buf);
            if (got == net.multiplexed_resident.would_block) return total;
            if (got == 0) {
                return if (wire.session.feed_tail.isActive()) error.TruncatedFrame else error.EndOfStream;
            }
            if (got < 0) return error.ConnectionLost;
            if (@as(usize, @intCast(got)) > rl.read_buf.len) return error.ConnectionLost;
            const chunk = rl.read_buf[0..@intCast(got)];
            self.core.feedBytes(wire.session, chunk) catch |err| {
                self.drainActions() catch {};
                self.writeOutbound(wire) catch {};
                self.closeWire(wire);
                return net.classifyApplyError(err);
            };
            total += chunk.len;
        }
    }

    /// One raw read off `wire`; the core owns outer framing and its tail.
    fn readAndFeed(self: *HostRuntime, wire: *Wire) !usize {
        const r = wire.link.stream.conn.r;
        if (r.bufferedLen() == 0) {
            r.fillMore() catch |err| switch (err) {
                error.EndOfStream => return if (wire.session.feed_tail.isActive()) error.TruncatedFrame else error.EndOfStream,
                error.ReadFailed => return error.ConnectionLost,
            };
        }
        const chunk = r.buffered();
        self.core.feedBytes(wire.session, chunk) catch |err| {
            // The core projected a typed op:abort for a session-authority
            // refusal; write it (the flush action is queued) and surface the
            // pump vocabulary the borrowing tier speaks, so `serve` and the
            // blocking waits see `ProtocolAbort`, not the raw refusal.
            r.toss(chunk.len);
            self.drainActions() catch {};
            self.writeOutbound(wire) catch {};
            self.closeWire(wire);
            return net.classifyApplyError(err);
        };
        r.toss(chunk.len);
        return chunk.len;
    }

    /// Pump until `flag` fires, under `budget` — the settle wait every view
    /// verb blocks through. The capture listener sets `flag` while a feed
    /// dispatches; the pump observes it at the next drain boundary.
    pub fn pumpUntilFlag(self: *HostRuntime, session: *driver_core.HostSession, flag: *const bool, budget: Budget) !void {
        self.enterDriver();
        defer self.leaveDriver();
        var probe = FlagProbe{ .session = session, .flag = flag };
        try self.pumpUntilProbe(&probe, budget);
    }

    const FlagProbe = struct {
        session: *driver_core.HostSession,
        flag: *const bool,
        fn done(self: *FlagProbe) bool {
            return self.flag.*;
        }
        fn resumeSkip(self: *FlagProbe) ?*driver_core.HostSession {
            _ = self;
            return null;
        }
    };

    /// One bounded pump step for a view's `stepReadable`/`serve` loops: drain
    /// actions, wait up to `timeout_ms`, feed one readable wire. Reports
    /// progress from `session`'s perspective.
    pub fn stepSession(self: *HostRuntime, session: *driver_core.HostSession, timeout_ms: i32) !?net.Progress {
        self.enterDriver();
        defer self.leaveDriver();
        // Every wait on this face applies the mailbox first; `serve` runs
        // this one rather than `pumpUntilProbe`, and a settle must not wait
        // for whichever loop the caller happened to pick.
        try self.applySettleMailbox();
        try self.resumeFeedTails(null);
        try self.drainActions();
        try self.advancePendingOpens();
        const session_wire = self.wires.get(session.peer_id) orelse return .closed;
        if (session_wire.closed) return .closed;
        const source = try self.waitAnySource(timeout_ms, false) orelse return null;
        switch (source) {
            .wire => |wire| {
                const fed_target = wire.session == session;
                switch (try self.feedReadable(wire, session)) {
                    .fed => |fed| {
                        try self.drainActions();
                        return if (fed_target) .{ .received = fed } else .idle;
                    },
                    .closed => return if (fed_target) .closed else .idle,
                }
            },
            .resident => |index| {
                const fed = try self.serviceResident(index, session);
                try self.drainActions();
                if (session_wire.closed) return .closed;
                return if (fed > 0) .{ .received = fed } else .idle;
            },
            .stream_connect => |row| {
                try self.adoptPendingStreamConnect(row);
                try self.drainActions();
                return .idle;
            },
        }
    }

    /// One host-wide pump step (ADR-0112): apply the settle mailbox, drain
    /// actions, wait up to `timeout_ms` for any ready source, service it,
    /// and drain again. Null when the wait ended with nothing to service (a
    /// timeout or a wake); `.idle` when a source was serviced without a
    /// counted frame — a resident feed reports through the sinks rather than
    /// the count here, and a wire closing surfaces through the close
    /// observer, never as an error of the step. A host with no source yet is
    /// simply parked on `timeout_ms`. When the step leaves userland-buffered
    /// bytes unread (a poll cannot see them), it posts the readiness wake so
    /// a parked embedder re-enters instead of stranding them.
    pub fn stepAny(self: *HostRuntime, timeout_ms: i32) !?net.Progress {
        self.enterDriver();
        defer self.leaveDriver();
        try self.applySettleMailbox();
        try self.resumeFeedTails(null);
        try self.drainActions();
        try self.advancePendingOpens();
        const source = try self.waitAnySource(timeout_ms, true) orelse {
            // The park may have ended on a staged dial's clamped deadline;
            // settle it now rather than a step later.
            try self.advancePendingOpens();
            self.nudgeIfWorkRemains();
            return null;
        };
        var progress: net.Progress = .idle;
        switch (source) {
            .wire => |wire| switch (try self.feedReadable(wire, null)) {
                .fed => |fed| progress = .{ .received = fed },
                .closed => {},
            },
            .resident => |index| _ = try self.serviceResident(index, null),
            .stream_connect => |row| try self.adoptPendingStreamConnect(row),
        }
        try self.drainActions();
        try self.advancePendingOpens();
        self.nudgeIfWorkRemains();
        return progress;
    }

    /// The self-wake nudge behind `stepAny`: a stream wire holding raw bytes
    /// in its userland read buffer is work no kernel set reports, so leave
    /// the armed readiness set readable rather than parking over it.
    fn nudgeIfWorkRemains(self: *HostRuntime) void {
        const rs = if (self.ready_set) |*r| r else return;
        var it = self.wires.valueIterator();
        while (it.next()) |wire| {
            if (wire.*.closed) continue;
            // Paused inbound — a held feed tail, or a sealed session's staged
            // channel bytes — already left the kernel too; the next step's
            // resume sweep consumes it, so the wake must fire for it as well.
            if (wire.*.session.pausedInboundPending()) return rs.postWake();
            switch (wire.*.link) {
                .stream => |*sl| if (sl.conn.hasBufferedRaw()) return rs.postWake(),
                .resident => {},
            }
        }
    }
};
