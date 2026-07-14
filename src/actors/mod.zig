//! pancake's actor layer — Goblins-shaped objects on top of the engine, and the
//! seam where the actor architecture meets OCapN.
//!
//! A `Vat` is a turn loop over actors. You `spawn` local actors, near-call them
//! (`$`, `Vat.near`, synchronous, same-vat only), or eventual-send (`<-`,
//! `Vat.send`, returning a `Vow`). A `Ref` is local *or* far, and a
//! peer-bound vat routes `send` uniformly: a local target queues a turn, a far
//! target leaves as an `op:deliver` over the peer. `Vat.bindExport` binds a local
//! actor to an export position so a partner's deliveries run it (the driver's
//! `publish` rides on it), and `Vat.serve` dispatches inbound peer
//! events — a deliver runs the actor and resolves the answer, a resolution fires
//! the matching far vow's listener. The vat is sync and owns no I/O: it rides
//! on the engine (imports it, never the reverse), enqueuing onto the peer's
//! outbound queue and reading its events while the application drives the socket.

const vat = @import("vat.zig");
const ocap_mod = @import("ocap.zig");

pub const Vat = vat.Vat;
pub const Turn = vat.Turn;
pub const Ref = vat.Ref;
pub const Vow = vat.Vow;
pub const Message = vat.Message;
pub const Resolution = vat.Resolution;
pub const Give = vat.Give;
pub const ResolveInterceptor = vat.ResolveInterceptor;
pub const InterceptOutcome = vat.InterceptOutcome;
pub const Listener = vat.Listener;
pub const HostedActor = vat.HostedActor;
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
