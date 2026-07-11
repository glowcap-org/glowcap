//! The sans-io driver core: the vat serve loop (`Served`), its options, the
//! shared vocabulary, and stateless GC — everything the driver tier needs that
//! touches no socket. This layer is `core = true` in `build.zig`'s
//! `layer_table`, so blocking I/O, sockets, and threads are an `arch-check`
//! failure here, exactly as they are in `engine`. It gives the serve core the
//! same I/O ban `engine.Node` already has, so the boundary the driver stands on
//! is enforced by the build, not by convention (ADR-0072). The I/O bindings —
//! `ConnectedVat`, `driver.BlockingHost` (a socket loop over this layer's
//! `Host`), the transport constructors — live above it in `driver`.

const served = @import("served.zig");
const vocab = @import("vocab.zig");
const host = @import("host.zig");
const action_drain = @import("action_drain.zig");

pub const gc = @import("gc.zig");
pub const drainActions = action_drain.drainActions;

pub const Served = served.Served;
pub const ServeOptions = served.ServeOptions;
pub const BeforeServeHook = served.BeforeServeHook;
pub const Publish = served.Publish;
pub const makeKeyedPeer = vocab.makeKeyedPeer;

// The byte-fed multi-connection host core (ADR-0072): the node's decisions
// executed with no socket (see `host.zig`). The `driver.BlockingHost` and
// the C ABI's `libpancake_driver` are its embedders.
pub const Host = host.Host;
pub const HostConnection = host.HostConnection;
pub const HostAction = host.HostAction;
pub const CrossedHellos = host.CrossedHellos;
pub const HostError = host.HostError;

pub const Error = vocab.Error;
pub const SettleCapture = vocab.SettleCapture;
pub const SettleFlag = vocab.SettleFlag;
pub const FetchCapture = vocab.FetchCapture;
pub const Identity = vocab.Identity;
pub const AcceptIdentity = vocab.AcceptIdentity;
pub const Vow = vocab.Vow;
pub const Capability = vocab.Capability;
pub const Settled = vocab.Settled;
pub const unreachable_client_designator = vocab.unreachable_client_designator;
pub const spawnAt = vocab.spawnAt;
