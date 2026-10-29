//! One directory's registered-name owner. Dropped observations leave the
//! bounded attempt running until finish_pending recovers its actual result.
use super::*;
use rooms_application::{
	directory::registration::{self as policy, Custody, Event, Id, NicknameAllocation, Notice},
	fields::Text,
};
use std::{
	cell::RefCell,
	future::poll_fn,
	task::{Poll, Waker},
};
mod registry;
pub(crate) use registry::Registry;

struct Inbox {
	events: policy::Events,
	event_waiter: Option<Waker>,
}
struct Name {
	reference: Ref,
	inbox: Rc<RefCell<Inbox>>,
	_root: Ref,
}
struct State {
	custody: Custody<Name>,
	outcome: Option<Result<Grant, Error>>,
	waiter: Option<Waker>,
}
struct Request {
	nick: String,
	allocation: NicknameAllocation,
	locator: String,
	voucher: Option<Vec<u8>>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Grant {
	pub nick: Text<32, true>,
	pub id: Id,
}
impl Grant {
	pub fn as_str(&self) -> &str {
		self.id.as_str()
	}
}
pub struct Registration<D: Tasks> {
	client: Client<D>,
	directory: Ref,
	notifications: introduction::Notifications,
	state: Rc<RefCell<State>>,
	pending: Option<D::Task>,
	closed: Option<D::Task>,
	claim: policy::Claim,
}
impl<D: Deadline + Tasks + Clone + 'static> Directory<D> {
	pub fn has_named_registration(&self) -> bool {
		self.client.directory_names.named(&self.reference)
	}
	/// Create an independent name owner. Keep and reuse it for replacements on
	/// this directory connection. The server decides which registration is live.
	pub fn registration(&self) -> Registration<D> {
		Registration::new(self.client.clone(), self.reference.clone(), self.introductions.clone())
	}
	pub fn signaling_registration(&self) -> Registration<D> {
		let mut registration = self.registration();
		registration.claim = policy::Claim::Signaling;
		registration
	}
}
impl<D: Deadline> Directory<D> {
	pub async fn member_registration(&self, peer: &str) -> Result<Id, Error> {
		let reply = self
			.client
			.ask(
				&self.reference,
				policy::MEMBER,
				&[peer],
				"the directory did not answer its member registration",
			)
			.await?;
		Ok(Id::parse(reply.0.as_str().unwrap_or(""))?)
	}
	pub async fn request_direct(&self, peer: &str, id: &Id) -> Result<(), Error> {
		self.client
			.ask(
				&self.reference,
				policy::REQUEST_DIRECT,
				&[peer, id.as_str()],
				"the directory did not answer requesting a direct route",
			)
			.await?;
		Ok(())
	}
	pub async fn offer_inbox(&self, peer: &str, id: &Id, opening: &str, inbox: &Ref) -> Result<(), Error> {
		let pending = {
			let args = [
				Argument::String(peer.into()),
				Argument::String(id.as_str().into()),
				Argument::String(opening.into()),
				inbox.clone().into(),
			];
			self.client.call(
				&self.reference,
				policy::OFFER_INBOX,
				&args,
				"the directory did not answer offering an inbox",
			)
		};
		pending.await?;
		Ok(())
	}
}
impl<D: Deadline + Tasks + Clone + 'static> Registration<D> {
	fn new(client: Client<D>, directory: Ref, notifications: introduction::Notifications) -> Self {
		let state = Rc::new(RefCell::new(State {
			custody: Default::default(),
			outcome: None,
			waiter: None,
		}));
		let weak = Rc::downgrade(&state);
		let session = client.session.clone();
		let closed = client.deadline.spawn(async move {
			let _ = session.closed().await;
			if let Some(state) = weak.upgrade() {
				close(&state);
			}
		});
		Self {
			client,
			directory,
			notifications,
			state,
			pending: None,
			closed: Some(closed),
			claim: policy::Claim::Named,
		}
	}
	pub async fn register(&mut self, nick: &str, locator: &str, voucher: Option<Vec<u8>>) -> Result<Grant, Error> {
		self.register_with_allocation(nick, NicknameAllocation::Exact, locator, voucher)
			.await
	}
	pub async fn register_with_allocation(
		&mut self,
		nick: &str,
		allocation: NicknameAllocation,
		locator: &str,
		voucher: Option<Vec<u8>>,
	) -> Result<Grant, Error> {
		let admission = self
			.client
			.directory_names
			.begin(&self.directory, &self.state, self.claim)?;
		self.state.borrow_mut().custody.begin()?;
		let (client, directory, weak) = (self.client.clone(), self.directory.clone(), Rc::downgrade(&self.state));
		let request = Request {
			nick: nick.to_owned(),
			allocation,
			locator: locator.to_owned(),
			voucher,
		};
		let notifications = self.notifications.clone();
		self.pending = Some(self.client.deadline.spawn(async move {
			let result = attempt(&client, &directory, request, &weak, (notifications, admission)).await;
			if let Some(state) = weak.upgrade() {
				let waiter = {
					let mut s = state.borrow_mut();
					s.outcome = Some(result);
					s.waiter.take()
				};
				if let Some(w) = waiter {
					w.wake();
				}
			}
		}));
		self.finish_pending().await
	}
	/// Recover a cancelled observation without sending another registration.
	pub async fn finish_pending(&mut self) -> Result<Grant, Error> {
		if self.pending.is_none() {
			return Err(policy::Error::NoPending.into());
		}
		let result = poll_fn(|cx| {
			let mut state = self.state.borrow_mut();
			if let Some(result) = state.outcome.take() {
				Poll::Ready(result)
			} else {
				state.waiter = Some(cx.waker().clone());
				Poll::Pending
			}
		})
		.await;
		self.pending = None;
		self.state.borrow_mut().custody.finish()?;
		result
	}
	pub async fn name_voucher(&self) -> Result<Option<Vec<u8>>, Error> {
		let name = {
			let state = self.state.borrow();
			state.custody.name()?.map(|n| n.reference.clone())
		};
		let Some(name) = name else { return Ok(None) };
		let reply = self
			.client
			.call(
				&name,
				policy::VOUCHER,
				&[],
				"the directory did not answer minting a name voucher",
			)
			.await?;
		match reply.0 {
			Argument::Bytes(bytes) => Ok(Some(bytes)),
			_ => Err(policy::Error::Voucher.into()),
		}
	}
	/// Transfer the name capability and retire local notifications. This does
	/// not ask the directory to unregister the name.
	pub fn take_name(&mut self) -> Result<Option<Ref>, Error> {
		Ok(self.state.borrow_mut().custody.take()?.map(|name| name.reference))
	}
	pub async fn next(&mut self) -> Result<Option<Event>, Error> {
		let inbox = {
			let state = self.state.borrow();
			if state.custody.ended() {
				return Ok(None);
			}
			state.custody.name()?.map(|n| n.inbox.clone())
		};
		let Some(inbox) = inbox else { return Ok(None) };
		poll_fn(|cx| {
			if self.state.borrow().custody.ended() {
				return Poll::Ready(Ok(None));
			}
			let mut i = inbox.borrow_mut();
			match i.events.pop() {
				Ok(Some(event)) => return Poll::Ready(Ok(Some(event))),
				Err(error) => return Poll::Ready(Err(error.into())),
				Ok(None) => {}
			}
			i.event_waiter = Some(cx.waker().clone());
			Poll::Pending
		})
		.await
	}
}
async fn attempt<D: Deadline>(
	client: &Client<D>,
	directory: &Ref,
	request: Request,
	state: &std::rc::Weak<RefCell<State>>,
	(notifications, admission): (introduction::Notifications, registry::Attempt),
) -> Result<Grant, Error> {
	let Request {
		nick,
		allocation,
		locator,
		voucher,
	} = request;
	let inbox = Rc::new(RefCell::new(Inbox {
		events: Default::default(),
		event_waiter: None,
	}));
	let weak = Rc::downgrade(&inbox);
	let owner = state.clone();
	let root = client.session.spawn_owned(move |verb, args| {
		let state = owner.upgrade().ok_or("the name registration has ended")?;
		if state.borrow().custody.ended() {
			return Err("the name registration has ended".into());
		}
		let inbox = weak.upgrade().ok_or("the name registration has ended")?;
		let verb = verb.ok_or("unknown method")?;
		let notice = policy::notice(verb, |i| args.get(i).map(Value)).map_err(|e| e.to_string())?;
		if let Some(Notice::Event(event)) = &notice
			&& event.kind == policy::Kind::Introducible
		{
			let opening = event
				.opening
				.as_ref()
				.and_then(|opening| opening.text().as_str())
				.ok_or("the introducible notice carries no opening text")?;
			notifications.notify(&event.registration, opening);
		}
		let (waiter, result) = {
			let mut i = inbox.borrow_mut();
			match notice {
				Some(Notice::Registered { .. }) => (None, Ok(())),
				Some(Notice::Event(event)) => {
					let result = i.events.push(event);
					(i.event_waiter.take(), result)
				}
				None => (None, Ok(())),
			}
		};
		if let Some(w) = waiter {
			w.wake();
		}
		result.map_err(|e| e.to_string())?;
		Ok(Argument::Void)
	})?;
	let expected_nick = nick.clone();
	let mut args = vec![nick.into(), locator.into(), root.clone().into()];
	if allocation == NicknameAllocation::Automatic {
		args.push(Argument::String(allocation.wire().into()));
	}
	if let Some(voucher) = voucher {
		args.push(Argument::Bytes(voucher));
	}
	let reply = client.call(
		directory,
		policy::REGISTER,
		&args,
		"the directory did not answer with a committed registration",
	);
	let mut reply = std::pin::pin!(reply);
	let mut closed = std::pin::pin!(client.session.closed());
	let reply = poll_fn(|cx| {
		if closed.as_mut().poll(cx).is_ready() {
			return Poll::Ready(Err(policy::Error::Ended.into()));
		}
		reply.as_mut().poll(cx)
	})
	.await?;
	let Some([nick, id, Argument::Reference(reference)]) = reply.0.as_list() else {
		return Err(policy::Error::Name.into());
	};
	let nick = nick
		.as_str()
		.filter(|nick| rooms_application::room::inbox::valid_nick(nick))
		.ok_or(policy::Error::Peer)?;
	if allocation == NicknameAllocation::Exact && nick != expected_nick {
		return Err(policy::Error::Grant.into());
	}
	let grant = Grant {
		nick: Text::new(nick.into()).ok_or(policy::Error::Peer)?,
		id: Id::parse(id.as_str().unwrap_or(""))?,
	};
	let state = state.upgrade().ok_or(policy::Error::Ended)?;
	state.borrow_mut().custody.replace(Name {
		reference: reference.clone(),
		inbox,
		_root: root,
	})?;
	admission.committed()?;
	Ok(grant)
}
fn close(state: &Rc<RefCell<State>>) {
	let (waiter, event_waiter) = {
		let mut state = state.borrow_mut();
		let event_waiter = state
			.custody
			.name()
			.ok()
			.flatten()
			.and_then(|n| n.inbox.borrow_mut().event_waiter.take());
		state.custody.close();
		(state.waiter.take(), event_waiter)
	};
	if let Some(w) = waiter {
		w.wake();
	}
	if let Some(w) = event_waiter {
		w.wake();
	}
}
impl<D: Tasks> Drop for Registration<D> {
	fn drop(&mut self) {
		close(&self.state);
		self.pending = None;
		self.closed = None;
	}
}
