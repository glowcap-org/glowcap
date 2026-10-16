//! Room subscription and membership custody, shared by every platform adapter.
//! The platform owns deadlines and the cancellable session-close observation.
use super::{stewardship::Stewardship, *};
use crate::Value;
use rooms_application::room::{
	carries::Carries,
	inbox::{self, Notice},
	membership::{self, Membership, Seat},
	policy::{MembershipKind, RoomPolicy},
	stewardship::Kind,
	subject::Subject,
};
use std::{
	cell::{Cell, RefCell},
	future::poll_fn,
	task::{Poll, Waker},
};
mod bridge;
mod conversation;
mod messages;
mod queries;
mod receipts;
pub use messages::Messages;
pub use receipts::Request;

pub enum Event<'a> {
	Typing {
		name: &'a str,
		on: bool,
	},
	Authority {
		kind: Kind,
		token: &'a str,
		claimable: bool,
	},
	Policy(RoomPolicy),
	Ended(&'a str),
}
pub type EventHandler = Box<dyn for<'a> FnMut(Event<'a>)>;
pub struct SubscribeOptions {
	pub voucher: Option<Vec<u8>>,
	pub on_event: EventHandler,
}
impl Default for SubscribeOptions {
	fn default() -> Self {
		Self {
			voucher: None,
			on_event: Box::new(|_| {}),
		}
	}
}
struct State {
	membership: Membership<Ref>,
	inbox: Option<Ref>,
	listed: Option<bool>,
	/// What the room said it carries, held by the time joining returns
	/// because the room states it ahead of the arrival mark.
	carries: Option<Carries>,
	ended_reason: Option<String>,
	arrival: Option<Waker>,
}
struct Inner<D> {
	client: Client<D>,
	reference: Ref,
	stewardship: Stewardship<D>,
	state: RefCell<State>,
	messages: messages::Shared,
	events: RefCell<EventHandler>,
}
pub struct Room<D: Tasks> {
	inner: Rc<Inner<D>>,
	closed: RefCell<Option<D::Task>>,
	/// Leaving needs no exclusive handle: a shared room retires under every
	/// holder at once, and a verb still holding it is refused by its seat.
	leave_started: Cell<bool>,
	leave_result: RefCell<Option<Result<(), Error>>>,
}
impl<D: Deadline> Inner<D> {
	fn retire(&self) -> Option<Seat<Ref>> {
		let (seat, waker) = {
			let mut state = self.state.borrow_mut();
			let seat = state.membership.retire();
			state.inbox = None;
			(seat, state.arrival.take())
		};
		self.stewardship.release();
		messages::close(&self.messages);
		if let Some(waker) = waker {
			waker.wake();
		}
		seat
	}
	fn notify(&self, verb: &str, args: &[Argument]) -> Result<Argument, String> {
		if self.state.borrow().membership.ended() {
			return Err("this room membership has ended".into());
		}
		let args: Vec<_> = args.iter().map(Value).collect();
		if verb == rooms_application::room::receipt::REJECTED {
			use rooms_application::room::{ArgumentView, receipt};
			let [token] = args.as_slice() else {
				return Err(receipt::Error::Malformed.to_string());
			};
			let request = token
				.integer()
				.and_then(receipt::request)
				.ok_or_else(|| receipt::Error::Malformed.to_string())?;
			let mut delivery = self.messages.borrow_mut();
			let messages::Delivery { queue, pending, .. } = &mut *delivery;
			pending.discard(request, queue);
			return Ok(Argument::Void);
		}
		if verb == rooms_application::room::receipt::TAG {
			let receipt = rooms_application::room::receipt::read(&args).map_err(|e| e.to_string())?;
			let mut delivery = self.messages.borrow_mut();
			let messages::Delivery { queue, pending, .. } = &mut *delivery;
			let message = pending.complete(receipt, queue).map_err(|e| e.to_string())?;
			let result = delivery.queue.push_owned(message);
			if result.is_err() {
				delivery.pending.clear();
			}
			let waker = delivery.waiter.take();
			drop(delivery);
			if let Some(waker) = waker {
				waker.wake();
			}
			result.map_err(|e| e.to_string())?;
			return Ok(Argument::Void);
		}
		let notice = inbox::read(verb, &args).map_err(|e| e.to_string())?;
		match notice {
			Notice::Ended(reason) => {
				self.state.borrow_mut().ended_reason = Some(reason.into());
				self.retire();
				(self.events.borrow_mut())(Event::Ended(reason));
			}
			Notice::Authority { kind, token, claimable } => {
				self.stewardship.forget(kind, token);
				(self.events.borrow_mut())(Event::Authority { kind, token, claimable });
			}
			Notice::Policy(policy) => (self.events.borrow_mut())(Event::Policy(policy)),
			Notice::Typing { name, on } => (self.events.borrow_mut())(Event::Typing { name, on }),
			Notice::Occupancy { listed, .. } => {
				let waker = {
					let mut s = self.state.borrow_mut();
					s.listed = Some(listed);
					s.membership.arrived();
					s.arrival.take()
				};
				if let Some(w) = waker {
					w.wake();
				}
			}
			Notice::Line(message) => {
				let arrived = message.arrived();
				if let Some(facts) = message.facts() {
					let mut state = self.state.borrow_mut();
					if let Some(listed) = facts.listed {
						state.listed = Some(listed);
					}
					if let Some(carries) = facts.carries {
						state.carries = Some(carries);
					}
				}
				let (result, waker) = {
					let mut d = self.messages.borrow_mut();
					let r = d.queue.push(message);
					if r.is_err() {
						d.pending.clear();
					}
					(r, d.waiter.take())
				};
				if let Some(w) = waker {
					w.wake();
				}
				result.map_err(|e| e.to_string())?;
				if arrived {
					let waker = {
						let mut s = self.state.borrow_mut();
						s.membership.arrived();
						s.arrival.take()
					};
					if let Some(w) = waker {
						w.wake();
					}
				}
			}
		}
		Ok(Argument::Void)
	}
}
impl<D: Deadline + Tasks + Clone + 'static> Room<D> {
	pub async fn subscribe(
		client: Client<D>,
		reference: Ref,
		nick: &str,
		options: SubscribeOptions,
	) -> Result<(Self, Messages), Error> {
		let delivery = Rc::new(RefCell::new(messages::Delivery {
			queue: Default::default(),
			pending: Default::default(),
			waiter: None,
		}));
		let inner = Rc::new(Inner {
			stewardship: Stewardship::new(client.clone(), reference.clone()),
			client,
			reference,
			state: RefCell::new(State {
				membership: Membership::new(),
				inbox: None,
				listed: None,
				carries: None,
				ended_reason: None,
				arrival: None,
			}),
			messages: delivery.clone(),
			events: RefCell::new(options.on_event),
		});
		let weak = Rc::downgrade(&inner);
		let inbox = inner
			.client
			.session
			.spawn_owned(move |verb, args| match weak.upgrade() {
				Some(inner) => inner.notify(verb, args),
				None => Err("this room membership has ended".into()),
			})?;
		inner.state.borrow_mut().inbox = Some(inbox.clone());
		let weak = Rc::downgrade(&inner);
		let session = inner.client.session.clone();
		let closed = inner.client.deadline.spawn(async move {
			let _ = session.closed().await;
			if let Some(inner) = weak.upgrade() {
				inner.retire();
			}
		});
		let room = Self {
			inner,
			closed: RefCell::new(Some(closed)),
			leave_started: Cell::new(false),
			leave_result: RefCell::new(None),
		};
		let pending = {
			let mut args = vec![Argument::String(nick.into()), Argument::Reference(inbox)];
			if let Some(voucher) = options.voucher {
				args.push(Argument::Bytes(voucher));
			}
			room.inner.client.call(
				&room.inner.reference,
				membership::SUBSCRIBE,
				&args,
				"the room did not answer joining",
			)
		};
		let answer = pending.await?;
		let args = answer.0.as_list().ok_or(membership::Error::Answer)?;
		let args: Vec<_> = args.iter().map(Value).collect();
		let seat = membership::read_answer(&args)?;
		room.inner.state.borrow_mut().membership.accept(seat)?;
		drop(answer);
		let arrival = poll_fn(|cx| {
			let mut state = room.inner.state.borrow_mut();
			if state.membership.ended() {
				return Poll::Ready(Err(membership::Error::Ended));
			}
			if state.membership.ready() {
				return Poll::Ready(Ok(()));
			}
			if state.arrival.as_ref().is_none_or(|old| !old.will_wake(cx.waker())) {
				state.arrival = Some(cx.waker().clone());
			}
			Poll::Pending
		});
		room.inner
			.client
			.deadline
			.within(authority::REQUEST_TIMEOUT_MS, arrival)
			.await
			.ok_or(Error::Timeout("the room did not announce arriving"))??;
		Ok((room, Messages { shared: delivery }))
	}
	pub fn stewardship(&self) -> &Stewardship<D> {
		&self.inner.stewardship
	}
	pub fn client(&self) -> &Client<D> {
		&self.inner.client
	}
	pub fn reference(&self) -> &Ref {
		&self.inner.reference
	}
	pub fn listed(&self) -> Option<bool> {
		self.inner.state.borrow().listed
	}
	/// What the room said it carries, or None from a room that never said.
	/// A caller choosing a verb takes the plain one then, because a room
	/// that has said nothing has promised nothing beyond it.
	pub fn carries(&self) -> Option<Carries> {
		self.inner.state.borrow().carries
	}
	pub fn kind(&self) -> Result<MembershipKind, Error> {
		Ok(self.inner.state.borrow().membership.seat()?.kind)
	}
	/// A subject capability is held by the current membership, independently
	/// of the room's mode or a saved manager link.
	pub fn can_set_subject(&self) -> bool {
		self.inner
			.state
			.borrow()
			.membership
			.seat()
			.is_ok_and(|seat| seat.subject.is_some())
	}
	pub fn ended_reason(&self) -> Option<String> {
		self.inner.state.borrow().ended_reason.clone()
	}
	fn seat(&self) -> Result<Ref, Error> {
		Ok(self.inner.state.borrow().membership.seat()?.reference.clone())
	}
	/// The files facet `subscribe` handed over, which `attach` and
	/// `postFiles` go to. Refused where the room withheld it: a room that
	/// cannot hold bytes, or an observer seat.
	fn files(&self) -> Result<Ref, Error> {
		let state = self.inner.state.borrow();
		let seat = state.membership.seat()?;
		Ok(seat.files.clone().ok_or(membership::Error::NoFiles)?)
	}
	/// Whether this membership holds the files facet, independently of the
	/// room's mode: what a composer draws its attach control from.
	pub fn can_post_files(&self) -> bool {
		self.inner
			.state
			.borrow()
			.membership
			.seat()
			.is_ok_and(|seat| seat.files.is_some())
	}
	pub async fn away(&self, reason: &str) -> Result<(), Error> {
		self.inner
			.client
			.ask(
				&self.seat()?,
				membership::AWAY,
				&[reason],
				"the room did not answer being away",
			)
			.await?;
		Ok(())
	}
	pub fn typing(&self, on: bool) -> Result<(), Error> {
		self.inner
			.client
			.session
			.tell(&self.seat()?, membership::TYPING, &[Argument::Boolean(on)])?;
		Ok(())
	}
	/// Set what the room is about. An empty subject takes it down. A link is
	/// shared with everyone who can read the room.
	pub async fn set_subject(&self, subject: &Subject) -> Result<(), Error> {
		let facet = self
			.inner
			.state
			.borrow()
			.membership
			.seat()?
			.subject
			.clone()
			.ok_or(membership::Error::NoSubject)?;
		let args: Vec<&str> = core::iter::once(subject.description()).chain(subject.link()).collect();
		self.inner
			.client
			.ask(
				&facet,
				membership::SET_SUBJECT,
				&args,
				"the room did not answer setting its subject",
			)
			.await?;
		Ok(())
	}
	/// Local retirement happens immediately. Dropping this future cannot keep
	/// the queue, inbox or subject facet alive while an unanswered goodbye is pending.
	pub async fn leave(&self) -> Result<(), Error> {
		if self.leave_started.get() {
			return self
				.leave_result
				.borrow()
				.clone()
				.unwrap_or(Err(membership::Error::GoodbyeUnobserved.into()));
		}
		let Some(seat) = self.inner.retire() else {
			return Ok(());
		};
		self.leave_started.set(true);
		self.closed.take();
		let result = self
			.inner
			.client
			.call(
				&seat.reference,
				membership::LEAVE,
				&[],
				"the room did not answer the goodbye",
			)
			.await
			.map(|_| ());
		*self.leave_result.borrow_mut() = Some(result.clone());
		result
	}

	pub fn replaced(&mut self) {
		self.inner.retire();
		self.closed.take();
	}
}
impl<D: Tasks> Drop for Room<D> {
	fn drop(&mut self) {
		self.closed.take();
		let mut state = self.inner.state.borrow_mut();
		state.membership.retire();
		state.inbox = None;
		messages::close(&self.inner.messages);
	}
}
