//! Goblins-shaped actors over the pancake peer, in native Rust.
//!
//! The actor model is a language-native layer on the typed peer surface, not a
//! wrapped C vat. A Rust actor is a Rust closure, the same way an async connection
//! is tokio rather than a foreign callback. A [`Vat`] holds local actors, each a
//! closure over a method verb and its arguments. When the vat is bound to a peer,
//! it also routes sends to remote objects over the wire. A leading symbol
//! argument is the method verb, matching Goblins's `($ obj 'method arg ...)`; the
//! rest are the call's arguments.
//!
//! The unified [`VatRef`] can name a local actor or a far object, and a [`Vow`]
//! can settle from a local turn or a wire answer. An application sends to a ref
//! without caring where it lives; the vat chooses the route. Two verbs mirror
//! Goblins:
//!
//!   * [`Vat::call`] is the synchronous near-call (`$`). It runs a local actor's
//!     behavior immediately and returns its value. It is legal only for a local
//!     ref, exactly as Goblins forbids `$` to a far ref.
//!   * [`Vat::send`] is the eventual send (`<-`). It is location-transparent: to a
//!     local ref it queues a turn, and to a far ref it sends an `op:deliver` over
//!     the bound peer. Either way it returns a [`Vow`] you observe with
//!     [`Vat::on`].

use crate::{Argument, Event, Peer, Reference, Resolution, Result};
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

/// An actor behavior: handle a `(verb, args)` call, returning a reply or an error
/// message (which becomes a broken resolution).
pub type Behavior = Box<dyn FnMut(&str, &[Argument]) -> std::result::Result<Argument, String>>;

/// A one-shot promise listener, fired with how the promise settled.
pub type Listener = Box<dyn FnOnce(Resolution)>;

/// A hook consulted before the vat resolves a delivered actor's answer
/// (ADR-0009, the gifter half). It is handed the answer and the reply the actor
/// returned; returning `true` claims the answer, the vat then leaves it
/// unresolved, so the hook can resolve it itself (a published actor that returns
/// a capability living on another connection originates a three-party handoff
/// rather than letting the vat encode a cross-connection reference). Returning
/// `false` falls through to the ordinary resolve.
pub type ResolveInterceptor = Box<dyn FnMut(u64, &Argument) -> bool>;

/// A reference the vat can eventual-send to, wherever the object lives.
#[derive(Debug, Clone, PartialEq)]
pub enum VatRef {
	/// An actor in this vat. `call` and `send` run its turns here.
	Local(u64),
	/// A partner-hosted object the bound peer holds. `send` routes to it as an
	/// `op:deliver`; `call` (near) is illegal.
	Far(Reference),
}

/// A handle to the eventual result of a [`Vat::send`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Vow {
	/// Result of a local send; settled by [`Vat::drive`].
	Local(u64),
	/// Result of a far send; the outbound answer position the partner resolves.
	Far(u64),
}

/// A behavior's tail-forward of its answer to another reference — the binding's
/// `Turn.forward` (ADR-0064). A forwarding behavior returns this instead of a
/// value, and the vat resolves the caller's answer from `target <- verb(args)`: a
/// local target near-calls (composing if it forwards again), a far target
/// eventual-sends and defers until the reply settles. It is the whole mechanism
/// behind a caretaker/attenuator — each is an ordinary actor whose behavior
/// forwards (or returns an error to refuse), so the proxy is a plain [`VatRef`] the
/// holder delegates and may call locally or over the wire alike.
pub struct Forward {
	/// The reference to forward to (local or far).
	pub target: VatRef,
	/// The verb to forward (the one the proxy was called with).
	pub verb: String,
	/// The arguments to forward (the ones the proxy was called with).
	pub args: Vec<Argument>,
}

/// A forwarding behavior: like a [`Behavior`], but it tail-forwards rather than
/// returning a value (or returns an error message to refuse the call).
type Forwarder = Box<dyn FnMut(&str, &[Argument]) -> std::result::Result<Forward, String>>;

/// An actor in the vat: an ordinary behavior that returns a value, or a forwarder
/// that tail-forwards its answer. Both dispatch through one path, so a forwarder
/// answers a local near-call exactly as it answers a partner's delivery.
enum Actor {
	Plain(Behavior),
	Forward(Forwarder),
}

/// One step of running an actor: a value to resolve with, or a forward to chase.
enum Step {
	Value(Argument),
	Forward(Forward),
}

/// How a delivered/driven turn settles: now, with a resolution (a value, a
/// refusal, or a fully near-called forward chain), or deferred onto a far
/// forward's promise that settles the answer when the reply arrives.
enum Outcome {
	Now(Resolution),
	Deferred(Vow),
}

/// A queued local eventual-send awaiting [`Vat::drive`].
struct Queued {
	target: u64,
	verb: String,
	args: Vec<Argument>,
	promise: u64,
}

/// A turn loop over local actors that, when bound to a peer, also routes far
/// sends over the wire and hosts published actors for inbound delivers.
///
/// A `Vat<'a>` borrows the peer it rides on (`&'a mut Peer`) so the borrow
/// checker keeps their lifetimes honest; drive the peer (feed/step/take_outbound)
/// through [`peer`](Vat::peer). The vat owns no I/O and no scheduler — it only
/// enqueues onto the peer's outbound queue and dispatches its events.
pub struct Vat<'a> {
	peer: Option<&'a mut Peer<'static>>,
	actors: HashMap<u64, Actor>,
	queue: Vec<Queued>,
	listeners: HashMap<u64, Listener>,
	/// Listener for a far send's promise, keyed by outbound answer position.
	far_listeners: HashMap<u64, Listener>,
	/// Local actor id for each export position published on the peer.
	exports: HashMap<u64, u64>,
	/// A wire answer an actor forwarded to a *far* target, awaiting that send's
	/// resolution. The forward listener cannot reach the peer, so it parks
	/// `(answer, resolution)` here; [`flush_forward_resolves`](Vat::flush_forward_resolves)
	/// drains it with peer access — the same deferral shape the enliven cache uses.
	forward_resolves: Rc<RefCell<Vec<(u64, Resolution)>>>,
	/// A *local* send's promise that a driven actor forwarded to a far target,
	/// awaiting that send's resolution — the local-call-of-a-far-proxy path. The
	/// far listener parks `(promise, resolution)` here;
	/// [`flush_forward_local_resolves`](Vat::flush_forward_local_resolves) settles
	/// the local promise once the wire reply arrives (ADR-0064).
	forward_local_resolves: Rc<RefCell<Vec<(u64, Resolution)>>>,
	/// Consulted before resolving a delivered actor's answer; claims the answer
	/// for the gifter half of a three-party handoff (ADR-0009).
	resolve_interceptor: Option<ResolveInterceptor>,
	next_actor: u64,
	next_promise: u64,
}

impl Default for Vat<'_> {
	fn default() -> Self {
		Vat::new()
	}
}

impl<'a> Vat<'a> {
	/// A pure-local vat (no wire). `call`/`send`/`drive` over local actors only.
	pub fn new() -> Vat<'a> {
		Vat {
			peer: None,
			actors: HashMap::new(),
			queue: Vec::new(),
			listeners: HashMap::new(),
			far_listeners: HashMap::new(),
			exports: HashMap::new(),
			forward_resolves: Rc::new(RefCell::new(Vec::new())),
			forward_local_resolves: Rc::new(RefCell::new(Vec::new())),
			resolve_interceptor: None,
			next_actor: 1,
			next_promise: 1,
		}
	}

	/// Install the [`ResolveInterceptor`] consulted before a delivered actor's
	/// answer is resolved. The connection driver sets this to originate the
	/// gifter half of a three-party handoff (ADR-0009) when a published actor
	/// returns a capability that lives on another connection.
	pub fn set_resolve_interceptor(
		&mut self,
		interceptor: impl FnMut(u64, &Argument) -> bool + 'static,
	) {
		self.resolve_interceptor = Some(Box::new(interceptor));
	}

	/// A vat bound to `peer`: far sends route to it, and [`publish`](Vat::publish)
	/// exports actors so inbound deliveries (via [`serve`](Vat::serve)) run them.
	pub fn over(peer: &'a mut Peer<'static>) -> Vat<'a> {
		let mut vat = Vat::new();
		vat.peer = Some(peer);
		vat
	}

	/// The peer this vat rides on, to feed/step/take_outbound around `serve`.
	/// Returns `None` for a pure-local vat.
	pub fn peer(&mut self) -> Option<&mut Peer<'static>> {
		self.peer.as_deref_mut()
	}

	/// Spawn a local actor, returning a local [`VatRef`].
	pub fn spawn(
		&mut self,
		behavior: impl FnMut(&str, &[Argument]) -> std::result::Result<Argument, String> + 'static,
	) -> VatRef {
		let id = self.next_actor;
		self.next_actor += 1;
		self.actors.insert(id, Actor::Plain(Box::new(behavior)));
		VatRef::Local(id)
	}

	/// The synchronous near-call (`$`): run `target`'s behavior now and return its
	/// value. Legal only for a local ref, a far ref must be reached with `send`.
	/// A forwarding actor (caretaker/attenuator) near-calls its target too, so a
	/// proxy over a local capability answers `$`; near-calling a proxy over a *far*
	/// target is the one illegal forward, since `$` cannot cross the wire.
	pub fn call(
		&mut self,
		target: &VatRef,
		verb: &str,
		args: &[Argument],
	) -> std::result::Result<Argument, String> {
		match target {
			VatRef::Local(id) => {
				let step = self.run_actor(*id, verb, args)?;
				self.resolve_step_near(step)
			}
			VatRef::Far(_) => Err("cannot near-call a far ref; use send".to_string()),
		}
	}

	/// Run one turn of the actor at `id`, yielding a value or a forward to chase.
	fn run_actor(
		&mut self,
		id: u64,
		verb: &str,
		args: &[Argument],
	) -> std::result::Result<Step, String> {
		match self
			.actors
			.get_mut(&id)
			.ok_or_else(|| "no such actor".to_string())?
		{
			Actor::Plain(behavior) => behavior(verb, args).map(Step::Value),
			Actor::Forward(forwarder) => forwarder(verb, args).map(Step::Forward),
		}
	}

	/// Resolve a step for a synchronous near-call: a value returns directly; a
	/// forward near-calls its (local) target and recurses, so a caretaker over an
	/// attenuator composes. A forward to a far target is illegal under `$`.
	fn resolve_step_near(&mut self, step: Step) -> std::result::Result<Argument, String> {
		match step {
			Step::Value(value) => Ok(value),
			Step::Forward(Forward { target, verb, args }) => match target {
				VatRef::Local(id) => {
					let inner = self.run_actor(id, &verb, &args)?;
					self.resolve_step_near(inner)
				}
				VatRef::Far(_) => {
					Err("cannot near-call a proxy forwarding to a far ref; use send".to_string())
				}
			},
		}
	}

	/// The eventual send (`<-`): location-transparent. A local target queues a
	/// turn for [`drive`](Vat::drive); a far target sends an `op:deliver` over the
	/// bound peer (a leading symbol carries the verb, matching Goblins's
	/// `($ obj 'method …)`). Returns a [`Vow`] for the result.
	pub fn send(&mut self, target: &VatRef, verb: &str, args: &[Argument]) -> Result<Vow> {
		match target {
			VatRef::Local(id) => {
				let promise = self.next_promise;
				self.next_promise += 1;
				self.queue.push(Queued {
					target: *id,
					verb: verb.to_string(),
					args: args.to_vec(),
					promise,
				});
				Ok(Vow::Local(promise))
			}
			VatRef::Far(reference) => {
				// The answer comes from the peer's one outbound-answer
				// allocator (`pancake_peer_next_answer`), so it can never
				// alias another question on the session.
				let answer = self
					.peer
					.as_deref_mut()
					.expect("a far send needs a bound peer")
					.next_answer()?;
				let mut full = Vec::with_capacity(args.len() + 1);
				// A non-empty verb leads as an OCapN symbol (Goblins's
				// `($ obj 'method …)`); an empty verb is a positional call with no
				// method symbol (Goblins's `(<- obj arg …)`), matching the Deno,
				// Python, and Racket vats.
				if !verb.is_empty() {
					full.push(Argument::Symbol(verb.to_string()));
				}
				full.extend_from_slice(args);
				let peer = self
					.peer
					.as_deref_mut()
					.expect("a far send needs a bound peer");
				peer.send_deliver(reference, &full, Some(answer))?;
				Ok(Vow::Far(answer))
			}
		}
	}

	/// Register a one-shot listener for `promise`. A local promise fires during
	/// [`drive`](Vat::drive); a far promise fires when the partner's resolution
	/// arrives and is dispatched by [`serve`](Vat::serve).
	pub fn on(&mut self, promise: Vow, listener: impl FnOnce(Resolution) + 'static) {
		match promise {
			Vow::Local(id) => {
				self.listeners.insert(id, Box::new(listener));
			}
			Vow::Far(answer) => {
				self.far_listeners.insert(answer, Box::new(listener));
			}
		}
	}

	/// Publish an actor at `export_position` so a partner's deliveries to it run the
	/// behavior. Registers the export on the bound peer and binds it. Requires a
	/// bound peer.
	pub fn publish(
		&mut self,
		export_position: u64,
		behavior: impl FnMut(&str, &[Argument]) -> std::result::Result<Argument, String> + 'static,
	) -> Result<VatRef> {
		let actor = self.spawn(behavior);
		let VatRef::Local(local_id) = actor else {
			unreachable!("spawn returns a local ref")
		};
		let peer = self
			.peer
			.as_deref_mut()
			.expect("publish needs a bound peer");
		peer.register_export(export_position)?;
		self.exports.insert(export_position, local_id);
		Ok(actor)
	}

	/// Publish a forwarding actor (a caretaker/attenuator, ADR-0064) at
	/// `export_position`: an ordinary export whose behavior tail-forwards rather
	/// than returning a value, so it answers a local near-call exactly as it
	/// answers a partner's delivery.
	pub fn publish_forwarder(
		&mut self,
		export_position: u64,
		forwarder: impl FnMut(&str, &[Argument]) -> std::result::Result<Forward, String> + 'static,
	) -> Result<()> {
		let local_id = self.next_actor;
		self.next_actor += 1;
		self.actors
			.insert(local_id, Actor::Forward(Box::new(forwarder)));
		let peer = self
			.peer
			.as_deref_mut()
			.expect("publish needs a bound peer");
		peer.register_export(export_position)?;
		self.exports.insert(export_position, local_id);
		Ok(())
	}

	/// Publish a caretaker at `export_position` forwarding to `target` (ADR-0064):
	/// every call forwards to `target` while `live` holds, then breaks with
	/// `Revoked`. The caller keeps the other handle to `live` and clears it to
	/// sever the proxy, no round trip, the way Zig's `RevokeCell` works.
	pub fn publish_caretaker(
		&mut self,
		export_position: u64,
		target: VatRef,
		live: Arc<AtomicBool>,
	) -> Result<()> {
		self.publish_forwarder(export_position, move |verb, args| {
			if !live.load(Ordering::SeqCst) {
				return Err("Revoked".to_string());
			}
			Ok(Forward {
				target: target.clone(),
				verb: verb.to_string(),
				args: args.to_vec(),
			})
		})
	}

	/// Publish an attenuator at `export_position` forwarding to `target`
	/// (ADR-0064): a call whose verb is in `verbs` forwards; any other breaks with
	/// `Attenuated`.
	pub fn publish_attenuator(
		&mut self,
		export_position: u64,
		target: VatRef,
		verbs: Vec<String>,
	) -> Result<()> {
		self.publish_forwarder(export_position, move |verb, args| {
			if !verbs.iter().any(|v| v == verb) {
				return Err("Attenuated".to_string());
			}
			Ok(Forward {
				target: target.clone(),
				verb: verb.to_string(),
				args: args.to_vec(),
			})
		})
	}

	/// Resolve the answers any proxy forwarded to a far target has settled. The
	/// forward listener parks them on a shared queue (it cannot reach the peer);
	/// this drains the queue and sends each resolve, the same deferral the enliven
	/// cache uses. The serve loop calls it after each served event.
	pub fn flush_forward_resolves(&mut self) -> Result<()> {
		loop {
			let pending: Vec<(u64, Resolution)> =
				self.forward_resolves.borrow_mut().drain(..).collect();
			if pending.is_empty() {
				break;
			}
			let peer = self
				.peer
				.as_deref_mut()
				.expect("resolving a forward needs a bound peer");
			for (answer, resolution) in pending {
				peer.send_resolve(answer, &resolution)?;
			}
		}
		Ok(())
	}

	/// Run the actor at `id` and resolve its answer: a value or a refusal settles
	/// now; a forward near-calls a local target (recursing, so caretaker over
	/// attenuator composes) and eventual-sends a far one, deferring the settle onto
	/// the reply. The one path the inbound-deliver and local-drive dispatch share,
	/// so a proxy behaves identically whoever calls it (ADR-0064's `Turn.forward`).
	fn dispatch(&mut self, id: u64, verb: &str, args: &[Argument]) -> Outcome {
		match self.run_actor(id, verb, args) {
			Ok(step) => self.resolve_step(step),
			Err(message) => Outcome::Now(Resolution::Break(message)),
		}
	}

	fn resolve_step(&mut self, step: Step) -> Outcome {
		match step {
			Step::Value(value) => Outcome::Now(Resolution::Fulfill(value)),
			Step::Forward(Forward { target, verb, args }) => match target {
				VatRef::Local(id) => match self.run_actor(id, &verb, &args) {
					Ok(inner) => self.resolve_step(inner),
					Err(message) => Outcome::Now(Resolution::Break(message)),
				},
				VatRef::Far(_) => match self.send(&target, &verb, &args) {
					Ok(promise) => Outcome::Deferred(promise),
					Err(_) => Outcome::Now(Resolution::Break(
						"a forward to a far target could not be sent".to_string(),
					)),
				},
			},
		}
	}

	/// Settle the local sends whose driven turn forwarded to a far target, now
	/// that the wire reply has arrived. The far listener parks each
	/// `(promise, resolution)`; this settles the local promise and fires its
	/// listener, the local-call-of-a-far-proxy counterpart to
	/// [`flush_forward_resolves`](Vat::flush_forward_resolves). The serve loop
	/// calls it after each served event.
	pub fn flush_forward_local_resolves(&mut self) {
		loop {
			let pending: Vec<(u64, Resolution)> =
				self.forward_local_resolves.borrow_mut().drain(..).collect();
			if pending.is_empty() {
				break;
			}
			for (promise, resolution) in pending {
				self.settle_local(promise, resolution);
			}
		}
	}

	/// Run queued local eventual-sends to quiescence, settling each promise with
	/// the behavior's value (or a break on error) and firing its listener. A turn
	/// that tail-forwards to a far target defers its promise onto that send's
	/// reply (settled later by [`flush_forward_local_resolves`](Vat::flush_forward_local_resolves)).
	/// Turns queued by a turn run in the same drive (FIFO).
	pub fn drive(&mut self) {
		let mut index = 0;
		while index < self.queue.len() {
			let Queued {
				target,
				verb,
				args,
				promise,
			} = std::mem::replace(
				&mut self.queue[index],
				Queued {
					target: 0,
					verb: String::new(),
					args: Vec::new(),
					promise: 0,
				},
			);
			index += 1;
			match self.dispatch(target, &verb, &args) {
				Outcome::Now(resolution) => self.settle_local(promise, resolution),
				Outcome::Deferred(far_promise) => {
					let queue = Rc::clone(&self.forward_local_resolves);
					self.on(far_promise, move |resolution| {
						queue
							.borrow_mut()
							.push((promise, normalize_forward(resolution)));
					});
				}
			}
		}
		self.queue.clear();
	}

	fn settle_local(&mut self, promise: u64, resolution: Resolution) {
		if let Some(listener) = self.listeners.remove(&promise) {
			listener(resolution);
		}
	}

	/// Map a wire reference to a vat target, routing a `Near` export this vat
	/// hosts to its local actor so a self-spawned cap resolves in-process rather
	/// than going out on the wire to its own export. A reference this vat does not
	/// host stays `Far`.
	pub fn resolve_target(&self, reference: &Reference) -> VatRef {
		if let Reference::Near { id, .. } = reference {
			if let Some(&local_id) = self.exports.get(id) {
				return VatRef::Local(local_id);
			}
		}
		VatRef::Far(reference.clone())
	}

	/// Dispatch one inbound peer event. A deliver to a published export runs the
	/// actor (leading symbol = verb) and resolves the answer with its reply; a
	/// resolve for a pending far promise fires its listener. Returns whether the
	/// event belonged to this vat (false means not ours; the caller handles it).
	pub fn serve(&mut self, event: &Event) -> Result<bool> {
		match event {
			Event::Deliver {
				target,
				args,
				answer,
			} => self.serve_deliver(target, args, *answer),
			Event::Resolve { answer, resolution } => Ok(self.serve_resolve(*answer, resolution)),
			_ => Ok(false),
		}
	}

	fn serve_deliver(
		&mut self,
		target: &Reference,
		args: &[Argument],
		answer: Option<u64>,
	) -> Result<bool> {
		let export_position = match target {
			Reference::Near { id, .. } => *id,
			_ => return Ok(false),
		};
		let actor = match self.exports.get(&export_position) {
			Some(id) => *id,
			None => return Ok(false),
		};

		// A leading symbol is the method verb; the rest are its arguments.
		let (verb, rest): (&str, &[Argument]) = match args.split_first() {
			Some((Argument::Symbol(symbol), rest)) => (symbol, rest),
			_ => ("", args),
		};

		// A plain actor resolves with its value; a forwarder (a caretaker/
		// attenuator) tail-resolves the answer from the forwarded send — deferring
		// it for a far target — through the one shared dispatch path (ADR-0064).
		match self.dispatch(actor, verb, rest) {
			Outcome::Now(resolution) => {
				if let Some(answer) = answer {
					// A published actor that returns a capability living on another
					// connection trips the resolve interceptor, which claims the
					// answer and originates the gifter half of a three-party handoff
					// (ADR-0009) instead of letting the vat encode a cross-connection
					// reference.
					if let Resolution::Fulfill(reply) = &resolution {
						let claimed = self
							.resolve_interceptor
							.as_mut()
							.map(|intercept| intercept(answer, reply))
							.unwrap_or(false);
						if claimed {
							return Ok(true);
						}
					}
					let peer = self
						.peer
						.as_deref_mut()
						.expect("serving a deliver needs a bound peer");
					peer.send_resolve(answer, &resolution)?;
				}
			}
			// A forward to a far target: defer this answer onto that send. The
			// listener parks the resolution; `flush_forward_resolves` sends it.
			Outcome::Deferred(far_promise) => {
				if let Some(answer) = answer {
					let queue = Rc::clone(&self.forward_resolves);
					self.on(far_promise, move |resolution| {
						queue
							.borrow_mut()
							.push((answer, normalize_forward(resolution)));
					});
				}
			}
		}
		Ok(true)
	}

	fn serve_resolve(&mut self, answer: u64, resolution: &Resolution) -> bool {
		match self.far_listeners.remove(&answer) {
			Some(listener) => {
				listener(resolution.clone());
				true
			}
			None => false,
		}
	}

	/// Break every far vow still awaiting a partner's resolution, firing each
	/// listener with `Break(message)`. The connection driver calls this when the
	/// wire goes away, so an outstanding `send` settles as a break carrying the
	/// reason rather than a bare transport error, the disconnect guarantee the
	/// Deno, Python, and Racket connections also give.
	pub fn break_far_vows(&mut self, message: &str) {
		let broken = Resolution::Break(message.to_string());
		for (_, listener) in self.far_listeners.drain() {
			listener(broken.clone());
		}
	}
}

/// Map a forwarded send's resolution to what the proxy's caller receives. A
/// three-party handoff give is not relayed through a forwarding proxy (single-hop,
/// ADR scope); break the caller's answer rather than mis-encode it.
fn normalize_forward(resolution: Resolution) -> Resolution {
	match resolution {
		Resolution::Handoff(_) => {
			Resolution::Break("a forwarded send resolved to a three-party handoff give".to_string())
		}
		other => other,
	}
}
