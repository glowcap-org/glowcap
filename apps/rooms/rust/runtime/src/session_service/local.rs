//! Trusted in-process access to the same session execution used by wire facets.
//! This handle owns no Host, transport, publication, or independent state.
pub(super) mod observation;
mod operator;
mod shares;
use super::{
	error::Error,
	facet::{Facet, Inner},
	revision::Revision,
	Completion, Platform,
};
pub use observation::{Observation, Observer};
use rooms_application::{
	room::ArgumentView,
	session::{checkpoint::Checkpoint, command::Request, snapshot::Snapshot, state::OperationId},
};
use std::rc::{Rc, Weak};

#[derive(Clone)]
pub struct Local<P: Platform>(Weak<Inner<P>>);
impl<P: Platform> Local<P> {
	pub(super) fn new(facet: &Facet<P>) -> Self {
		Self(Rc::downgrade(&facet.0))
	}
	fn facet(&self) -> Result<Facet<P>, Error> {
		let facet = Facet(
			self.0
				.upgrade()
				.ok_or_else(|| Error::refused("local Rooms session is closed"))?,
		);
		facet.require_live()?;
		Ok(facet)
	}
	pub fn command(&self, request: &Request<'_, impl ArgumentView>) -> Result<Completion, Error> {
		let facet = self.facet()?;
		super::verbs::command::prepare(&facet, request)?.start(&facet)
	}
	/// The embedding owner can fence recording while retiring device storage.
	/// This authority is local to the host and is never exported on a wire facet.
	pub fn pause_recording(&self) -> Result<crate::session_archive::RecordingPause, Error> {
		Ok(self.facet()?.0.archive.pause_recording())
	}
	pub fn replace(&self, id: OperationId, base: u64, checkpoint: Checkpoint) -> Result<Completion, Error> {
		let facet = self.facet()?;
		Revision::admitted(facet.0.commands.prepare_replace(id, base, checkpoint)?).start(&facet)
	}
	pub fn adopt(&self, id: OperationId, base: u64, checkpoint: Checkpoint) -> Result<Completion, Error> {
		let facet = self.facet()?;
		Revision::admitted(facet.0.commands.prepare_adoption(id, base, checkpoint)?).start(&facet)
	}
	/// Register before reading the initial snapshot; no state change can fall
	/// between those synchronous operations on the session executor.
	pub fn observe(&self, observer: Rc<dyn Observer>) -> Result<Observation, Error> {
		self.facet()?.0.local_views.attach(observer)
	}
	pub fn files(
		&self,
		id: OperationId,
		base: u64,
		conversation: &str,
		command: crate::rooms::FileCommand,
	) -> Result<Completion, Error> {
		let facet = self.facet()?;
		super::verbs::files::prepare(&facet, id, base, conversation, command)?.start(&facet)
	}
	pub async fn history(
		&self,
		filter: rooms_application::archive::Filter,
	) -> Result<Vec<crate::session_archive::KeptRecord<P>>, Error> {
		let facet = self.facet()?;
		let access = super::authority::HistoryAccess::new(&facet, &super::authority::Authority::Admin)?;
		let rows = facet
			.0
			.archive
			.read(filter)
			.map_err(Error::runtime)?
			.wait()
			.await
			.map_err(Error::runtime)?;
		access.check()?;
		Ok(rows)
	}
	pub async fn history_view(
		&self,
		filter: rooms_application::archive::Filter,
	) -> Result<crate::session_archive::HistoryView<P>, Error> {
		let facet = self.facet()?;
		let access = super::authority::HistoryAccess::new(&facet, &super::authority::Authority::Admin)?;
		let view = facet
			.0
			.archive
			.read_view(filter)
			.map_err(Error::runtime)?
			.wait()
			.await
			.map_err(Error::runtime)?;
		access.check()?;
		Ok(view)
	}
	pub fn archived_file(
		&self,
		record: rooms_application::archive::Record,
		index: usize,
	) -> Result<super::ArchivedFile<P>, Error> {
		super::ArchivedFile::local(&self.facet()?, record, index)
	}
	pub fn resume(&self, id: OperationId) -> Result<Completion, Error> {
		let facet = self.facet()?;
		super::verbs::results::resume(&facet, id)?.start(&facet)
	}
	pub fn resolve(
		&self,
		id: OperationId,
		outcome: rooms_application::session::state::Outcome,
	) -> Result<Completion, Error> {
		let facet = self.facet()?;
		Revision::admitted(facet.0.commands.resolve(id, outcome)?).start(&facet)
	}
	pub async fn bridge_form(&self, conversation: &str) -> Result<Option<rooms_application::bridge::Form>, Error> {
		let facet = self.facet()?;
		let form = facet.0.rooms.bridge_form(conversation).await.map_err(Error::runtime)?;
		facet.require_live()?;
		Ok(form)
	}
	pub fn grant(
		&self,
		command: rooms_application::grants::Command,
	) -> Result<crate::grant_commands::GrantReply, Error> {
		let facet = self.facet()?;
		facet
			.0
			.grant_commands
			.get()
			.ok_or_else(|| Error::runtime("Rooms grant owner is not ready"))?
			.change(command)
			.map_err(Error::runtime)
	}
	pub fn operations(
		&self,
		scope: &str,
		capability: rooms_application::session::operations::Capability,
	) -> Result<Completion<rooms_application::session::operations::Snapshot>, Error> {
		let facet = self.facet()?;
		super::verbs::operations::prepare_snapshot(&facet, scope, capability)?.start(&facet)
	}
	pub fn typing(&self, observation: &Observation, conversation: &str, on: bool) -> Result<(), Error> {
		let facet = self.facet()?;
		let origin = facet.0.local_views.identify(observation)?;
		super::verbs::typing::send(&facet, conversation, on, None, Some(origin))
	}
	pub fn snapshot(&self) -> Result<Snapshot, Error> {
		let facet = self.facet()?;
		facet.local_snapshot()
	}
}
