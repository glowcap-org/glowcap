//! A direct notification becomes usable only after serialized durable acceptance.
//! Issued contexts carry permanent conversation and directory lifetimes.
use super::{DirectoryRuntime, Generation, Platform, RegistrationWork};
use crate::session_state::SessionView;
use rooms_application::{
	directory::registration,
	session::checkpoint::{
		reconciliation::{Fact, Id},
		Checkpoint, DirectIntent,
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
	pub fn nickname(&self) -> Result<String, String> {
		self.0
			.view
			.read(|state| {
				state
					.checkpoint()
					.map_err(|e| e.to_string())?
					.directories()
					.find(|directory| directory.id == self.directory())
					.ok_or("the direct directory is no longer intended")?
					.nick
					.text()
					.as_str()
					.map(str::to_owned)
					.ok_or_else(|| "the direct nickname is not valid UTF-8".into())
			})
			.map_err(|e| e.to_string())?
	}

	pub fn recording_policy<T>(&self, with: impl FnOnce(bool, &str) -> Result<T, String>) -> Result<T, String> {
		self.0
			.view
			.read(|state| {
				let checkpoint = state.checkpoint().map_err(|e| e.to_string())?;
				if !checkpoint.keeps_history() {
					return with(false, "");
				}
				let directory = checkpoint
					.directories()
					.find(|directory| directory.id == self.directory())
					.ok_or("the recording directory is no longer intended")?;
				with(
					checkpoint.keeps_history(),
					directory
						.nick
						.text()
						.as_str()
						.ok_or("the recording nickname is not valid UTF-8")?,
				)
			})
			.map_err(|e| e.to_string())?
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
	) -> AcceptedDirect {
		self.issue_with(
			checkpoint,
			intent,
			work.key.clone(),
			work.event.registration.clone(),
			view,
		)
	}
	fn issue_with(
		&mut self,
		checkpoint: &Checkpoint,
		intent: DirectIntent<'_>,
		directory: Rc<Generation>,
		registration: registration::Id,
		view: SessionView,
	) -> AcceptedDirect {
		self.reconcile(checkpoint);
		if let Some(existing) = self
			.0
			.iter()
			.filter_map(Weak::upgrade)
			.find(|context| context.matches(intent) && Rc::ptr_eq(&context.directory, &directory))
		{
			return AcceptedDirect(existing);
		}
		// One weak entry per current committed conversation: the checkpoint's
		// conversation bound also bounds this registry. Actors own their contexts.
		let context = Rc::new(Context {
			id: intent.id.clone(),
			peer: intent.peer.clone(),
			registration,
			directory,
			active: Cell::new(true),
			view,
		});
		self.0.push(Rc::downgrade(&context));
		AcceptedDirect(context)
	}
}
impl<P: Platform> DirectoryRuntime<P> {
	/// A committed direct conversation on a currently connected directory.
	/// Opening the route is a separate dispatcher effect.
	pub fn intended_direct(&self, conversation: &str) -> Result<AcceptedDirect, String> {
		if self.is_closed() {
			return Err("the directory runtime has retired".into());
		}
		let view = self.commands.view();
		let checkpoint = view
			.read(|state| state.checkpoint_handle())
			.map_err(|e| e.to_string())?
			.map_err(|e| e.to_string())?;
		let intent = checkpoint
			.directs()
			.find(|intent| !intent.closed && intent.id.text().as_str() == Some(conversation))
			.ok_or("that direct conversation is no longer intended")?;
		let registration = registration::Id::parse(
			intent
				.registration
				.text()
				.as_str()
				.ok_or("the direct registration is not valid UTF-8")?,
		)
		.map_err(|e| e.to_string())?;
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
			.ok_or("the direct directory is no longer connected")?;
		Ok(state
			.directs
			.issue_with(&checkpoint, intent, directory, registration, view))
	}
	/// A reverse-route request can use only already committed conversation
	/// intent. It never invokes acceptance or creates a new conversation.
	pub fn requested_direct(&self, work: &RegistrationWork) -> Result<Option<AcceptedDirect>, String> {
		if work.event.kind != registration::Kind::DirectRequested {
			return Err("this notification is not a reciprocal route request".into());
		}
		self.require_current(work)?;
		self.accepted(work)
	}
	pub fn direct_directory(
		&self,
		accepted: &AcceptedDirect,
	) -> Result<rooms_glowcap::client::directory::Directory<P>, String> {
		if self.is_closed() || !accepted.current() {
			return Err("the direct conversation has retired".into());
		}
		self.shared
			.borrow()
			.rows
			.iter()
			.find(|row| accepted.in_directory(&row.key))
			.and_then(|row| row.live())
			.map(|live| live.directory().clone())
			.ok_or_else(|| "the direct directory is no longer connected".into())
	}
	/// Accept only MintInboxFor from this runtime's current registration.
	/// This returns durable intent and its lifetime; publication is a separate
	/// effect and must check the returned context before offering or delivering.
	pub async fn accept_direct(&self, work: &RegistrationWork) -> Result<AcceptedDirect, String> {
		if work.event.kind != registration::Kind::MintInboxFor {
			return Err("this directory notification cannot accept a direct conversation".into());
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
				.ok_or("directory identity is not scalar text")?,
			&work.event.registration,
		)
		.ok_or("direct conversation identity exceeds its bound")?;
		let fact = Fact::DirectAccepted {
			conversation: id,
			directory: work.key.id.as_ref().clone(),
			peer: Id::new(work.event.peer.text().clone()).expect("validated notification peer"),
			registration: rooms_application::fields::Text::new(work.event.registration.as_str().into())
				.expect("validated registration ID"),
		};
		self.commands
			.prepare_scoped_fact(fact, &work.key.scope)
			.map_err(|e| e.to_string())?
			.send()
			.map_err(|e| e.to_string())?
			.wait()
			.await?;
		self.require_current(work)?;
		self.accepted(work)?
			.ok_or_else(|| "the accepted direct conversation is no longer intended".into())
	}
	fn require_current(&self, work: &RegistrationWork) -> Result<(), String> {
		if self.is_closed()
			|| !work.current()
			|| !self
				.shared
				.borrow()
				.rows
				.iter()
				.any(|row| Rc::ptr_eq(&row.key, &work.key))
		{
			return Err("the directory registration has retired or belongs to another session".into());
		}
		Ok(())
	}
	fn accepted(&self, work: &RegistrationWork) -> Result<Option<AcceptedDirect>, String> {
		let view = self.commands.view();
		let checkpoint = view
			.read(|state| state.checkpoint_handle())
			.map_err(|e| e.to_string())?
			.map_err(|e| e.to_string())?;
		let Some(intent) = checkpoint.directs().find(|intent| {
			!intent.closed
				&& intent.directory == work.key.id.as_ref()
				&& intent.registration.text().as_str() == Some(work.event.registration.as_str())
		}) else {
			return Ok(None);
		};
		if intent.peer.text() != work.event.peer.text() {
			return Err("the direct registration belongs to a different peer".into());
		}
		Ok(Some(self.shared.borrow_mut().directs.issue(
			&checkpoint,
			intent,
			work,
			view,
		)))
	}
}
