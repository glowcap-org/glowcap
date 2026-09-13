//! A direct notification becomes usable only after serialized durable acceptance.
//! Issued contexts carry permanent conversation and directory lifetimes.
use super::{DirectoryRuntime, Generation, Platform, RegistrationWork};
use crate::{Error, session::state::SessionView};
use rooms_application::{
	directory::registration,
	session::checkpoint::{
		Checkpoint, DirectIntent,
		reconciliation::{Fact, Id},
	},
};
use std::{
	cell::Cell,
	rc::{Rc, Weak},
};

#[derive(Clone)]
pub struct AcceptedDirect(Rc<Context>);
struct Context {
	id: Id,
	peer: Id,
	registration: registration::Id,
	directory: Rc<Generation>,
	active: Cell<bool>,
	partner_left: Cell<bool>,
	view: SessionView,
}
impl Context {
	fn matches(&self, intent: DirectIntent<'_>) -> bool {
		!intent.closed
			&& intent.id == &self.id
			&& intent.directory == self.directory.id.as_ref()
			&& intent.peer == &self.peer
			&& intent.registration.text().as_str() == Some(self.registration.as_str())
	}
}
impl AcceptedDirect {
	pub fn owned_by(&self, view: &SessionView) -> bool {
		self.0.view.same_owner(view)
	}
	pub fn nickname(&self) -> Result<String, Error> {
		self.0.view.read(|state| {
			state
				.checkpoint()?
				.directories()
				.find(|directory| directory.id == self.directory())
				.ok_or_else(|| Error::stale("the direct directory is no longer intended"))?
				.nick
				.text()
				.as_str()
				.map(str::to_owned)
				.ok_or_else(|| Error::invalid("the direct nickname is not valid UTF-8"))
		})?
	}

	pub fn recording_policy<T>(&self, with: impl FnOnce(bool, &str) -> Result<T, Error>) -> Result<T, Error> {
		self.0.view.read(|state| {
			let checkpoint = state.checkpoint()?;
			if !checkpoint.keeps_history() {
				return with(false, "");
			}
			let directory = checkpoint
				.directories()
				.find(|directory| directory.id == self.directory())
				.ok_or_else(|| Error::stale("the recording directory is no longer intended"))?;
			with(
				checkpoint.keeps_history(),
				directory
					.nick
					.text()
					.as_str()
					.ok_or_else(|| Error::invalid("the recording nickname is not valid UTF-8"))?,
			)
		})?
	}
	pub(super) fn in_directory(&self, generation: &Rc<Generation>) -> bool {
		Rc::ptr_eq(&self.0.directory, generation)
	}
	pub fn same_context(&self, other: &Self) -> bool {
		Rc::ptr_eq(&self.0, &other.0)
	}
	pub fn conversation(&self) -> &Id {
		&self.0.id
	}
	pub fn directory(&self) -> &Id {
		&self.0.directory.id
	}
	pub fn peer(&self) -> &Id {
		&self.0.peer
	}
	/// The peer's name as text. Acceptance refused any peer whose name is not
	/// valid text, so every producer reads it here without a check of its own.
	pub fn peer_name(&self) -> &str {
		self.0
			.peer
			.text()
			.as_str()
			.expect("the direct peer name was validated at acceptance")
	}
	/// Exact unregister evidence for this context, retained across checkpoint retirement.
	pub fn partner_left(&self) -> bool {
		self.0.partner_left.get()
	}
	pub fn registration(&self) -> &registration::Id {
		&self.0.registration
	}
	/// Check on every use, including after awaited effects. A closed context
	/// cannot revive when an identical checkpoint is subsequently restored.
	pub fn current(&self) -> bool {
		self.0.active.get()
			&& self.0.directory.scope.current()
			&& self
				.0
				.view
				.read(|state| {
					state
						.checkpoint()
						.is_ok_and(|checkpoint| checkpoint.directs().any(|intent| self.0.matches(intent)))
				})
				.unwrap_or(false)
	}
}

#[derive(Default)]
pub(super) struct Accepted(Vec<Weak<Context>>);
impl Accepted {
	pub fn registration_retired(&mut self, directory: &Rc<Generation>, peer: &rooms_application::directory::Member) {
		for context in self.0.iter().filter_map(Weak::upgrade) {
			if Rc::ptr_eq(&context.directory, directory)
				&& context.peer.text() == peer.name.text()
				&& peer.registration_id.as_str() == Some(context.registration.as_str())
			{
				context.partner_left.set(true);
			}
		}
	}

	pub fn reconcile(&mut self, checkpoint: &Checkpoint) {
		self.0.retain(|weak| {
			let Some(context) = weak.upgrade() else { return false };
			if !context.directory.scope.current() || !checkpoint.directs().any(|intent| context.matches(intent)) {
				context.active.set(false);
			}
			context.active.get()
		});
	}
	fn issue(
		&mut self,
		checkpoint: &Checkpoint,
		intent: DirectIntent<'_>,
		work: &RegistrationWork,
		view: SessionView,
	) -> Result<AcceptedDirect, Error> {
		self.issue_with(
			checkpoint,
			intent,
			work.key.clone(),
			work.event.registration.clone(),
			view,
		)
	}
	/// A context is issued once per committed conversation and validated
	/// here, at the one place it is made, so `AcceptedDirect::peer_name` holds
	/// for its whole life. A checkpoint may arrive whole from a caller, so the
	/// peer name is checked rather than trusted.
	fn issue_with(
		&mut self,
		checkpoint: &Checkpoint,
		intent: DirectIntent<'_>,
		directory: Rc<Generation>,
		registration: registration::Id,
		view: SessionView,
	) -> Result<AcceptedDirect, Error> {
		if intent.peer.text().as_str().is_none() {
			return Err(Error::invalid("the direct peer name is not valid text"));
		}
		self.reconcile(checkpoint);
		if let Some(existing) = self
			.0
			.iter()
			.filter_map(Weak::upgrade)
			.find(|context| context.matches(intent) && Rc::ptr_eq(&context.directory, &directory))
		{
			return Ok(AcceptedDirect(existing));
		}
		// One weak entry per current committed conversation: the checkpoint's
		// conversation bound also bounds this registry. Actors own their contexts.
		let context = Rc::new(Context {
			id: intent.id.clone(),
			peer: intent.peer.clone(),
			registration,
			directory,
			active: Cell::new(true),
			partner_left: Cell::new(false),
			view,
		});
		self.0.push(Rc::downgrade(&context));
		Ok(AcceptedDirect(context))
	}
}
impl<P: Platform> DirectoryRuntime<P> {
	/// A committed direct conversation on a currently connected directory.
	/// Opening the route is a separate dispatcher effect.
	pub fn intended_direct(&self, conversation: &str) -> Result<AcceptedDirect, Error> {
		if self.is_closed() {
			return Err(Error::closed("the directory runtime has retired"));
		}
		let view = self.commands.view();
		let checkpoint = view.read(|state| state.checkpoint_handle())??;
		let intent = checkpoint
			.directs()
			.find(|intent| !intent.closed && intent.id.text().as_str() == Some(conversation))
			.ok_or_else(|| Error::stale("that direct conversation is no longer intended"))?;
		let registration = registration::Id::parse(
			intent
				.registration
				.text()
				.as_str()
				.ok_or_else(|| Error::invalid("the direct registration is not valid UTF-8"))?,
		)
		.map_err(Error::invalid_by)?;
		let mut state = self.shared.borrow_mut();
		let directory = state
			.rows
			.iter()
			.find(|row| {
				row.wanted.id.as_ref() == intent.directory
					&& row.phase == super::Phase::Connected
					&& row.key.scope.current()
			})
			.map(|row| row.key.clone())
			.ok_or_else(|| Error::closed("the direct directory is no longer connected"))?;
		state
			.directs
			.issue_with(&checkpoint, intent, directory, registration, view)
	}
	/// A reverse-route request can use only already committed conversation
	/// intent. It never invokes acceptance or creates a new conversation.
	pub fn requested_direct(&self, work: &RegistrationWork) -> Result<Option<AcceptedDirect>, Error> {
		if work.event.kind != registration::Kind::DirectRequested {
			return Err(Error::invalid("this notification is not a reciprocal route request"));
		}
		self.require_current(work)?;
		self.accepted(work)
	}
	pub fn direct_directory(
		&self,
		accepted: &AcceptedDirect,
	) -> Result<rooms_glowcap::client::directory::Directory<P>, Error> {
		if self.is_closed() || !accepted.current() {
			return Err(Error::closed("the direct conversation has retired"));
		}
		self.shared
			.borrow()
			.rows
			.iter()
			.find(|row| accepted.in_directory(&row.key))
			.and_then(|row| row.live())
			.map(|live| live.directory().clone())
			.ok_or_else(|| Error::closed("the direct directory is no longer connected"))
	}
	/// Accept only MintInboxFor from this runtime's current registration.
	/// This returns durable intent and its lifetime; publication is a separate
	/// effect and must check the returned context before offering or delivering.
	pub async fn accept_direct(&self, work: &RegistrationWork) -> Result<AcceptedDirect, Error> {
		if work.event.kind != registration::Kind::MintInboxFor {
			return Err(Error::invalid(
				"this directory notification cannot accept a direct conversation",
			));
		}
		self.require_current(work)?;
		if let Some(accepted) = self.accepted(work)? {
			return Ok(accepted);
		}
		let id = rooms_application::session::checkpoint::direct_id(
			work.key
				.id
				.text()
				.as_str()
				.ok_or_else(|| Error::invalid("directory identity is not scalar text"))?,
			&work.event.registration,
		)
		.ok_or_else(|| Error::invalid("direct conversation identity exceeds its bound"))?;
		let fact = Fact::DirectAccepted {
			conversation: id,
			directory: work.key.id.as_ref().clone(),
			peer: Id::new(work.event.peer.text().clone()).expect("validated notification peer"),
			registration: rooms_application::fields::Text::new(work.event.registration.as_str().into())
				.expect("validated registration ID"),
		};
		self.commands
			.prepare_scoped_fact(fact, &work.key.scope)?
			.send()?
			.wait()
			.await?;
		self.require_current(work)?;
		self.accepted(work)?
			.ok_or_else(|| Error::stale("the accepted direct conversation is no longer intended"))
	}
	fn require_current(&self, work: &RegistrationWork) -> Result<(), Error> {
		if self.is_closed()
			|| !work.current()
			|| !self
				.shared
				.borrow()
				.rows
				.iter()
				.any(|row| Rc::ptr_eq(&row.key, &work.key))
		{
			return Err(Error::stale(
				"the directory registration has retired or belongs to another session",
			));
		}
		Ok(())
	}
	fn accepted(&self, work: &RegistrationWork) -> Result<Option<AcceptedDirect>, Error> {
		let view = self.commands.view();
		let checkpoint = view.read(|state| state.checkpoint_handle())??;
		let Some(intent) = checkpoint.directs().find(|intent| {
			!intent.closed
				&& intent.directory == work.key.id.as_ref()
				&& intent.registration.text().as_str() == Some(work.event.registration.as_str())
		}) else {
			return Ok(None);
		};
		if intent.peer.text() != work.event.peer.text() {
			return Err(Error::stale("the direct registration belongs to a different peer"));
		}
		self.shared
			.borrow_mut()
			.directs
			.issue(&checkpoint, intent, work, view)
			.map(Some)
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::{
		documents::VolatileDocuments,
		entropy::{Entropy, EntropyUnavailable},
		session::state::DurableSession,
	};
	struct UnusedEntropy;
	impl Entropy for UnusedEntropy {
		fn fill(&mut self, _: &mut [u8]) -> Result<(), EntropyUnavailable> {
			unreachable!()
		}
	}
	#[test]
	fn departure_evidence_names_the_exact_generation_peer_and_registration() {
		let owner = DurableSession::new(VolatileDocuments::default(), UnusedEntropy);
		let directory = Generation::new(Rc::new(Id::new("directory".into()).unwrap()));
		let context = Rc::new(Context {
			id: Id::new("conversation".into()).unwrap(),
			peer: Id::new("bob".into()).unwrap(),
			registration: registration::Id::parse("11111111-1111-4111-8111-111111111111").unwrap(),
			directory: directory.clone(),
			active: Cell::new(true),
			partner_left: Cell::new(false),
			view: owner.view(),
		});
		let accepted = AcceptedDirect(context.clone());
		let mut contexts = Accepted(vec![Rc::downgrade(&context)]);
		let mut peer = rooms_application::directory::Member {
			name: rooms_application::fields::Text::new("bob".into()).unwrap(),
			registration_id: "22222222-2222-4222-8222-222222222222".into(),
		};
		contexts.registration_retired(&directory, &peer);
		assert!(!accepted.partner_left(), "same nickname with a different registration");
		peer.registration_id = context.registration.as_str().into();
		let replacement = Generation::new(directory.id.clone());
		contexts.registration_retired(&replacement, &peer);
		assert!(
			!accepted.partner_left(),
			"same directory name with a different lifetime"
		);
		peer.name = rooms_application::fields::Text::new("carol".into()).unwrap();
		contexts.registration_retired(&directory, &peer);
		assert!(!accepted.partner_left(), "a different member is not this partner");
		peer.name = rooms_application::fields::Text::new("bob".into()).unwrap();
		contexts.registration_retired(&directory, &peer);
		assert!(accepted.partner_left());
		assert!(
			context.active.get(),
			"discovery evidence does not bypass durable retirement"
		);
		contexts.reconcile(&Checkpoint::empty());
		assert!(!context.active.get());
		assert!(
			accepted.partner_left(),
			"the cleanup owner retains the cause after checkpoint retirement"
		);
	}
}
