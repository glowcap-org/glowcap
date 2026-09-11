//! A directory connection attempt retains its work across cancelled readiness
//! observations. The session runtime owns these attempts and their live clients;
//! dropping one directory never explicitly closes a shared transport.
use crate::session_commands::SessionCommands;
use rooms_application::session::{
	checkpoint::reconciliation::{Fact, Field, Id},
	directory::DirectoryView,
};
use rooms_glowcap::client::{directory::Directory, Deadline, Tasks};
use tokio::task::JoinHandle;

mod live;
pub use live::{DirectoryEvents, DirectoryState, Event, LiveDirectory, Notice};

pub struct Register {
	/// This session peer's advertised locator, supplied by its listener owner.
	pub member_locator: String,
	pub voucher: Option<Vec<u8>>,
}
/// Transfer a held directory when this runtime already owns that peer
/// connection. Dialing again does not adopt existing capabilities.
pub enum Source<P: crate::connections::Platform> {
	/// Use the Host's configured native providers or browser connectors.
	Dial {
		connections: crate::connections::Connections<P>,
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
}
impl Intent {
	fn ensure_current(&self, commands: &SessionCommands) -> Result<(), String> {
		let current = commands
			.view()
			.read(|state| {
				Ok::<_, rooms_application::session::state::Error>(state.checkpoint()?.directories().any(|directory| {
					directory.id == &self.id && directory.locator == &self.locator && directory.nick == &self.nick
				}))
			})
			.map_err(|e| e.to_string())?
			.map_err(|e| e.to_string())?;
		if current {
			Ok(())
		} else {
			Err("the directory intent changed while connecting".into())
		}
	}
}
pub struct DirectoryConnection<P: Tasks> {
	pending: Option<JoinHandle<Result<LiveDirectory<P>, String>>>,
	live: Option<LiveDirectory<P>>,
	failure: Option<String>,
}
impl<P: Deadline + Tasks + Clone + 'static> DirectoryConnection<P> {
	pub fn take_ready(&mut self) -> Option<LiveDirectory<P>> {
		self.live.take()
	}
	/// Resolve the selected committed intent before starting I/O. Readiness
	/// includes the durable reached fact and, for a named directory, name custody
	/// and its reconnect voucher. Drive this on the Host's LocalSet.
	pub fn start(source: Source<P>, commands: SessionCommands, id: &Id, register: Register) -> Result<Self, String> {
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
						}),
				)
			})
			.map_err(|e| e.to_string())?
			.map_err(|e| e.to_string())?
			.ok_or("the directory is no longer in this session")?;
		let pending = tokio::task::spawn_local(connect(source, commands, intent, register));
		Ok(Self {
			pending: Some(pending),
			live: None,
			failure: None,
		})
	}
	/// Cancellation abandons only this observation. A second call resumes the
	/// same connection attempt, including any in-flight durable reconciliation.
	pub async fn ready(&mut self) -> Result<&mut LiveDirectory<P>, String> {
		if let Some(pending) = &mut self.pending {
			let result = pending
				.await
				.map_err(|e| format!("directory connection worker ended: {e}"));
			self.pending = None;
			match result.and_then(core::convert::identity) {
				Ok(live) => self.live = Some(live),
				Err(error) => self.failure = Some(error),
			}
		}
		self.live.as_mut().ok_or_else(|| {
			self.failure
				.clone()
				.unwrap_or_else(|| "the directory owner is closed".into())
		})
	}
	/// Stop admission and await actual task retirement. An already-admitted
	/// durable fact remains owned by SessionCommands and drains at its shutdown.
	pub async fn close(&mut self) -> Result<(), String> {
		self.live = None;
		if let Some(pending) = &mut self.pending {
			pending.abort();
			let result = pending.await;
			self.pending = None;
			if let Err(error) = result {
				if !error.is_cancelled() {
					return Err(format!("directory connection worker ended: {error}"));
				}
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
) -> Result<LiveDirectory<P>, String> {
	let requested_nick = intent
		.nick
		.text()
		.as_str()
		.ok_or("the directory nick is not valid Unicode")?;
	let (directory, granted_nick) = match source {
		Source::Dial { connections } => {
			let locator = intent
				.locator
				.text()
				.as_str()
				.and_then(rooms_glowcap::routes::locator)
				.ok_or("the directory locator is invalid")?;
			let connection = connections.connect(&locator).await.map_err(|e| e.to_string())?;
			let client = connection.client;
			(
				Directory::fetch(client).await.map_err(|e| e.to_string())?,
				String::new(),
			)
		}
		Source::Adopt { directory, nick } => (directory, nick),
	};
	let nick = if granted_nick.is_empty() {
		requested_nick
	} else {
		&granted_nick
	};
	if !nick.is_empty() && !rooms_application::room::inbox::valid_nick(nick) {
		return Err("the directory nick is invalid".into());
	}
	let (snapshot, updates) = directory.watch().await.map_err(|e| e.to_string())?.into_parts();
	commands
		.prepare_fact(Fact::DirectoryReached {
			directory: intent.id.clone(),
			locator: intent.locator.clone(),
		})
		.map_err(|e| e.to_string())?
		.send()
		.map_err(|e| e.to_string())?
		.wait()
		.await?;
	// The reached fact may be stale by the time it commits. Never register a
	// name for intent that was removed or changed while this attempt waited.
	intent.ensure_current(&commands)?;
	let mut name = None;
	let mut voucher = None;
	if !nick.is_empty() {
		let mut registration = directory.registration();
		registration
			.register(nick, &register.member_locator, register.voucher)
			.await
			.map_err(|e| e.to_string())?;
		voucher = registration.name_voucher().await.map_err(|e| e.to_string())?;
		name = Some(registration);
	}
	intent.ensure_current(&commands)?;
	updates.status().map_err(|e| e.to_string())?;
	Ok(LiveDirectory::new(
		directory,
		nick.to_owned(),
		DirectoryView::new(intent.id, snapshot),
		updates,
		name,
		voucher,
	))
}
