//! A room-link offer enters the durable serializer. Admission owns
//! its bounded record before a receiver defers the wire acknowledgement.
use super::{AcceptedDirect, Directories, DirectoryRuntime, Platform};
use crate::{
	Error,
	session::commands::{Admission, SessionCommands},
};
use rooms_application::session::state::OperationId;
use std::{
	cell::RefCell,
	rc::{Rc, Weak},
};

/// Safe to retain in a hosted receiver: directory and transport custody stay
/// with the parent. The command handle retains no Host or live capability.
#[derive(Clone)]
pub struct RoomLinkReceiver<P: Platform> {
	directories: Weak<RefCell<Directories<P>>>,
	commands: SessionCommands,
	stop: tokio::sync::watch::Receiver<bool>,
	done: tokio::sync::watch::Receiver<Option<Result<(), Error>>>,
}

impl<P: Platform> DirectoryRuntime<P> {
	pub fn room_links(&self) -> RoomLinkReceiver<P> {
		RoomLinkReceiver {
			directories: Rc::downgrade(&self.shared),
			commands: self.commands.clone(),
			stop: self.stop.subscribe(),
			done: self.done.clone(),
		}
	}
}
impl<P: Platform> RoomLinkReceiver<P> {
	pub(super) fn random_id(
		&self,
		prefix: &str,
	) -> Result<rooms_application::session::checkpoint::reconciliation::Id, Error> {
		self.directories
			.upgrade()
			.ok_or_else(|| Error::closed("the directory owner has ended"))?
			.borrow_mut()
			.random_id(prefix)
	}

	/// Once sent, the admitted receipt can commit after its carrying direct
	/// closes: the offer already delivered durable authority. Unsent admission
	/// can be dropped without executing; the caller owns the reply observation.
	pub fn prepare(&self, context: &AcceptedDirect, label: &str, link: &str) -> Result<Admission<u64>, Error> {
		let nick = self.with_directory(context, |_, live| live.nick().to_owned())?;
		let id = self.random_id("invitation-")?;
		let invitation = rooms_glowcap::routes::received_room_link(
			id.text().as_str().expect("generated invitation identifier"),
			&nick,
			label,
			context.peer_name(),
			link,
		)
		.map_err(Error::invalid_by)?;
		Ok(self.commands.prepare_room_link(
			OperationId::new(id.text().clone()).expect("bounded invitation operation identifier"),
			invitation,
		)?)
	}
	pub(super) fn with_directory<T>(
		&self,
		context: &AcceptedDirect,
		read: impl FnOnce(&Rc<super::Generation>, &crate::directories::session::DirectoryState<P>) -> T,
	) -> Result<T, Error> {
		if *self.stop.borrow()
			|| self.stop.has_changed().is_err()
			|| self.done.borrow().is_some()
			|| self.done.has_changed().is_err()
			|| !context.current()
		{
			return Err(Error::closed("the invitation's direct conversation has retired"));
		}
		let directories = self
			.directories
			.upgrade()
			.ok_or_else(|| Error::closed("the invitation's directory owner has ended"))?;
		let directories = directories.borrow();
		let row = directories
			.rows
			.iter()
			.find(|row| context.in_directory(&row.key))
			.ok_or_else(|| Error::stale("the invitation belongs to another runtime or retired directory"))?;
		let live = row
			.live()
			.ok_or_else(|| Error::closed("the invitation directory is disconnected"))?;
		Ok(read(&row.key, live))
	}
}
