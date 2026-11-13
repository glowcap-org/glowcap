//! Direct inbox acquisition through a held directory and the Host's handoff path.
use super::*;
use rooms_application::directory::{introduction as policy, registration::Id};
use std::{cell::Cell, future::poll_fn, task::Poll};

#[derive(Clone, Default)]
pub(crate) struct Slots(Rc<Cell<usize>>);
impl Slots {
	fn enter(&self) -> Result<Active, Error> {
		if self.0.get() == policy::MAX_OUTSTANDING {
			return Err(policy::Error::Full.into());
		}
		self.0.set(self.0.get() + 1);
		Ok(Active(self.clone()))
	}
}
struct Active(Slots);
impl Drop for Active {
	fn drop(&mut self) {
		self.0.0.set(self.0.0.get() - 1);
	}
}
/// The inbox and the actual connection on which a reciprocal inbox belongs.
/// Dropping this result releases its capability, not a shared exporter session.
pub struct Introduction {
	pub inbox: Ref,
	pub registration: Id,
	connection: Rc<Session>,
}
impl Introduction {
	pub(crate) fn into_parts(self) -> (Ref, Id, Rc<Session>) {
		(self.inbox, self.registration, self.connection)
	}
	pub fn session(&self) -> &Session {
		&self.connection
	}
}
struct OpeningSequence(Cell<u64>);

impl<D: Deadline + Tasks + Clone + 'static> Directory<D> {
	pub async fn introduce(&self, peer: &str, expected: Option<&Id>) -> Result<Introduction, Error> {
		let sequence = self
			.client
			.session
			.host()
			.application_state(|| OpeningSequence(Cell::new(0)))?;
		let next = sequence.0.get().checked_add(1).ok_or(policy::Error::Full)?;
		sequence.0.set(next);
		let opening = format!("direct:{next}");
		self.introduce_opening(peer, expected, &opening).await
	}
	/// One call waits for the inbox belonging to these exact registrations.
	pub async fn introduce_opening(
		&self,
		peer: &str,
		expected: Option<&Id>,
		opening: &str,
	) -> Result<Introduction, Error> {
		if !policy::valid_opening(opening) {
			return Err(policy::Error::Capability.into());
		}
		let _active = self.introductions.enter()?;
		let work = async {
			let id = match expected {
				Some(id) => id.clone(),
				None => self.member_registration(peer).await?,
			};
			self.introduce_once(peer, &id, opening).await
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
	async fn introduce_once(&self, peer: &str, id: &Id, opening: &str) -> Result<Introduction, Error> {
		let args = [
			Argument::String(peer.into()),
			Argument::String(id.as_str().into()),
			Argument::String(opening.into()),
		];
		let reply = self
			.client
			.deadline
			.within(
				policy::REQUEST_TIMEOUT_MS,
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
		let connection = if reply.via.is_some() {
			// The redeem result observes the exporter. This client must own its
			// share of that connection until its line and delegated files retire.
			let session = self
				.client
				.session
				.host()
				.reference_session(&inbox)?
				.ok_or(policy::Error::Ended)?;
			Rc::new(session)
		} else {
			self.client.session.clone()
		};
		Ok(Introduction {
			inbox,
			registration: id.clone(),
			connection,
		})
	}
}
