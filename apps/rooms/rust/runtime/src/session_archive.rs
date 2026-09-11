//! Session-owned archive effects are admitted synchronously and executed in
//! order. A selected unavailable peer never becomes implicit local recording.
use crate::{archive::Backend, platform::Platform};
use glowcap::Runtime;
use rooms_application::archive::{index::Page, Filter, Record};
use rooms_glowcap::client::files::File;
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
	sync::Arc,
};
use tokio::sync::{mpsc, oneshot, watch, OwnedSemaphorePermit, Semaphore};
mod blobs;
mod capture;
pub use capture::MAX_STREAMS;
mod issuer;
mod share;
mod sources;
use sources::Sources;
mod targets;
pub use blobs::{ArchivedBlob, LocalBlob};
mod worker;
/// The share behavior the session service publishes for a share it hands out.
use share::Work;
pub use targets::{Blob, Keeper, KeptRecord, Local, Peer};
pub use worker::Worker;
pub const MAX_PENDING: usize = 64;
pub const MAX_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_FILE_BYTES: usize = 64 * 1024 * 1024;
pub struct HistoryView<P: Platform> {
	pub records: Vec<KeptRecord<P>>,
	pub local: bool,
	pub peer: bool,
}
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Report {
	pub completed: u64,
	pub refused: u64,
	pub lost_replies: u64,
	pub cleanup_failures: u64,
	pub partial_recordings: u64,
	pub metadata_only_recordings: u64,
	/// Why durable share publications were not restored at startup, when they
	/// were not. The worker keeps serving; the owner decides who hears it.
	pub restore_failure: Option<String>,
}
pub use crate::archive_recording::{FileRecording, MetadataReason, Recorded, Recording, Reply};
/// Retained archive admission, including captures whose replies were abandoned.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Usage {
	pub requests: usize,
	pub bytes: usize,
	pub files: usize,
	pub captures: usize,
}
pub struct SessionArchive<P: Platform>(Rc<State<P>>);
/// Fences new recordings while a retention change clears and commits.
pub struct RecordingPause(Rc<Cell<usize>>);
impl Drop for RecordingPause {
	fn drop(&mut self) {
		self.0.set(self.0.get() - 1);
	}
}
struct State<P: Platform> {
	changes: tokio::sync::broadcast::Sender<rooms_application::archive::change::Change>,
	hosting: crate::archive::hosting::Budget,
	platform: P,
	local_blobs: bool,
	peer_selected: Cell<bool>,
	selection_issue: RefCell<Option<String>>,
	status: watch::Sender<()>,
	recording_pauses: Rc<Cell<usize>>,
	captures: Rc<Cell<usize>>,
	requests: mpsc::Sender<Pending<P>>,
	stop: watch::Sender<bool>,
	done: watch::Receiver<Option<Report>>,
	usage: Rc<Cell<Budget>>,
	capacity: Arc<Semaphore>,
}
#[derive(Clone, Copy, Default)]
struct Budget {
	bytes: usize,
	files: usize,
}
struct Permit {
	usage: Rc<Cell<Budget>>,
	_count: OwnedSemaphorePermit,
	bytes: usize,
	files: usize,
}
impl Drop for Permit {
	fn drop(&mut self) {
		let mut usage = self.usage.get();
		usage.bytes -= self.bytes;
		usage.files -= self.files;
		self.usage.set(usage);
	}
}
// Most requests keep inline custody. Only capture shares it with tasks and buffers.
enum Custody {
	Owned { _permit: Permit },
	Shared { _permit: Rc<Permit> },
}
struct Pending<P: Platform> {
	command: Command<P>,
	_permit: Custody,
}
type Answer<T> = oneshot::Sender<Result<T, String>>;
enum Command<P: Platform> {
	Lend(
		glowcap::Session,
		rooms_application::archive::Facet,
		Answer<glowcap::Ref>,
	),
	SharedPage(Work<P>, Filter, u64, usize, glowcap::Resolver),
	BlobReader(String, Answer<rooms_application::archive::blobs::Reader>),
	ReadBlob(rooms_application::archive::blobs::Reader, u64, usize, Answer<Vec<u8>>),
	Share(rooms_application::archive::shares::Share, Answer<String>),
	Revoke(String, Answer<bool>),
	Shares(Answer<Vec<rooms_glowcap::client::archive::ShareView>>),
	Issued(Answer<Vec<rooms_glowcap::client::archive::ShareView>>),
	Select(Option<String>, Answer<()>),
	Prepare(String, Answer<()>),
	Put(Record, Vec<File<P>>, Answer<u64>),
	Record(
		Record,
		String,
		Option<capture::Capture>,
		FileRecording,
		Answer<Recorded>,
	),
	Clear(Answer<()>),
	Read(Filter, Answer<Vec<KeptRecord<P>>>),
	ReadView(Filter, Answer<HistoryView<P>>),
	Page(Filter, u64, usize, Answer<Page>),
}
impl<P: Platform> SessionArchive<P> {
	/// Subscribe before the first history read. Lag means invalidate all;
	/// recording never waits for a view, including one that abandoned its reply.
	pub fn changes(&self) -> tokio::sync::broadcast::Receiver<rooms_application::archive::change::Change> {
		self.0.changes.subscribe()
	}
	pub fn usage(&self) -> Usage {
		let budget = self.0.usage.get();
		Usage {
			requests: MAX_PENDING - self.0.capacity.available_permits(),
			bytes: budget.bytes,
			files: budget.files,
			captures: self.0.captures.get(),
		}
	}

	/// The runtime is borrowed through shared custody; closing archives never
	/// closes unrelated rooms or direct sessions using that runtime.
	pub fn new<B: Backend>(platform: P, runtime: Rc<Runtime>, backend: B) -> (Self, Worker<B, P>) {
		let (requests, rx) = mpsc::channel(MAX_PENDING);
		let (stop, _) = watch::channel(false);
		let status = watch::channel(()).0;
		let (finished, done) = watch::channel(None);
		let local_blobs = backend.retains_blobs();
		let state = Rc::new(State {
			// Sixteen scopes, each bounded by archive context limits. A lagging
			// consumer rereads its account instead of retaining an event backlog.
			changes: tokio::sync::broadcast::channel(16).0,
			platform,
			local_blobs,
			peer_selected: Cell::new(false),
			selection_issue: RefCell::new(None),
			status,
			recording_pauses: Rc::default(),
			captures: Rc::new(Cell::new(0)),
			requests,
			stop,
			done,
			usage: Rc::new(Cell::new(Budget::default())),
			capacity: Arc::new(Semaphore::new(MAX_PENDING)),
			hosting: Default::default(),
		});
		let worker = Worker::new(runtime, backend, state.clone(), rx, finished);
		(Self(state), worker)
	}
	pub fn select(&self, link: Option<String>) -> Result<Reply<()>, String> {
		let bytes = link.as_ref().map_or(0, String::len);
		let peer_selected = link.is_some();
		let reply = self.0.admit(bytes, 0, |reply| Command::Select(link, reply))?;
		// This is the target of subsequently admitted recordings. Connection
		// realization remains ordered in the worker and may explicitly refuse.
		self.0.peer_selected.set(peer_selected);
		Ok(reply)
	}
	pub fn selection_issue(&self) -> Option<String> {
		self.0.selection_issue.borrow().clone()
	}
	pub fn status_changes(&self) -> watch::Receiver<()> {
		self.0.status.subscribe()
	}
	pub fn prepare(&self, link: String) -> Result<Reply<()>, String> {
		self.0.admit(link.len(), 0, |reply| Command::Prepare(link, reply))
	}
	pub fn pause_recording(&self) -> RecordingPause {
		self.0.recording_pauses.set(self.0.recording_pauses.get() + 1);
		RecordingPause(self.0.recording_pauses.clone())
	}
	pub fn put(&self, record: Record, sources: Vec<File<P>>) -> Result<Reply<u64>, String> {
		if self.0.recording_pauses.get() != 0 {
			return Err("history retention is changing".into());
		}
		if !sources.is_empty() {
			rooms_application::archive::blobs::validate_sources(
				&record,
				sources.iter().map(|s| &s.attachment().description),
			)
			.map_err(|e| e.to_string())?;
		}
		let (bytes, files) = input_budget(&record, &sources)?;
		self.0.admit(bytes, files, |reply| Command::Put(record, sources, reply))
	}
	/// Admit on the session LocalSet. File capture starts independently of the
	/// ordered storage queue; completion reports capture and storage refusal.
	/// Withdrawals retain no file sources.
	/// When pending file bytes reach their ceiling, metadata is still admitted;
	/// the completion reports why its attachment bytes were omitted.
	pub fn record_message(
		&self,
		source: &rooms_application::text::DocumentText,
		message: &rooms_application::archive::recording::Message<'_>,
		sources: Vec<File<P>>,
	) -> Result<Option<Recording>, String> {
		self.record_sources(source, message, Sources::Live(sources))
	}
	pub fn record_files(
		&self,
		source: &rooms_application::text::DocumentText,
		message: &rooms_application::archive::recording::Message<'_>,
		sources: Vec<crate::media_files::FileView>,
	) -> Result<Option<Recording>, String> {
		self.record_sources(source, message, Sources::Views(sources))
	}
	fn record_sources(
		&self,
		source: &rooms_application::text::DocumentText,
		message: &rooms_application::archive::recording::Message<'_>,
		mut sources: Sources<P>,
	) -> Result<Option<Recording>, String> {
		if self.0.recording_pauses.get() != 0 {
			return Ok(None);
		}
		let Some(record) = rooms_application::archive::recording::message(source, message, sources.descriptions())
			.map_err(|e| e.to_string())?
		else {
			return Ok(None);
		};
		if message.change == rooms_application::room::message::ChangeKind::Withdrawn {
			sources = Sources::Live(Vec::new());
		}
		let coordinates = record.coordinates().clone();
		let (mut bytes, mut files) = sources.budget(&record)?;
		let mut retention = if sources.is_empty() {
			FileRecording::NoFiles
		} else {
			FileRecording::Stored
		};
		let metadata = if sources.is_empty() {
			None
		} else if !(self.0.peer_selected.get() || self.0.local_blobs) {
			Some(MetadataReason::BackendUnsupported)
		} else if files > MAX_FILE_BYTES.saturating_sub(self.0.usage.get().files) {
			Some(MetadataReason::PendingBytes)
		} else if sources.len() > capture::MAX_STREAMS.saturating_sub(self.0.captures.get()) {
			Some(MetadataReason::PendingCaptures)
		} else {
			None
		};
		if let Some(reason) = metadata {
			sources = Sources::Live(Vec::new());
			retention = FileRecording::MetadataOnly(reason);
			(bytes, files) = sources.budget(&record)?;
		}
		if !sources.is_empty() {
			bytes = bytes.saturating_add(capture::overhead(&sources));
		}
		let nick = if message.kind == rooms_application::archive::ConversationKind::Room {
			message.nick.to_owned()
		} else {
			String::new()
		};
		let completion = self.0.admit_with_custody(
			bytes.saturating_add(nick.capacity()),
			files,
			!sources.is_empty(),
			None,
			|answer, permit| {
				let capture = if sources.is_empty() {
					None
				} else {
					Some(capture::Capture::start(
						sources,
						permit.expect("capture has shared custody"),
						self.0.captures.clone(),
					))
				};
				Command::Record(record, nick, capture, retention, answer)
			},
		)?;
		Ok(Some(Recording {
			coordinates,
			completion,
		}))
	}
	/// A durable session barrier waits for bounded admission instead of losing
	/// an erase request at queue pressure. Once admitted, the worker owns it even
	/// if observation is cancelled. FIFO ordering and ingestion fences are shared
	/// with clear_local; this method introduces no second erasure path.
	pub async fn clear_local_when_ready(&self) -> Result<(), String> {
		let mut stop = self.0.stop.subscribe();
		if *stop.borrow() {
			return Err("session archive is closed".into());
		}
		let count = tokio::select! {
			permit = self.0.capacity.clone().acquire_owned() => permit.map_err(|_| "session archive capacity is closed")?,
			_ = stop.changed() => return Err("session archive is closed".into()),
			_ = self.0.requests.closed() => return Err("session archive worker retired".into()),
		};
		self.0
			.admit_with_custody(0, 0, false, Some(count), |answer, _| Command::Clear(answer))?
			.wait()
			.await
	}

	pub fn clear_local(&self) -> Result<Reply<()>, String> {
		self.0.admit(0, 0, Command::Clear)
	}
	pub fn read(&self, filter: Filter) -> Result<Reply<Vec<KeptRecord<P>>>, String> {
		filter.validate().map_err(|e| e.to_string())?;
		self.0
			.admit(filter.retained_bytes(), 0, |reply| Command::Read(filter, reply))
	}
	pub fn read_view(&self, filter: Filter) -> Result<Reply<HistoryView<P>>, String> {
		filter.validate().map_err(|e| e.to_string())?;
		self.0
			.admit(filter.retained_bytes(), 0, |reply| Command::ReadView(filter, reply))
	}
	pub fn read_page(&self, filter: Filter, after: u64, limit: usize) -> Result<Reply<Page>, String> {
		filter.validate().map_err(|e| e.to_string())?;
		if rooms_application::fields::SafeInteger::<false>::new(after).is_none()
			|| limit == 0
			|| limit > rooms_application::archive::MAX_READ
		{
			return Err("invalid archive page request".into());
		}
		self.0.admit(filter.retained_bytes(), 0, |reply| {
			Command::Page(filter, after, limit, reply)
		})
	}
	pub fn issue_share(&self, share: rooms_application::archive::shares::Share) -> Result<Reply<String>, String> {
		self.0.admit(
			share.filter().retained_bytes() + share.label().heap_bytes() + share.id().len(),
			0,
			|answer| Command::Share(share, answer),
		)
	}
	pub fn revoke_share(&self, id: String) -> Result<Reply<bool>, String> {
		self.0.admit(id.len(), 0, |answer| Command::Revoke(id, answer))
	}
	pub fn shares(&self) -> Result<Reply<Vec<rooms_glowcap::client::archive::ShareView>>, String> {
		self.0.admit(0, 0, Command::Shares)
	}
	/// Issued durable shares this session can name. A selected archive peer is
	/// the issuer when one is connected; otherwise the local store is.
	pub fn list_issued(&self) -> Result<Reply<Vec<rooms_glowcap::client::archive::ShareView>>, String> {
		self.0.admit(0, 0, Command::Issued)
	}

	pub async fn close(&self) -> Result<Report, String> {
		self.0.stop.send_replace(true);
		let mut done = self.0.done.clone();
		loop {
			if let Some(report) = done.borrow().clone() {
				return Ok(report);
			}
			done.changed()
				.await
				.map_err(|_| "session archive worker did not complete shutdown")?;
		}
	}
}
impl<P: Platform> Drop for SessionArchive<P> {
	fn drop(&mut self) {
		self.0.stop.send_replace(true);
	}
}

impl<P: Platform> State<P> {
	fn admit<T>(
		&self,
		bytes: usize,
		files: usize,
		make: impl FnOnce(Answer<T>) -> Command<P>,
	) -> Result<Reply<T>, String> {
		self.admit_with_custody(bytes, files, false, None, |answer, _| make(answer))
	}
	fn admit_with_custody<T>(
		&self,
		bytes: usize,
		files: usize,
		shared: bool,
		count: Option<OwnedSemaphorePermit>,
		make: impl FnOnce(Answer<T>, Option<Rc<Permit>>) -> Command<P>,
	) -> Result<Reply<T>, String> {
		self.enqueue(bytes, files, shared, count, |permit| {
			let (answer, reply) = oneshot::channel();
			Ok((make(answer, permit), Reply::from_receiver(reply)))
		})
	}
	fn enqueue<T>(
		&self,
		bytes: usize,
		files: usize,
		shared: bool,
		count: Option<OwnedSemaphorePermit>,
		make: impl FnOnce(Option<Rc<Permit>>) -> Result<(Command<P>, T), String>,
	) -> Result<T, String> {
		if *self.stop.borrow() {
			return Err("session archive is closed".into());
		}
		let mut usage = self.usage.get();
		if bytes > MAX_BYTES.saturating_sub(usage.bytes) || files > MAX_FILE_BYTES.saturating_sub(usage.files) {
			return Err("session archive is at its pending-work ceiling".into());
		}
		let count = match count {
			Some(permit) => permit,
			None => self
				.capacity
				.clone()
				.try_acquire_owned()
				.map_err(|_| "session archive is at its pending-work ceiling")?,
		};
		let slot = self
			.requests
			.try_reserve()
			.map_err(|_| "session archive queue is unavailable")?;
		usage.bytes += bytes;
		usage.files += files;
		self.usage.set(usage);
		let permit = Permit {
			usage: self.usage.clone(),
			_count: count,
			bytes,
			files,
		};
		let (custody, shared) = if shared {
			let permit = Rc::new(permit);
			(
				Custody::Shared {
					_permit: permit.clone(),
				},
				Some(permit),
			)
		} else {
			(Custody::Owned { _permit: permit }, None)
		};
		let (command, result) = make(shared)?;
		slot.send(Pending {
			command,
			_permit: custody,
		});
		Ok(result)
	}
}

fn input_budget<P: Platform>(record: &Record, sources: &Vec<File<P>>) -> Result<(usize, usize), String> {
	let files = sources
		.iter()
		.try_fold(0usize, |n, s| n.checked_add(s.attachment().description.size()))
		.ok_or("archive file budget overflow")?;
	let bytes = sources.iter().fold(
		record
			.retained_bytes()
			.saturating_add(sources.capacity().saturating_mul(core::mem::size_of::<File<P>>())),
		|bytes, source| bytes.saturating_add(source.attachment().description.retained_bytes()),
	);
	Ok((bytes, files))
}

impl<P: Platform> crate::archive_recording::Recorder for SessionArchive<P> {
	fn record(
		&self,
		source: &rooms_application::text::DocumentText,
		message: &rooms_application::archive::recording::Message<'_>,
		files: crate::archive_recording::Files,
	) -> Result<Option<Recording>, String> {
		use crate::archive_recording::Files;
		match files {
			Files::Retained(files) => self.record_files(source, message, files),
			Files::Received { session, attachments } => {
				let client = rooms_glowcap::client::Client::new(session, self.0.platform.clone());
				let files = attachments
					.into_iter()
					.map(|file| File::received(client.clone(), file))
					.collect();
				self.record_message(source, message, files)
			}
		}
	}
}
