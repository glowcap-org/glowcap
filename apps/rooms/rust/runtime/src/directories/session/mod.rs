//! A directory connection attempt retains its work across cancelled readiness
//! observations. The session runtime owns these attempts and their live clients;
//! dropping one directory never explicitly closes a shared transport.
use crate::{Error, session::commands::SessionCommands};
use rooms_application::session::{
	checkpoint::reconciliation::{Fact, Field, Id},
	directory::DirectoryView,
};
use rooms_glowcap::client::{Deadline, Tasks, directory::Directory};
use tokio::task::JoinHandle;

mod live;
pub use live::{DirectoryEvents, DirectoryState, Event, LiveDirectory, Notice};

pub struct Register {
	/// This session peer's advertised locator, supplied by its listener owner.
	pub member_locator: String,
	pub voucher: Option<Vec<u8>>,
}
/// Transfer a held directory when this runtime already owns that peer
/// connection. Dialing again does not adopt capabilities from another connection.
pub enum Source<P: crate::directories::connections::Platform> {
	/// Use the Host's configured native providers or browser connectors.
	Dial {
		connections: crate::directories::connections::Connections<P>,
	},
	Adopt {
		directory: Directory<P>,
		/// Share keeps the granted name, which may differ from saved intent.
		nick: String,
	},
}
struct Intent {
	id: Id,
	locator: Id,
	nick: Field,
	nick_allocation: rooms_application::directory::registration::NicknameAllocation,
}
impl Intent {
	fn ensure_current(&self, commands: &SessionCommands) -> Result<(), Error> {
		let current = commands.view().read(|state| {
			Ok::<_, rooms_application::session::state::Error>(state.checkpoint()?.directories().any(|directory| {
				directory.id == &self.id
					&& directory.locator == &self.locator
					&& directory.nick == &self.nick
					&& directory.nick_allocation == self.nick_allocation
			}))
		})??;
		if current {
			Ok(())
		} else {
			Err(Error::stale("the directory intent changed while connecting"))
		}
	}
}
pub struct DirectoryConnection<P: Tasks> {
	pending: Option<JoinHandle<Result<LiveDirectory<P>, Error>>>,
	live: Option<LiveDirectory<P>>,
	failure: Option<Error>,
}
impl<P: Deadline + Tasks + Clone + 'static> DirectoryConnection<P> {
	pub fn take_ready(&mut self) -> Option<LiveDirectory<P>> {
		self.live.take()
	}
	/// Resolve the selected committed intent before starting I/O. Readiness
	/// includes the durable reached fact and, for a named directory, name custody
	/// and its reconnect voucher. Drive this on the Host's LocalSet.
	pub fn start(source: Source<P>, commands: SessionCommands, id: &Id, register: Register) -> Result<Self, Error> {
		let intent = commands
			.view()
			.read(|state| {
				Ok::<_, rooms_application::session::state::Error>(
					state
						.checkpoint()?
						.directories()
						.find(|directory| directory.id == id)
						.map(|directory| Intent {
							id: directory.id.clone(),
							locator: directory.locator.clone(),
							nick: directory.nick.clone(),
							nick_allocation: directory.nick_allocation,
						}),
				)
			})??
			.ok_or_else(|| Error::stale("the directory is no longer in this session"))?;
		let pending = tokio::task::spawn_local(connect(source, commands, intent, register));
		Ok(Self {
			pending: Some(pending),
			live: None,
			failure: None,
		})
	}
	/// Cancellation abandons only this observation. A second call resumes the
	/// same connection attempt, including any in-flight durable reconciliation.
	pub async fn ready(&mut self) -> Result<&mut LiveDirectory<P>, Error> {
		if let Some(pending) = &mut self.pending {
			let result = pending
				.await
				.map_err(|e| Error::closed(format!("directory connection worker ended: {e}")));
			self.pending = None;
			match result.and_then(core::convert::identity) {
				Ok(live) => self.live = Some(live),
				Err(error) => self.failure = Some(error),
			}
		}
		self.live.as_mut().ok_or_else(|| {
			self.failure
				.clone()
				.unwrap_or_else(|| Error::closed("the directory owner is closed"))
		})
	}
	/// Stop admission and await actual task retirement. An already-admitted
	/// durable fact remains owned by SessionCommands and drains at its shutdown.
	pub async fn close(&mut self) -> Result<(), Error> {
		self.live = None;
		if let Some(pending) = &mut self.pending {
			pending.abort();
			let result = pending.await;
			self.pending = None;
			if let Err(error) = result
				&& !error.is_cancelled()
			{
				return Err(Error::closed(format!("directory connection worker ended: {error}")));
			}
		}
		Ok(())
	}
}
impl<P: Tasks> Drop for DirectoryConnection<P> {
	fn drop(&mut self) {
		if let Some(pending) = &self.pending {
			pending.abort();
		}
	}
}

async fn connect<P: Deadline + Tasks + Clone + 'static>(
	source: Source<P>,
	commands: SessionCommands,
	intent: Intent,
	register: Register,
) -> Result<LiveDirectory<P>, Error> {
	let requested_nick = intent
		.nick
		.text()
		.as_str()
		.ok_or_else(|| Error::invalid("the directory nick is not valid Unicode"))?;
	let (directory, prior_grant) = match source {
		Source::Dial { connections } => {
			let locator = intent
				.locator
				.text()
				.as_str()
				.and_then(rooms_glowcap::routes::locator)
				.ok_or_else(|| Error::invalid("the directory locator is invalid"))?;
			let connection = connections.connect(&locator).await?;
			let client = connection.client;
			(Directory::fetch(client).await.map_err(Error::peer)?, String::new())
		}
		Source::Adopt { directory, nick } => (directory, nick),
	};
	let (registration_nick, allocation) = if prior_grant.is_empty() {
		(requested_nick.to_owned(), intent.nick_allocation)
	} else {
		(
			prior_grant,
			rooms_application::directory::registration::NicknameAllocation::Exact,
		)
	};
	if !registration_nick.is_empty() && !rooms_application::room::inbox::valid_nick(&registration_nick) {
		return Err(Error::invalid("the directory nick is invalid"));
	}
	let (snapshot, updates) = directory.watch().await.map_err(Error::peer)?.into_parts();
	commands
		.prepare_fact(Fact::DirectoryReached {
			directory: intent.id.clone(),
			locator: intent.locator.clone(),
		})?
		.send()?
		.wait()
		.await?;
	// The reached fact may be stale by the time it commits. Never register a
	// name for intent that was removed or changed while this attempt waited.
	intent.ensure_current(&commands)?;
	let mut name = None;
	let mut voucher = None;
	let mut actual_nick = registration_nick.clone();
	if !registration_nick.is_empty() {
		let mut registration = directory.registration();
		let grant = registration
			.register_with_allocation(
				&registration_nick,
				allocation,
				&register.member_locator,
				register.voucher,
			)
			.await
			.map_err(Error::peer)?;
		let granted = grant
			.nick
			.text()
			.as_str()
			.ok_or_else(|| Error::invalid("the granted directory nick is not valid Unicode"))?;
		// The registration notice is the commit outcome. All downstream room
		// admission and reconnect custody use it, never the requested base.
		actual_nick = granted.into();
		voucher = registration.name_voucher().await.map_err(Error::peer)?;
		name = Some(registration);
	}
	intent.ensure_current(&commands)?;
	updates.status().map_err(|e| Error::peer(e.into()))?;
	Ok(LiveDirectory::new(
		directory,
		actual_nick,
		DirectoryView::new(intent.id, snapshot),
		updates,
		name,
		voucher,
	))
}
