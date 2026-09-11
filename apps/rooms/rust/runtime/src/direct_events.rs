//! Direct messages, delegated edits and typing enter one bounded event stream.
//! Reserve event custody before spawning or mutating a line; no I/O runs in-turn.
use crate::directory_runtime::AcceptedDirect;
use crate::entropy::Entropy;
use crate::media_files::{FileView, PreviousFile};
use glowcap::{Ref, Session};
pub use rooms_application::direct::event::{Content, Direction, Line};
use rooms_application::room::{
	attachment::Attachment,
	line::{LineChange, Proposal, MAX_LINE_BYTES, MAX_MESSAGE_FILES},
	message::{ChangeKind, LineId},
};
use rooms_glowcap::client::direct::received_line::{self, Changes};
use std::{
	cell::{Cell, RefCell},
	collections::BTreeMap,
	rc::{Rc, Weak},
};
use tokio::sync::{mpsc, watch};
mod outgoing;
mod recording;
pub use outgoing::OutgoingEvent;
pub(crate) use recording::{Observations as RecordingObservations, Settlement as RecordingSettlement};

pub use crate::platform::Platform;

pub const EVENT_LIMIT: usize = 256;
pub const EVENT_BYTES: usize = 2 * 1024 * 1024;
pub struct Event {
	/// Identifies this event owner's line-id namespace across restarts.
	pub generation: [u8; 16],
	/// Unix milliseconds sampled at admission, before consumer delay.
	pub at: u64,
	pub context: AcceptedDirect,
	pub direction: Direction,
	pub from: String,
	pub editable: bool,
	pub content: Content<Ref>,
	/// Full attachment view, including files preserved by an edit.
	pub files: Vec<FileView>,
	/// Admission and completion are separate from message acceptance. A refused
	/// archive admission must not hide an accepted message from its observers.
	pub recording: Result<Option<crate::archive_recording::Recording>, String>,
	_permit: Permit,
}
impl Event {
	pub fn line(&self) -> Option<&Line<Ref>> {
		self.content.line()
	}
}
pub struct Events(mpsc::Receiver<Event>);
impl Events {
	pub async fn next(&mut self) -> Option<Event> {
		self.0.recv().await
	}
}
struct State<P: Platform> {
	platform: P,
	generation: [u8; 16],
	tx: RefCell<Option<mpsc::Sender<Event>>>,
	held: Rc<Cell<(usize, usize)>>,
	next: Cell<u64>,
	recorder: Option<recording::Recorder>,
	media: RefCell<Option<crate::media::Media<u64, P>>>,
	recording_issues: RefCell<BTreeMap<String, String>>,
	changed: watch::Sender<()>,
}
pub struct DirectEvents<P: Platform> {
	state: Rc<State<P>>,
	closing_media: Option<crate::media::Media<u64, P>>,
}
#[derive(Clone)]
pub struct EventReceiver<P: Platform>(Weak<State<P>>);
struct Permit {
	held: Rc<Cell<(usize, usize)>>,
	bytes: usize,
}
impl Drop for Permit {
	fn drop(&mut self) {
		let (count, bytes) = self.held.get();
		self.held.set((count - 1, bytes - self.bytes));
	}
}
pub struct Reservation {
	generation: [u8; 16],
	at: u64,
	slot: mpsc::OwnedPermit<Event>,
	permit: Permit,
}
impl<P: Platform> State<P> {
	fn reserve(&self, context: &AcceptedDirect, payload: usize) -> Result<Reservation, String> {
		if !context.current() {
			return Err("the direct conversation has retired".into());
		}
		let sender = self.tx.borrow();
		let sender = sender.as_ref().ok_or("direct event owner is closed")?;
		let bytes = core::mem::size_of::<Event>()
			.saturating_add(self.recorder.as_ref().map_or(0, recording::Recorder::event_bytes))
			.saturating_add(payload)
			.saturating_add(context.conversation().text().heap_bytes())
			.saturating_add(context.directory().text().heap_bytes())
			.saturating_add(context.peer().text().heap_bytes() * 2)
			.saturating_add(context.registration().as_str().len());
		let (count, held) = self.held.get();
		if count == EVENT_LIMIT || bytes > EVENT_BYTES.saturating_sub(held) {
			return Err("direct event backlog exceeded its count or byte limit".into());
		}
		let at = self.platform.unix_millis().map_err(|error| error.to_string())?;
		let slot = sender
			.clone()
			.try_reserve_owned()
			.map_err(|_| "direct event consumer is unavailable")?;
		self.held.set((count + 1, held + bytes));
		Ok(Reservation {
			generation: self.generation,
			at,
			slot,
			permit: Permit {
				held: self.held.clone(),
				bytes,
			},
		})
	}
}
impl<P: Platform> DirectEvents<P> {
	pub fn new(platform: P, entropy: &mut impl Entropy) -> Result<(Self, Events), String> {
		let mut generation = [0; 16];
		entropy
			.fill(&mut generation)
			.map_err(|_| "direct event generation entropy is unavailable")?;
		let (tx, rx) = mpsc::channel(EVENT_LIMIT);
		let changed = watch::channel(()).0;
		Ok((
			Self {
				state: Rc::new(State {
					platform: platform.clone(),
					generation,
					tx: RefCell::new(Some(tx)),
					held: Rc::new(Cell::new((0, 0))),
					next: Cell::new(1),
					recorder: None,
					media: RefCell::new(Some(crate::media::Media::new(platform))),
					recording_issues: RefCell::new(BTreeMap::new()),
					changed,
				}),
				closing_media: None,
			},
			Events(rx),
		))
	}
	pub fn receiver(&self) -> EventReceiver<P> {
		EventReceiver(Rc::downgrade(&self.state))
	}
	/// Refuse new messages and delegated changes immediately. Queued events
	/// drain before Events::next returns None; handed-out events keep custody.
	pub fn close(&self) {
		self.state.tx.borrow_mut().take();
	}
	/// Stop producers and observe incoming capture cancellation. A cancelled
	/// shutdown keeps its owner here so the next call can finish observing it.
	pub async fn close_files(&mut self) -> Result<(), String> {
		self.close();
		if self.closing_media.is_none() {
			self.closing_media = self.state.media.borrow_mut().take();
		}
		if let Some(media) = &mut self.closing_media {
			media.close().await?;
		}
		self.closing_media.take();
		Ok(())
	}
}
impl<P: Platform> Drop for DirectEvents<P> {
	fn drop(&mut self) {
		self.close();
	}
}
impl<P: Platform> EventReceiver<P> {
	pub fn changes(&self) -> watch::Receiver<()> {
		self.0
			.upgrade()
			.map(|state| state.changed.subscribe())
			.unwrap_or_else(|| watch::channel(()).1)
	}
	pub fn recording_issues(&self) -> Vec<(String, String)> {
		self.0
			.upgrade()
			.map(|state| {
				state
					.recording_issues
					.borrow()
					.iter()
					.map(|(subject, reason)| (subject.clone(), reason.clone()))
					.collect()
			})
			.unwrap_or_default()
	}
	/// Reconcile one admitted line's archive outcome. A later successful write
	/// clears the exact conversation issue; unrelated directs remain untouched.
	pub(super) fn settle_recording(&self, settlement: RecordingSettlement) {
		let Some(state) = self.0.upgrade() else { return };
		let (mut subject, reason) = settlement.parts();
		let changed = {
			let mut issues = state.recording_issues.borrow_mut();
			match reason {
				Some(reason) => {
					let reason = rooms_application::failure::reason_prefix(&reason).to_owned();
					if !issues.contains_key(&subject)
						&& issues.len() >= rooms_application::session::checkpoint::MAX_CONVERSATIONS - 1
					{
						subject = "archive".into();
					}
					if issues.get(&subject) == Some(&reason) {
						false
					} else {
						issues.insert(subject, reason);
						true
					}
				}
				None => issues.remove(&subject).is_some(),
			}
		};
		if changed {
			state.changed.send_replace(());
		}
	}
	/// Typing is an ordered, bounded transient event. Attached views own its
	/// auto-clear timer; this producer does not allocate a line identity.
	pub fn typing(&self, context: AcceptedDirect, on: bool) -> Result<(), String> {
		let state = self.0.upgrade().ok_or("the direct event owner has ended")?;
		let reservation = state.reserve(&context, 0)?;
		reservation.slot.send(Event {
			generation: reservation.generation,
			at: reservation.at,
			from: context
				.peer()
				.text()
				.as_str()
				.ok_or("the direct peer is not valid UTF-8")?
				.to_owned(),
			direction: Direction::Incoming,
			editable: false,
			context,
			content: Content::Typing { on },
			files: Vec::new(),
			recording: Ok(None),
			_permit: reservation.permit,
		});
		Ok(())
	}
	/// Admission succeeds only after both the returned line and its initial
	/// message event have owners. Configured recording is admitted before event
	/// publication; successful message admission is not a persistence receipt.
	pub fn post(
		&self,
		context: AcceptedDirect,
		session: &Session,
		text: &str,
		files: Vec<Attachment<Ref>>,
	) -> Result<Ref, String> {
		let state = self.0.upgrade().ok_or("the direct event owner has ended")?;
		if text.len() > MAX_LINE_BYTES || files.len() > MAX_MESSAGE_FILES {
			return Err("invalid direct message size".into());
		}
		let reservation = state.reserve(
			&context,
			text.len()
				.saturating_add(file_bytes(&files))
				.saturating_add((files.capacity() - files.len()) * core::mem::size_of::<Attachment<Ref>>()),
		)?;
		let id = LineId::new(state.next.get()).ok_or("direct line identifiers are exhausted")?;
		let previous = Rc::new(RefCell::new(Vec::new()));
		let changes = LineChanges {
			previous: previous.clone(),
			state: Rc::downgrade(&state),
			context: context.clone(),
		};
		let current = context.clone();
		let owner = Rc::downgrade(&state);
		let behavior = received_line::behavior(
			id,
			context
				.peer()
				.text()
				.as_str()
				.ok_or("the direct peer is not valid UTF-8")?
				.to_owned(),
			files.clone(),
			move || current.current() && owner.upgrade().is_some_and(|state| state.tx.borrow().is_some()),
			changes,
		)?;
		let line = session.spawn_owned(behavior).map_err(|e| e.to_string())?;
		let received = state
			.media
			.borrow_mut()
			.as_mut()
			.ok_or("incoming media owner is closed")?
			.receive(id.get(), session, files.clone(), &mut previous.borrow_mut())?;
		state.next.set(id.get() + 1);
		let content = Content::Line(Line {
			line: id,
			text: text.into(),
			kind: ChangeKind::Said,
			files,
		});
		let recording = state.record(&context, &content, received.clone(), reservation.at, None);
		reservation.slot.send(Event {
			generation: reservation.generation,
			at: reservation.at,
			from: context
				.peer()
				.text()
				.as_str()
				.ok_or("the direct peer is not valid UTF-8")?
				.to_owned(),
			direction: Direction::Incoming,
			editable: false,
			context,
			content,
			files: received,
			recording,
			_permit: reservation.permit,
		});
		Ok(line)
	}
}
fn file_bytes(files: &[Attachment<Ref>]) -> usize {
	files.iter().fold(core::mem::size_of_val(files), |bytes, file| {
		bytes
			.saturating_add(file.description.retained_bytes() * 2)
			.saturating_add(core::mem::size_of::<FileView>())
	})
}
struct LineChanges<P: Platform> {
	previous: Rc<RefCell<Vec<PreviousFile>>>,
	state: Weak<State<P>>,
	context: AcceptedDirect,
}
struct ChangeReservation {
	event: Reservation,
	files: Vec<FileView>,
}
impl<P: Platform> Changes for LineChanges<P> {
	type Reservation = ChangeReservation;
	fn reserve(&mut self, proposal: Proposal<'_, Attachment<Ref>>) -> Result<Self::Reservation, String> {
		let state = self.state.upgrade().ok_or("the direct event owner has retired")?;
		let session = glowcap::current_session()
			.map_err(|e| e.to_string())?
			.ok_or("a direct line change needs its delivering session")?;
		let payload = proposal.files().fold(proposal.text.len(), |bytes, file| {
			bytes
				.saturating_add(core::mem::size_of::<Attachment<Ref>>())
				.saturating_add(file.description.retained_bytes() * 2)
				.saturating_add(core::mem::size_of::<FileView>())
		});
		let event = state.reserve(&self.context, payload)?;
		let files = state
			.media
			.borrow_mut()
			.as_mut()
			.ok_or("incoming media owner is closed")?
			.receive(
				proposal.id.get(),
				&session,
				proposal.files().cloned().collect(),
				&mut self.previous.borrow_mut(),
			)?;
		Ok(ChangeReservation { event, files })
	}
	fn commit(&mut self, reservation: Self::Reservation, change: LineChange<'_, '_, Attachment<Ref>>) {
		let ChangeReservation {
			event: reservation,
			files: received,
		} = reservation;
		let content = Content::Line(Line {
			line: change.id,
			text: change.text.into(),
			kind: change.kind,
			files: change.files.to_vec(),
		});
		let recording = self
			.state
			.upgrade()
			.ok_or_else(|| "the direct event owner has retired".into())
			.and_then(|state| state.record(&self.context, &content, received.clone(), reservation.at, None));
		reservation.slot.send(Event {
			generation: reservation.generation,
			at: reservation.at,
			from: change.from.into(),
			direction: Direction::Incoming,
			editable: false,
			context: self.context.clone(),
			content,
			files: received,
			recording,
			_permit: reservation.permit,
		});
	}
}
