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
pub const default_listener_setup_ms: i64 = 10_000;
const settle_mailbox = @import("settle_mailbox.zig");

const crypto = foundation.crypto;

const Budget = driver_core.Budget;
const Error = driver_core.Error;
const AdmissionError = Error || error{ProviderContract};
const Identity = driver_core.Identity;
const OperationFailure = @import("operation_failure.zig").OperationFailure;

/// Expand a provider's portable locator claim at the driver authority that
/// composes transport realization with Host semantics. Known transports gain
/// their canonical dial metadata here; extensions retain their declared
/// metadata after symbol validation.
fn canonicalProviderProfile(profile: model.transport.Metadata) !model.transport.Metadata {
    if (model.transport.parseKnown(profile.symbol) == null) {
        model.transport.validateSymbol(profile.symbol) catch return error.InvalidTransportName;
        return profile;
    }
    return model.transport.metadataFromClaim(
        profile.symbol,
        profile.designator_scheme,
        profile.sealed_channel,
    ) catch |err| switch (err) {
        error.InvalidTransportSymbol => error.InvalidTransportName,
        error.TransportSemanticsConflict => error.TransportSemanticsConflict,
    };
}

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
    /// Installed provider packages and their configuration/lifetime owner.
    /// Package overlap and idempotency are Runtime composition policy; an ABI
    /// adapter supplies only the opaque comparison and release effects.
    provider_packages: std.ArrayListUnmanaged(InstalledProviderPackage) = .empty,
    /// Canonical transport profiles with a listener pending or active. Keys
    /// borrow the provider registry, which outlives this map. The Runtime owns
    /// occupancy; adapter listener ids are only handles onto that authority.
    listener_profiles: std.StringHashMapUnmanaged(void) = .{},
    /// Activated listeners owned by this Runtime, keyed by the observer tag
    /// their accepted sessions report. Keeping the transport handles here
    /// makes Runtime close, readiness service, and accept admission driver
    /// facts instead of adapter choreography.
    active_listeners: std.AutoHashMapUnmanaged(u64, ActiveListener) = .empty,
    opts: Options,
    wires: std.AutoHashMapUnmanaged(engine.PeerId, *Wire) = .{},
    /// Wires whose transport is not yet closed. Closed wire rows remain in
    /// `wires` until explicit session release, so close completion cannot use
    /// map cardinality without conflating shutdown with memory lifetime.
    open_wire_count: usize = 0,
    /// Application-visible owning session handles. Runtime retirement keeps
    /// their wires and Host active, then begins cancel close when the final
    /// handle releases. Internal redeem wires do not extend this ownership
    /// barrier on their own.
    claimed_session_handles: usize = 0,
    /// Listener admission is sealed while claimed sessions retain this
    /// Runtime. Distinct from Host finish: sessions remain fully active.
    retiring: bool = false,
    /// Callback-time retirement seals admission immediately; listener I/O and
    /// pending setup cancellation wait for the enclosing step to unwind.
    retirement_effects_pending: bool = false,
    /// A callback-time close has already sealed core admission; listener and
    /// transport effects run when the enclosing driver step regains control.
    close_effects_pending: bool = false,
    /// Session wrappers dropped from inside a behavior callback transfer their
    /// release request here. The wrappers themselves carry the intrusive
    /// nodes, so this rare path allocates nothing and keeps every runtime lease
    /// alive until the outermost driver call reaches quiescence.
    deferred_session_releases: ?*DeferredSessionRelease = null,
    draining_session_releases: bool = false,
    /// Runtime observers run inside the pump, after core callbacks have
    /// unwound but before the pump may stop borrowing its current rows. An
    /// owning Session may transfer cleanup through `deferSessionRelease`;
    /// every direct Runtime reentry remains refused until the observer returns.
    observer_callback_depth: usize = 0,
    /// A failure crossed a Runtime callback or post-commit boundary that could
    /// not return it directly. Detection may happen in an ABI adapter or in
    /// Runtime cleanup, but terminality is Runtime policy and every later
    /// application operation observes this one sticky concrete cause.
    terminal_failure: ?OperationFailure = null,
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
    dial_scratch: std.ArrayListUnmanaged(*PendingOpen) = .empty,
    /// Staged stream listener setups mirrored into each wait. Rows are pinned
    /// for the same reason as pending opens: completion callbacks may mutate
    /// the owning list.
    listen_scratch: std.ArrayListUnmanaged(*PendingListener) = .empty,
    /// Active stream listeners mirrored into one readiness wait. Rows live in
    /// `active_listeners` and remain stable because listener mutation never
    /// occurs during the wait.
    active_listener_scratch: std.ArrayListUnmanaged(*TransportListener) = .empty,
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
    /// Listener construction that waits on provider progress. Completed
    /// listeners never remain here: finish transfers ownership to the
    /// observer, while cancellation and failure consume the attempt.
    pending_listeners: std.ArrayListUnmanaged(*PendingListener) = .empty,
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
    driver_depth: usize = 0,

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
        /// Wall-clock deadline for listener construction that waits on an
        /// external daemon, rendezvous registration, or scheduler.
        listener_setup: Budget = .{ .ms = default_listener_setup_ms },
        /// Wall-clock deadline for blocking answer-waits after the session
        /// is open (`settle` / `call` / `fetch`).
        settle: Budget,
        /// Recipient for failures produced only by implicit destruction, where
        /// no return value survives. Explicit close/deinit barriers return the
        /// same `OperationFailure` instead and never call this observer.
        unhandled_failure: ?FailureObserver = null,
    };

    pub const FailureObserver = struct {
        ctx: *anyopaque,
        report: *const fn (ctx: *anyopaque, failure: OperationFailure) void,
    };

    /// Runtime-only controls for adopting an existing byte-fed Host. Core
    /// protocol and frame settings come from that Host, so an adapter cannot
    /// accidentally construct a second configuration authority.
    pub const AdoptionOptions = struct {
        wire_buffer_bytes: usize = default_wire_buffer_bytes,
        max_pending_opens: usize = default_max_pending_opens,
        handshake: Budget,
        listener_setup: Budget = .{ .ms = default_listener_setup_ms },
        settle: Budget,
    };

    /// What an owning close does with work admitted before its barrier. A
    /// finite finish budget starts when the first finish begins; repeated
    /// finish calls observe that same deadline. Cancel may escalate finish.
    pub const PendingWork = driver_core.PendingWork;
    pub const CloseOutcome = driver_core.CloseOutcome;

    pub const DeferredSessionRelease = struct {
        session: *driver_core.HostSession,
        ctx: *anyopaque,
        complete: *const fn (ctx: *anyopaque) bool,
        next: ?*DeferredSessionRelease = null,
        queued: bool = false,
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
        /// The installed close observer reserved publication before this
        /// session became visible. Close consumes it; release-before-close
        /// gives it back.
        close_event_reserved: bool = false,
        /// One owning `driver.Session` has claimed release authority for this
        /// wire. Kept beside `closed` so the two booleans consume existing
        /// struct padding rather than another per-wire word.
        session_handle_claimed: bool = false,
        /// Whether inbound application frames may dispatch. True for every
        /// wire a blocking caller drives; the event-surfacing loop archive
        /// marks a session it publishes as an event unattended at open, and
        /// `attendSession` turns delivery on once the embedder announces it
        /// is serving — the loop tier's spelling of the byte-fed contract
        /// that `serve()` is what resumes frames held behind the handshake.
        /// While false, a stream wire's socket leaves the readiness set and
        /// the wait set, so unread bytes wait in the kernel (a closed wire's
        /// fd is removed for the same spin-forever reason); a resident link's
        /// pushed records absorb into the session's own feed tail.
        attended: bool = true,

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
            /// Inbound bytes read while the wire was unattended. A resident
            /// pushes records that cannot wait in a kernel buffer, so they
            /// park here in arrival order and `attendSession` replays them
            /// through the ordinary feed. Bounded by
            /// `unattended_parked_cap_bytes`; a partner that floods before
            /// the embedder serves is closed, not buffered without bound.
            parked: std.ArrayListUnmanaged(u8) = .empty,

            pub const PendingOut = struct {
                frame: foundation.Frame,
                prefix: [foundation.stream_framing.prefix_buffer_bytes]u8,
                prefix_len: usize,
                offset: usize,
            };
        };
    };

    /// The most inbound a resident link parks for a session the embedder has
    /// not yet attended. Pipelined first frames from a legitimate partner are
    /// small (a fetch, a give); this bound exists so a partner cannot spend
    /// the setup window growing heap nobody asked for. A stream link parks
    /// nothing: its bytes wait in the kernel socket buffer instead.
    pub const unattended_parked_cap_bytes: usize = 64 * 1024;

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
        observation: SessionAcceptObservation,
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
            observation: ?SessionAcceptObservation = null,
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

        /// Consume a stream-backed listener for the native blocking Server
        /// face. Multiplexed listeners remain HostRuntime-owned because their
        /// accept routing is resident-wide.
        fn takeStream(self: *TransportListener) ?net.netlayer.Listener {
            return switch (self.source) {
                .stream => |stream| blk: {
                    const listener = stream.handle;
                    self.* = undefined;
                    break :blk listener;
                },
                .resident => null,
            };
        }
    };

    pub const ListenerStopOutcome = struct {
        found: bool,
        failure: ?OperationFailure = null,
    };

    const ActiveListener = struct {
        transport: TransportListener,
        locator: model.PeerLocator,
    };

    /// A complete, caller-inspectable locator prepared by the driver but not
    /// yet published. Commit consumes it; deinit is the transactional unwind.
    pub const PreparedListenerLocator = struct {
        value: model.PeerLocator,

        pub fn deinit(self: *PreparedListenerLocator, allocator: std.mem.Allocator) void {
            model.freePeerLocator(allocator, self.value);
            self.* = undefined;
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

    pub const ProviderPackageOwner = struct {
        ctx: *anyopaque,
        same_configuration: *const fn (installed: *anyopaque, candidate: *anyopaque) anyerror!bool,
        release: *const fn (ctx: *anyopaque) ?OperationFailure,
    };

    pub const ProviderPackage = struct {
        registrations: []const ProviderRegistration,
        owner: ProviderPackageOwner,
    };

    const InstalledProviderPackage = struct {
        profiles: []model.transport.Metadata,
        owner: ProviderPackageOwner,

        fn overlaps(self: InstalledProviderPackage, candidate: []const ProviderRegistration) !bool {
            for (self.profiles) |installed| for (candidate) |registration| {
                const profile = try canonicalProviderProfile(registration.profile());
                if (std.mem.eql(u8, installed.symbol, profile.symbol)) return true;
            };
            return false;
        }

        fn hasSameProfiles(self: InstalledProviderPackage, candidate: []const ProviderRegistration) !bool {
            if (self.profiles.len != candidate.len) return false;
            for (self.profiles) |installed| {
                for (candidate) |registration| {
                    if (installed.eql(try canonicalProviderProfile(registration.profile()))) break;
                } else return false;
            }
            return true;
        }

        fn deinit(self: *InstalledProviderPackage, allocator: std.mem.Allocator) ?OperationFailure {
            allocator.free(self.profiles);
            const failure = self.owner.release(self.owner.ctx);
            self.* = undefined;
            return failure;
        }
    };

    const OpenAdmissionAuthority = enum {
        application,
        pending_dial,
    };

    /// How many ready records one drain pass claims before looping.
    const resident_event_batch = 32;

    /// Where a readiness wait's report came from: a stream wire's own
    /// descriptor, or one multiplexed resident's descriptor (whose drained
    /// records the caller services).
    const ReadySource = union(enum) {
        wire: *Wire,
        resident: usize,
        stream_dial: *PendingOpen,
        stream_listen: *PendingListener,
        stream_accept: *TransportListener,
    };

    /// A blocking convenience parks only while the barrier it is driving
    /// still needs external progress. Ordinary `stepAny` has no such goal.
    const StepGoal = union(enum) {
        none,
        host_close,
        session_close: *const driver_core.HostSession,

        fn reached(self: StepGoal, runtime: *const HostRuntime) bool {
            return switch (self) {
                .none => false,
                .host_close => runtime.closeOutcome() != .pending,
                .session_close => |session| runtime.sessionCloseOutcome(session) != .pending,
            };
        }
    };

    /// Which external effects an action drain may execute. A terminal
    /// provider failure still permits resource-release callbacks, but never
    /// another operational callback into the failed provider surface.
    const ExternalEffectMode = enum { operational, cleanup_only };

    /// A taker for application-visible completions the native face would
    /// otherwise free (ADR-0112). `take` returns true when it took ownership
    /// of the action — payload and all, freed later through
    /// `Host.freeAction` — and false to leave the free to the drain. Called
    /// on the driving thread, inside the action drain; it must not re-enter
    /// the host. `reserve` runs while the completion is still parked; `take`
    /// consumes that reservation, while a false return gives it to `release`.
    pub const CompletionSink = struct {
        ctx: *anyopaque,
        reserve: *const fn (ctx: *anyopaque) anyerror!void = reserveNothing,
        release: *const fn (ctx: *anyopaque) void = releaseNothing,
        take: *const fn (ctx: *anyopaque, action: driver_core.HostAction) bool,
    };

    /// Told once per wire, on the driving thread, at the moment the pump
    /// marks it closed. `failure` is null for clean EOF or an owner-requested
    /// close; otherwise it preserves the driver's typed classification and
    /// concrete Zig cause. The session pointer and failure are borrowed for
    /// the call. Dropping an owning `Session` is supported and defers its
    /// release to the outer driver boundary; direct Runtime reentry is refused.
    /// Wire adoption calls `reserve` before it commits. Close consumes that
    /// seat through `closed`; release-before-close returns it through `release`.
    pub const CloseObserver = struct {
        ctx: *anyopaque,
        reserve: *const fn (ctx: *anyopaque) anyerror!void = reserveNothing,
        release: *const fn (ctx: *anyopaque) void = releaseNothing,
        closed: *const fn (
            ctx: *anyopaque,
            session: *driver_core.HostSession,
            failure: ?OperationFailure,
        ) void,
    };

    /// A staged session-open outcome seam (ADR-0112). Before committing an
    /// open, the host calls `reserve`; a synchronous refusal calls `release`,
    /// while successful admission transfers that reservation to exactly one
    /// `opened` or `failed` callback. The default admission callbacks are
    /// no-ops for in-process observers; queue-backed embeddings override them
    /// so outcome publication cannot allocate after commitment.
    ///
    /// `opened` hands the caller its now-open session; if it refuses ownership,
    /// the Runtime unwinds that unexposed session and calls `failed` with the
    /// exact refusal. Otherwise `failed` reports an earlier open refusal after
    /// the session was already unwound. Callbacks run on the
    /// driving thread, inside the pump, and must not re-enter the host. The
    /// context and functions must outlive the operation or active listener
    /// that retains them.
    pub const SessionOpenObserver = struct {
        ctx: *anyopaque,
        reserve: *const fn (ctx: *anyopaque, tag: u64) anyerror!void = reserveNoop,
        release: *const fn (ctx: *anyopaque, tag: u64) void = releaseNoop,
        abandoned: *const fn (ctx: *anyopaque, tag: u64) void = releaseNoop,
        opened: *const fn (ctx: *anyopaque, tag: u64, session: *driver_core.HostSession) anyerror!void,
        failed: *const fn (ctx: *anyopaque, tag: u64, failure: OperationFailure) void,

        fn reserveNoop(_: *anyopaque, _: u64) anyerror!void {}
        fn releaseNoop(_: *anyopaque, _: u64) void {}
    };

    /// Outcome owner for connections admitted by a listener. A failed
    /// handshake is listener hygiene, not an application operation failure,
    /// so the Runtime abandons the reservation without exposing a failure
    /// callback. Only a completed handshake becomes observable.
    pub const SessionAcceptObserver = struct {
        ctx: *anyopaque,
        reserve: *const fn (ctx: *anyopaque, tag: u64) anyerror!void = reserveNoop,
        release: *const fn (ctx: *anyopaque, tag: u64) void = releaseNoop,
        abandoned: *const fn (ctx: *anyopaque, tag: u64) void = releaseNoop,
        opened: *const fn (ctx: *anyopaque, tag: u64, session: *driver_core.HostSession) anyerror!void,
        failed: *const fn (ctx: *anyopaque, tag: u64, failure: OperationFailure) void,

        fn reserveNoop(_: *anyopaque, _: u64) anyerror!void {}
        fn releaseNoop(_: *anyopaque, _: u64) void {}
    };

    /// Outcome owner for one generic listener-construction operation. The
    /// runtime retains this value only for staged setup; bounded setup calls
    /// it before `startListener` returns. `ready` takes listener ownership.
    pub const ListenerObserver = struct {
        ctx: *anyopaque,
        reserve: *const fn (ctx: *anyopaque, tag: u64) anyerror!void = reserveNoop,
        release: *const fn (ctx: *anyopaque, tag: u64) void = releaseNoop,
        abandoned: *const fn (ctx: *anyopaque, tag: u64) void = releaseNoop,
        ready: *const fn (ctx: *anyopaque, tag: u64, listener: TransportListener) void,
        failed: *const fn (ctx: *anyopaque, tag: u64, failure: OperationFailure) void,

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

    const SessionAcceptObservation = struct {
        observer: SessionAcceptObserver,
        tag: u64,
    };

    const OpenAdmission = struct {
        runtime: *HostRuntime,
        pending_work: ?driver_core.Host.PendingWorkLease,

        fn release(self: *OpenAdmission) void {
            std.debug.assert(self.runtime.open_admissions != 0);
            self.runtime.open_admissions -= 1;
            if (self.pending_work) |*lease| lease.complete();
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
        /// A bound wire can fail before the pending-open sweep publishes its
        /// outcome. Keep that exact cause on the short-lived operation row so
        /// a failed dial/accept does not collapse into `ConnectionClosed`.
        close_cause: ?OperationFailure = null,

        const Stage = union(enum) {
            /// Per-stream dial in flight, awaiting its own readiness fd.
            stream_dial: net.netlayer.DialAttempt,
            /// Resident dial in flight, awaiting its `ev_connect` record.
            resident_dial: struct {
                resident: usize,
                attempt: net.multiplexed_resident.DialAttempt,
            },
            /// Wire bound; the CapTP handshake advancing through the pump.
            handshake,
        };
        const Outcome = union(enum) {
            /// An application-staged open: report through its operation
            /// observer, carrying this tag.
            operation: SessionOpenObservation,
            /// A redeem dial answering a core `dial` action: report through
            /// `exporterDialed` / `dialFailed`.
            redeem: engine.Node.PendingId,
            /// A staged accept: report through the accept observer,
            /// carrying the caller's listener tag.
            listener_accept: SessionAcceptObservation,
        };
    };

    const PendingListener = struct {
        stage: union(enum) {
            stream: net.netlayer.ListenAttempt,
            resident: struct {
                attempt: net.MultiplexedResident.ListenAttempt,
                resident: usize,
            },
        },
        transport: []const u8,
        designator_scheme: net.netlayer.DesignatorScheme,
        deadline_ms: ?i64,
        observation: ListenerObservation,
    };

    const ListenerObservation = struct {
        observer: ListenerObserver,
        tag: u64,
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
    ) (std.mem.Allocator.Error || Error || driver_core.HostInitError)!HostRuntime {
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
        var core_opts = driver_core.Host.Options{
            .codec = opts.codec,
            .captp_version = opts.captp_version,
        };
        core_opts.limits.max_frame_bytes = opts.frame_cap;
        core.* = try driver_core.Host.init(allocator, seed, session_root, core_opts);
        var runtime = HostRuntime{
            .allocator = allocator,
            .io = io,
            .core = core,
            .opts = opts,
        };
        errdefer runtime.deinit();
        runtime.registerNetlayers(netlayers) catch |err| switch (err) {
            // Initial construction has not exposed or armed a readiness set,
            // so provider registration cannot perform a kernel-set update.
            error.ReadinessUpdateFailed => unreachable,
            else => return @errorCast(err),
        };
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
        adoption: AdoptionOptions,
    ) (std.mem.Allocator.Error || Error || driver_core.Host.RuntimeAdoptionError)!HostRuntime {
        const opts = Options{
            .frame_cap = core.opts.limits.max_frame_bytes,
            .wire_buffer_bytes = adoption.wire_buffer_bytes,
            .max_pending_opens = adoption.max_pending_opens,
            .codec = core.opts.codec,
            .captp_version = core.opts.captp_version,
            .handshake = adoption.handshake,
            .listener_setup = adoption.listener_setup,
            .settle = adoption.settle,
            .unhandled_failure = null,
        };
        if (opts.frame_cap == 0 or opts.wire_buffer_bytes == 0 or opts.max_pending_opens == 0)
            return Error.InvalidBufferConfiguration;
        try core.checkRuntimeAdoption();
        var runtime = HostRuntime{
            .allocator = allocator,
            .io = io,
            .core = core,
            .opts = opts,
            .owns_core = false,
        };
        errdefer runtime.deinitAfterFailedAdoption();
        runtime.registerNetlayers(netlayers) catch |err| switch (err) {
            // Initial construction has not exposed or armed a readiness set,
            // so provider registration cannot perform a kernel-set update.
            error.ReadinessUpdateFailed => unreachable,
            else => return @errorCast(err),
        };
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
        self.addProvidersAfterAdmission(registrations, resident_indices) catch |err| switch (err) {
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
    /// Returns false when an equivalent package is already installed; the
    /// caller retains the candidate owner in that case. A true result consumes
    /// the owner until Runtime teardown.
    pub fn addProviderPackage(
        self: *HostRuntime,
        package: ProviderPackage,
        resident_indices: []?usize,
    ) !bool {
        try self.admitApplicationOperation();
        if (package.registrations.len == 0 or resident_indices.len != package.registrations.len)
            return error.InvalidProviderPackage;

        for (self.provider_packages.items) |installed| {
            if (!try installed.overlaps(package.registrations)) continue;
            if (!try installed.hasSameProfiles(package.registrations)) return error.ProviderConfigurationConflict;
            if (try installed.owner.same_configuration(installed.owner.ctx, package.owner.ctx)) return false;
            return error.ProviderConfigurationConflict;
        }

        const profiles = try self.allocator.alloc(model.transport.Metadata, package.registrations.len);
        errdefer self.allocator.free(profiles);
        try self.provider_packages.ensureUnusedCapacity(self.allocator, 1);
        try self.addProvidersAfterAdmission(package.registrations, resident_indices);
        for (package.registrations, profiles) |registration, *profile| {
            profile.* = try canonicalProviderProfile(registration.profile());
            profile.symbol = self.transportName(profile.symbol).?;
        }
        self.provider_packages.appendAssumeCapacity(.{
            .profiles = profiles,
            .owner = package.owner,
        });
        return true;
    }

    pub fn addProviders(self: *HostRuntime, registrations: []const ProviderRegistration, resident_indices: []?usize) !void {
        try self.admitApplicationOperation();
        try self.addProvidersAfterAdmission(registrations, resident_indices);
    }

    fn addProvidersAfterAdmission(
        self: *HostRuntime,
        registrations: []const ProviderRegistration,
        resident_indices: []?usize,
    ) !void {
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
            const profile = try canonicalProviderProfile(registration.profile());
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
        errdefer for (readiness_fds[0..readiness_added]) |fd| self.removeReadyFd(fd);
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

    /// Begin one listener construction through the generic runtime seam.
    /// Bounded providers may call `ready` before this returns; providers that
    /// wait on external progress retain one pending attempt driven by
    /// `stepAny`. Once observation is reserved, every provider outcome is
    /// reported exactly once through `ready` or `failed`.
    pub fn startListener(
        self: *HostRuntime,
        transport: []const u8,
        requested_designator: []const u8,
        options: net.OperationOptions,
        tag: u64,
        observer: ListenerObserver,
    ) !void {
        try self.admitApplicationOperation();
        const provider = self.providerFor(transport) orelse return Error.UnknownTransport;
        switch (provider.source) {
            .stream => |nl| if (!nl.supportsListen()) return Error.UnknownTransport,
            .resident => |index| if (self.residents.items[index].resident.acceptor() == null)
                return Error.UnknownTransport,
        }
        try observer.reserve(observer.ctx, tag);
        var observation_owned = true;
        errdefer if (observation_owned) observer.release(observer.ctx, tag);
        try self.reserveListenerProfile(provider.transport);
        var profile_owned = true;
        errdefer if (profile_owned) self.releaseListenerProfile(provider.transport);
        const observation = ListenerObservation{ .observer = observer, .tag = tag };

        switch (provider.source) {
            .stream => |nl| {
                const config = net.netlayer.ListenConfig{
                    .designator = requested_designator,
                    .identity = self.core.node.publicKey(),
                    .options = options,
                };
                const result = switch (nl.listen(self.allocator, config)) {
                    .admitted => |result| result,
                    .failed => |failure| {
                        self.releaseListenerProfile(provider.transport);
                        profile_owned = false;
                        observation_owned = false;
                        self.reportObservedFailureChain(observer, tag, failure);
                        return;
                    },
                };
                switch (result) {
                    .ready => |listener| {
                        profile_owned = false;
                        observation_owned = false;
                        observer.ready(observer.ctx, tag, .{
                            .transport = provider.transport,
                            .designator_scheme = nl.designatorScheme(),
                            .source = .{ .stream = .{ .handle = listener } },
                        });
                        return;
                    },
                    .pending => {},
                }
                var attempt = result.pending;
                const fd = attempt.readinessFd();
                if (fd < 0 or self.descriptorInUse(fd)) {
                    self.releaseListenerProfile(provider.transport);
                    profile_owned = false;
                    observation_owned = false;
                    self.reportListenAttemptFailure(observer, tag, &attempt, if (fd < 0)
                        error.ReadinessUnavailable
                    else
                        error.ReadinessDescriptorConflict);
                    return;
                }
                const row = self.allocator.create(PendingListener) catch |err| {
                    self.releaseListenerProfile(provider.transport);
                    profile_owned = false;
                    observation_owned = false;
                    self.reportListenAttemptFailure(observer, tag, &attempt, err);
                    return;
                };
                self.pending_listeners.ensureUnusedCapacity(self.allocator, 1) catch |err| {
                    self.allocator.destroy(row);
                    self.releaseListenerProfile(provider.transport);
                    profile_owned = false;
                    observation_owned = false;
                    self.reportListenAttemptFailure(observer, tag, &attempt, err);
                    return;
                };
                if (self.ready_set) |*rs| rs.add(fd) catch |err| {
                    self.allocator.destroy(row);
                    self.releaseListenerProfile(provider.transport);
                    profile_owned = false;
                    observation_owned = false;
                    self.reportListenAttemptFailure(observer, tag, &attempt, err);
                    return;
                };
                row.* = .{
                    .stage = .{ .stream = attempt.take() },
                    .transport = provider.transport,
                    .designator_scheme = nl.designatorScheme(),
                    .deadline_ms = self.listenerSetupDeadline(),
                    .observation = observation,
                };
                self.pending_listeners.appendAssumeCapacity(row);
                profile_owned = false;
                observation_owned = false;
            },
            .resident => |index| {
                const runtime = &self.residents.items[index];
                const acceptor = runtime.resident.acceptor().?;
                const route_id = mintRuntimeId(&runtime.next_listener_route) catch |err| {
                    self.releaseListenerProfile(provider.transport);
                    profile_owned = false;
                    observation_owned = false;
                    self.reportObservedFailure(observer, tag, err);
                    return;
                };
                const host_designator = self.core.node.publicKey().toDesignator();
                const effective_designator: []const u8 = if (requested_designator.len == 0 and
                    provider.designator_scheme == .key)
                    &host_designator
                else
                    requested_designator;
                var result = acceptor.listen(
                    route_id,
                    provider.transport,
                    effective_designator,
                    options,
                ) catch |err| {
                    self.releaseListenerProfile(provider.transport);
                    profile_owned = false;
                    observation_owned = false;
                    self.reportObservedFailure(observer, tag, err);
                    return;
                };
                switch (result) {
                    .ready => |listener| {
                        profile_owned = false;
                        observation_owned = false;
                        observer.ready(observer.ctx, tag, .{
                            .transport = provider.transport,
                            .designator_scheme = provider.designator_scheme,
                            .source = .{ .resident = .{ .runtime = index, .listener = listener } },
                        });
                    },
                    .pending => |*pending| {
                        defer if (pending.deinit()) |failure| self.noteTerminalFailureChain(failure);
                        const row = self.allocator.create(PendingListener) catch |err| {
                            self.releaseListenerProfile(provider.transport);
                            profile_owned = false;
                            observation_owned = false;
                            self.reportObservedFailure(observer, tag, err);
                            return;
                        };
                        self.pending_listeners.ensureUnusedCapacity(self.allocator, 1) catch |err| {
                            self.allocator.destroy(row);
                            self.releaseListenerProfile(provider.transport);
                            profile_owned = false;
                            observation_owned = false;
                            self.reportObservedFailure(observer, tag, err);
                            return;
                        };
                        row.* = .{
                            .stage = .{ .resident = .{
                                .attempt = pending.*,
                                .resident = index,
                            } },
                            .transport = provider.transport,
                            .designator_scheme = provider.designator_scheme,
                            .deadline_ms = self.listenerSetupDeadline(),
                            .observation = observation,
                        };
                        pending.route_id = null;
                        self.pending_listeners.appendAssumeCapacity(row);
                        profile_owned = false;
                        observation_owned = false;
                    },
                }
            },
        }
    }

    fn reserveListenerProfile(self: *HostRuntime, transport: []const u8) !void {
        if (self.listener_profiles.contains(transport)) return Error.ListenerProfileInUse;
        try self.listener_profiles.ensureUnusedCapacity(self.allocator, 1);
        self.listener_profiles.putAssumeCapacity(transport, {});
    }

    fn releaseListenerProfile(self: *HostRuntime, transport: []const u8) void {
        std.debug.assert(self.listener_profiles.remove(transport));
    }

    /// Explicitly blocking native convenience over `startListener`. Product
    /// loops and bindings use the staged operation directly.
    pub fn bindListener(
        self: *HostRuntime,
        transport: []const u8,
        requested_designator: []const u8,
        options: net.OperationOptions,
    ) !TransportListener {
        const Capture = struct {
            listener: ?TransportListener = null,
            failure: ?anyerror = null,

            fn ready(ctx: *anyopaque, _: u64, listener: TransportListener) void {
                const capture: *@This() = @ptrCast(@alignCast(ctx));
                capture.listener = listener;
            }

            fn failed(ctx: *anyopaque, _: u64, failure: OperationFailure) void {
                const capture: *@This() = @ptrCast(@alignCast(ctx));
                capture.failure = failure.cause;
            }
        };
        var capture: Capture = .{};
        errdefer if (capture.listener) |*listener| {
            if (self.closeListener(listener)) |failure| self.noteTerminalOperationFailure(failure);
        } else self.cancelListenerObserver(&capture);
        try self.startListener(transport, requested_designator, options, 0, .{
            .ctx = &capture,
            .ready = Capture.ready,
            .failed = Capture.failed,
        });
        while (capture.listener == null and capture.failure == null) _ = try self.stepAny(-1);
        if (capture.failure) |err| return err;
        return capture.listener.?;
    }

    /// Transfer a stream listener out of Runtime ownership. The raw listener's
    /// owner becomes responsible for uniqueness above this Runtime.
    pub fn takeStreamListener(self: *HostRuntime, listener: *TransportListener) ?net.netlayer.Listener {
        const transport = listener.transportName();
        const stream = listener.takeStream() orelse return null;
        self.releaseListenerProfile(transport);
        return stream;
    }

    fn cancelListenerObserver(self: *HostRuntime, observer_ctx: *anyopaque) void {
        for (self.pending_listeners.items) |row| {
            if (row.observation.observer.ctx != observer_ctx) continue;
            self.failPendingListener(row, error.Canceled);
            return;
        }
    }

    /// Materialize the complete locator an active listener publishes. The
    /// provider owns transport-specific hints; the driver validates the
    /// dispatch symbol and takes ownership of the returned model value.
    pub fn listenerLocator(self: *const HostRuntime, listener: *const TransportListener) !model.PeerLocator {
        const locator = switch (listener.source) {
            .stream => |stream| try stream.handle.localLocator(self.allocator),
            .resident => |resident| try resident.listener.localLocator(self.allocator),
        };
        errdefer model.freePeerLocator(self.allocator, locator);
        if (!std.mem.eql(u8, locator.transport, listener.transportName()) or locator.designator.len == 0)
            return error.ProviderContract;
        return locator;
    }

    /// Query or copy opaque provider state that restores this listener's local
    /// transport address. Null means the transport has no restoration state;
    /// otherwise the result is the complete size and a short output is untouched.
    pub fn listenerRestorationState(
        self: *const HostRuntime,
        listener: *const TransportListener,
        out: []u8,
    ) net.netlayer.RestorationStateError!?usize {
        _ = self;
        return switch (listener.source) {
            .stream => |stream| try stream.handle.restorationState(out),
            .resident => |resident| try resident.listener.restorationState(out),
        };
    }

    /// Validate and canonicalize a replacement locator through the provider
    /// that owns this active listener. The caller owns the returned value.
    pub fn canonicalizeListenerLocator(
        self: *const HostRuntime,
        listener: *const TransportListener,
        locator: model.PeerLocator,
    ) !model.PeerLocator {
        try self.admitApplicationOperation();
        const canonical = switch (listener.source) {
            .stream => |stream| try stream.handle.canonicalizeLocator(self.allocator, locator),
            .resident => |resident| try resident.listener.canonicalizeLocator(self.allocator, locator),
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
        observer: SessionAcceptObserver,
    ) !void {
        const observation = SessionAcceptObservation{ .observer = observer, .tag = tag };
        // One publication right lives with the active listener. Accepted
        // sessions reserve independently; this seat is consumed only by the
        // listener's terminal failure and released by an explicit close.
        try observer.reserve(observer.ctx, tag);
        errdefer observer.release(observer.ctx, tag);
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

    /// Prepare the exact complete locator this listener will publish. The
    /// result is not authoritative until `activateOwnedListener` consumes it.
    pub fn prepareListenerLocator(
        self: *HostRuntime,
        listener: *const TransportListener,
    ) !PreparedListenerLocator {
        const local = try self.listenerLocator(listener);
        defer model.freePeerLocator(self.allocator, local);
        return .{ .value = try self.core.prepareAdvertisedLocator(self.allocator, local) };
    }

    /// Transfer one prepared listener and locator into Runtime ownership.
    /// Runtime close stops every owned listener and removes its Host route
    /// before advancing terminal Host close.
    pub fn activateOwnedListener(
        self: *HostRuntime,
        listener: *TransportListener,
        prepared: *PreparedListenerLocator,
        tag: u64,
        observer: SessionAcceptObserver,
    ) !void {
        try self.admitApplicationOperation();
        if (self.active_listeners.contains(tag)) return error.ListenerAlreadyActive;
        if (!std.mem.eql(u8, prepared.value.transport, listener.transportName())) return error.ProviderContract;
        try self.active_listeners.ensureUnusedCapacity(self.allocator, 1);
        try self.core.retainPreparedAdvertisedLocator(prepared.value);
        errdefer self.core.retireAdvertisedLocator(prepared.value.transport);
        try self.activateListener(listener, tag, observer);
        self.active_listeners.putAssumeCapacity(tag, .{
            .transport = listener.*,
            .locator = prepared.value,
        });
        listener.* = undefined;
        prepared.* = undefined;
    }

    pub fn ownedListenerLocator(self: *const HostRuntime, tag: u64) ?model.PeerLocator {
        return (self.active_listeners.get(tag) orelse return null).locator;
    }

    pub fn ownedListenerRestorationState(
        self: *const HostRuntime,
        tag: u64,
        out: []u8,
    ) !?usize {
        try self.admitApplicationOperation();
        const listener = self.active_listeners.get(tag) orelse return error.ListenerNotActive;
        return self.listenerRestorationState(&listener.transport, out);
    }

    /// Prepare a replacement locator through the owning provider and Host
    /// profile. Commit is separate so an adapter can reserve its projection
    /// before the authoritative route changes.
    pub fn prepareOwnedListenerAdvertisement(
        self: *HostRuntime,
        tag: u64,
        locator: model.PeerLocator,
    ) !PreparedListenerLocator {
        const listener = self.active_listeners.get(tag) orelse return error.ListenerNotActive;
        const canonical = try self.canonicalizeListenerLocator(&listener.transport, locator);
        defer model.freePeerLocator(self.allocator, canonical);
        return .{ .value = try self.core.prepareAdvertisedLocator(self.allocator, canonical) };
    }

    pub fn commitOwnedListenerAdvertisement(
        self: *HostRuntime,
        tag: u64,
        prepared: *PreparedListenerLocator,
    ) !void {
        try self.admitApplicationOperation();
        const listener = self.active_listeners.getPtr(tag) orelse return error.ListenerNotActive;
        if (!std.mem.eql(u8, listener.transport.transportName(), prepared.value.transport))
            return error.ProviderContract;
        try self.core.retainPreparedAdvertisedLocator(prepared.value);
        model.freePeerLocator(self.allocator, listener.locator);
        listener.locator = prepared.value;
        prepared.* = undefined;
    }

    pub fn selectOwnedListener(self: *HostRuntime, tag: u64) !bool {
        try self.admitApplicationOperation();
        const listener = self.active_listeners.get(tag) orelse return error.ListenerNotActive;
        return self.core.selectAdvertisedLocator(listener.transport.transportName());
    }

    /// Stop and remove one Runtime-owned listener. Sessions already yielded
    /// through its observer remain owned by their session handles.
    fn closeActiveListener(self: *HostRuntime, tag: u64) ListenerStopOutcome {
        const removed = self.active_listeners.fetchRemove(tag) orelse return .{ .found = false };
        var listener = removed.value;
        const observation = self.activeListenerObservation(&listener.transport);
        self.core.retireAdvertisedLocator(listener.transport.transportName());
        const failure = self.closeListener(&listener.transport);
        model.freePeerLocator(self.allocator, listener.locator);
        if (observation) |value| value.observer.abandoned(value.observer.ctx, value.tag);
        return .{ .found = true, .failure = failure };
    }

    fn activeListenerObservation(self: *const HostRuntime, listener: *const TransportListener) ?SessionAcceptObservation {
        return switch (listener.source) {
            .stream => |stream| stream.observation,
            .resident => |resident| (self.resident_listeners.get(.{
                .resident = resident.runtime,
                .route = resident.listener.route_id,
            }) orelse return null).observation,
        };
    }

    fn failActiveListener(self: *HostRuntime, tag: u64, primary: OperationFailure) void {
        const removed = self.active_listeners.fetchRemove(tag) orelse return;
        var listener = removed.value;
        const observation = self.activeListenerObservation(&listener.transport) orelse unreachable;
        self.core.retireAdvertisedLocator(listener.transport.transportName());
        var failure = primary;
        if (self.closeListener(&listener.transport)) |cleanup| failure.noteFailure(cleanup);
        model.freePeerLocator(self.allocator, listener.locator);
        observation.observer.failed(observation.observer.ctx, observation.tag, failure);
    }

    /// Stop a listener operation by its Runtime tag, whether setup is still
    /// pending or the listener is active. The observer receives cancellation
    /// for a pending setup; an active listener is removed synchronously.
    pub fn stopOwnedListener(self: *HostRuntime, tag: u64) ListenerStopOutcome {
        const active = self.closeActiveListener(tag);
        if (active.found) return active;
        return self.cancelListener(tag);
    }

    fn closeOwnedListeners(self: *HostRuntime) void {
        while (self.active_listeners.count() != 0) {
            var it = self.active_listeners.keyIterator();
            const tag = (it.next() orelse unreachable).*;
            const outcome = self.closeActiveListener(tag);
            std.debug.assert(outcome.found);
            if (outcome.failure) |failure| self.noteTerminalOperationFailure(failure);
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
        const acceptable = switch (stream.handle.waitAcceptableDetailed(0)) {
            .ready => |ready| ready,
            .failed => |failure| {
                self.failActiveListener(observation.tag, OperationFailure.fromAcceptFailure(failure));
                return 0;
            },
        };
        if (!acceptable) return 0;
        try self.startAcceptWire(stream.handle, listener.transport, observation.tag, observation.observer);
        return 1;
    }

    pub fn closeListener(self: *HostRuntime, listener: *TransportListener) ?OperationFailure {
        const transport = listener.transportName();
        const had_terminal_failure = self.terminal_failure != null;
        var failure: ?OperationFailure = null;
        switch (listener.source) {
            .stream => |stream| {
                if (stream.observation) |observation| self.cancelAccepts(observation.tag);
                if (stream.handle.readinessFd()) |fd| self.unwatchFd(fd);
                if (!had_terminal_failure and self.terminal_failure != null)
                    failure = self.terminal_failure;
                if (stream.handle.close()) |close_failure| {
                    if (failure) |*first| {
                        first.noteChain(close_failure);
                        self.noteTerminalFailureChain(close_failure);
                    } else {
                        failure = OperationFailure.fromChain(close_failure);
                    }
                }
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
                if (resident.listener.stopListen()) |cleanup| {
                    if (failure) |*first|
                        first.noteChain(cleanup)
                    else
                        failure = OperationFailure.fromChain(cleanup);
                }
            },
        }
        self.releaseListenerProfile(transport);
        return failure;
    }

    /// Arm the aggregate readiness set (ADR-0112) and return its one
    /// pollable descriptor. Idempotent. From arming on, every stream wire
    /// fd, resident readiness fd, and mailbox wake fd is mirrored into the
    /// set as it comes and goes, so an embedder parks on this descriptor and
    /// calls `stepAny` when it reads ready. The descriptor is owned by this
    /// host and dies with it.
    pub fn readinessDescriptor(self: *HostRuntime) !i32 {
        try self.admitApplicationOperation();
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
            .stream_dial => |attempt| try rs.add(attempt.readinessFd()),
            .resident_dial, .handshake => {},
        };
        for (self.pending_listeners.items) |row| switch (row.stage) {
            .stream => |attempt| try rs.add(attempt.readinessFd()),
            .resident => {},
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
        self.removeReadyFd(fd);
        for (self.listener_fds.items, 0..) |existing, i| {
            if (existing == fd) {
                const removed = self.listener_fds.swapRemove(i);
                std.debug.assert(removed == fd);
                return;
            }
        }
    }

    fn removeReadyFd(self: *HostRuntime, fd: i32) void {
        if (self.ready_set) |*rs| rs.remove(fd) catch |err| self.noteTerminalFailure(err);
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
            .stream_dial => |attempt| if (attempt.readinessFd() == fd) return true,
            .resident_dial, .handshake => {},
        };
        for (self.pending_listeners.items) |row| {
            switch (row.stage) {
                .stream => |attempt| if (attempt.readinessFd() == fd) return true,
                .resident => {},
            }
        }
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
    pub fn wakeReadiness(self: *HostRuntime) net.wake_channel.Failure!void {
        if (self.ready_set) |*rs| try rs.postWake();
    }

    /// Route application-visible completions (`settled` / `failed`) that no
    /// in-process wait claims to `sink` instead of freeing them (ADR-0112).
    pub fn setCompletionSink(self: *HostRuntime, sink: ?CompletionSink) void {
        self.completion_sink = sink;
    }

    /// Observe wires the pump closes (EOF, fault, dispatch refusal). Installing
    /// over existing wires reserves every close publication transactionally.
    /// Replace an installed observer by removing it first; direct replacement
    /// would transfer reservations between unrelated owners.
    pub fn setCloseObserver(self: *HostRuntime, observer: ?CloseObserver) !void {
        if (observer == null) {
            self.clearCloseObserver();
            return;
        } else if (self.close_observer == null) {
            const installing = observer.?;
            var wires = self.wires.valueIterator();
            errdefer {
                var rollback = self.wires.valueIterator();
                while (rollback.next()) |wire| {
                    if (wire.*.close_event_reserved) {
                        installing.release(installing.ctx);
                        wire.*.close_event_reserved = false;
                    }
                }
            }
            while (wires.next()) |wire| {
                try installing.reserve(installing.ctx);
                wire.*.close_event_reserved = true;
            }
        } else {
            return error.CloseObserverAlreadyInstalled;
        }
        self.close_observer = observer;
    }

    /// Detach the close observer and return every still-reserved publication
    /// right. Unlike installation this cannot fail, so teardown callers do
    /// not need to encode an impossible error as a process-fatal assertion.
    pub fn clearCloseObserver(self: *HostRuntime) void {
        if (self.close_observer) |installed| {
            var wires = self.wires.valueIterator();
            while (wires.next()) |wire| {
                if (wire.*.close_event_reserved) {
                    installed.release(installed.ctx);
                    wire.*.close_event_reserved = false;
                }
            }
        }
        self.close_observer = null;
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

    /// Return the registry-owned canonical symbol for `transport`. Callers
    /// may retain this slice for the HostRuntime lifetime without copying.
    pub fn transportName(self: *const HostRuntime, transport: []const u8) ?[]const u8 {
        return (self.providerFor(transport) orelse return null).transport;
    }

    /// Enter one native driver operation. Public only for the sibling Session
    /// face; this is not an embedder-facing synchronization primitive.
    pub fn enterDriver(self: *HostRuntime) void {
        if (comptime std.debug.runtime_safety) self.core.assertOwner();
        self.driver_depth += 1;
    }

    /// Leave one native driver operation, transferring the core only when the
    /// outermost call has stopped dispatching work.
    pub fn leaveDriver(self: *HostRuntime) void {
        std.debug.assert(self.driver_depth > 0);
        self.driver_depth -= 1;
        if (self.driver_depth != 0 or self.draining_session_releases) return;
        if (self.drainDeferredSessionReleases()) return;
        self.core.releaseDriverOwnership();
    }

    /// Release the current thread's quiescent driver claim. The next driver
    /// operation claims it again; this permits sequential, never concurrent,
    /// handover between host threads.
    pub fn detachThread(self: *HostRuntime) void {
        std.debug.assert(self.driver_depth == 0);
        self.core.releaseDriverOwnership();
    }

    /// Transfer a Session wrapper's implicit cancel/release request while a
    /// behavior callback still holds the Host latch. The request is consumed
    /// after the outermost driver verb unwinds; `complete` may destroy this
    /// runtime when it releases the final retained lease, which it reports so
    /// the drain returns without touching `self` again.
    pub fn deferSessionRelease(self: *HostRuntime, request: *DeferredSessionRelease) !void {
        self.enterDriver();
        defer self.leaveDriver();

        std.debug.assert(self.withinCallback());
        std.debug.assert(!request.queued);
        const wire = self.wires.get(request.session.peer_id) orelse return Error.SessionNotOwned;
        if (wire.session != request.session or !wire.session_handle_claimed) return Error.SessionNotOwned;
        self.core.beginSessionClose(request.session, .cancel, net.clock.nowMs(self.io)) catch |err|
            self.noteTerminalFailure(err);
        request.next = self.deferred_session_releases;
        request.queued = true;
        self.deferred_session_releases = request;
    }

    fn drainDeferredSessionReleases(self: *HostRuntime) bool {
        if (self.deferred_session_releases == null) return false;
        self.draining_session_releases = true;

        // The callback unwind normally staged a CLOSE action. Retry any core
        // work left behind by allocation pressure, then execute the physical
        // close before consuming a wrapper's native ownership.
        self.progressSessionCloses() catch |err| self.noteTerminalFailure(err);
        self.drainActions() catch |err| self.noteTerminalFailure(err);

        var request = self.deferred_session_releases;
        self.deferred_session_releases = null;
        while (request) |current| {
            const next = current.next;
            const wire = self.wires.get(current.session.peer_id);
            if (wire == null or wire.?.session != current.session) unreachable;
            if (!wire.?.closed) {
                current.next = self.deferred_session_releases;
                self.deferred_session_releases = current;
                request = next;
                continue;
            }

            current.next = null;
            current.queued = false;
            self.releaseWireOwned(current.session) catch |err| {
                self.noteTerminalFailure(err);
                current.next = self.deferred_session_releases;
                self.deferred_session_releases = current;
                request = next;
                continue;
            };
            if (current.complete(current.ctx)) return true;
            request = next;
        }
        self.draining_session_releases = false;
        if (self.deferred_session_releases != null) self.nudgeIfWorkRemains();
        return false;
    }

    /// Ask the Host authority whether an external runtime verb may enter its
    /// top-level execution window. Adapter-local queue/step guards remain
    /// separate from this semantic callback boundary.
    pub fn refuseReentry(self: *HostRuntime) error{ ReenteredHost, WrongThread }!void {
        if (self.observer_callback_depth != 0) return error.ReenteredHost;
        try self.core.refuseReentry();
    }

    pub fn withinCallback(self: *const HostRuntime) bool {
        return self.observer_callback_depth != 0 or self.core.withinCallback();
    }

    /// Seal runtime and Host admission and begin one monotonic close barrier.
    /// `stepAny` advances the barrier; `close` is the blocking convenience.
    pub fn beginClose(self: *HostRuntime, pending: PendingWork) void {
        self.enterDriver();
        defer self.leaveDriver();

        self.beginCloseOwned(pending);
    }

    fn beginCloseOwned(self: *HostRuntime, pending: PendingWork) void {
        self.retiring = false;
        self.retirement_effects_pending = false;
        self.close_effects_pending = true;
        self.core.beginClose(pending, net.clock.nowMs(self.io));
        self.wakeReadiness() catch |err| self.noteTerminalFailure(err);
    }

    /// Seal one session's application admission and begin or escalate its
    /// close. The core owns policy and pending-work completion; this Runtime
    /// supplies monotonic time and drives the transport effect.
    pub fn beginSessionClose(
        self: *HostRuntime,
        session: *driver_core.HostSession,
        pending: PendingWork,
    ) !void {
        self.enterDriver();
        defer self.leaveDriver();

        const wire = self.wires.get(session.peer_id) orelse return Error.SessionNotOwned;
        if (wire.session != session) return Error.SessionNotOwned;
        try self.core.beginSessionClose(session, pending, net.clock.nowMs(self.io));
        self.wakeReadiness() catch |err| self.noteTerminalFailure(err);
    }

    /// Begin one session close and drive its transport barrier on this thread.
    pub fn closeSession(self: *HostRuntime, session: *driver_core.HostSession, pending: PendingWork) !void {
        try self.refuseReentry();
        // Hold the driver claim across the whole barrier. A behavior reached
        // while finish is driving may defer the final Session release; that
        // release must not free `session` between this loop's progress step and
        // its outcome check.
        self.enterDriver();
        defer self.leaveDriver();

        try self.beginSessionClose(session, pending);
        while (self.sessionCloseOutcome(session) == .pending)
            _ = try self.stepAnyToward(-1, .{ .session_close = session });
        if (self.sessionCloseOutcome(session) == .timed_out) return Error.CloseTimedOut;
    }

    pub fn sessionCloseOutcome(self: *const HostRuntime, session: *const driver_core.HostSession) CloseOutcome {
        const wire_closed = if (self.wires.get(session.peer_id)) |wire| wire.closed else true;
        return self.core.sessionCloseOutcome(session, wire_closed);
    }

    pub const SessionCloseStatus = struct {
        phase: driver_core.HostSession.LifecyclePhase,
        outcome: CloseOutcome,
    };

    /// Observe one session through Runtime ownership. Adapter projections use
    /// this instead of reaching through the Runtime to core session state.
    pub fn sessionCloseStatus(
        self: *const HostRuntime,
        session: *const driver_core.HostSession,
    ) Error!SessionCloseStatus {
        const wire = self.wires.get(session.peer_id) orelse return Error.SessionNotOwned;
        if (wire.session != session) return Error.SessionNotOwned;
        return .{
            .phase = session.lifecyclePhase(),
            .outcome = self.core.sessionCloseOutcome(session, wire.closed),
        };
    }

    /// Release one completion payload transferred through the Runtime sink.
    pub fn freeAction(self: *HostRuntime, action: driver_core.HostAction) void {
        self.core.freeAction(action);
    }

    /// Supply monotonic time to the core-owned session close policy.
    fn progressSessionCloses(self: *HostRuntime) !void {
        try self.core.progressSessionCloses(net.clock.nowMs(self.io));
    }

    /// Begin close and drive it to completion on the calling thread.
    pub fn close(self: *HostRuntime, pending: PendingWork) !void {
        try self.refuseReentry();
        self.beginClose(pending);
        while (self.closeOutcome() == .pending) _ = try self.stepAnyToward(-1, .host_close);
        if (self.closeOutcome() == .timed_out) return Error.CloseTimedOut;
    }

    /// Stop listener admission and retire this Runtime after every session
    /// handle already transferred to the application releases. This is the
    /// server/listener ownership contract, not Host finish policy: retained
    /// sessions remain active, and the final release begins cancel close.
    pub fn beginRetirement(self: *HostRuntime) void {
        self.enterDriver();
        defer self.leaveDriver();
        if (self.core.lifecyclePhase() != .active) return;
        self.retiring = true;
        self.retirement_effects_pending = true;
        self.wakeReadiness() catch |err| self.noteTerminalFailure(err);
    }

    fn progressRetirement(self: *HostRuntime) !void {
        if (!self.retiring) return;
        if (self.retirement_effects_pending) {
            self.retirement_effects_pending = false;
            self.closeOwnedListeners();
            self.cancelPendingListenerSetups();
        }
        if (self.claimed_session_handles == 0) self.beginCloseOwned(.cancel);
    }

    /// Whether listener setup and active listener ownership have fully retired.
    /// ABI adapters use this fact only to release their locator projections.
    pub fn listenerOwnershipRetired(self: *const HostRuntime) bool {
        return self.pending_listeners.items.len == 0 and self.active_listeners.count() == 0;
    }

    pub fn lifecyclePhase(self: *const HostRuntime) driver_core.Host.LifecyclePhase {
        return self.core.lifecyclePhase();
    }

    pub fn closeOutcome(self: *const HostRuntime) CloseOutcome {
        if (self.retiring) return .pending;
        const completion_reached = self.core.lifecyclePhase() == .closed and
            self.pending_opens.items.len == 0 and
            self.pending_listeners.items.len == 0 and
            self.open_wire_count == 0;
        return self.core.closeOutcome(completion_reached);
    }

    /// Advance close using only immediate work. The outer step owns waiting;
    /// this method owns deadline escalation, operation cancellation, and wire
    /// closure after terminal frames have been written. Provider fail-stop
    /// uses cleanup-only effects and closes without another transport write.
    fn progressClose(self: *HostRuntime, effect_mode: ExternalEffectMode) !void {
        try self.progressRetirement();
        if (self.close_effects_pending) {
            self.close_effects_pending = false;
            self.closeOwnedListeners();
            self.cancelPendingListenerSetups();
        }
        if (self.core.lifecyclePhase() == .active) return;
        if (self.core.lifecyclePhase() != .closed)
            try self.core.progressClose(net.clock.nowMs(self.io));
        if (self.core.lifecyclePhase() == .terminating or self.core.lifecyclePhase() == .closed)
            self.cancelPendingRuntimeWork();

        try self.drainActionsWith(effect_mode);
        if (effect_mode == .operational) try self.advancePendingOpens();
        if (self.core.lifecyclePhase() == .terminating or self.core.lifecyclePhase() == .closed)
            self.cancelPendingRuntimeWork();
        try self.drainActionsWith(effect_mode);
    }

    fn cancelPendingRuntimeWork(self: *HostRuntime) void {
        while (self.pending_opens.pop()) |row| {
            const outcome = row.outcome;
            var discarded = self.discardPendingOpen(row);
            switch (outcome) {
                .operation => |observation| {
                    const observer = observation.observer;
                    var failure = OperationFailure.fromError(error.Canceled);
                    if (discarded.cleanup) |cleanup| failure.noteChain(cleanup);
                    self.reportObservedOperationFailure(observer, observation.tag, failure);
                },
                .listener_accept => |observation| {
                    if (discarded.cleanup) |cleanup| self.noteTerminalFailureChain(cleanup);
                    const observer = observation.observer;
                    observer.abandoned(observer.ctx, observation.tag);
                },
                // Core cancellation already failed the parked enliven and
                // consumed its dial authority.
                .redeem => {},
            }
            discarded.admission.release();
        }
        self.cancelPendingListenerSetups();
    }

    fn cancelPendingListenerSetups(self: *HostRuntime) void {
        while (self.pending_listeners.items.len != 0)
            self.failPendingListener(self.pending_listeners.items[self.pending_listeners.items.len - 1], error.Canceled);
    }

    /// Tear down every wire, then the core (which breaks every parked vow).
    pub fn deinit(self: *HostRuntime) void {
        _ = self.deinitOutcome();
    }

    /// The same complete ownership sweep, returning the Runtime's exact first
    /// terminal failure after asynchronous provider retirement has joined.
    /// Adapters project this value; they never inspect Runtime state to infer it.
    pub fn deinitOutcome(self: *HostRuntime) ?OperationFailure {
        self.deinitImpl(true);
        return self.terminal_failure;
    }

    /// Unwind an adopted-core runtime that never escaped its constructor. The
    /// prior byte-fed owner receives the core unchanged, so rollback frees only
    /// runtime scaffolding and must not cross the Host close barrier.
    pub fn deinitAfterFailedAdoption(self: *HostRuntime) void {
        std.debug.assert(!self.owns_core);
        self.deinitImpl(false);
    }

    fn deinitImpl(self: *HostRuntime, cancel_core: bool) void {
        std.debug.assert(self.driver_depth == 0);
        std.debug.assert(self.deferred_session_releases == null);
        // Deinit is the implicit resource-management path, so it escalates to
        // cancel before the infallible ownership sweep below.
        if (cancel_core) self.beginClose(.cancel);
        // Active listeners own the accepted handshakes that still name them.
        // Retire those rows before the general pending-open sweep frees their
        // storage; listener cancellation must never traverse dead row pointers.
        self.closeOwnedListeners();
        // Resident connects without a wire own a session only through their
        // pending row. Handshake rows own a wire and fall through the wire
        // sweep below, so each core session is released exactly once.
        for (self.pending_opens.items) |row| switch (row.stage) {
            .stream_dial => {
                if (row.stage.stream_dial.deinit()) |failure| self.noteTerminalFailureChain(failure);
                self.core.releaseSession(row.session) catch unreachable;
            },
            .resident_dial => {
                if (row.stage.resident_dial.attempt.deinit()) |failure| self.noteTerminalFailureChain(failure);
                self.core.releaseSession(row.session) catch unreachable;
            },
            .handshake => {},
        };
        var it = self.wires.valueIterator();
        while (it.next()) |wire_slot| {
            const wire = wire_slot.*;
            const session = wire.session;
            if (wire.session_handle_claimed) {
                std.debug.assert(self.claimed_session_handles != 0);
                self.claimed_session_handles -= 1;
            }
            self.freeWire(wire);
            self.core.releaseSession(session) catch unreachable;
        }
        std.debug.assert(self.open_wire_count == 0);
        std.debug.assert(self.claimed_session_handles == 0);
        self.wires.deinit(self.allocator);
        self.resident_wires.deinit(self.allocator);
        // A pending dial cannot outlive the stack frame awaiting it, so the
        // map is empty here; only its capacity is released.
        self.pending_resident_dials.deinit(self.allocator);
        // The ownership sweep above retired every row's resident connect,
        // wire, and core session. Only row storage remains here.
        for (self.pending_opens.items) |row| {
            switch (row.outcome) {
                .operation => |observation| {
                    const observer = observation.observer;
                    observer.release(observer.ctx, observation.tag);
                },
                .listener_accept => |observation| {
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
        for (self.pending_listeners.items) |row| {
            switch (row.stage) {
                .stream => |*attempt| if (attempt.deinit()) |failure|
                    self.noteTerminalFailureChain(failure),
                .resident => |*pending| if (pending.attempt.deinit()) |failure|
                    self.noteTerminalFailureChain(failure),
            }
            self.releaseListenerProfile(row.transport);
            const observation = row.observation;
            observation.observer.abandoned(observation.observer.ctx, observation.tag);
            self.allocator.destroy(row);
        }
        self.pending_listeners.deinit(self.allocator);
        self.active_listeners.deinit(self.allocator);
        self.listener_profiles.deinit(self.allocator);
        var listener_it = self.resident_listeners.valueIterator();
        while (listener_it.next()) |listener| if (listener.listener.stopListen()) |failure|
            self.noteTerminalFailureChain(failure);
        self.resident_listeners.deinit(self.allocator);
        self.residents.deinit(self.allocator);
        self.providers.deinit(self.allocator);
        var package_index = self.provider_packages.items.len;
        while (package_index != 0) {
            package_index -= 1;
            if (self.provider_packages.items[package_index].deinit(self.allocator)) |failure|
                self.noteTerminalOperationFailure(failure);
        }
        self.provider_packages.deinit(self.allocator);
        self.poll_scratch.deinit(self.allocator);
        self.conn_scratch.deinit(self.allocator);
        self.dial_scratch.deinit(self.allocator);
        self.listen_scratch.deinit(self.allocator);
        self.active_listener_scratch.deinit(self.allocator);
        self.borrow_scratch.deinit(self.allocator);
        self.extra_fd_scratch.deinit(self.allocator);
        self.listener_fds.deinit(self.allocator);
        if (self.mailbox) |mb| mb.deinit();
        if (self.ready_set) |*rs| rs.deinit();
        if (self.owns_core) {
            if (self.core.deinitOutcome()) |failure| self.noteTerminalFailure(failure);
            self.allocator.destroy(self.core);
        }
    }

    /// Dial `locator` into an open session: mint the dialed half (the core
    /// registers crossed hellos and encodes the signed hello), bind the
    /// transport wire, and pump the keyed handshake under the handshake
    /// budget. On any failure the wire, the shell, and the hello registration
    /// unwind together.
    pub fn connectLocator(
        self: *HostRuntime,
        locator: model.PeerLocator,
        options: net.OperationOptions,
    ) !*driver_core.HostSession {
        self.enterDriver();
        defer self.leaveDriver();
        var admission = try self.acquireOpenAdmission(.application);
        defer admission.release();
        try self.core.ensureAdvertisedLocator(locator.transport);
        const session = try self.core.openDialedLocator(locator);
        errdefer {
            self.dropWire(session.peer_id);
            self.core.releaseSession(session) catch unreachable;
        }
        try self.bindWire(session, locator, options);
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
    pub fn startDial(
        self: *HostRuntime,
        locator: model.PeerLocator,
        options: net.OperationOptions,
        tag: u64,
        observer: SessionOpenObserver,
    ) !void {
        self.enterDriver();
        defer self.leaveDriver();
        try observer.reserve(observer.ctx, tag);
        errdefer observer.release(observer.ctx, tag);
        try self.stageDial(locator, options, .{ .operation = .{ .observer = observer, .tag = tag } }, .application);
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
        var admission = try self.acquireOpenAdmission(.application);
        errdefer admission.release();
        const provider = self.providerFor(transport) orelse return Error.UnknownTransport;
        const resident_index = switch (provider.source) {
            .stream => return Error.UnknownTransport,
            .resident => |index| index,
        };
        const runtime = self.residents.items[resident_index].resident;
        const claimer = runtime.externalClaimer() orelse return Error.UnknownTransport;
        try observer.reserve(observer.ctx, tag);
        errdefer observer.release(observer.ctx, tag);
        var claimed = switch (claimer.claimExternal(subject)) {
            .claimed => |connection| connection,
            .failed => |failure| {
                admission.release();
                observer.failed(observer.ctx, tag, .fromChain(failure.chain));
                return;
            },
        };
        defer if (claimed.deinit()) |failure| self.noteTerminalFailureChain(failure);
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
            self.core.releaseSession(session) catch unreachable;
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
            .outcome = .{ .operation = .{ .observer = observer, .tag = tag } },
        };
        // Publish the ownership row before bytes move. A synchronous EOF must
        // settle through this operation's observer, never the close observer
        // for application-owned sessions.
        self.pending_opens.appendAssumeCapacity(row);
        const wire = self.wires.get(session.peer_id).?;
        self.writeOutbound(wire) catch |err| self.closeWire(wire, err);
        if (!wire.closed) _ = self.feedReadable(wire, null) catch |err| self.closeWire(wire, err);
    }

    /// The shared staged-dial mint behind `startDial` and the
    /// redeem drain: open the dialed half, start the transport connect, and
    /// park a `PendingOpen` row for the pump to settle. `locator` is
    /// borrowed for the call; nothing of it is retained.
    fn stageDial(
        self: *HostRuntime,
        locator: model.PeerLocator,
        options: net.OperationOptions,
        outcome: PendingOpen.Outcome,
        authority: OpenAdmissionAuthority,
    ) !void {
        var admission = try self.acquireOpenAdmission(authority);
        errdefer admission.release();
        const session = switch (authority) {
            .application => blk: {
                try self.core.ensureAdvertisedLocator(locator.transport);
                break :blk try self.core.openDialedLocator(locator);
            },
            .pending_dial => blk: {
                const ticket = switch (outcome) {
                    .redeem => |ticket| ticket,
                    .operation, .listener_accept => unreachable,
                };
                break :blk try self.core.openPendingDial(ticket) orelse {
                    admission.release();
                    return;
                };
            },
        };
        errdefer {
            self.dropWire(session.peer_id);
            self.core.releaseSession(session) catch unreachable;
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
                var attempt = switch (dialer.startDial(
                    request_id,
                    locator,
                    options,
                )) {
                    .admitted => |attempt| attempt,
                    .failed => |failure| {
                        row.* = .{
                            .admission = admission,
                            .session = session,
                            .stage = .handshake,
                            .deadline_ms = deadline_ms,
                            .outcome = outcome,
                        };
                        self.pending_opens.appendAssumeCapacity(row);
                        self.removePendingRow(row);
                        try self.failPendingOpenFailure(row, .fromDialFailure(failure));
                        return;
                    },
                };
                defer if (attempt.deinit()) |failure| self.noteTerminalFailureChain(failure);
                row.* = .{
                    .admission = admission,
                    .session = session,
                    .stage = .{ .resident_dial = .{
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
                    var attempt = switch (nl.startDial(locator, options)) {
                        .admitted => |attempt| attempt,
                        .failed => |failure| {
                            row.* = .{
                                .admission = admission,
                                .session = session,
                                .stage = .handshake,
                                .deadline_ms = deadline_ms,
                                .outcome = outcome,
                            };
                            self.pending_opens.appendAssumeCapacity(row);
                            self.removePendingRow(row);
                            try self.failPendingOpenFailure(row, .fromDialFailure(failure));
                            return;
                        },
                    };
                    errdefer if (attempt.deinit()) |cleanup| self.noteTerminalFailureChain(cleanup);
                    const fd = attempt.readinessFd();
                    if (fd < 0) return Error.TransportNotPollable;
                    if (self.descriptorInUse(fd)) return error.ReadinessDescriptorConflict;
                    if (self.ready_set) |*rs| try rs.add(fd);
                    errdefer self.removeReadyFd(fd);
                    row.* = .{
                        .admission = admission,
                        .session = session,
                        .stage = .{ .stream_dial = attempt.take() },
                        .deadline_ms = deadline_ms,
                        .outcome = outcome,
                    };
                } else {
                    try self.bindStreamWire(session, locator, nl, options);
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

    fn listenerSetupDeadline(self: *const HostRuntime) ?i64 {
        return switch (self.opts.listener_setup) {
            .unbounded => null,
            .ms => |v| net.clock.nowMs(self.io) + v,
        };
    }

    /// Cancel one admitted listener setup. Active listeners are owned by the
    /// caller and close through `closeListener`; this method names only the
    /// pending construction state.
    pub fn cancelListener(self: *HostRuntime, tag: u64) ListenerStopOutcome {
        for (self.pending_listeners.items, 0..) |row, i| {
            if (row.observation.tag != tag) continue;
            std.debug.assert(self.pending_listeners.swapRemove(i) == row);
            var failure: ?OperationFailure = null;
            switch (row.stage) {
                .stream => |*attempt| {
                    self.removeReadyFd(attempt.readinessFd());
                    if (attempt.deinit()) |cleanup|
                        failure = OperationFailure.fromChain(cleanup);
                },
                .resident => |*pending| {
                    if (pending.attempt.deinit()) |cleanup|
                        failure = OperationFailure.fromChain(cleanup);
                },
            }
            const observation = row.observation;
            self.releaseListenerProfile(row.transport);
            self.allocator.destroy(row);
            observation.observer.abandoned(observation.observer.ctx, tag);
            return .{ .found = true, .failure = failure };
        }
        return .{ .found = false };
    }

    fn finishPendingListener(self: *HostRuntime, row: *PendingListener) void {
        self.removePendingListener(row);
        const transport = row.transport;
        const designator_scheme = row.designator_scheme;
        const observation = row.observation;
        const listener: TransportListener = switch (row.stage) {
            .stream => |*attempt| blk: {
                self.removeReadyFd(attempt.readinessFd());
                const stream = switch (attempt.finish(self.allocator)) {
                    .ready => |listener| listener,
                    .failed => |failure| {
                        self.releaseListenerProfile(transport);
                        self.allocator.destroy(row);
                        self.reportObservedFailureChain(observation.observer, observation.tag, failure);
                        return;
                    },
                };
                break :blk .{
                    .transport = transport,
                    .designator_scheme = designator_scheme,
                    .source = .{ .stream = .{ .handle = stream } },
                };
            },
            .resident => |*pending| blk: {
                const resident_listener = pending.attempt.finish() catch |err| {
                    self.releaseListenerProfile(transport);
                    self.allocator.destroy(row);
                    self.reportObservedFailure(observation.observer, observation.tag, err);
                    return;
                };
                break :blk .{
                    .transport = transport,
                    .designator_scheme = designator_scheme,
                    .source = .{ .resident = .{
                        .runtime = pending.resident,
                        .listener = resident_listener,
                    } },
                };
            },
        };
        self.allocator.destroy(row);
        observation.observer.ready(observation.observer.ctx, observation.tag, listener);
    }

    fn failPendingListener(self: *HostRuntime, row: *PendingListener, err: anyerror) void {
        self.removePendingListener(row);
        var failure = net.netlayer.ListenFailure.init(err);
        switch (row.stage) {
            .stream => |*attempt| {
                self.removeReadyFd(attempt.readinessFd());
                if (attempt.deinit()) |cleanup| failure.noteChain(cleanup);
            },
            .resident => |*pending| if (pending.attempt.deinit()) |cleanup| failure.noteChain(cleanup),
        }
        const observation = row.observation;
        self.releaseListenerProfile(row.transport);
        self.allocator.destroy(row);
        self.reportObservedFailureChain(observation.observer, observation.tag, failure);
    }

    fn pendingResidentListener(
        self: *HostRuntime,
        resident: usize,
        route: usize,
    ) ?*PendingListener {
        for (self.pending_listeners.items) |row| switch (row.stage) {
            .resident => |pending| if (pending.resident == resident and pending.attempt.id() == route)
                return row,
            .stream => {},
        };
        return null;
    }

    fn removePendingListener(self: *HostRuntime, row: *PendingListener) void {
        for (self.pending_listeners.items, 0..) |candidate, i| {
            if (candidate != row) continue;
            std.debug.assert(self.pending_listeners.swapRemove(i) == row);
            return;
        }
        unreachable;
    }

    fn advancePendingListeners(self: *HostRuntime) void {
        const now = net.clock.nowMs(self.io);
        var i: usize = 0;
        while (i < self.pending_listeners.items.len) {
            const row = self.pending_listeners.items[i];
            if (row.deadline_ms) |deadline| {
                if (now >= deadline) {
                    self.failPendingListener(row, error.ListenerSetupTimedOut);
                    continue;
                }
            }
            i += 1;
        }
    }

    /// Accept one ready connection from `listener` without pumping its
    /// handshake (ADR-0112): mint the accepted half, bind the wire, and park
    /// a staged row beside the dials. The accept observer hears `opened` with
    /// `tag` only when the partner's hello completes the handshake. A wire
    /// close or budget expiry is retired as listener hygiene, so one silent
    /// connector cannot park the step or become an application operation
    /// failure. Call after the listener reported acceptable, so the accept
    /// syscall itself does not block.
    pub fn startAcceptWire(
        self: *HostRuntime,
        listener: net.netlayer.Listener,
        transport: []const u8,
        tag: u64,
        observer: SessionAcceptObserver,
    ) !void {
        self.enterDriver();
        defer self.leaveDriver();
        var admission = try self.acquireOpenAdmission(.application);
        errdefer admission.release();
        try observer.reserve(observer.ctx, tag);
        errdefer observer.release(observer.ctx, tag);
        const session = try self.core.openAcceptedAdvertised(transport);
        errdefer {
            self.dropWire(session.peer_id);
            self.core.releaseSession(session) catch unreachable;
        }
        const row = try self.allocator.create(PendingOpen);
        errdefer self.allocator.destroy(row);
        try self.pending_opens.ensureUnusedCapacity(self.allocator, 1);
        if (try self.bindAcceptedWireDetailed(session, listener)) |failure| {
            self.allocator.destroy(row);
            self.core.releaseSession(session) catch unreachable;
            admission.release();
            observer.release(observer.ctx, tag);
            self.failActiveListener(tag, OperationFailure.fromAcceptFailure(failure));
            return;
        }
        row.* = .{
            .admission = admission,
            .session = session,
            .stage = .handshake,
            .deadline_ms = self.handshakeDeadline(),
            .outcome = .{ .listener_accept = .{ .observer = observer, .tag = tag } },
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
                .listener_accept => |value| if (value.tag == tag) value else null,
                else => null,
            };
            if (observation == null) {
                i += 1;
                continue;
            }
            std.debug.assert(self.pending_opens.swapRemove(i) == row);
            var discarded = self.discardPendingOpen(row);
            if (discarded.cleanup) |cleanup| self.noteTerminalFailureChain(cleanup);
            const obs = observation.?.observer;
            obs.abandoned(obs.ctx, tag);
            discarded.admission.release();
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
                    try self.failPendingOpenFailure(row, row.close_cause orelse OperationFailure.fromError(Error.ConnectionClosed));
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
        defer {
            row.admission.release();
            self.allocator.destroy(row);
        }
        switch (row.outcome) {
            .operation => |observation| {
                const obs = observation.observer;
                obs.opened(obs.ctx, observation.tag, row.session) catch |err| {
                    var failure = self.operationFailure(err);
                    self.releaseWire(row.session) catch |cleanup| failure.noteFailure(self.operationFailure(cleanup));
                    obs.failed(obs.ctx, observation.tag, failure);
                    return;
                };
            },
            .redeem => |ticket| {
                self.core.exporterDialed(ticket, row.session) catch |err| {
                    try self.releaseWire(row.session);
                    try self.core.dialFailed(ticket, @errorName(err));
                    return err;
                };
            },
            .listener_accept => |observation| {
                const obs = observation.observer;
                obs.opened(obs.ctx, observation.tag, row.session) catch |err| {
                    var failure = self.operationFailure(err);
                    self.releaseWire(row.session) catch |cleanup| failure.noteFailure(self.operationFailure(cleanup));
                    obs.failed(obs.ctx, observation.tag, failure);
                    return;
                };
            },
        }
        // The settle queued post-open work (withdraws, parked enlivens, the
        // observer's own effects); answer it before the next row's verdict.
        try self.drainActions();
    }

    /// Unwind and report one failed session open. The still-parked
    /// resident connect is canceled; a bound wire drops with its session.
    fn failPendingOpen(self: *HostRuntime, row: *PendingOpen, err: anyerror) !void {
        return self.failPendingOpenFailure(row, self.operationFailure(err));
    }

    fn failPendingOpenFailure(self: *HostRuntime, row: *PendingOpen, original_failure: OperationFailure) !void {
        const outcome = row.outcome;
        var discarded = self.discardPendingOpen(row);
        defer discarded.admission.release();
        var failure = original_failure;
        if (discarded.cleanup) |cleanup| failure.noteChain(cleanup);
        switch (outcome) {
            .operation => |observation| {
                const obs = observation.observer;
                obs.failed(obs.ctx, observation.tag, failure);
            },
            .redeem => |ticket| try self.core.dialFailed(ticket, failure.primaryName()),
            .listener_accept => |observation| {
                const obs = observation.observer;
                obs.abandoned(obs.ctx, observation.tag);
            },
        }
        try self.drainActions();
    }

    /// Infallibly retire the transport and session owned by a failed pending
    /// open. Outcome notification and action draining stay with the caller:
    /// listener close uses this after admission is sealed and must not become
    /// half-closed because an unrelated queued action failed to drain.
    const DiscardedOpen = struct {
        admission: OpenAdmission,
        cleanup: ?foundation.FailureChain = null,
    };

    fn discardPendingOpen(self: *HostRuntime, row: *PendingOpen) DiscardedOpen {
        defer self.allocator.destroy(row);
        const admission = row.admission;
        var cleanup: ?foundation.FailureChain = null;
        switch (row.stage) {
            .stream_dial => |*attempt| {
                self.removeReadyFd(attempt.readinessFd());
                cleanup = attempt.deinit();
            },
            .resident_dial => cleanup = row.stage.resident_dial.attempt.deinit(),
            .handshake => {},
        }
        self.dropWire(row.session.peer_id);
        self.core.releaseSession(row.session) catch unreachable;
        return .{ .admission = admission, .cleanup = cleanup };
    }

    fn pendingOpenByRequest(self: *HostRuntime, resident_index: usize, request_id: usize) ?*PendingOpen {
        for (self.pending_opens.items) |row| switch (row.stage) {
            .stream_dial => {},
            .resident_dial => |dial| if (dial.resident == resident_index and dial.attempt.id() == request_id) return row,
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

    fn acquireOpenAdmission(self: *HostRuntime, authority: OpenAdmissionAuthority) AdmissionError!OpenAdmission {
        switch (authority) {
            .application => try self.checkRuntimeApplicationAdmission(),
            .pending_dial => if (self.terminal_failure != null) return error.ProviderContract,
        }
        if (!self.pendingOpenSlotAvailable()) return Error.PendingOpenLimitReached;
        const pending_work = switch (authority) {
            .application => try self.core.admitPendingWork(),
            .pending_dial => null,
        };
        self.open_admissions += 1;
        return .{ .runtime = self, .pending_work = pending_work };
    }

    /// Refuse new application work after either retirement or Host close.
    /// Concrete Runtime verbs own this check; adapters may project the error
    /// but never need a shadow admission state.
    fn admitApplicationOperation(self: *const HostRuntime) AdmissionError!void {
        try self.checkRuntimeApplicationAdmission();
        try self.core.admitApplicationOperation();
    }

    fn checkRuntimeApplicationAdmission(self: *const HostRuntime) AdmissionError!void {
        if (self.terminal_failure != null) return error.ProviderContract;
        if (self.retiring) return Error.HostClosing;
    }

    /// Adapter preflight for work that must inspect or retain foreign provider
    /// state before it can call the Runtime transaction that consumes it.
    pub fn checkApplicationAdmission(self: *const HostRuntime) AdmissionError!void {
        try self.admitApplicationOperation();
    }

    /// Preserve a failure that crossed a callback or ownership-commit boundary
    /// with no direct return channel. The first cause is authoritative: every
    /// later operation and adapter projection reads it through
    /// `operationFailure` instead of inferring failure from stopped progress.
    pub fn noteTerminalFailure(self: *HostRuntime, cause: anyerror) void {
        if (self.terminal_failure) |*failure|
            failure.note(cause)
        else
            self.terminal_failure = OperationFailure.fromError(cause);
    }

    fn noteTerminalFailureChain(self: *HostRuntime, chain: net.netlayer.ListenerCloseFailure) void {
        if (self.terminal_failure) |*failure|
            failure.noteChain(chain)
        else
            self.terminal_failure = OperationFailure.fromChain(chain);
    }

    pub fn noteTerminalOperationFailure(self: *HostRuntime, later: OperationFailure) void {
        if (self.terminal_failure) |*failure|
            failure.noteFailure(later)
        else
            self.terminal_failure = later;
    }

    /// Publish a callerless failure without changing runtime control flow.
    /// The process owner chooses the observer; the library never terminates.
    pub fn reportUnhandledFailure(self: *HostRuntime, failure: OperationFailure) void {
        if (self.opts.unhandled_failure) |observer| observer.report(observer.ctx, failure);
    }

    /// Record a provider callback contract violation at the driver boundary.
    /// Adapters detect representation-specific invalid results; the Runtime
    /// owns the resulting fail-stop policy.
    pub fn failProviderContract(self: *HostRuntime) void {
        self.noteTerminalFailure(error.ProviderContract);
    }

    fn reportObservedFailure(self: *HostRuntime, observer: anytype, tag: u64, cause: anyerror) void {
        if (self.terminal_failure != null) {
            self.noteTerminalFailure(cause);
            observer.abandoned(observer.ctx, tag);
            return;
        }
        observer.failed(observer.ctx, tag, OperationFailure.fromError(cause));
    }

    fn reportObservedOperationFailure(self: *HostRuntime, observer: anytype, tag: u64, failure: OperationFailure) void {
        if (self.terminal_failure != null) {
            self.noteTerminalOperationFailure(failure);
            observer.abandoned(observer.ctx, tag);
            return;
        }
        observer.failed(observer.ctx, tag, failure);
    }

    fn reportObservedFailureChain(
        self: *HostRuntime,
        observer: anytype,
        tag: u64,
        failure: net.netlayer.ListenFailure,
    ) void {
        if (self.terminal_failure != null) {
            self.noteTerminalOperationFailure(.fromChain(failure));
            observer.abandoned(observer.ctx, tag);
            return;
        }
        observer.failed(observer.ctx, tag, OperationFailure.fromChain(failure));
    }

    fn reportListenAttemptFailure(
        self: *HostRuntime,
        observer: anytype,
        tag: u64,
        attempt: *net.netlayer.ListenAttempt,
        cause: anyerror,
    ) void {
        var failure = net.netlayer.ListenFailure.init(cause);
        if (attempt.deinit()) |cleanup| failure.noteChain(cleanup);
        self.reportObservedFailureChain(observer, tag, failure);
    }

    pub fn terminalFailure(self: *const HostRuntime) ?OperationFailure {
        return self.terminal_failure;
    }

    /// Classify one failed Runtime operation against the sticky provider
    /// verdict. Once provider execution is fail-stop, that shared verdict is
    /// authoritative even when the adapter had to return a narrower seam error.
    pub fn operationFailure(self: *const HostRuntime, cause: anyerror) OperationFailure {
        return self.terminal_failure orelse OperationFailure.fromError(cause);
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
    /// row to the handshake stage. `DialAttempt.finish` consumes the request,
    /// so a failure settles the row failed with nothing left to cancel.
    fn adoptPendingResidentDial(self: *HostRuntime, resident_index: usize, row: *PendingOpen) !void {
        std.debug.assert(row.stage.resident_dial.resident == resident_index);
        const resident = self.residents.items[resident_index].resident;
        var conn = switch (row.stage.resident_dial.attempt.finish()) {
            .connected => |conn| conn,
            .failed => |failure| {
                self.removePendingRow(row);
                return self.failPendingOpenFailure(row, .fromDialFailure(failure));
            },
        };
        defer if (conn.deinit()) |failure| self.noteTerminalFailureChain(failure);
        const remote_key = resident.connRemoteKey(conn.borrow()) catch |err| {
            self.removePendingRow(row);
            return self.failPendingOpen(row, err);
        };
        row.stage = .handshake;
        if (remote_key) |key| {
            row.session.served.port.peer.bindVerifiedChannelKey(key);
        }
        self.adoptResidentConn(row.session, resident_index, &conn) catch |err| {
            self.removePendingRow(row);
            return self.failPendingOpen(row, err);
        };
        // The hello's flush action drained to a no-op while the wire did not
        // exist yet; push the queued frame now that it does.
        const wire = self.wires.get(row.session.peer_id).?;
        self.writeOutbound(wire) catch |err| self.closeWire(wire, err);
    }

    /// Claim a ready per-stream connect, transfer it into an ordinary wire,
    /// and advance the row to the shared CapTP handshake stage.
    fn adoptPendingStreamDial(self: *HostRuntime, row: *PendingOpen) !void {
        std.debug.assert(row.stage == .stream_dial);
        self.removeReadyFd(row.stage.stream_dial.readinessFd());
        const bufs = self.allocBufs() catch |err| {
            self.removePendingRow(row);
            return self.failPendingOpen(row, err);
        };
        var owns_bufs = true;
        defer if (owns_bufs) self.freeBufs(bufs);
        const conn = switch (row.stage.stream_dial.finish(row.session.served.port.peer, .{
            .read = bufs.read,
            .write = bufs.write,
        })) {
            .connected => |conn| conn,
            .failed => |failure| {
                row.stage = .handshake;
                self.removePendingRow(row);
                return self.failPendingOpenFailure(row, .fromDialFailure(failure));
            },
        };
        row.stage = .handshake;
        self.adoptConn(row.session, conn, bufs) catch |err| {
            self.removePendingRow(row);
            return self.failPendingOpen(row, err);
        };
        owns_bufs = false;
        // The hello flush drained before the wire existed. Push it now.
        const wire = self.wires.get(row.session.peer_id).?;
        self.writeOutbound(wire) catch |err| self.closeWire(wire, err);
    }

    /// The longest a nonblocking embedder may park on readiness before its
    /// next zero-timeout step: milliseconds until the nearest pending-work
    /// deadline (the close grace, a session's close grace, a dial or listener
    /// setup budget), clamped at zero, or -1 when no finite deadline is
    /// pending and readiness alone advances the loop. The blocking tiers get
    /// the same bound applied inside their own park.
    pub fn stepWaitMs(self: *const HostRuntime) i32 {
        return self.clampTimeoutToPendingWork(-1);
    }

    /// Bound a park by the nearest pending operation deadline, so an expiry is
    /// noticed by the wait that spans it rather than the next external event.
    fn clampTimeoutToPendingWork(self: *const HostRuntime, timeout_ms: i32) i32 {
        const now_ms = net.clock.nowMs(self.io);
        const core_wait = self.core.closeWaitMs(now_ms);
        var nearest_wait: ?i64 = if (core_wait >= 0) core_wait else null;
        for (self.pending_opens.items) |row| {
            const deadline = row.deadline_ms orelse continue;
            const wait = if (deadline <= now_ms)
                0
            else
                std.math.sub(i64, deadline, now_ms) catch std.math.maxInt(i64);
            if (nearest_wait == null or wait < nearest_wait.?) nearest_wait = wait;
        }
        for (self.pending_listeners.items) |row| {
            const deadline = row.deadline_ms orelse continue;
            const wait = if (deadline <= now_ms)
                0
            else
                std.math.sub(i64, deadline, now_ms) catch std.math.maxInt(i64);
            if (nearest_wait == null or wait < nearest_wait.?) nearest_wait = wait;
        }
        const wait = nearest_wait orelse return timeout_ms;
        const remaining = std.math.cast(i32, wait) orelse std.math.maxInt(i32);
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
        var admission = try self.acquireOpenAdmission(.application);
        defer admission.release();
        const session = try self.core.openAcceptedAdvertised(transport);
        errdefer {
            self.dropWire(session.peer_id);
            self.core.releaseSession(session) catch unreachable;
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

    fn bindAcceptedWireDetailed(self: *HostRuntime, session: *driver_core.HostSession, listener: net.netlayer.Listener) !?net.netlayer.AcceptFailure {
        const bufs = try self.allocBufs();
        errdefer self.freeBufs(bufs);
        const conn = switch (listener.acceptDetailed(session.served.port.peer, .{ .read = bufs.read, .write = bufs.write })) {
            .accepted => |conn| conn,
            .failed => |failure| return failure,
        };
        try self.adoptConn(session, conn, bufs);
        return null;
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
    fn bindWire(
        self: *HostRuntime,
        session: *driver_core.HostSession,
        locator: model.PeerLocator,
        options: net.OperationOptions,
    ) !void {
        const provider = self.providerFor(locator.transport) orelse return Error.UnknownTransport;
        switch (provider.source) {
            .stream => |nl| {
                if (!nl.supportsDial()) return Error.UnknownTransport;
                try self.bindStreamWire(session, locator, nl, options);
            },
            .resident => |resident_index| {
                const dialer = self.residents.items[resident_index].resident.dialer() orelse
                    return Error.UnknownTransport;
                try self.bindResidentWire(session, resident_index, dialer, locator, options);
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
        options: net.OperationOptions,
    ) !void {
        const bufs = try self.allocBufs();
        errdefer self.freeBufs(bufs);
        const conn = try nl.dial(
            session.served.port.peer,
            locator,
            .{ .read = bufs.read, .write = bufs.write },
            options,
        );
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
        options: net.OperationOptions,
    ) !void {
        const runtime = &self.residents.items[resident_index];
        const resident = runtime.resident;
        const request_id = try mintRuntimeId(&runtime.next_request);
        var attempt = switch (dialer.startDial(
            request_id,
            locator,
            options,
        )) {
            .admitted => |attempt| attempt,
            .failed => |failure| return failure.classification,
        };
        defer if (attempt.deinit()) |failure| self.noteTerminalFailureChain(failure);
        var conn = try self.awaitResidentConnect(resident_index, &attempt, self.opts.handshake);
        defer if (conn.deinit()) |failure| self.noteTerminalFailureChain(failure);
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
        attempt: *net.multiplexed_resident.DialAttempt,
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
            self.advancePendingListeners();
            if (wait.ready) return switch (attempt.finish()) {
                .connected => |conn| conn,
                .failed => |failure| failure.classification,
            };
            const timeout: i32 = if (deadline_ms) |d| blk: {
                const remaining = d - net.clock.nowMs(self.io);
                if (remaining <= 0) return Error.HandshakeTimedOut;
                break :blk std.math.cast(i32, remaining) orelse std.math.maxInt(i32);
            } else -1;
            const source = try self.waitAnySource(timeout, false) orelse continue;
            switch (source) {
                .wire => |wire| _ = try self.feedReadable(wire, null),
                .resident => |index| _ = try self.serviceResident(index, null),
                .stream_dial => |row| try self.adoptPendingStreamDial(row),
                .stream_listen => |row| self.finishPendingListener(row),
                .stream_accept => |listener| _ = try self.acceptReady(listener),
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
        errdefer self.removeReadyFd(handle);
        if (self.close_observer) |observer| try observer.reserve(observer.ctx);
        errdefer if (self.close_observer) |observer| observer.release(observer.ctx);
        try self.wires.ensureUnusedCapacity(self.allocator, 1);
        const wire = try self.allocator.create(Wire);
        wire.* = .{
            .link = .{ .stream = .{ .conn = owned_conn, .read_buf = bufs.read, .write_buf = bufs.write } },
            .session = session,
            .close_event_reserved = self.close_observer != null,
        };
        self.wires.putAssumeCapacity(session.peer_id, wire);
        self.open_wire_count += 1;
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
        if (self.close_observer) |observer| try observer.reserve(observer.ctx);
        errdefer if (self.close_observer) |observer| observer.release(observer.ctx);
        try self.wires.ensureUnusedCapacity(self.allocator, 1);
        try self.resident_wires.ensureUnusedCapacity(self.allocator, 1);
        const wire = try self.allocator.create(Wire);
        wire.* = .{
            .link = .{ .resident = .{ .index = resident_index, .conn = conn, .read_buf = read_buf } },
            .session = session,
            .close_event_reserved = self.close_observer != null,
        };
        self.wires.putAssumeCapacity(session.peer_id, wire);
        self.resident_wires.putAssumeCapacity(
            .{ .resident = resident_index, .conn = conn },
            wire,
        );
        self.open_wire_count += 1;
        _ = claimed.take();
    }

    /// Free one wire's transport and buffers. The caller owns the `wires`
    /// row; the resident routing row leaves here, with the link it routes.
    fn freeWire(self: *HostRuntime, wire: *Wire) void {
        if (wire.close_event_reserved) {
            const observer = self.close_observer orelse unreachable;
            observer.release(observer.ctx);
            wire.close_event_reserved = false;
        }
        if (!wire.closed) {
            std.debug.assert(self.open_wire_count != 0);
            self.open_wire_count -= 1;
        }
        switch (wire.link) {
            .stream => |*stream| {
                // Tolerant re-remove: `closeWire` already swept a closed
                // wire's fd, but a release without a close comes here first.
                if (stream.conn.socketHandle()) |fd| self.removeReadyFd(fd);
                stream.conn.deinit();
                self.allocator.free(stream.read_buf);
                self.allocator.free(stream.write_buf);
            },
            .resident => |*rl| {
                std.debug.assert(self.resident_wires.remove(.{ .resident = rl.index, .conn = rl.conn }));
                if (self.residents.items[rl.index].resident.connClose(rl.conn)) |failure|
                    self.noteTerminalFailureChain(failure);
                if (rl.pending) |*pending| pending.frame.deinit();
                rl.parked.deinit(self.allocator);
                self.allocator.free(rl.read_buf);
            },
        }
        self.allocator.destroy(wire);
    }

    fn dropWire(self: *HostRuntime, peer_id: engine.PeerId) void {
        if (self.wires.fetchRemove(peer_id)) |kv| self.freeWire(kv.value);
    }

    /// Mark `wire` closed and break its session's far vows so every waiter
    /// hears the closure — without freeing anything. `cause` is null only for
    /// clean EOF or an owner-requested close; every fault crosses this one seam
    /// with its concrete cause. The shell and wire stay parked until their
    /// owner releases them (the view's deinit, or host teardown), because a
    /// view still holds the session pointer; freeing here is the double-release
    /// this split exists to prevent.
    fn closeWire(self: *HostRuntime, wire: *Wire, cause: ?anyerror) void {
        if (wire.closed) return;
        const failure = self.takeWireFailure(wire) orelse if (cause) |err| OperationFailure.fromError(err) else null;
        self.closeWireFailure(wire, failure);
    }

    fn takeWireFailure(self: *HostRuntime, wire: *Wire) ?OperationFailure {
        const chain = switch (wire.link) {
            .stream => |*sl| sl.conn.takeFailure(),
            .resident => |rl| self.residents.items[rl.index].resident.takeFailure(rl.conn),
        } orelse return null;
        return OperationFailure.fromChain(chain);
    }

    fn closeWireFailure(self: *HostRuntime, wire: *Wire, failure: ?OperationFailure) void {
        if (wire.closed) return;
        wire.closed = true;
        std.debug.assert(self.open_wire_count != 0);
        self.open_wire_count -= 1;
        // A closed stream wire leaves every wait immediately: its fd would
        // otherwise hold the armed readiness set readable forever while
        // `waitAnySource` skips it.
        switch (wire.link) {
            .stream => |*sl| if (sl.conn.socketHandle()) |fd| self.removeReadyFd(fd),
            .resident => {},
        }
        const reason = if (failure) |value| value.primaryName() else "connection closed";
        wire.session.host.transportClosed(wire.session, reason) catch |err|
            self.noteTerminalFailure(err);
        // A staged dial's session reports through the dial path when the
        // sweep sees the closed wire; the embedder has never held it, so a
        // close event here would name a session it cannot know.
        if (self.pendingOpenFor(wire.session)) |row| row.close_cause = failure;
        if (self.close_observer) |obs| {
            if (self.pendingOpenFor(wire.session) == null) {
                std.debug.assert(wire.close_event_reserved);
                wire.close_event_reserved = false;
                self.observer_callback_depth += 1;
                defer self.observer_callback_depth -= 1;
                obs.closed(
                    obs.ctx,
                    wire.session,
                    failure,
                );
            }
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
    pub fn unpublish(self: *HostRuntime, name: []const u8) !void {
        self.enterDriver();
        defer self.leaveDriver();
        return self.core.unpublish(name);
    }

    /// Adopt a settled/failed completion the enliven wait below is waiting
    /// for; ownership moves to `claimed_completion` and the wait frees it.
    fn claimCompletion(self: *HostRuntime, action: driver_core.HostAction) bool {
        if (!self.wouldClaimCompletion(action)) return false;
        self.claimed_completion = action;
        return true;
    }

    fn wouldClaimCompletion(self: *const HostRuntime, action: driver_core.HostAction) bool {
        const wanted = self.awaited_completion orelse return false;
        const vow_id = switch (action) {
            .settled => |settled| settled.vow_id,
            .failed => |failed| failed.vow_id,
            else => return false,
        };
        return vow_id == wanted and self.claimed_completion == null;
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
            try self.connectLocator(sturdy.peer, .inherit);
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
                const Projection = struct {
                    fn identity(_: void, value: driver_core.Value) anyerror!driver_core.Value {
                        return value;
                    }
                };
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                return switch (self.core.projectCompletion(action, arena.allocator(), {}, Projection.identity)) {
                    .settled => |settled| switch (settled.value) {
                        .capability => |capability| capability,
                        else => driver_core.Error.FetchNotACapability,
                    },
                    .failed => |failed| switch (failed.failure) {
                        .broken => driver_core.Error.FetchBroken,
                        .closed => driver_core.Error.ConnectionClosed,
                    },
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
    /// it is written first (a condemned session's abort must reach the
    /// partner). A transport refusal closes the wire through the ordinary
    /// observable failure path; post-commit core failures become the Runtime's
    /// sticky terminal cause. The core then breaks its vows and fail-closes
    /// sibling answers before the transport is released.
    pub fn releaseWire(self: *HostRuntime, session: *driver_core.HostSession) !void {
        self.enterDriver();
        defer self.leaveDriver();

        try self.releaseWireOwned(session);
    }

    fn releaseWireOwned(self: *HostRuntime, session: *driver_core.HostSession) !void {
        try self.refuseReentry();
        if (session.host != self.core) return Error.SessionNotOwned;
        const wire = self.wires.get(session.peer_id) orelse return Error.SessionNotOwned;
        if (wire.session != session) return Error.SessionNotOwned;
        const peer_id = session.peer_id;
        const claimed = wire.session_handle_claimed;
        if (!wire.closed)
            self.writeOutbound(wire) catch |err| self.closeWire(wire, err);
        // `releaseSession` has only pre-commit failure edges. Cross it before
        // consuming the wire so an error always leaves the caller's handle
        // retryable; everything below is the one-way ownership commit.
        try self.core.releaseSession(session);
        self.dropWire(peer_id);
        if (claimed) {
            std.debug.assert(self.claimed_session_handles != 0);
            self.claimed_session_handles -= 1;
        }
        self.drainActions() catch |err| self.noteTerminalFailure(err);
        // Retirement remains runtime work after this handle is consumed. A
        // refusal becomes sticky terminal state rather than an error that
        // invites the caller to reuse a freed session pointer.
        if (self.retiring and self.claimed_session_handles == 0)
            self.progressRetirement() catch |err| self.noteTerminalFailure(err);
    }

    /// Claim the one owning `driver.Session` handle permitted for a wire.
    /// Allocation happens before this call, so a successful claim never needs
    /// rollback and duplicate release authority is unrepresentable.
    pub fn claimSessionHandle(self: *HostRuntime, session: *driver_core.HostSession) Error!void {
        self.enterDriver();
        defer self.leaveDriver();
        try self.claimSessionHandleOwned(session);
    }

    fn claimSessionHandleOwned(self: *HostRuntime, session: *driver_core.HostSession) Error!void {
        const wire = self.wires.get(session.peer_id) orelse return Error.SessionNotOwned;
        if (wire.session != session) return Error.SessionNotOwned;
        if (wire.session_handle_claimed) return Error.SessionAlreadyOwned;
        wire.session_handle_claimed = true;
        self.claimed_session_handles += 1;
    }

    /// Resolve the live exporter session named by one opaque Host capability
    /// and ensure the Runtime's single application handle owns it. Repeated
    /// exposure is idempotent; a previously internal redeem wire is admitted
    /// as application work and claimed before its pointer crosses an adapter.
    pub fn claimReferenceExporter(self: *HostRuntime, raw_ref: u64) AdmissionError!?*driver_core.HostSession {
        self.enterDriver();
        defer self.leaveDriver();

        const session = self.core.capabilitySession(self.core.capabilityFromRaw(raw_ref)) orelse return null;
        const wire = self.wires.get(session.peer_id) orelse return null;
        if (wire.session != session) return null;
        if (!wire.session_handle_claimed) {
            try self.admitApplicationOperation();
            try self.claimSessionHandleOwned(session);
        }
        return session;
    }

    /// Whether this runtime still owns the exact session shell named by a
    /// queued adapter event. The peer id is carried separately so a stale event
    /// never dereferences a shell already released by the application.
    pub fn sessionEventIsLive(
        self: *const HostRuntime,
        peer_id: engine.PeerId,
        session: *const driver_core.HostSession,
    ) bool {
        const wire = self.wires.get(peer_id) orelse return false;
        return wire.session == session;
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
        try self.drainActionsWith(.operational);
    }

    fn drainActionsWith(self: *HostRuntime, effect_mode: ExternalEffectMode) !void {
        self.enterDriver();
        defer self.leaveDriver();
        // HostRuntime is the explicitly blocking front: unlike Bridge, it owns no
        // shared reactor turn to yield to. Preserve its to-quiescence contract
        // while the shared drain still exposes each finite core slice.
        while (try driver_core.drainActions(
            self.core,
            EntropySource{ .io = self.io },
            Exec{ .runtime = self, .effect_mode = effect_mode },
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
        effect_mode: ExternalEffectMode,

        pub fn prepare(self: Exec, action: driver_core.HostAction) !void {
            switch (action) {
                .settled, .failed => {},
                else => return,
            }
            if (self.runtime.wouldClaimCompletion(action)) return;
            if (self.runtime.completion_sink) |sink| try sink.reserve(sink.ctx);
        }

        pub fn flush(self: Exec, peer_id: engine.PeerId) !void {
            if (self.effect_mode == .cleanup_only) return;
            const wire = self.runtime.wires.get(peer_id) orelse return;
            if (wire.closed) return;
            self.runtime.writeOutbound(wire) catch |err| self.runtime.closeWire(wire, err);
        }

        pub fn close(self: Exec, peer_id: engine.PeerId) !void {
            const wire = self.runtime.wires.get(peer_id) orelse return;
            if (!wire.closed and self.effect_mode == .operational)
                self.runtime.writeOutbound(wire) catch |err| self.runtime.closeWire(wire, err);
            if (!wire.closed) self.runtime.closeWire(wire, null);
        }

        pub fn dial(self: Exec, d: @FieldType(driver_core.HostAction, "dial")) !void {
            if (self.effect_mode == .cleanup_only) {
                try self.runtime.core.dialFailed(d.ticket, "transport provider failed");
                return;
            }
            try self.runtime.answerDial(d.ticket);
        }

        pub fn cancelDial(self: Exec, d: @FieldType(driver_core.HostAction, "cancel_dial")) !void {
            self.runtime.cancelRedeemDial(d.ticket);
            try self.runtime.core.dialCancelled(d.ticket);
        }

        pub fn complete(self: Exec, action: driver_core.HostAction) !void {
            if (self.runtime.claimCompletion(action)) return;
            if (self.runtime.completion_sink) |sink| {
                if (sink.take(sink.ctx, action)) return;
                sink.release(sink.ctx);
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
        // stageDial borrows the complete active route for this call.
        self.stageDial(pending, .inherit, .{ .redeem = ticket }, .pending_dial) catch |err| {
            try self.core.dialFailed(ticket, @errorName(err));
            return;
        };
    }

    /// Interrupt one native redeem dial selected by the core's cancellation
    /// action. Public dials and accepts have their own observers and are
    /// retired by `cancelPendingRuntimeWork`; this command names only the
    /// core ticket whose external effect must acknowledge retirement.
    fn cancelRedeemDial(self: *HostRuntime, ticket: engine.Node.PendingId) void {
        for (self.pending_opens.items, 0..) |row, index| switch (row.outcome) {
            .redeem => |pending| if (pending == ticket) {
                std.debug.assert(self.pending_opens.swapRemove(index) == row);
                var discarded = self.discardPendingOpen(row);
                if (discarded.cleanup) |cleanup| self.noteTerminalFailureChain(cleanup);
                discarded.admission.release();
                return;
            },
            .operation, .listener_accept => {},
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

    /// Stop dispatching `session`'s inbound until `attendSession`: the event
    /// queue is about to surface it, and the embedder has not run its
    /// post-open setup (publish, spawn). A stream wire's socket leaves the
    /// readiness set so kernel-held bytes cannot spin a parked embedder;
    /// `waitAnySource` already skips unattended wires.
    pub fn markSessionUnattended(self: *HostRuntime, session: *driver_core.HostSession) void {
        const wire = self.wires.get(session.peer_id) orelse return;
        if (wire.closed or !wire.attended) return;
        wire.attended = false;
        switch (wire.link) {
            .stream => |*sl| if (sl.conn.socketHandle()) |fd| self.removeReadyFd(fd),
            .resident => {},
        }
    }

    /// The embedder announced it is serving `session`: deliver inbound from
    /// here on. Bytes that arrived first replay in order — a resident link's
    /// parked chunks feed now, a paused handshake tail resumes through the
    /// next step's sweep, and a stream socket rejoins the readiness set.
    /// Idempotent on a session already delivering; a foreign or unknown
    /// handle refuses, exactly as release does, because silently ignoring
    /// one leaves the real session's inbound held with nothing to say why.
    pub fn attendSession(self: *HostRuntime, session: *driver_core.HostSession) !void {
        if (session.host != self.core) return Error.SessionNotOwned;
        const wire = self.wires.get(session.peer_id) orelse return Error.SessionNotOwned;
        if (wire.session != session) return Error.SessionNotOwned;
        if (wire.closed or wire.attended) return;
        wire.attended = true;
        switch (wire.link) {
            .stream => |*sl| if (self.ready_set) |*rs| if (sl.conn.socketHandle()) |fd| {
                rs.add(fd) catch |err| {
                    wire.attended = false;
                    return err;
                };
            },
            .resident => |*rl| if (rl.parked.items.len > 0) {
                const parked = rl.parked.items;
                self.core.feedBytes(wire.session, parked) catch |err| {
                    const failure = net.classifyApplyError(err);
                    self.drainActions() catch |drain_err| {
                        self.closeWire(wire, failure);
                        return drain_err;
                    };
                    self.closeWire(wire, failure);
                    return;
                };
                rl.parked.clearAndFree(self.allocator);
            },
        }
        // A parked embedder must re-poll: the rejoined fd or the resumable
        // tail is progress its current wait set cannot see.
        if (self.ready_set) |*rs| rs.postWake() catch |err| self.noteTerminalFailure(err);
    }

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
            if (!wire.attended) continue;
            if (wire.session == skip) continue;
            if (wire.session.pausedInboundPending()) {
                self.core.feedBytes(wire.session, &.{}) catch |err| {
                    const failure = net.classifyApplyError(err);
                    self.drainActions() catch |drain_err| {
                        self.closeWire(wire, failure);
                        return drain_err;
                    };
                    self.closeWire(wire, failure);
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
            self.advancePendingListeners();
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
                .stream_dial => |row| try self.adoptPendingStreamDial(row),
                .stream_listen => |row| self.finishPendingListener(row),
                .stream_accept => |listener| _ = try self.acceptReady(listener),
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
            error.ConnectionLost => {
                self.closeWire(wire, error.ConnectionLost);
                return .closed;
            },
            error.TruncatedFrame => {
                self.closeWire(wire, error.TruncatedFrame);
                return .closed;
            },
            error.EndOfStream => {
                self.closeWire(wire, null);
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
        try self.applySettleMailboxWith(.operational);
    }

    fn applySettleMailboxWith(self: *HostRuntime, effect_mode: ExternalEffectMode) !void {
        const mb = self.mailbox orelse return;
        var first_failure: ?anyerror = null;
        mb.drainWake() catch |err| {
            first_failure = err;
        };
        mb.apply(self.io, self.core) catch |err| {
            if (first_failure == null) first_failure = err;
        };
        self.drainActionsWith(effect_mode) catch |err| {
            if (first_failure == null) first_failure = err;
        };
        if (first_failure) |err| {
            self.noteTerminalFailure(err);
            return err;
        }
    }

    /// Fill the scratch lists with the live stream wires and every resident's
    /// readiness descriptor, and wait for the first ready source. Null on
    /// timeout, and on the mailbox wake (applying is the loop top's job,
    /// which runs whether or not the poll happened to select that row).
    fn waitAnySource(self: *HostRuntime, timeout_ms: i32, empty_ok: bool) !?ReadySource {
        if (self.ready_set) |*rs| rs.drainWake() catch |err| {
            self.noteTerminalFailure(err);
            return err;
        };
        self.conn_scratch.clearRetainingCapacity();
        var it = self.wires.valueIterator();
        while (it.next()) |wire| {
            if (!wire.*.closed and wire.*.attended and wire.*.link == .stream) {
                try self.conn_scratch.append(self.allocator, wire.*);
            }
        }
        const n = self.conn_scratch.items.len;
        // A blocking verb with no source left has nothing that can ever wake
        // it; `stepAny` passes `empty_ok` because a step-driven host with no
        // session yet is parked on its own budget, not stranded.
        var staged_stream_dials: usize = 0;
        for (self.pending_opens.items) |row| if (row.stage == .stream_dial) {
            staged_stream_dials += 1;
        };
        if (n == 0 and self.residents.items.len == 0 and staged_stream_dials == 0 and
            self.pending_listeners.items.len == 0 and !empty_ok)
            return Error.ConnectionClosed;
        if (n > 0) {
            std.mem.rotate(*Wire, self.conn_scratch.items, self.wait_cursor % n);
            self.wait_cursor +%= 1;
        }
        self.extra_fd_scratch.clearRetainingCapacity();
        for (self.residents.items) |runtime| {
            try self.extra_fd_scratch.append(self.allocator, runtime.readiness_fd);
        }
        self.dial_scratch.clearRetainingCapacity();
        for (self.pending_opens.items) |row| switch (row.stage) {
            .stream_dial => |attempt| {
                try self.dial_scratch.append(self.allocator, row);
                try self.extra_fd_scratch.append(self.allocator, attempt.readinessFd());
            },
            .resident_dial, .handshake => {},
        };
        self.listen_scratch.clearRetainingCapacity();
        for (self.pending_listeners.items) |row| switch (row.stage) {
            .stream => |attempt| {
                try self.listen_scratch.append(self.allocator, row);
                try self.extra_fd_scratch.append(self.allocator, attempt.readinessFd());
            },
            .resident => {},
        };
        self.active_listener_scratch.clearRetainingCapacity();
        var listener_it = self.active_listeners.valueIterator();
        while (listener_it.next()) |listener| switch (listener.transport.source) {
            .stream => |stream| if (stream.handle.readinessFd()) |fd| {
                try self.active_listener_scratch.append(self.allocator, &listener.transport);
                try self.extra_fd_scratch.append(self.allocator, fd);
            },
            .resident => {},
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
            self.clampTimeoutToPendingWork(timeout_ms),
            self.extra_fd_scratch.items,
        ) orelse return null;
        if (idx < n) return .{ .wire = self.conn_scratch.items[idx] };
        const extra = idx - n;
        if (extra < self.residents.items.len) return .{ .resident = extra };
        const dial_index = extra - self.residents.items.len;
        if (dial_index < self.dial_scratch.items.len)
            return .{ .stream_dial = self.dial_scratch.items[dial_index] };
        const listen_index = dial_index - self.dial_scratch.items.len;
        if (listen_index < self.listen_scratch.items.len)
            return .{ .stream_listen = self.listen_scratch.items[listen_index] };
        const accept_index = listen_index - self.listen_scratch.items.len;
        if (accept_index < self.active_listener_scratch.items.len)
            return .{ .stream_accept = self.active_listener_scratch.items[accept_index] };
        return null;
    }

    /// Drain and answer one resident's ready records: dial completions release their
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
        if (event.events & er.ev_listen != 0) {
            if (self.pendingResidentListener(resident_index, event.subject)) |row| {
                self.finishPendingListener(row);
            } else if (self.residents.items[resident_index].resident.acceptor()) |acceptor| {
                if (acceptor.cancelListen(event.subject)) |failure| self.noteTerminalFailureChain(failure);
            }
            return 0;
        }
        if (event.events & er.ev_accept != 0) {
            const listener = self.resident_listeners.get(.{
                .resident = resident_index,
                .route = event.subject,
            }) orelse return 0;
            var conn = switch (listener.listener.finishAcceptDetailed()) {
                .connection => |conn| conn orelse return 0,
                .failed => |failure| {
                    self.failActiveListener(listener.observation.tag, OperationFailure.fromAcceptFailure(failure));
                    return 0;
                },
            };
            defer if (conn.deinit()) |failure| self.noteTerminalFailureChain(failure);
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
                try self.adoptPendingResidentDial(resident_index, row);
            } else {
                // The awaiting frame unwound (budget expiry, caller error)
                // before the connect completed; release the resident's half.
                if (dialer.cancelDial(event.subject)) |failure| self.noteTerminalFailureChain(failure);
            }
            return 0;
        }
        const wire = self.resident_wires.get(.{
            .resident = resident_index,
            .conn = event.subject,
        }) orelse return 0;
        if (wire.closed) return 0;
        if (event.events & er.ev_writable != 0) {
            self.writeOutbound(wire) catch |err| self.closeWire(wire, err);
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
        // Clean resident EOF is always READABLE|CLOSED: `feedReadable` drains
        // the buffered tail and observes the zero read above. CLOSED alone is
        // the resident's fault signal (reader or writer failure).
        if (event.events & er.ev_closed != 0) self.closeWire(wire, error.ConnectionLost);
        return own_fed;
    }

    /// Adopt one connection claimed from a resident accept queue and park its
    /// CapTP handshake under the same observer path as a stream listener.
    fn startAcceptedResidentConn(
        self: *HostRuntime,
        resident_index: usize,
        conn: *net.multiplexed_resident.ClaimedConnection,
        transport: []const u8,
        observation: SessionAcceptObservation,
    ) !void {
        var admission = try self.acquireOpenAdmission(.application);
        errdefer admission.release();
        const observer = observation.observer;
        try observer.reserve(observer.ctx, observation.tag);
        errdefer observer.release(observer.ctx, observation.tag);
        const resident = self.residents.items[resident_index].resident;
        const session = try self.core.openAcceptedAdvertised(transport);
        errdefer {
            self.dropWire(session.peer_id);
            self.core.releaseSession(session) catch unreachable;
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
            .outcome = .{ .listener_accept = observation },
        };
        self.pending_opens.appendAssumeCapacity(row);
        const wire = self.wires.get(session.peer_id).?;
        self.writeOutbound(wire) catch |err| self.closeWire(wire, err);
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
            if (!wire.attended) {
                if (rl.parked.items.len + chunk.len > unattended_parked_cap_bytes)
                    return error.ConnectionLost;
                try rl.parked.appendSlice(self.allocator, chunk);
                total += chunk.len;
                continue;
            }
            self.core.feedBytes(wire.session, chunk) catch |err| {
                const failure = net.classifyApplyError(err);
                self.drainActions() catch |drain_err| {
                    self.closeWire(wire, failure);
                    return drain_err;
                };
                self.writeOutbound(wire) catch |write_err| {
                    self.closeWire(wire, write_err);
                    return failure;
                };
                self.closeWire(wire, failure);
                return failure;
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
            const failure = net.classifyApplyError(err);
            self.drainActions() catch |drain_err| {
                self.closeWire(wire, failure);
                return drain_err;
            };
            self.writeOutbound(wire) catch |write_err| {
                self.closeWire(wire, write_err);
                return failure;
            };
            self.closeWire(wire, failure);
            return failure;
        };
        r.toss(chunk.len);
        return chunk.len;
    }

    /// Pump until `flag` fires, under `budget` — the settle wait every view
    /// verb blocks through. The capture listener sets `flag` while a feed
    /// dispatches; the pump observes it at the next drain boundary.
    pub fn pumpUntilFlag(self: *HostRuntime, session: *driver_core.HostSession, flag: *const bool, budget: Budget) !void {
        try self.refuseReentry();
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
        try self.refuseReentry();
        self.enterDriver();
        defer self.leaveDriver();
        // Every wait on this face applies the mailbox first; `serve` runs
        // this one rather than `pumpUntilProbe`, and a settle must not wait
        // for whichever loop the caller happened to pick.
        try self.applySettleMailbox();
        try self.resumeFeedTails(null);
        try self.drainActions();
        try self.advancePendingOpens();
        self.advancePendingListeners();
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
            .stream_dial => |row| {
                try self.adoptPendingStreamDial(row);
                try self.drainActions();
                return .idle;
            },
            .stream_listen => |row| {
                self.finishPendingListener(row);
                return .idle;
            },
            .stream_accept => |listener| {
                _ = try self.acceptReady(listener);
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
        try self.refuseReentry();
        self.enterDriver();
        defer self.leaveDriver();
        return self.stepAnyOwned(timeout_ms, .none);
    }

    fn stepAnyToward(self: *HostRuntime, timeout_ms: i32, goal: StepGoal) !?net.Progress {
        self.enterDriver();
        defer self.leaveDriver();
        return self.stepAnyOwned(timeout_ms, goal);
    }

    fn stepAnyOwned(self: *HostRuntime, timeout_ms: i32, goal: StepGoal) !?net.Progress {
        if (self.terminal_failure) |failure| {
            return self.stepAfterTerminalFailure(timeout_ms, goal, failure);
        }
        try self.progressSessionCloses();
        try self.progressClose(.operational);
        if (self.closeOutcome() != .pending) return null;
        try self.applySettleMailbox();
        try self.resumeFeedTails(null);
        try self.drainActions();
        try self.advancePendingOpens();
        self.advancePendingListeners();
        if (self.terminal_failure) |failure| return failure.cause;
        // Immediate lifecycle work can satisfy a blocking convenience. Check
        // its barrier at the one boundary after which this step may park.
        if (goal.reached(self)) return null;
        const source = try self.waitAnySource(timeout_ms, true) orelse {
            // The park may have ended on a staged dial's clamped deadline;
            // settle it now rather than a step later.
            try self.advancePendingOpens();
            self.advancePendingListeners();
            try self.progressSessionCloses();
            try self.progressClose(.operational);
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
            .stream_dial => |row| try self.adoptPendingStreamDial(row),
            .stream_listen => |row| self.finishPendingListener(row),
            .stream_accept => |listener| _ = try self.acceptReady(listener),
        }
        try self.drainActions();
        try self.advancePendingOpens();
        self.advancePendingListeners();
        try self.progressSessionCloses();
        try self.progressClose(.operational);
        if (self.terminal_failure) |failure| return failure.cause;
        self.nudgeIfWorkRemains();
        return progress;
    }

    /// Keep core-owned close barriers executable after a provider violates its
    /// contract without making another operational call through that provider.
    /// Only mailbox settles, monotonic deadlines, and release callbacks remain
    /// live. The wake posted by close initiation is consumed here explicitly;
    /// leaving it unread would turn accidental busy-spinning into liveness.
    fn stepAfterTerminalFailure(
        self: *HostRuntime,
        timeout_ms: i32,
        goal: StepGoal,
        failure: OperationFailure,
    ) !?net.Progress {
        if (!self.terminalCleanupPending()) return failure.cause;
        if (self.ready_set) |*ready_set| ready_set.drainWake() catch |err|
            self.noteTerminalFailure(err);

        try self.applySettleMailboxWith(.cleanup_only);
        try self.progressSessionCloses();
        try self.progressClose(.cleanup_only);
        if (goal.reached(self) or !self.terminalCleanupPending()) return null;

        try self.waitForTerminalSignal(timeout_ms);
        if (self.ready_set) |*ready_set| ready_set.drainWake() catch |err|
            self.noteTerminalFailure(err);
        try self.applySettleMailboxWith(.cleanup_only);
        try self.progressSessionCloses();
        try self.progressClose(.cleanup_only);
        return null;
    }

    /// Park only on sources that remain legal after provider fail-stop. Wire,
    /// resident, listener, and staged-open descriptors are deliberately absent.
    fn waitForTerminalSignal(self: *HostRuntime, timeout_ms: i32) !void {
        const timeout = self.clampTimeoutToPendingWork(timeout_ms);
        if (timeout == 0) return;

        self.extra_fd_scratch.clearRetainingCapacity();
        if (self.mailbox) |mailbox|
            try self.extra_fd_scratch.append(self.allocator, mailbox.wakeFd());
        if (self.ready_set) |*ready_set|
            try self.extra_fd_scratch.append(self.allocator, ready_set.wakeFd());

        if (self.extra_fd_scratch.items.len == 0) {
            const sleep_ms = if (timeout < 0) std.math.maxInt(i32) else timeout;
            try std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(sleep_ms), .awake);
            return;
        }
        try self.poll_scratch.resize(self.allocator, self.extra_fd_scratch.items.len);
        _ = try net.waitAnyReadable(&.{}, self.poll_scratch.items, timeout, self.extra_fd_scratch.items);
    }

    fn terminalCleanupPending(self: *HostRuntime) bool {
        switch (self.core.lifecyclePhase()) {
            .finishing, .terminating => return true,
            .closed => return false,
            .active => {},
        }
        var wires = self.wires.valueIterator();
        while (wires.next()) |wire| {
            if (wire.*.session.lifecyclePhase() != .active) return true;
        }
        return false;
    }

    /// The self-wake nudge behind `stepAny`: a stream wire holding raw bytes
    /// in its userland read buffer is work no kernel set reports, so leave
    /// the armed readiness set readable rather than parking over it.
    fn nudgeIfWorkRemains(self: *HostRuntime) void {
        const rs = if (self.ready_set) |*r| r else return;
        if (self.deferred_session_releases != null) {
            rs.postWake() catch |err| self.noteTerminalFailure(err);
            return;
        }
        var it = self.wires.valueIterator();
        while (it.next()) |wire| {
            if (wire.*.closed) continue;
            // Paused inbound — a held feed tail, or a sealed session's staged
            // channel bytes — already left the kernel too; the next step's
            // resume sweep consumes it, so the wake must fire for it as well.
            if (wire.*.session.pausedInboundPending()) {
                rs.postWake() catch |err| self.noteTerminalFailure(err);
                return;
            }
            switch (wire.*.link) {
                .stream => |*sl| if (sl.conn.hasBufferedRaw()) {
                    rs.postWake() catch |err| self.noteTerminalFailure(err);
                    return;
                },
                .resident => {},
            }
        }
    }
};

fn reserveNothing(_: *anyopaque) anyerror!void {}

fn releaseNothing(_: *anyopaque) void {}
