//! pancake's actor layer — Goblins-shaped objects on top of the engine, and the
//! seam where the actor architecture meets OCapN.
//!
//! A `Vat` is a turn loop over actors. You `spawn` local actors, near-call them
//! (`$`, `Vat.near`, synchronous, same-vat only), or eventual-send (`<-`,
//! `Vat.send`, returning a `Vow`). A `Ref` is local *or* far, and a
//! `Port` routes `send` uniformly: a local target queues a Vat turn; a far target
//! leaves as an `op:deliver` over that Port's peer. Ports own wire exports and
//! far-vow answer names while the Vat owns actors and scheduling. Both remain
//! sync and no-I/O; the application drives the socket.

const vat = @import("vat/mod.zig");
const ocap_mod = @import("ocap.zig");

pub const Vat = vat.Vat;
pub const Port = vat.Port;
pub const Turn = vat.Turn;
pub const Ref = vat.Ref;
pub const Vow = vat.Vow;
pub const Message = vat.Message;
pub const IngressId = vat.IngressId;
pub const QueueLimits = vat.QueueLimits;
pub const Resolution = vat.Resolution;
pub const Give = vat.Give;
pub const ResolveInterceptor = vat.ResolveInterceptor;
pub const InterceptOutcome = vat.InterceptOutcome;
pub const Listener = vat.Listener;
pub const HostedActor = vat.HostedActor;
pub const steady_turn_arena_bytes = vat.steady_turn_arena_bytes;
pub const steady_spare_arena_bytes = vat.steady_spare_arena_bytes;
pub const steady_settle_arena_bytes = vat.steady_settle_arena_bytes;
pub const steady_list_bytes = vat.steady_list_bytes;
/// A point-in-time capture of every snapshottable actor's state
/// (`Vat.snapshot`), restored with `Vat.restore` — re-exported so a consumer
/// can name the value it holds between the two calls (ADR-0060).
pub const Snapshot = vat.Snapshot;
pub const Error = vat.Error;

/// Object-capability forwarding proxies — a revocable caretaker and a verb
/// allow-list attenuator — over any local or far reference.
pub const ocap = ocap_mod;
pub const caretaker = ocap_mod.caretaker;
pub const attenuate = ocap_mod.attenuate;
