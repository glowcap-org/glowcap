//! Shared media materialization from capabilities or local source readers.
//! Views can expire while admitted readers retain their immutable bytes.
use crate::Error;
use glowcap::{Host, Ref, Session};
use rooms_application::{
	files::{FileDescription, sources::MAX_SOURCES},
	room::attachment::Attachment,
};
use rooms_glowcap::client::Deadline;
use rooms_glowcap::client::{
	Client,
	files::{
		File,
		capture::{Captured, Chunk},
	},
};
use std::{
	cell::{Cell, RefCell},
	collections::VecDeque,
	rc::{Rc, Weak},
};
use tokio::{sync::Notify, task::JoinHandle};

pub use rooms_application::files::receiving::Usage;
use rooms_application::files::receiving::{Budget, Charge};
pub struct MediaFiles<P: Deadline + Clone + 'static> {
	platform: P,
	rows: RefCell<VecDeque<Row>>,
	budget: Budget,
	closed: Cell<bool>,
	failure: Option<Error>,
}
struct Entry {
	identity: RefCell<Option<(Host, Ref)>>,
	description: Rc<FileDescription>,
	result: RefCell<Option<Result<Rc<Retained>, Error>>>,
	changed: Notify,
	active: Cell<bool>,
	expired: Cell<bool>,
	pins: Cell<usize>,
	selections: Cell<usize>,
}
struct Row {
	entry: Rc<Entry>,
	task: Option<JoinHandle<()>>,
}
impl std::ops::Deref for Row {
	type Target = Entry;
	fn deref(&self) -> &Entry {
		&self.entry
	}
}
struct Pin(Rc<Entry>);
impl Drop for Pin {
	fn drop(&mut self) {
		self.0.pins.set(self.0.pins.get() - 1);
		if self.0.expired.get() && self.0.pins.get() == 0 {
			self.0.result.borrow_mut().take();
		}
	}
}
struct Retained {
	bytes: Captured,
	_permit: Charge,
}
struct Completion {
	entry: Weak<Entry>,
}
/// Sender custody completes only when the peer acknowledges all upload bytes.
/// Dropping an unfinished upload makes its already-published views fail.
pub struct UploadCapture {
	answer: tokio::sync::oneshot::Sender<Captured>,
	bytes: Captured,
}
impl UploadCapture {
	pub fn complete(self) {
		// tolerant: the line or media owner may have retired during upload.
		let _ = self.answer.send(self.bytes);
	}
}
impl Drop for Completion {
	fn drop(&mut self) {
		if let Some(entry) = self.entry.upgrade() {
			entry.active.set(false);
			if entry.result.borrow().is_none() && (!entry.expired.get() || entry.pins.get() != 0) {
				*entry.result.borrow_mut() = Some(Err(Error::closed("media capture ended before completion")));
			}
			entry.changed.notify_waiters();
		}
	}
}
/// Borrowed media access. Cloning this handle does not pin bytes against eviction.
#[derive(Clone)]
pub struct FileView {
	entry: Rc<Entry>,
	description: Rc<FileDescription>,
}
/// A line's custody of a media file. Retiring its final selection expires
/// views while admitted readers retain their independently charged bytes.
pub struct Selection {
	file: FileView,
}
/// Actor-local history retains no Host or bytes. References are compared only
/// within the Host that owns this line actor, including delegated deliveries.
pub struct PreviousFile {
	blob: Ref,
	size: usize,
	entry: Weak<Entry>,
}
impl FileView {
	/// Retain this line's selection. It leases the same entry and cannot revive
	/// an expired view; the final selection retires the entry for new readers.
	pub fn select(self) -> Selection {
		self.entry.selections.set(self.entry.selections.get() + 1);
		Selection { file: self }
	}

	pub fn previous(&self, blob: Ref) -> PreviousFile {
		PreviousFile {
			blob,
			size: self.description.size(),
			entry: Rc::downgrade(&self.entry),
		}
	}
}
impl Drop for Selection {
	fn drop(&mut self) {
		let entry = &self.file.entry;
		entry.selections.set(entry.selections.get() - 1);
		if entry.selections.get() == 0 {
			entry.expire();
		}
	}
}
/// An admitted reader or archive write pins the completed materialization and
/// its byte charge independently of later view expiration.
#[derive(Clone)]
pub struct Materialized {
	retained: Rc<Retained>,
	description: Rc<FileDescription>,
}
impl Materialized {
	/// A span outside the retained bytes is the caller's mistake; the bytes
	/// themselves are all here.
	pub fn span(&self, offset: u64, maximum: usize) -> Result<Chunk, Error> {
		self.retained.bytes.span(offset, maximum).map_err(Error::invalid)
	}
	pub fn description(&self) -> &FileDescription {
		&self.description
	}
	pub fn read(&self, offset: u64, maximum: usize) -> Result<Vec<u8>, Error> {
		self.span(offset, maximum).map(Chunk::into_vec)
	}
}

impl FileView {
	pub fn description(&self) -> &FileDescription {
		&self.description
	}
	/// Admission pins this result immediately, before polling the returned
	/// future. Later view expiration cannot cancel that admitted observation.
	pub fn materialize(&self) -> impl std::future::Future<Output = Result<Materialized, Error>> + use<> {
		let admitted = if self.entry.expired.get() {
			Err(Error::stale("media file is no longer retained"))
		} else {
			self.entry.pins.set(self.entry.pins.get() + 1);
			Ok(Pin(self.entry.clone()))
		};
		let description = self.description.clone();
		async move {
			let pin = admitted?;
			loop {
				let changed = pin.0.changed.notified();
				if let Some(result) = &*pin.0.result.borrow() {
					return result.clone().map(|retained| Materialized { retained, description });
				}
				changed.await;
			}
		}
	}
	pub async fn read(&self, offset: u64, maximum: usize) -> Result<Vec<u8>, Error> {
		self.materialize().await?.read(offset, maximum)
	}
}
impl FileView {
	/// Export a fresh one-pass grant over these retained immutable bytes.
	pub fn source(&self) -> rooms_glowcap::client::sources::Source {
		rooms_glowcap::client::sources::Source::reader(self.description().clone(), ViewSource(self.clone()))
	}
}
struct ViewSource(FileView);
impl rooms_glowcap::client::sources::Reader for ViewSource {
	fn read(
		&self,
		offset: usize,
		length: usize,
	) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<Vec<u8>, String>>>> {
		let materialized = self.0.materialize();
		// A source read answers a CapTP caller, so both classed failures become
		// refusal text here and nowhere earlier.
		Box::pin(async move {
			materialized
				.await
				.map_err(Error::into_refusal)?
				.read(offset as u64, length)
				.map_err(Error::into_refusal)
		})
	}
}

impl Entry {
	fn expire(&self) {
		self.expired.set(true);
		self.identity.borrow_mut().take();
		if self.pins.get() == 0 {
			self.result.borrow_mut().take();
		}
		self.changed.notify_waiters();
	}
	fn reclaimable(&self) -> bool {
		self.pins.get() == 0
			&& self
				.result
				.borrow()
				.as_ref()
				.is_some_and(|result| result.as_ref().is_ok_and(|bytes| Rc::strong_count(bytes) == 1))
	}
}
impl<P: Deadline + Clone + Default + 'static> Default for MediaFiles<P> {
	fn default() -> Self {
		Self::new(P::default())
	}
}
impl<P: Deadline + Clone + 'static> MediaFiles<P> {
	pub fn new(platform: P) -> Self {
		Self {
			platform,
			rows: Default::default(),
			budget: Default::default(),
			closed: Cell::new(false),
			failure: None,
		}
	}
}
impl<P: Deadline + Clone + 'static> MediaFiles<P> {
	/// Retain a whole immutable upload batch under the receiver's ordinary
	/// eviction policy. Kept files and admitted readers survive; a refusal
	/// leaves prior custody intact, like outgoing direct-source admission.
	pub fn uploads(
		&self,
		session: &Session,
		uploads: Vec<(Ref, Captured)>,
		protected: &[Ref],
	) -> Result<Vec<UploadCapture>, Error> {
		if self.closed.get() {
			return Err(Error::closed("media file owner is closed"));
		}
		if !rooms_application::files::receiving::selection_fits(uploads.iter().map(|(_, bytes)| bytes.description())) {
			return Err(Error::invalid(
				"upload selection exceeds its file count or byte ceiling",
			));
		}
		let mut rows = self.rows.borrow_mut();
		let host = session.host();
		for (at, (blob, _)) in uploads.iter().enumerate() {
			if uploads[..at].iter().any(|(old, _)| old == blob)
				|| rows.iter().any(|row| {
					row.identity
						.borrow()
						.as_ref()
						.is_some_and(|(owner, held)| owner.same_host(&host) && held == blob)
				}) {
				return Err(Error::invalid("upload identity is already admitted"));
			}
		}
		let bytes = uploads.iter().map(|(_, bytes)| bytes.description().size()).sum();
		let selected: Vec<_> = rows
			.iter()
			.filter(|row| {
				row.identity
					.borrow()
					.as_ref()
					.is_some_and(|(owner, blob)| owner.same_host(&host) && protected.contains(blob))
			})
			.map(|row| row.entry.clone())
			.collect();
		self.make_space(&mut rows, uploads.len(), bytes, &selected)?;
		Ok(uploads
			.into_iter()
			.map(|(blob, bytes)| {
				let (answer, result) = tokio::sync::oneshot::channel();
				rows.push_back(self.capture_with(
					bytes.description().clone(),
					Some((host.clone(), blob)),
					async move {
						result
							.await
							.map_err(|_| "the local upload ended without acknowledging every byte".to_owned())
					},
				));
				UploadCapture { answer, bytes }
			})
			.collect())
	}
	pub fn usage(&self) -> Usage {
		self.budget.usage()
	}
	/// Admit on a LocalSet. New work begins after the actor turn; duplicate
	/// retained capabilities share the same result, including a capture refusal.
	pub fn receive(&self, session: &Session, attachment: Attachment<Ref>) -> Result<FileView, Error> {
		self.receive_many(session, vec![attachment])
			.map(|mut files| files.remove(0))
	}
	/// Admit the whole selection before evicting or starting any source. Shared
	/// capabilities spend capacity once; selected existing rows cannot be victims.
	pub fn receive_many(&self, session: &Session, attachments: Vec<Attachment<Ref>>) -> Result<Vec<FileView>, Error> {
		self.receive_retaining(session, attachments, &[])
	}
	pub fn receive_retaining(
		&self,
		session: &Session,
		attachments: Vec<Attachment<Ref>>,
		previous: &[PreviousFile],
	) -> Result<Vec<FileView>, Error> {
		if self.closed.get() {
			return Err(Error::closed("incoming file owner is closed"));
		}
		if !rooms_application::files::receiving::selection_fits(attachments.iter().map(|file| &file.description)) {
			return Err(Error::invalid(
				"incoming selection exceeds its file count or byte ceiling",
			));
		}
		let host = session.host();
		let mut rows = self.rows.borrow_mut();
		let mut selected = Vec::<Rc<Entry>>::new();
		let mut fresh = Vec::<Attachment<Ref>>::new();
		let mut preserved = Vec::with_capacity(attachments.len());
		for attachment in &attachments {
			if let Some(old) = previous.iter().find(|old| old.blob == attachment.blob) {
				if old.size != attachment.description.size() {
					return Err(Error::invalid("retained incoming file metadata changed"));
				}
				let entry = old.entry.upgrade().unwrap_or_else(|| {
					Rc::new(Entry {
						identity: RefCell::new(None),
						description: Rc::new(attachment.description.clone()),
						result: Default::default(),
						changed: Notify::new(),
						active: Cell::new(false),
						expired: Cell::new(true),
						pins: Cell::new(0),
						selections: Cell::new(0),
					})
				});
				selected.push(entry.clone());
				preserved.push(Some(entry));
				continue;
			}
			preserved.push(None);
			if let Some(row) = rows.iter().find(|row| {
				row.identity
					.borrow()
					.as_ref()
					.is_some_and(|(owner, blob)| owner.same_host(&host) && blob == &attachment.blob)
			}) {
				if row.description.size() != attachment.description.size() {
					return Err(Error::invalid("retained incoming file metadata changed"));
				}
				selected.push(row.entry.clone());
			} else if let Some(previous) = fresh.iter().find(|file| file.blob == attachment.blob) {
				if previous.description.size() != attachment.description.size() {
					return Err(Error::invalid("incoming batch gives one capability different sizes"));
				}
			} else {
				fresh.push(attachment.clone());
			}
		}
		let bytes = fresh.iter().map(|file| file.description.size()).sum();
		self.make_space(&mut rows, fresh.len(), bytes, &selected)?;
		for attachment in fresh {
			rows.push_back(self.capture(session, attachment));
		}
		Ok(attachments
			.into_iter()
			.zip(preserved)
			.map(|(attachment, preserved)| {
				let entry = preserved.unwrap_or_else(|| {
					rows.iter()
						.find(|row| {
							row.identity
								.borrow()
								.as_ref()
								.is_some_and(|(owner, blob)| owner.same_host(&host) && blob == &attachment.blob)
						})
						.expect("admitted selection")
						.entry
						.clone()
				});
				FileView {
					entry: entry.clone(),
					description: if *entry.description == attachment.description {
						entry.description.clone()
					} else {
						Rc::new(attachment.description)
					},
				}
			})
			.collect())
	}
	fn make_space(
		&self,
		rows: &mut VecDeque<Row>,
		count: usize,
		bytes: usize,
		selected: &[Rc<Entry>],
	) -> Result<(), Error> {
		let victim = |row: &Row| {
			!row.active.get()
				&& !selected.iter().any(|entry| Rc::ptr_eq(entry, &row.entry))
				&& (row.reclaimable() || row.result.borrow().as_ref().is_none_or(Result::is_err))
		};
		let (free_rows, free_files, free_bytes) =
			rows.iter()
				.filter(|row| victim(row))
				.fold((0, 0, 0), |(count, files, bytes), row| {
					(
						count + 1,
						files + usize::from(row.reclaimable()),
						bytes + if row.reclaimable() { row.description.size() } else { 0 },
					)
				});
		if rows.len() - free_rows + count > MAX_SOURCES
			|| !self.budget.can_admit_many(count, bytes, free_files, free_bytes)
		{
			return Err(Error::exhausted(
				"media files are pinned at their capture or memory ceiling",
			));
		}
		while rows.len() + count > MAX_SOURCES || !self.budget.can_admit_many(count, bytes, 0, 0) {
			let at = rows
				.iter()
				.position(&victim)
				.expect("batch preflight found reclaimable custody");
			rows.remove(at).expect("retained row").expire();
		}
		Ok(())
	}
	/// Retain a validated local source batch for outgoing messages. Selected
	/// existing views survive pressure; failure leaves all prior custody intact.
	pub fn retain_sources(
		&self,
		sources: Vec<rooms_glowcap::client::sources::Source>,
		protected: &[FileView],
	) -> Result<Vec<FileView>, Error> {
		if self.closed.get() {
			return Err(Error::closed("media file owner is closed"));
		}
		if !rooms_application::files::receiving::selection_fits(sources.iter().map(|source| source.description())) {
			return Err(Error::invalid("media selection exceeds its file count or byte ceiling"));
		}
		let bytes = sources.iter().map(|source| source.description().size()).sum();
		let selected: Vec<_> = protected.iter().map(|file| file.entry.clone()).collect();
		let mut rows = self.rows.borrow_mut();
		self.make_space(&mut rows, sources.len(), bytes, &selected)?;
		Ok(sources
			.into_iter()
			.map(|source| {
				let platform = self.platform.clone();
				let row = self.capture_with(source.description().clone(), None, async move {
					source.materialize(&platform).await
				});
				let file = FileView {
					entry: row.entry.clone(),
					description: row.description.clone(),
				};
				rows.push_back(row);
				file
			})
			.collect())
	}

	fn capture(&self, session: &Session, attachment: Attachment<Ref>) -> Row {
		let identity = Some((session.host(), attachment.blob.clone()));
		let description = attachment.description.clone();
		let file = File::received(Client::new(session.borrowed(), self.platform.clone()), attachment);
		self.capture_with(description, identity, async move { Captured::read(&file).await })
	}
	/// A capture that did not deliver every byte is a source that stopped
	/// answering; the retained diagnostic is bounded like every other reason.
	fn capture_with(
		&self,
		description: FileDescription,
		identity: Option<(Host, Ref)>,
		capture: impl std::future::Future<Output = Result<Captured, String>> + 'static,
	) -> Row {
		let size = description.size();
		let entry = Rc::new(Entry {
			identity: RefCell::new(identity),
			description: Rc::new(description),
			result: Default::default(),
			changed: Notify::new(),
			active: Cell::new(true),
			expired: Cell::new(false),
			pins: Cell::new(0),
			selections: Cell::new(0),
		});
		let mut permit = self
			.budget
			.reserve(size)
			.expect("preflight and eviction reserved capacity");
		let completion = Completion {
			entry: Rc::downgrade(&entry),
		};
		let task = tokio::task::spawn_local(async move {
			let guard = completion;
			let result = capture
				.await
				.map_err(|error| Error::closed(rooms_application::failure::reason_prefix(&error).to_owned()));
			permit.captured();
			let result = result.map(|bytes| Rc::new(Retained { bytes, _permit: permit }));
			if let Some(entry) = guard.entry.upgrade()
				&& (!entry.expired.get() || entry.pins.get() != 0)
			{
				*entry.result.borrow_mut() = Some(result);
			}
		});
		Row {
			entry,
			task: Some(task),
		}
	}

	/// Retire this view without cancelling its admitted source read. A pending
	/// materialization remains charged until the capture actually ends.
	pub fn expire(&self, file: &FileView) {
		if self
			.rows
			.borrow()
			.iter()
			.any(|entry| Rc::ptr_eq(&entry.entry, &file.entry))
		{
			file.entry.expire();
		}
	}
	/// Stop admission, invalidate views and observe cancellation of owned tasks.
	/// Materialized leases held by callers retain their original byte charge.
	pub async fn close(&mut self) -> Result<(), Error> {
		self.closed.set(true);
		for entry in self.rows.get_mut().iter_mut() {
			entry.expire();
			if let Some(task) = entry.task.as_mut() {
				task.abort();
				if let Err(e) = task.await
					&& !e.is_cancelled()
				{
					self.failure.get_or_insert_with(|| Error::closed(e.to_string()));
				}
			}
			entry.task.take();
		}
		self.rows.get_mut().clear();
		self.failure.clone().map_or(Ok(()), Err)
	}
}
impl<P: Deadline + Clone + 'static> Drop for MediaFiles<P> {
	fn drop(&mut self) {
		for mut entry in self.rows.get_mut().drain(..) {
			entry.expire();
			if let Some(task) = entry.task.take() {
				task.abort();
			}
		}
	}
}
