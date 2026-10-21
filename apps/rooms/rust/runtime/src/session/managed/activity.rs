//! One session-owned event journal for local and attached consumers. Retained
//! callback origins reauthorize queued data. Tokens never reconstruct authority.
mod archive;
mod origin;
mod outgoing;
mod projection;
pub(super) mod reader;
use super::{InboxOrigin, ReceivedLine};
use glowcap::{Ref, Result, loam};
pub use origin::Origin;
use rooms_application::{content::session::custody, room::attachment::Attachment};
use rooms_glowcap::client::{Deadline, Tasks};
use std::{
	cell::{Cell, RefCell},
	collections::{BTreeMap, VecDeque},
	rc::{Rc, Weak},
};
use tokio::sync::Notify;

const MAX_EVENTS: usize = 4096;
const MAX_BYTES: usize = 16 * 1024 * 1024;
const MAX_READS: usize = 16;

pub struct Event<P: Tasks> {
	pub data: String,
	history: RefCell<History>,
	pub origin: Origin,
	pub files: Vec<Attachment<Ref>>,
	pub incoming: Option<Incoming>,
	pub line: Option<Rc<ReceivedLine<P>>>,
	charge: Option<Charge>,
}
pub enum Incoming {
	Hand(custody::Role, Ref),
	Offer(custody::Role, String, RefCell<Option<Ref>>),
}
impl Incoming {
	pub fn role(&self) -> custody::Role {
		match self {
			Self::Hand(role, _) | Self::Offer(role, _, _) => *role,
		}
	}
	pub(super) fn offer(role: custody::Role, uri: &str) -> core::result::Result<Self, String> {
		if uri.len() > loam::ReferenceRequest::MAX_URI_BYTES {
			return Err("Offered capability recipe exceeds its bound".into());
		}
		glowcap::parse_sturdyref(uri, glowcap::CaptpVersion::V1_0).map_err(|error| error.to_string())?;
		Ok(Self::Offer(role, uri.into(), RefCell::new(None)))
	}
}
enum History {
	None,
	Reserved,
	Recorded(rooms_application::archive::Coordinates),
}
impl History {
	/// A direct edit reserves archive identity backing before the line changes.
	/// Three bounded UTF-16 identities may require three UTF-8 bytes per unit.
	/// Recording fills that reservation synchronously at commit. File actors can
	/// already share the immutable event without forcing a second event copy.
	fn bytes(&self) -> usize {
		match self {
			Self::None => 0,
			Self::Reserved => 9 * rooms_application::archive::MAX_ID_BYTES,
			Self::Recorded(value) => value.source.heap_bytes() + value.generation.heap_bytes() + value.id.heap_bytes(),
		}
	}
}
pub struct ActivityDelivery<P: Tasks> {
	pub cursor: u64,
	pub gap: bool,
	pub unavailable: bool,
	pub event: Option<Rc<Event<P>>>,
}
struct Charge {
	bytes: Rc<Cell<usize>>,
	count: usize,
}
impl Drop for Charge {
	fn drop(&mut self) {
		self.bytes.set(self.bytes.get() - self.count);
	}
}
impl<P: Tasks> Event<P> {
	fn bytes(&self) -> usize {
		size_of::<Self>()
			+ 2 * size_of::<usize>()
			+ self.files.len() * reader::file_bytes::<P>()
			+ self.data.capacity()
			+ match &self.incoming {
				Some(Incoming::Offer(_, uri, _)) => uri.capacity(),
				_ => 0,
			} + self.history.borrow().bytes()
			+ self.files.capacity() * size_of::<Attachment<Ref>>()
			+ self
				.files
				.iter()
				.map(|file| file.description.retained_bytes())
				.sum::<usize>()
	}
}
impl<P: Tasks> Event<P> {
	pub fn history(&self) -> Option<rooms_application::archive::Coordinates> {
		match &*self.history.borrow() {
			History::Recorded(value) => Some(value.clone()),
			History::None | History::Reserved => None,
		}
	}
}
struct Entry<P: Tasks> {
	id: u64,
	event: Rc<Event<P>>,
	files: Vec<Ref>,
}
pub(in crate::session::managed) struct PreparedEvent<P: Tasks> {
	activity: Rc<Activity<P>>,
	pub(in crate::session::managed) event: Rc<Event<P>>,
	files: Vec<Ref>,
}
impl<P: Tasks> PreparedEvent<P> {
	fn commit(self) {
		let activity = &self.activity;
		let id = activity.next.get();
		#[expect(
			clippy::expect_used,
			reason = "a u64 event counter does not reach its ceiling in a process lifetime, and a wrap would alias event identities"
		)]
		activity
			.next
			.set(id.checked_add(1).expect("synchronously admitted event identity"));
		if let Some(line) = &self.event.line {
			activity.lines.borrow_mut().insert(line.id().get(), line.clone());
		}
		let mut entries = activity.entries.borrow_mut();
		if entries.len() == MAX_EVENTS {
			entries.pop_front();
		}
		entries.push_back(Entry {
			id,
			event: self.event,
			files: self.files,
		});
		activity.changed.notify_waiters();
	}
}
/// Backlog and direct-line lifetime have separate budgets. Display eviction
/// cannot retire an editable direct line. Withdrawal and session close do.
pub struct Activity<P: Tasks> {
	host: glowcap::Host,
	platform: P,
	entries: RefCell<VecDeque<Entry<P>>>,
	bytes: Rc<Cell<usize>>,
	next: Cell<u64>,
	incarnation: Cell<Option<loam::LiveIncarnation>>,
	lines: RefCell<BTreeMap<u64, Rc<ReceivedLine<P>>>>,
	closed: Cell<bool>,
	changed: Rc<Notify>,
	reads: RefCell<BTreeMap<u64, P::Task>>,
	next_read: Cell<u64>,
	reader: RefCell<Option<Ref>>,
	failure: RefCell<Option<glowcap::Error>>,
}
impl<P: Tasks> Activity<P> {
	pub(super) fn new(host: glowcap::Host, platform: P) -> Self {
		Self {
			host,
			platform,
			entries: Default::default(),
			bytes: Rc::new(Cell::new(0)),
			next: Cell::new(1),
			incarnation: Cell::new(None),
			lines: Default::default(),
			closed: Cell::new(false),
			changed: Rc::new(Notify::new()),
			reads: Default::default(),
			next_read: Cell::new(1),
			reader: Default::default(),
			failure: Default::default(),
		}
	}
}
impl<P: Tasks + Deadline + Clone + 'static> Activity<P> {
	fn reserve(self: &Rc<Self>, mut event: Event<P>, evict: bool) -> core::result::Result<PreparedEvent<P>, String> {
		if self.closed.get() {
			return Err("Session activity has closed".into());
		}
		let bytes = event.bytes();
		if bytes > MAX_BYTES {
			return Err("Session event exceeds its byte budget".into());
		}
		self.next
			.get()
			.checked_add(1)
			.ok_or("Session activity tokens exhausted")?;
		if event.line.is_some() && self.lines.borrow().len() == MAX_EVENTS {
			return Err("Direct line custody is full".into());
		}
		let mut entries = self.entries.borrow_mut();
		while bytes > MAX_BYTES - self.bytes.get() {
			if !evict {
				return Err("Session event reservation exceeds retained byte budget".into());
			}
			let Some(oldest) = entries.pop_front() else {
				return Err("Session event custody is full; release held files and events".into());
			};
			drop(oldest);
		}
		self.bytes.set(self.bytes.get() + bytes);
		event.charge = Some(Charge {
			bytes: self.bytes.clone(),
			count: bytes,
		});
		let event = Rc::new(event);
		Ok(PreparedEvent {
			activity: self.clone(),
			event,
			files: Vec::new(),
		})
	}
	fn prepare(self: &Rc<Self>, event: Event<P>, evict: bool) -> core::result::Result<PreparedEvent<P>, String> {
		let mut prepared = self.reserve(event, evict)?;
		prepared.prepare_files().map_err(|error| error.to_string())?;
		Ok(prepared)
	}
	fn push(self: &Rc<Self>, event: Event<P>) -> core::result::Result<(), String> {
		self.prepare(event, true)?.commit();
		Ok(())
	}
	/// The confirmed Loam lifetime fences presentation identities across reopen.
	/// Binding is one-time even when no events have yet been accepted. status-allow: pending state or quoted runtime label
	pub fn bind_incarnation(&self, marker: loam::LiveIncarnation) -> Result<()> {
		if self.incarnation.get().is_some() {
			return Err(loam::refusal("activity incarnation already bound"));
		}
		self.incarnation.set(Some(marker));
		Ok(())
	}
	pub fn token(&self, cursor: u64) -> Result<String> {
		use std::fmt::Write;
		let marker = self
			.incarnation
			.get()
			.ok_or_else(|| loam::refusal("activity lifetime is not confirmed"))?;
		let mut token = String::with_capacity(103);
		for byte in marker.encode() {
			let _ = write!(&mut token, "{byte:02x}");
		}
		let _ = write!(&mut token, ":{cursor}");
		Ok(token)
	}
	pub(super) fn parse_token(&self, token: &str) -> Result<u64> {
		if token.len() > 103 {
			return Err(loam::refusal("activity token exceeds its bound"));
		}
		let (incarnation, counter) = token
			.split_once(':')
			.ok_or_else(|| loam::refusal("invalid activity token"))?;
		let expected = self.token(0)?;
		if incarnation != &expected[..82] {
			return Err(loam::refusal("activity token belongs to another incarnation"));
		}
		let id = counter
			.parse::<u64>()
			.map_err(|_| loam::refusal("invalid activity counter"))?;
		if id.to_string() != counter {
			return Err(loam::refusal("noncanonical activity counter"));
		}
		Ok(id)
	}
	pub fn cursor(&self) -> u64 {
		self.next.get() - 1
	}
	pub(super) fn read_actor(&self) -> Result<Ref> {
		self.reader
			.borrow()
			.as_ref()
			.cloned()
			.ok_or_else(|| loam::refusal("activity reader is not initialized"))
	}
	pub(super) fn file(&self, id: u64, index: usize) -> Result<Ref> {
		self.entries
			.borrow()
			.iter()
			.find(|entry| entry.id == id)
			.and_then(|entry| entry.files.get(index))
			.cloned()
			.ok_or_else(|| loam::refusal("activity file token has expired"))
	}
	pub(in crate::session::managed) fn event(&self, id: u64) -> Result<Rc<Event<P>>> {
		self.entries
			.borrow()
			.iter()
			.find(|entry| entry.id == id)
			.map(|entry| entry.event.clone())
			.ok_or_else(|| loam::refusal("activity token has expired"))
	}
	fn withdraw(&self, id: u64) {
		if let Some(line) = self.lines.borrow_mut().remove(&id) {
			line.retire();
		}
	}
}
impl<P: Tasks + Deadline + Clone + 'static> PreparedEvent<P> {
	pub(in crate::session::managed) fn prepare_files(&mut self) -> Result<()> {
		if self.files.len() == self.event.files.len() {
			return Ok(());
		}
		let activity = &self.activity;
		self.files = (0..self.event.files.len())
			.map(|index| activity.file_actor(&activity.host, activity.platform.clone(), self.event.clone(), index))
			.collect::<Result<Vec<_>>>()?;
		Ok(())
	}
}
impl<P: Tasks + Deadline + Clone + 'static> super::Session<P> {
	pub fn activity(&self) -> Rc<Activity<P>> {
		self.state.activity.clone()
	}
	/// The single production supervisor feeds this parser, independently of
	/// attached viewers. All adapters receive the same domain event projection.
	pub fn activity_receiver(&self, target: &super::MembershipTarget) -> super::MembershipReceiver {
		projection::receiver(
			target.clone(),
			Rc::downgrade(&self.state),
			Rc::downgrade(&self.state.activity),
			Rc::new(self.line_receiver()),
		)
	}
	pub fn activity_receivers(&self) -> impl FnMut(&super::MembershipTarget) -> super::MembershipReceiver + 'static {
		let events = Rc::downgrade(&self.state.activity);
		let owner = Rc::downgrade(&self.state);
		let lines = Rc::new(self.line_receiver());
		move |target| projection::receiver(target.clone(), owner.clone(), events.clone(), lines.clone())
	}
}
impl<P: Tasks + Deadline + Clone + 'static> Activity<P> {
	/// Trusted in-process consumers still recheck the original callback before
	/// delivery. Remote viewers additionally enter through a managed read facade.
	pub async fn receive_after(
		self: &Rc<Self>,
		host: &glowcap::Host,
		platform: P,
		cursor: u64,
		wait: bool,
	) -> Result<ActivityDelivery<P>> {
		reader::receive(&Rc::downgrade(self), host, platform, cursor, wait).await
	}
	pub(super) async fn close(&self, platform: &P) -> Result<()> {
		self.closed.set(true);
		self.changed.notify_waiters();
		let drained = async {
			loop {
				let changed = self.changed.notified();
				tokio::pin!(changed);
				changed.as_mut().enable();
				if self.reads.borrow().is_empty() {
					break;
				}
				changed.await;
			}
		};
		if !self.reads.borrow().is_empty()
			&& platform
				.within(rooms_application::room::authority::REQUEST_TIMEOUT_MS, drained)
				.await
				.is_none()
		{
			return Err(loam::refusal("activity reads still own unresolved waits; retry close"));
		}
		self.reader.borrow_mut().take();
		self.entries.borrow_mut().clear();
		for line in self.lines.borrow_mut().values() {
			line.retire();
		}
		self.lines.borrow_mut().clear();
		match self.failure.borrow_mut().take() {
			Some(error) => Err(error),
			None => Ok(()),
		}
	}
}
