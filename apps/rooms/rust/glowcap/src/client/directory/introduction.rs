//! Direct inbox acquisition through a held directory and the Host's handoff path.
use super::*;
use rooms_application::{
	directory::{introduction as policy, registration::Id},
	failure::{Failure, FailureCode},
};
use std::{
	cell::RefCell,
	future::poll_fn,
	task::{Poll, Waker},
};

#[derive(Default)]
struct State {
	notices: policy::Notices<Waker>,
	active: usize,
}
#[derive(Clone, Default)]
pub(crate) struct Notifications(Rc<RefCell<State>>);
impl Notifications {
	pub(super) fn notify(&self, id: &Id) {
		let wake = self.0.borrow_mut().notices.notify(id);
		for w in wake {
			w.wake();
		}
	}
	fn enter(&self) -> Result<Active, Error> {
		let mut state = self.0.borrow_mut();
		if state.active == policy::MAX_OUTSTANDING {
			return Err(policy::Error::Full.into());
		}
		state.active += 1;
		Ok(Active(self.clone()))
	}
	async fn wait(&self, id: &Id, use_banked: bool) -> Result<(), Error> {
		let mut held = Wait {
			notifications: self.clone(),
			ticket: None,
		};
		poll_fn(|cx| {
			let mut state = self.0.borrow_mut();
			if let Some(ticket) = held.ticket.as_ref() {
				match state.notices.observe(ticket, cx.waker().clone()) {
					Ok(true) => {
						held.ticket = None;
						Poll::Ready(Ok(()))
					}
					Ok(false) => Poll::Pending,
					Err(e) => Poll::Ready(Err(e.into())),
				}
			} else {
				match state.notices.wait(id, use_banked, cx.waker().clone()) {
					Ok(Some(ticket)) => {
						held.ticket = Some(ticket);
						Poll::Pending
					}
					Ok(None) => Poll::Ready(Ok(())),
					Err(e) => Poll::Ready(Err(e.into())),
				}
			}
		})
		.await
	}
}
struct Active(Notifications);
impl Drop for Active {
	fn drop(&mut self) {
		self.0.0.borrow_mut().active -= 1;
	}
}
struct Wait {
	notifications: Notifications,
	ticket: Option<policy::Ticket>,
}
impl Drop for Wait {
	fn drop(&mut self) {
		if let Some(ticket) = self.ticket.as_ref() {
			self.notifications.0.borrow_mut().notices.cancel(ticket);
		}
	}
}
/// The inbox and the actual connection on which a reciprocal inbox belongs.
/// Dropping this result releases its capability, not a shared exporter session.
pub struct Introduction {
	pub inbox: Ref,
	pub registration: Id,
	connection: Rc<Session>,
	owns_connection: bool,
}
impl Introduction {
	pub(crate) fn into_parts(self) -> (Ref, Id, Rc<Session>, bool) {
		(self.inbox, self.registration, self.connection, self.owns_connection)
	}
	pub fn session(&self) -> &Session {
		&self.connection
	}
}
impl<D: Deadline + Tasks + Clone + 'static> Directory<D> {
	pub async fn introduce(&self, peer: &str, expected: Option<&Id>) -> Result<Introduction, Error> {
		let _active = self.introductions.enter()?;
		let work = async {
			let id = match expected {
				Some(id) => id.clone(),
				None => self.member_registration(peer).await?,
			};
			match self.introduce_once(peer, &id).await {
				Err(e) if pending(&e) => {}
				result => return result,
			}
			let mut retries = policy::Retries::default();
			while let Some(use_banked) = retries.next_wait() {
				self.client
					.deadline
					.within(policy::WAIT_MS, self.introductions.wait(&id, use_banked))
					.await
					.ok_or(policy::Error::Pending)??;
				match self.introduce_once(peer, &id).await {
					Err(e) if pending(&e) => {}
					result => return result,
				}
			}
			Err(policy::Error::Pending.into())
		};
		let (mut work, mut closed) = (std::pin::pin!(work), std::pin::pin!(self.client.session.closed()));
		poll_fn(|cx| {
			if closed.as_mut().poll(cx).is_ready() {
				return Poll::Ready(Err(policy::Error::Ended.into()));
			}
			work.as_mut().poll(cx)
		})
		.await
	}
	async fn introduce_once(&self, peer: &str, id: &Id) -> Result<Introduction, Error> {
		let args = [Argument::String(peer.into()), Argument::String(id.as_str().into())];
		let reply = self
			.client
			.deadline
			.within(
				authority::REQUEST_TIMEOUT_MS,
				self.client
					.session
					.send_redeeming(&self.reference, policy::INTRODUCE, &args),
			)
			.await
			.ok_or(Error::Timeout(
				"the directory did not finish redeeming its introduction",
			))??;
		let Argument::Reference(inbox) = reply.reply else {
			return Err(policy::Error::Capability.into());
		};
		let owns_connection = reply.via.is_some();
		let connection = if owns_connection {
			// The redeem result observes the exporter. This client must own its
			// share of that connection until its line and delegated files retire.
			let session = self
				.client
				.session
				.host()
				.reference_session(&inbox)?
				.ok_or(policy::Error::Ended)?;
			Rc::new(session.with_gc())
		} else {
			self.client.session.clone()
		};
		Ok(Introduction {
			inbox,
			registration: id.clone(),
			connection,
			owns_connection,
		})
	}
}
fn pending(error: &Error) -> bool {
	let Error::Binding(error) = error else { return false };
	error.kind() == glowcap::ErrorKind::Broken
		&& error
			.message()
			.and_then(Failure::parse)
			.is_some_and(|f| f.code == FailureCode::IntroductionPending)
}
