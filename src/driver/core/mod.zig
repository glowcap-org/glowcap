//! The sans-io driver core: the vat serve loop (`Served`), its options, the
//! shared vocabulary, and stateless GC — everything the driver tier needs that
//! touches no socket. This layer is `core = true` in `build.zig`'s
//! `layer_table`, so blocking I/O, sockets, and threads are an `arch-check`
//! failure here, exactly as they are in `engine`. It gives the serve core the
//! same I/O ban `engine.Node` already has, so the boundary the driver stands on
//! is enforced by the build, not by convention (ADR-0072). The I/O bindings —
//! `BlockingSession`, `driver.Bridge` (the completion-loop embedder over this
//! layer's `Host`), the transport constructors — live above it in `driver`.

const served = @import("served.zig");
const builtin = @import("builtin");
const vocab = @import("vocab.zig");
const host = @import("host.zig");
const capability = @import("capability.zig");
const value = @import("value.zig");
const host_action = @import("host/action.zig");
const crossed_hellos = @import("crossed_hellos.zig");
const action_drain = @import("action_drain.zig");
const dial_plan = @import("dial_plan.zig");
const gc = @import("gc.zig");
const host_pump = @import("host/pump.zig");
const close = @import("close.zig");

/// Narrow support for white-box core tests. Empty in production builds so
/// pump mechanics and direct GC emission never become embedder API.
pub const testing = if (builtin.is_test) struct {
    pub const queueUniqueSessionAction = host_pump.testing.queueUniqueSessionAction;

    pub fn emitStatelessAfter(peer: *@import("engine").Peer, event: *@import("engine").Event) !void {
        try gc.emitStatelessAfter(peer, event);
    }

    pub fn condemn(core_host: *host.Host, session: *host.HostSession, kind: @import("model").AbortKind, message: []const u8) !void {
        try host_pump.condemn(core_host, session, kind, message);
    }

    pub fn markDirty(core_host: *host.Host, peer_handle: @import("engine").PeerHandle) void {
        host_pump.testing.markDirty(core_host, peer_handle);
    }

    pub fn finishCommittedWork(core_host: *host.Host, session: *host.HostSession) void {
        host_pump.finishCommittedWork(core_host, session);
    }

    pub fn retainFailureMessage(allocator: @import("std").mem.Allocator, message: []const u8) host_action.RetainedFailureMessage {
        return host_action.retainFailureMessage(allocator, message);
    }
} else struct {};
pub const drainActions = action_drain.drainActions;
pub const DrainResult = action_drain.DrainResult;

pub const Served = served.Served;
pub const DriveError = served.DriveError;
pub const ServeOptions = served.ServeOptions;
pub const BeforeServeHook = served.BeforeServeHook;
pub const Publish = served.Publish;
pub const default_loop_local_turn_budget = served.default_loop_local_turn_budget;

// The byte-fed multi-session CapTP host core (ADR-0072): the node's decisions
// executed with no socket (see `host.zig`). `driver.Bridge` and
// the C ABI's `libpancake_host` are its embedders.
pub const Host = host.Host;
pub const HostSession = host.HostSession;
/// The sealed byte channel (ADR-0107): the Noise_XK composition a sealed
/// `HostSession` runs its wire through. Its ephemeral derives from the unique
/// per-session signing seed; embedders supply one fresh session root per Host.
pub const HostAction = host_action.HostAction;
pub const VowFailure = host_action.VowFailure;
pub const HostFailure = @import("host/failure.zig").HostFailure;
/// The live trace tap: the sink vocabulary a Host reports its own session
/// opens, message verbs, and closes through (`Host.setTrace`).
pub const trace = @import("trace.zig");
pub const CrossedHellos = crossed_hellos.CrossedHellos;
pub const DialTarget = crossed_hellos.DialTarget;
pub const HostError = host.HostError;
pub const SessionReleaseError = host.SessionReleaseError;
pub const HostInitError = host.Host.InitError;
pub const PendingWork = close.PendingWork;
pub const PendingWorkInput = close.PendingWorkInput;
pub const CloseGrace = close.Grace;
pub const max_finite_close_grace_ms = close.max_finite_grace_ms;
pub const CloseOutcome = close.CloseOutcome;
pub const EnlivenPeerPolicy = host.EnlivenPeerPolicy;
pub const PeerProvenance = host.PeerProvenance;
pub const EnlivenStart = host.EnlivenStart;
/// The opaque Host-scoped capability identity (ADR-0096): what an owning-tier
/// application holds instead of an actor id or a wire position. The same
/// identity the C ABI and every binding carry as their `Ref`.
pub const Capability = capability.Ref;
/// Injection seam for adapters that erase a native capability's Registry
/// pointer. The adapter owns any synchronization and process-wide state.
pub const CapabilityIdIssuer = capability.IdIssuer;
/// The owning tier's passable value and reply (see `value.zig`): data arms
/// mirror `model.Argument`, capability mentions are opaque.
pub const Value = value.Value;
pub const Reply = value.Reply;
/// The Value-shaped hosted-behavior adapter and its per-delivery window
/// (see `host.zig`): how an owning-tier behavior answers with opaque
/// capabilities instead of wire references.
pub const Hosting = host.Hosting;
pub const HostTurn = host.HostTurn;

pub const Error = vocab.Error;
pub const default_handshake_timeout_ms = vocab.default_handshake_timeout_ms;
pub const default_handshake_budget = vocab.default_handshake_budget;
pub const discovery_retry_ms = vocab.discovery_retry_ms;
pub const discovery_max_attempts = vocab.discovery_max_attempts;
pub const max_local_forward_hops = vocab.max_local_forward_hops;
pub const Budget = vocab.Budget;
pub const SettleCapture = vocab.SettleCapture;
pub const SettleFlag = vocab.SettleFlag;
pub const FetchCapture = vocab.FetchCapture;
pub const Identity = vocab.Identity;
pub const PartnerIdentity = vocab.PartnerIdentity;
pub const DurableProvenance = vocab.DurableProvenance;
pub const AcceptIdentity = vocab.AcceptIdentity;
pub const Vow = vocab.Vow;
pub const Exported = vocab.Exported;
pub const Settled = vocab.Settled;
pub const unreachable_client_designator = vocab.unreachable_client_designator;
pub const DesignatorScheme = vocab.DesignatorScheme;
pub const spawnAt = vocab.spawnAt;

pub const DialPlan = dial_plan.DialPlan;
pub const DialShape = dial_plan.Shape;
pub const DialPosture = dial_plan.Posture;
pub const AcceptPlan = dial_plan.AcceptPlan;
pub const planDial = dial_plan.planDial;
pub const planDialProfile = dial_plan.planDialProfile;
pub const planAccept = dial_plan.planAccept;
