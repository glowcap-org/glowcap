//! One explicit directory route owns each signaling exchange through cleanup.
use super::*;
use rooms_application::signaling as policy;
use std::cell::RefCell;
mod inbox;
mod state;
pub use inbox::Inbox;
pub use state::CleanupFailure;
pub(crate) use state::Registry;
use state::{wait, wake, State};

pub struct Exchange<D: Tasks> {
	client: Client<D>,
	directory: Ref,
	designator: policy::Id,
	state: Rc<RefCell<State>>,
	registry: Registry,
	reply: RefCell<Option<Ref>>,
	worker: RefCell<Option<D::Task>>,
	closed: RefCell<Option<D::Task>>,
}
impl<D: Deadline + Tasks + Clone + 'static> Directory<D> {
	pub fn signaling_exchange(&self, designator: &str) -> Result<Exchange<D>, Error> {
		let designator = policy::Id::parse(designator)?;
		let state = Rc::new(RefCell::new(State::default()));
		self.signaling.insert(&designator, &state)?;
		let weak = Rc::downgrade(&state);
		let reply = match self.client.session.spawn_owned(move |verb, args| {
			let state = weak.upgrade().ok_or("the signaling exchange has ended")?;
			let reply = policy::reply(verb, args.len(), |i| args.get(i).map(Value)).map_err(|e| e.to_string())?;
			let result = state.borrow_mut().core.receive(reply);
			wake(&state);
			result.map_err(|e| e.to_string())?;
			Ok(Argument::Void)
		}) {
			Ok(reply) => reply,
			Err(error) => {
				self.signaling.remove(&state);
				return Err(error.into());
			}
		};
		let weak = Rc::downgrade(&state);
		let session = self.client.session.clone();
		let closed = self.client.deadline.spawn(async move {
			let _ = session.closed().await;
			if let Some(state) = weak.upgrade() {
				state.borrow_mut().core.retire();
				wake(&state);
			}
		});
		Ok(Exchange {
			client: self.client.clone(),
			directory: self.reference.clone(),
			designator,
			state,
			registry: self.signaling.clone(),
			reply: RefCell::new(Some(reply)),
			worker: RefCell::new(None),
			closed: RefCell::new(Some(closed)),
		})
	}
	pub fn take_signaling_failure(&self) -> Option<CleanupFailure> {
		self.signaling.take_failure()
	}
	pub async fn offer_signaling(&self, inbox: &Ref) -> Result<(), Error> {
		let pending = self.client.call(
			&self.reference,
			policy::OFFER_INBOX,
			&[inbox.clone().into()],
			"the directory did not accept its signaling inbox",
		);
		pending.await?;
		Ok(())
	}
	pub fn signal_answer(&self, id: &policy::Id, answer: &policy::Description) -> Result<(), Error> {
		tell(
			&self.client.session,
			&self.reference,
			policy::ANSWER,
			id.as_str(),
			answer.as_str(),
		)
	}
	pub fn signal_candidate(&self, id: &policy::Id, candidate: &policy::Candidate) -> Result<(), Error> {
		tell(
			&self.client.session,
			&self.reference,
			policy::CANDIDATE,
			id.as_str(),
			candidate.as_str(),
		)
	}
}
impl<D: Deadline + Tasks + Clone + 'static> Exchange<D> {
	/// Start once. The exchange owns the bounded attempt; dropping an answer
	/// observation neither retries the offer nor loses its actual milestones.
	pub fn offer(&self, description: &policy::Description) -> Result<(), Error> {
		self.state.borrow_mut().core.start()?;
		let (client, directory, designator, reply, state) = (
			self.client.clone(),
			self.directory.clone(),
			self.designator.clone(),
			self.reply.borrow().as_ref().ok_or(policy::Error::Ended)?.clone(),
			self.state.clone(),
		);
		let description = description.clone();
		*self.worker.borrow_mut() = Some(self.client.deadline.spawn(async move {
			let work = async {
				let pending = {
					let args = [designator.as_str().into(), description.as_str().into(), reply.into()];
					client.call(
						&directory,
						policy::OFFER,
						&args,
						"the directory did not answer its signaling offer",
					)
				};
				if let Err(error) = pending.await {
					state.borrow_mut().core.fail(error);
					wake(&state);
				}
				state::settled(&state).await
			};
			let failure = match client.deadline.within(policy::TIMEOUT_MS, work).await {
				None => Some(Error::Timeout("the signaling exchange timed out")),
				Some(Err(error)) => Some(error),
				Some(Ok(())) => None,
			};
			if let Some(error) = failure {
				state.borrow_mut().core.fail(error);
				wake(&state);
			}
		}));
		Ok(())
	}
	pub async fn answer(&self) -> Result<policy::Description, Error> {
		wait(&self.state, |core| core.answer()).await
	}
	pub async fn candidate(&self, candidate: &policy::Candidate) -> Result<(), Error> {
		let id = wait(&self.state, |core| core.accepted()).await?;
		tell(
			&self.client.session,
			&self.directory,
			policy::CANDIDATE,
			id.as_str(),
			candidate.as_str(),
		)
	}
	pub async fn next_candidate(&self) -> Result<Option<policy::Candidate>, Error> {
		wait(&self.state, |core| {
			if core.ended() {
				Ok(Some(None))
			} else {
				core.candidate().map(|candidate| candidate.map(Some))
			}
		})
		.await
	}
}
impl<D: Tasks> Exchange<D> {
	pub fn close(&self) -> Result<(), Error> {
		let id = self.state.borrow_mut().core.retire();
		self.worker.borrow_mut().take();
		self.reply.borrow_mut().take();
		self.closed.borrow_mut().take();
		self.registry.remove(&self.state);
		wake(&self.state);
		if let Some(id) = id {
			self.client
				.session
				.tell(&self.directory, policy::DONE, &[id.as_str().into()])?;
		}
		Ok(())
	}
}
impl<D: Tasks> Drop for Exchange<D> {
	fn drop(&mut self) {
		if let Err(error) = self.close() {
			self.registry.failed(error);
		}
	}
}
fn tell(session: &Session, directory: &Ref, verb: &str, id: &str, payload: &str) -> Result<(), Error> {
	session.tell(directory, verb, &[id.into(), payload.into()])?;
	Ok(())
}
