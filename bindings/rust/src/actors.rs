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
//! The unified [`Ref`] can name a local actor or a far object, and a [`Promise`]
//! can settle from a local turn or a wire answer. An application sends to a ref
//! without caring where it lives; the vat chooses the route. Two verbs mirror
//! Goblins:
//!
//!   * [`Vat::call`] is the synchronous near-call (`$`). It runs a local actor's
//!     behavior immediately and returns its value. It is legal only for a local
//!     ref, exactly as Goblins forbids `$` to a far ref.
//!   * [`Vat::send`] is the eventual send (`<-`). It is location-transparent: to a
//!     local ref it queues a turn, and to a far ref it sends an `op:deliver` over
//!     the bound peer. Either way it returns a [`Promise`] you observe with
//!     [`Vat::on`].

use crate::{Argument, Event, Peer, Reference, Resolution, Result};
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

/// An actor behavior: handle a `(verb, args)` call, returning a reply or an error
/// message (which becomes a broken resolution).
pub type Behavior = Box<dyn FnMut(&str, &[Argument]) -> std::result::Result<Argument, String>>;

/// A one-shot promise listener, fired with how the promise settled.
pub type Listener = Box<dyn FnOnce(Resolution)>;

/// A hook consulted before the vat resolves a delivered actor's answer
/// (ADR-0009, the gifter half). It is handed the answer and the reply the actor
/// returned; returning `true` claims the answer — the vat then leaves it
/// unresolved, so the hook can resolve it itself (a published actor that returns
/// a capability living on another connection originates a three-party handoff
/// rather than letting the vat encode a cross-connection reference). Returning
/// `false` falls through to the ordinary resolve.
pub type ResolveInterceptor = Box<dyn FnMut(u64, &Argument) -> bool>;

/// A reference the vat can eventual-send to, wherever the object lives.
#[derive(Debug, Clone, PartialEq)]
pub enum Ref {
	/// An actor in this vat. `call` and `send` run its turns here.
	Local(u64),
	/// A partner-hosted object the bound peer holds. `send` routes to it as an
	/// `op:deliver`; `call` (near) is illegal.
	Far(Reference),
}

/// A handle to the eventual result of a [`Vat::send`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Promise {
	/// Result of a local send; settled by [`Vat::drive`].
	Local(u64),
	/// Result of a far send; the outbound answer position the partner resolves.
	Far(u64),
}

/// An object-capability membrane (ADR-0064): a forwarding proxy over `target`
/// (local or far). A caretaker forwards until revoked, then breaks every call; an
/// attenuator forwards only its allow-listed verbs and breaks the rest. The proxy
/// is an ordinary export — a partner delivers to it like any other capability.
struct Membrane {
	target: Ref,
	policy: MembranePolicy,
}

enum MembranePolicy {
	/// Forwards while `live`; once revoked, every call breaks with `Revoked`.
	Caretaker { live: bool },
	/// Forwards a call whose verb is in `verbs`; any other breaks with `Attenuated`.
	Attenuate { verbs: Vec<String> },
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
	actors: HashMap<u64, Behavior>,
	queue: Vec<Queued>,
	listeners: HashMap<u64, Listener>,
	/// Listener for a far send's promise, keyed by outbound answer position.
	far_listeners: HashMap<u64, Listener>,
	/// Local actor id for each export position published on the peer.
	exports: HashMap<u64, u64>,
	/// Membrane (caretaker/attenuator) for each local id that hosts one, instead
	/// of an ordinary behavior (ADR-0064).
	membranes: HashMap<u64, Membrane>,
	/// Answers a membrane forwarded to a *far* target, awaiting that send's
	/// resolution. The forward listener cannot reach the peer, so it parks
	/// `(answer, resolution)` here; [`flush_forward_resolves`](Vat::flush_forward_resolves)
	/// drains it with peer access — the same deferral shape the enliven cache uses.
	forward_resolves: Rc<RefCell<Vec<(u64, Resolution)>>>,
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
			membranes: HashMap::new(),
			forward_resolves: Rc::new(RefCell::new(Vec::new())),
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

	/// The peer this vat rides on — to feed/step/take_outbound around `serve`.
	/// Returns `None` for a pure-local vat.
	pub fn peer(&mut self) -> Option<&mut Peer<'static>> {
		self.peer.as_deref_mut()
	}

	/// Spawn a local actor, returning a local [`Ref`].
	pub fn spawn(
		&mut self,
		behavior: impl FnMut(&str, &[Argument]) -> std::result::Result<Argument, String> + 'static,
	) -> Ref {
		let id = self.next_actor;
		self.next_actor += 1;
		self.actors.insert(id, Box::new(behavior));
		Ref::Local(id)
	}

	/// The synchronous near-call (`$`): run `target`'s behavior now and return its
	/// value. Legal only for a local ref — a far ref must be reached with `send`.
	pub fn call(
		&mut self,
		target: &Ref,
		verb: &str,
		args: &[Argument],
	) -> std::result::Result<Argument, String> {
		match target {
			Ref::Local(id) => self.call_local(*id, verb, args),
			Ref::Far(_) => Err("cannot near-call a far ref; use send".to_string()),
		}
	}

	fn call_local(
		&mut self,
		id: u64,
		verb: &str,
		args: &[Argument],
	) -> std::result::Result<Argument, String> {
		let behavior = self
			.actors
			.get_mut(&id)
			.ok_or_else(|| "no such actor".to_string())?;
		behavior(verb, args)
	}

	/// The eventual send (`<-`): location-transparent. A local target queues a
	/// turn for [`drive`](Vat::drive); a far target sends an `op:deliver` over the
	/// bound peer (a leading symbol carries the verb, matching Goblins's
	/// `($ obj 'method …)`). Returns a [`Promise`] for the result.
	pub fn send(&mut self, target: &Ref, verb: &str, args: &[Argument]) -> Result<Promise> {
		match target {
			Ref::Local(id) => {
				let promise = self.next_promise;
				self.next_promise += 1;
				self.queue.push(Queued {
					target: *id,
					verb: verb.to_string(),
					args: args.to_vec(),
					promise,
				});
				Ok(Promise::Local(promise))
			}
			Ref::Far(reference) => {
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
				// method symbol (Goblins's `(<- obj arg …)`) — matching the Deno,
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
				Ok(Promise::Far(answer))
			}
		}
	}

	/// Register a one-shot listener for `promise`. A local promise fires during
	/// [`drive`](Vat::drive); a far promise fires when the partner's resolution
	/// arrives and is dispatched by [`serve`](Vat::serve).
	pub fn on(&mut self, promise: Promise, listener: impl FnOnce(Resolution) + 'static) {
		match promise {
			Promise::Local(id) => {
				self.listeners.insert(id, Box::new(listener));
			}
			Promise::Far(answer) => {
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
	) -> Result<Ref> {
		let actor = self.spawn(behavior);
		let Ref::Local(local_id) = actor else {
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

	/// Publish a caretaker membrane at `export_position` forwarding to `target`
	/// (ADR-0064): a partner's deliveries forward to `target` until
	/// [`revoke_membrane`](Vat::revoke_membrane), then break with `Revoked`.
	pub fn publish_caretaker(&mut self, export_position: u64, target: Ref) -> Result<()> {
		self.publish_membrane(export_position, target, MembranePolicy::Caretaker { live: true })
	}

	/// Publish an attenuator membrane at `export_position` forwarding to `target`
	/// (ADR-0064): a delivery whose verb is in `verbs` forwards; any other breaks
	/// with `Attenuated`.
	pub fn publish_attenuator(
		&mut self,
		export_position: u64,
		target: Ref,
		verbs: Vec<String>,
	) -> Result<()> {
		self.publish_membrane(export_position, target, MembranePolicy::Attenuate { verbs })
	}

	fn publish_membrane(
		&mut self,
		export_position: u64,
		target: Ref,
		policy: MembranePolicy,
	) -> Result<()> {
		let local_id = self.next_actor;
		self.next_actor += 1;
		let peer = self.peer.as_deref_mut().expect("publish needs a bound peer");
		peer.register_export(export_position)?;
		self.exports.insert(export_position, local_id);
		self.membranes.insert(local_id, Membrane { target, policy });
		Ok(())
	}

	/// Revoke the caretaker membrane published at `export_position`: subsequent
	/// deliveries to it break with `Revoked`. A no-op for an unknown position or a
	/// non-caretaker membrane.
	pub fn revoke_membrane(&mut self, export_position: u64) {
		if let Some(&local_id) = self.exports.get(&export_position) {
			if let Some(membrane) = self.membranes.get_mut(&local_id) {
				if let MembranePolicy::Caretaker { live } = &mut membrane.policy {
					*live = false;
				}
			}
		}
	}

	/// Resolve the answers any membrane forwarded to a far target has settled. The
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

	// Dispatch an inbound deliver that landed on a membrane proxy: refuse it
	// (revoked/attenuated) or forward it. A local target near-calls and resolves
	// synchronously; a far target eventual-sends and defers the answer onto the
	// forwarded send (ADR-0064's `Turn.forward`).
	fn serve_membrane(
		&mut self,
		local_id: u64,
		verb: &str,
		args: &[Argument],
		answer: Option<u64>,
	) -> Result<bool> {
		let membrane = self.membranes.get(&local_id).expect("a membrane local id");
		let target = membrane.target.clone();
		let refusal: Option<&'static str> = match &membrane.policy {
			MembranePolicy::Caretaker { live } => {
				if *live {
					None
				} else {
					Some("Revoked")
				}
			}
			MembranePolicy::Attenuate { verbs } => {
				if verbs.iter().any(|v| v == verb) {
					None
				} else {
					Some("Attenuated")
				}
			}
		};

		if let Some(message) = refusal {
			if let Some(answer) = answer {
				let peer = self.peer.as_deref_mut().expect("a bound peer");
				peer.send_resolve(answer, &Resolution::Break(message.to_string()))?;
			}
			return Ok(true);
		}

		match target {
			// A local target wants a value now: near-call and resolve in place.
			Ref::Local(_) => {
				let result = self.call(&target, verb, args);
				if let Some(answer) = answer {
					let peer = self.peer.as_deref_mut().expect("a bound peer");
					match result {
						Ok(reply) => peer.send_resolve(answer, &Resolution::Fulfill(reply))?,
						Err(message) => peer.send_resolve(answer, &Resolution::Break(message))?,
					}
				}
			}
			// A far target: forward the send and defer this answer onto it. The
			// listener parks the resolution; `flush_forward_resolves` sends it.
			Ref::Far(_) => {
				let promise = self.send(&target, verb, args)?;
				if let Some(answer) = answer {
					let queue = Rc::clone(&self.forward_resolves);
					self.on(promise, move |resolution| {
						let forwarded = match resolution {
							// A forwarded send that resolved to a three-party handoff
							// give is not relayed through a membrane (single-hop, ADR
							// scope); break the caller's answer rather than mis-encode.
							Resolution::Handoff(_) => Resolution::Break(
								"a membrane-forwarded send resolved to a handoff give".to_string(),
							),
							other => other,
						};
						queue.borrow_mut().push((answer, forwarded));
					});
				}
			}
		}
		Ok(true)
	}

	/// Run queued local eventual-sends to quiescence, settling each promise with
	/// the behavior's value (or a break on error) and firing its listener. Turns
	/// queued by a turn run in the same drive (FIFO).
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
			let resolution = match self.call_local(target, &verb, &args) {
				Ok(value) => Resolution::Fulfill(value),
				Err(message) => Resolution::Break(message),
			};
			self.settle_local(promise, resolution);
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
	pub fn resolve_target(&self, reference: &Reference) -> Ref {
		if let Reference::Near { id, .. } = reference {
			if let Some(&local_id) = self.exports.get(id) {
				return Ref::Local(local_id);
			}
		}
		Ref::Far(reference.clone())
	}

	/// Dispatch one inbound peer event. A deliver to a published export runs the
	/// actor (leading symbol = verb) and resolves the answer with its reply; a
	/// resolve for a pending far promise fires its listener. Returns whether the
	/// event belonged to this vat (false → not ours; the caller handles it).
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

		// A membrane proxy forwards (or refuses) rather than running a behavior.
		if self.membranes.contains_key(&actor) {
			return self.serve_membrane(actor, verb, rest, answer);
		}

		let result = self.call_local(actor, verb, rest);
		if let Some(answer) = answer {
			// A published actor that returns a capability living on another
			// connection trips the resolve interceptor, which claims the answer
			// and originates the gifter half of a three-party handoff (ADR-0009)
			// instead of letting the vat encode a cross-connection reference.
			if let Ok(reply) = &result {
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
			match result {
				Ok(reply) => peer.send_resolve(answer, &Resolution::Fulfill(reply)),
				Err(message) => peer.send_resolve(answer, &Resolution::Break(message)),
			}?;
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
	/// reason rather than a bare transport error — the disconnect guarantee the
	/// Deno, Python, and Racket connections also give.
	pub fn break_far_vows(&mut self, message: &str) {
		let broken = Resolution::Break(message.to_string());
		for (_, listener) in self.far_listeners.drain() {
			listener(broken.clone());
		}
	}
}
