//! Recording starts in admitted callbacks, independently of presentation.
//! Archive capture retains the exact source and rechecks it around every read.
use super::{InboxOrigin, Opened, Session, State};
use crate::{
	archive::{
		recording::completion_issue,
		session::{Destination, SessionArchive},
	},
	platform::Platform,
};
use glowcap::{Argument, Host, Ref, Result, loam};
use rooms_application::{
	archive::{ConversationKind, Coordinates, recording::Message},
	content::session::workspace::InboxSelection,
	open_graph::Selection,
	room::{
		attachment::Attachment,
		message::{ChangeKind, LineId},
	},
	text::DocumentText,
};
use rooms_glowcap::client::{Deadline, Tasks, files::File, sources::Reader, workspace::Workspace};
use std::{
	cell::RefCell,
	collections::BTreeMap,
	future::Future,
	pin::Pin,
	rc::{Rc, Weak},
};
use tokio::sync::Notify;
mod availability;
pub(super) mod destination;
mod retention;

pub(super) async fn admit<P: Tasks + Deadline + Clone + 'static>(
	writer: &Rc<super::executor::Writer>,
	platform: P,
	workspace: &Workspace<P>,
	selected: &InboxSelection,
	inbox: &Ref,
) -> Result<Option<Destination>> {
	let selection = serde_json::to_string(selected).map_err(|_| loam::refusal("invalid recording selection"))?;
	let args = [writer.root()?.into(), selection.into(), inbox.clone().into()];
	let reply = platform
		.within(rooms_application::room::authority::REQUEST_TIMEOUT_MS, async {
			writer.host.send(workspace.reference(), "record-inbox", &args).await
		})
		.await
		.ok_or_else(|| loam::refusal("recording admission did not answer"))??;
	match reply {
		Argument::Boolean(false) => Ok(None),
		Argument::Void => Ok(Some(Destination::Device)),
		Argument::String(encoded) => {
			let key = serde_json::from_str(&encoded).map_err(|_| loam::refusal("invalid recording target"))?;
			Ok(Some(destination::selected(writer.clone(), platform, key)))
		}
		_ => Err(loam::refusal("invalid recording admission")),
	}
}

pub(super) struct Line<'a> {
	pub from: &'a str,
	pub text: &'a str,
	pub previews: &'a Selection,
	pub id: LineId,
	pub change: ChangeKind,
	pub system: bool,
}
pub(super) struct Outgoing<'a> {
	pub origin: &'a rooms_application::content::session::outgoing::Origin,
	pub history: &'a rooms_application::content::session::workspace::Id,
	pub text: &'a str,
	pub change: ChangeKind,
}
pub(super) trait Sink {
	fn observe_archive(
		&self,
		key: Option<
			rooms_application::content::session::custody::FieldKey<
				rooms_application::content::session::custody::ArchiveAccess,
			>,
		>,
		session: Option<glowcap::Session>,
	);
	fn erasing(&self) -> bool;
	fn retry(&self);
	fn reader(&self) -> &Ref;
	fn record(&self, origin: &InboxOrigin, line: &Line<'_>, files: &[Attachment<Ref>]) -> Option<Coordinates>;
	fn outgoing(
		&self,
		source: &Ref,
		message: Outgoing<'_>,
		files: &[Attachment<Ref>],
		destination: Option<Destination>,
	) -> Option<Coordinates>;
	fn close(&self) -> Pin<Box<dyn Future<Output = Result<()>> + '_>>;
}
struct Recording<P: Platform> {
	retention: retention::Owner<P>,
	owner: Weak<State<P>>,
	archive: Rc<SessionArchive<P>>,
	source: DocumentText,
	reader: Ref,
	observations: Rc<RefCell<BTreeMap<u64, P::Task>>>,
	changed: Rc<Notify>,
	next: std::cell::Cell<u64>,
}
impl<P: Platform> Opened<P> {
	/// Install before starting memberships. The archive worker and its backend
	/// already belong to the embedding. Device archive storage may be shared by
	/// tabs, so the stable committed owner key scopes both recording and reading.
	pub fn record_to(&self, archive: Rc<SessionArchive<P>>, source: DocumentText) -> Result<()> {
		use std::fmt::Write;
		let mut scoped = source
			.as_str()
			.ok_or_else(|| loam::refusal("invalid archive recording source"))?
			.to_owned();
		scoped.push(':');
		for byte in &self.anchor().resource.encode()[..33] {
			let _ = write!(&mut scoped, "{byte:02x}");
		}
		if scoped.encode_utf16().count() > rooms_application::archive::MAX_ID_BYTES {
			return Err(loam::refusal("archive recording source exceeds its bound"));
		}
		self.session().install_recording(archive, scoped.into())
	}
}
impl<P: Platform> Session<P> {
	fn install_recording(&self, archive: Rc<SessionArchive<P>>, source: DocumentText) -> Result<()> {
		if self.state.recording.borrow().is_some() || self.state.memberships.active() != 0 || self.state.closing.get() {
			return Err(loam::refusal("install archive before starting session activity"));
		}
		let reader = archive
			.local_reader(
				&self.state.writer.host,
				rooms_application::archive::Filter {
					source: Some(source.clone()),
					..Default::default()
				},
			)
			.map_err(|e| loam::refusal(e.to_string()))?;
		let retention = retention::Owner::start(self, archive.clone(), source.clone())?;
		*self.state.recording.borrow_mut() = Some(Rc::new(Recording {
			retention,
			owner: Rc::downgrade(&self.state),
			archive,
			source,
			reader,
			observations: Default::default(),
			changed: Rc::new(Notify::new()),
			next: std::cell::Cell::new(1),
		}));
		Ok(())
	}
}
pub(super) fn record<P: Tasks + Deadline + Clone + 'static>(
	owner: &Weak<State<P>>,
	origin: &InboxOrigin,
	line: &Line<'_>,
	files: &[Attachment<Ref>],
) -> Option<Coordinates> {
	let owner = owner.upgrade()?;
	let recording = owner.recording.borrow().clone()?;
	recording.record(origin, line, files)
}
impl<P: Platform> Sink for Recording<P> {
	fn observe_archive(
		&self,
		key: Option<
			rooms_application::content::session::custody::FieldKey<
				rooms_application::content::session::custody::ArchiveAccess,
			>,
		>,
		session: Option<glowcap::Session>,
	) {
		self.retention.observe_archive(key, session);
	}
	fn outgoing(
		&self,
		source: &Ref,
		message: Outgoing<'_>,
		files: &[Attachment<Ref>],
		destination: Option<Destination>,
	) -> Option<Coordinates> {
		let Outgoing {
			origin,
			history,
			text,
			change,
		} = message;
		let destination = destination?;
		let owner = self.owner.upgrade()?;
		let record = || -> Result<Option<crate::archive::recording::Recording>> {
			if self.observations.borrow().len() == crate::archive::session::MAX_PENDING {
				return Err(loam::refusal("archive receipt observations are full"));
			}
			self.next
				.get()
				.checked_add(1)
				.ok_or_else(|| loam::refusal("archive observation identities exhausted"))?;
			let from = origin
				.from
				.text()
				.as_str()
				.ok_or_else(|| loam::refusal("outgoing sender required"))?;
			let sources = files
				.iter()
				.map(|file| {
					File::mediated(
						file.clone(),
						OutgoingFile {
							host: owner.writer.host.clone(),
							platform: owner.platform.clone(),
							source: source.clone(),
							blob: file.blob.clone(),
							reader: Rc::new(tokio::sync::Mutex::new(None)),
						},
						core::mem::size_of::<OutgoingFile<P>>()
							+ core::mem::size_of::<tokio::sync::Mutex<Option<Ref>>>()
							+ 2 * core::mem::size_of::<usize>(),
					)
				})
				.collect();
			self.archive
				.record_message_to(
					destination,
					&self.source,
					&Message {
						keep: true,
						generation: Some(origin.generation.text()),
						kind: ConversationKind::Direct,
						directory: origin.directory.text(),
						conversation: history.text(),
						nick: from,
						from,
						text,
						previews: &origin.previews,
						system: false,
						line: rooms_application::room::message::LineId::new(origin.id.get()),
						change,
						at: owner.platform.unix_millis().map_err(|e| loam::refusal(e.to_string()))?,
					},
					sources,
				)
				.map_err(|e| loam::refusal(e.to_string()))
		};
		match record() {
			Ok(Some(recording)) => Some(self.observe(&owner, recording)),
			Ok(None) => None,
			Err(error) => {
				owner.writer.report("outgoing archive recording", &error);
				None
			}
		}
	}
	fn retry(&self) {
		self.retention.retry();
	}
	fn erasing(&self) -> bool {
		self.retention.is_running()
	}
	fn reader(&self) -> &Ref {
		&self.reader
	}
	fn record(&self, origin: &InboxOrigin, line: &Line<'_>, files: &[Attachment<Ref>]) -> Option<Coordinates> {
		if line.system {
			return None;
		}
		let destination = origin.recording_destination()?;
		let owner = self.owner.upgrade()?;
		let record = || -> Result<Option<crate::archive::recording::Recording>> {
			if self.observations.borrow().len() == crate::archive::session::MAX_PENDING {
				return Err(loam::refusal("archive receipt observations are full"));
			}
			self.next
				.get()
				.checked_add(1)
				.ok_or_else(|| loam::refusal("archive observation identities exhausted"))?;
			let (selection, _) = origin
				.installed()
				.ok_or_else(|| loam::refusal("recording requires an installed conversation"))?;
			let (kind, directory, nick) = match selection {
				InboxSelection::Room {
					directory, nickname, ..
				} => (
					ConversationKind::Room,
					directory,
					nickname.text().text().as_str().unwrap_or(""),
				),
				InboxSelection::Direct { directory, .. } => (ConversationKind::Direct, directory, ""),
				InboxSelection::Directory { .. } => return Ok(None),
			};
			// The confirmed Loam lifetime and exact callback field distinguish
			// repeated line IDs, reconnects and cold restoration. A display name
			// supplies neither authority nor archive identity.
			let marker = owner.activity.incarnation_hex()?;
			let key = selection.coordinate().key;
			let generation: DocumentText = format!("{}:{:016x}{:016x}", marker, key.slot(), key.generation()).into();
			let directory = directory.text().clone();
			let conversation = selection
				.history_id()
				.ok_or_else(|| loam::refusal("conversation inbox is absent"))?
				.text()
				.clone();
			let at = owner.platform.unix_millis().map_err(|e| loam::refusal(e.to_string()))?;
			let sources = files
				.iter()
				.map(|file| {
					File::mediated(
						file.clone(),
						CallbackFile {
							host: owner.writer.host.clone(),
							platform: owner.platform.clone(),
							origin: origin.clone(),
							blob: file.blob.clone(),
							reader: Rc::new(tokio::sync::Mutex::new(None)),
						},
						origin.retained_bytes()
							+ core::mem::size_of::<tokio::sync::Mutex<Option<Ref>>>()
							+ 2 * core::mem::size_of::<usize>(),
					)
				})
				.collect();
			self.archive
				.record_message_to(
					destination,
					&self.source,
					&Message {
						keep: true,
						generation: Some(&generation),
						kind,
						directory: &directory,
						conversation: &conversation,
						nick,
						from: line.from,
						text: line.text,
						previews: line.previews,
						system: line.system,
						line: Some(line.id),
						change: line.change,
						at,
					},
					sources,
				)
				.map_err(|e| loam::refusal(e.to_string()))
		};
		let recording = match record() {
			Ok(recording) => recording?,
			Err(error) => {
				owner.writer.report("archive recording", &error);
				return None;
			}
		};
		Some(self.observe(&owner, recording))
	}
	fn close(&self) -> Pin<Box<dyn Future<Output = Result<()>> + '_>> {
		Box::pin(async {
			self.retention.close().await?;
			let owner = self
				.owner
				.upgrade()
				.ok_or_else(|| loam::refusal("recording owner has closed"))?;
			let drain = async {
				loop {
					let changed = self.changed.notified();
					tokio::pin!(changed);
					changed.as_mut().enable();
					if self.observations.borrow().is_empty() {
						break;
					}
					changed.await;
				}
			};
			owner
				.platform
				.within(rooms_application::room::authority::REQUEST_TIMEOUT_MS, drain)
				.await
				.ok_or_else(|| loam::refusal("archive receipts are still pending; retry close"))?;
			Ok(())
		})
	}
}
impl<P: Platform> Recording<P> {
	fn observe(&self, owner: &Rc<State<P>>, recording: crate::archive::recording::Recording) -> Coordinates {
		let coordinates = recording.coordinates;
		let id = self.next.get();
		self.next.set(id + 1);
		let weak = self.owner.clone();
		let observations = self.observations.clone();
		let changed = self.changed.clone();
		let task = owner.platform.spawn(async move {
			if let Some(issue) = completion_issue(recording.completion.await)
				&& let Some(owner) = weak.upgrade()
			{
				owner.writer.report("archive recording", &loam::refusal(issue));
			}
			observations.borrow_mut().remove(&id);
			changed.notify_waiters();
		});
		self.observations.borrow_mut().insert(id, task);
		coordinates
	}
}

/// Local uploads retain their exact source. Capture never refetches by name.
struct OutgoingFile<P> {
	host: Host,
	platform: P,
	source: Ref,
	blob: Ref,
	reader: Rc<tokio::sync::Mutex<Option<Ref>>>,
}
impl<P: Platform> Reader for OutgoingFile<P> {
	fn read(
		&self,
		offset: usize,
		length: usize,
	) -> Pin<Box<dyn Future<Output = core::result::Result<Vec<u8>, String>>>> {
		let (host, platform, source, blob, reader) = (
			self.host.clone(),
			self.platform.clone(),
			self.source.clone(),
			self.blob.clone(),
			self.reader.clone(),
		);
		Box::pin(async move {
			let read = async {
				let mut held = reader.lock().await;
				if held.is_none() {
					*held = Some(
						Workspace::local(host.clone(), platform.clone(), source)
							.file_reader(&blob)
							.await
							.map_err(|e| e.to_string())?,
					);
				}
				let opened = held
					.as_ref()
					.ok_or_else(|| "outgoing archive file reader is not opened".to_owned())?;
				match host
					.send(
						opened,
						rooms_application::protocol_data::READ,
						&[(offset as i64).into(), (length as i64).into()],
					)
					.await
					.map_err(|e| e.to_string())?
				{
					glowcap::Argument::Bytes(bytes) => Ok(bytes),
					_ => Err("invalid outgoing archive file chunk".into()),
				}
			};
			platform
				.within(rooms_application::files::transfer::STALL_MS, read)
				.await
				.ok_or_else(|| "outgoing archive file source stopped answering".to_owned())?
		})
	}
}
/// Capture keeps only bounded attachment metadata, exact callback authority
/// and one lazy managed reader. It borrows no viewer event or ring entry and
/// copies no file bytes beyond the source's returned chunk.
struct CallbackFile<P> {
	host: Host,
	platform: P,
	origin: InboxOrigin,
	blob: Ref,
	reader: Rc<tokio::sync::Mutex<Option<Ref>>>,
}
impl<P: Platform> Reader for CallbackFile<P> {
	fn read(
		&self,
		offset: usize,
		length: usize,
	) -> Pin<Box<dyn Future<Output = core::result::Result<Vec<u8>, String>>>> {
		let (host, platform, origin, blob, reader) = (
			self.host.clone(),
			self.platform.clone(),
			self.origin.clone(),
			self.blob.clone(),
			self.reader.clone(),
		);
		Box::pin(async move {
			let read = async {
				origin.check(&host, platform.clone()).await.map_err(|e| e.to_string())?;
				let mut held = reader.lock().await;
				if held.is_none() {
					let source = Workspace::local(host.clone(), platform.clone(), origin.source().clone());
					*held = Some(source.file_reader(&blob).await.map_err(|e| e.to_string())?);
				}
				let opened = held
					.as_ref()
					.ok_or_else(|| "captured file reader is not opened".to_owned())?;
				let result = host
					.send(
						opened,
						rooms_application::protocol_data::READ,
						&[(offset as i64).into(), (length as i64).into()],
					)
					.await
					.map_err(|e| e.to_string())?;
				origin.check(&host, platform.clone()).await.map_err(|e| e.to_string())?;
				match result {
					glowcap::Argument::Bytes(bytes) => Ok(bytes),
					_ => Err("invalid captured file chunk".into()),
				}
			};
			platform
				.within(rooms_application::files::transfer::STALL_MS, read)
				.await
				.ok_or_else(|| "archive file source stopped answering".to_owned())?
		})
	}
}
