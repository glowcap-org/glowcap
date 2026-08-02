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
const vocab = @import("vocab.zig");
const host = @import("host.zig");
const capability = @import("capability.zig");
const value = @import("value.zig");
const host_action = @import("host_action.zig");
const crossed_hellos = @import("crossed_hellos.zig");
const action_drain = @import("action_drain.zig");
const dial_plan = @import("dial_plan.zig");
const gc = @import("gc.zig");

/// Stateless GC emission after a serve event (ADR-0008). `Served` wires this
/// internally; the named export exists for the unit test that pins the nested-
/// introduction balance without constructing a full `Served`.
pub const emitStatelessAfter = gc.emitStatelessAfter;
pub const drainActions = action_drain.drainActions;

pub const Served = served.Served;
pub const ServeOptions = served.ServeOptions;
pub const BeforeServeHook = served.BeforeServeHook;
pub const Publish = served.Publish;

// The byte-fed multi-session CapTP host core (ADR-0072): the node's decisions
// executed with no socket (see `host.zig`). `driver.Bridge` and
// the C ABI's `libpancake_host` are its embedders.
pub const Host = host.Host;
pub const HostSession = host.HostSession;
pub const HostAction = host_action.HostAction;
pub const CrossedHellos = crossed_hellos.CrossedHellos;
pub const HostError = host.HostError;
pub const EnlivenPeerPolicy = host.EnlivenPeerPolicy;
pub const PeerProvenance = host.PeerProvenance;
pub const EnlivenStart = host.EnlivenStart;
/// The opaque Host-scoped capability identity (ADR-0096): what an owning-tier
/// application holds instead of an actor id or a wire position. The same
/// identity the C ABI and every binding carry as their `Ref`.
pub const Capability = capability.Ref;
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
pub const designatorSchemeForTransport = vocab.designatorSchemeForTransport;
pub const spawnAt = vocab.spawnAt;

pub const DialPlan = dial_plan.DialPlan;
pub const DialShape = dial_plan.Shape;
pub const DialPosture = dial_plan.Posture;
pub const AcceptPlan = dial_plan.AcceptPlan;
pub const planDial = dial_plan.planDial;
pub const planAccept = dial_plan.planAccept;
