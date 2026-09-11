//! Outgoing direct effects retain their delegated line and local media custody.
//! One admitted effect per conversation; unrelated conversations progress together.
mod plan;
mod worker;
use crate::{
	direct_events::{EventReceiver, OutgoingEvent},
	direct_routes::RouteReceiver,
	directory_runtime::AcceptedDirect,
};
use crate::{
	media_files::{FileView, MediaFiles, Selection},
	platform::Platform,
};
use rooms_application::{
	files::sources::MAX_BYTES,
	room::message::{ChangeKind, LineId},
};
use rooms_glowcap::client::{
	direct::Direct,
	posted_line::PostedLine,
	sources::{Source, Sources},
};
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
};
use tokio::sync::{mpsc, oneshot, watch};
pub use worker::OutgoingWorker;

pub const OPERATION_LIMIT: usize = 32;
pub const LINE_LIMIT: usize = 2000;
const REQUEST_BYTES: usize = MAX_BYTES + 2 * 1024 * 1024;
/// Evidence available to the caller, including when local completion fails.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Delivery {
	NotSent,
	Uncertain,
	Accepted,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Failure {
	pub delivery: Delivery,
	pub reason: String,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Sent {
	pub line: LineId,
	pub editable: bool,
}
/// Observation only: dropping this does not cancel an admitted effect.
pub struct Sending {
	answer: oneshot::Receiver<Result<Sent, Failure>>,
	progress: Rc<Cell<Delivery>>,
	_permit: Rc<Permit>,
}
impl Sending {
	pub async fn wait(self) -> Result<Sent, Failure> {
		self.answer
			.await
			.unwrap_or_else(|_| Err(failure(self.progress.get(), "outgoing worker ended without answering")))
	}
}
#[derive(Clone)]
pub struct DirectOutgoing<P: Platform> {
	state: Rc<State<P>>,
	requests: mpsc::Sender<Request<P>>,
	events: EventReceiver<P>,
	routes: RouteReceiver<P>,
	stop: watch::Sender<bool>,
	done: watch::Receiver<Option<Result<(), String>>>,
}
struct State<P: Platform> {
	closed: Cell<bool>,
	held: Rc<Cell<(usize, usize)>>,
	busy: RefCell<Vec<AcceptedDirect>>,
	rows: RefCell<Vec<Row<P>>>,
}
struct Row<P: Platform> {
	context: AcceptedDirect,
	id: LineId,
	line: Option<Rc<PostedLine<P>>>,
	uncertain: bool,
	files: Vec<FileView>,
	_selections: Vec<Selection>,
}
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
struct Busy<P: Platform> {
	state: Rc<State<P>>,
	context: AcceptedDirect,
}
impl<P: Platform> Drop for Busy<P> {
	fn drop(&mut self) {
		self.state.busy.borrow_mut().retain(|c| !c.same_context(&self.context));
	}
}
enum Target<P: Platform> {
	Post(Rc<Direct<P>>),
	Change(Rc<PostedLine<P>>),
}
struct Request<P: Platform> {
	context: AcceptedDirect,
	target: Target<P>,
	plan: plan::Plan,
	event: OutgoingEvent<P>,
	progress: Rc<Cell<Delivery>>,
	answer: oneshot::Sender<Result<Sent, Failure>>,
	_permit: Rc<Permit>,
	_busy: Busy<P>,
}
impl<P: Platform> DirectOutgoing<P> {
	pub(super) fn require_line(&self, line: rooms_application::direct::operation::LineKey) -> Result<(), String> {
		if self.events.generation()? != line.generation {
			return Err("that line belongs to another event generation".into());
		}
		Ok(())
	}
	/// The parent establishes routes and owns the wire Sources pool. Run this
	/// worker on its LocalSet and close it before events, sources or transport.
	pub fn new(
		platform: P,
		routes: RouteReceiver<P>,
		events: EventReceiver<P>,
		sources: Rc<Sources<P>>,
	) -> (Self, OutgoingWorker<P>) {
		let state = Rc::new(State {
			closed: Cell::new(false),
			held: Default::default(),
			busy: Default::default(),
			rows: Default::default(),
		});
		let (requests, rx) = mpsc::channel(OPERATION_LIMIT);
		let (stop, stopping) = watch::channel(false);
		let (finished, done) = watch::channel(None);
		let worker = OutgoingWorker {
			routes: routes.clone(),
			state: state.clone(),
			sources,
			media: MediaFiles::new(platform),
			requests: rx,
			stopping,
			finished,
			pending: Vec::new(),
		};
		(
			Self {
				state,
				requests,
				routes,
				events,
				stop,
				done,
			},
			worker,
		)
	}
	pub fn send(&self, context: &AcceptedDirect, text: &str, files: Vec<Source>) -> Result<Sending, String> {
		let plan = plan::Plan::post(text, files)?;
		self.admit(context, None, Target::Post(self.routes.line(context)?), plan)
	}
	pub fn edit(&self, context: &AcceptedDirect, id: LineId, text: &str) -> Result<Sending, String> {
		self.change(context, id, "edit", text, &[], Vec::new())
	}
	pub fn refile(
		&self,
		context: &AcceptedDirect,
		id: LineId,
		caption: &str,
		keep: &[u32],
		files: Vec<Source>,
	) -> Result<Sending, String> {
		self.change(context, id, "refile", caption, keep, files)
	}
	pub fn withdraw(&self, context: &AcceptedDirect, id: LineId) -> Result<Sending, String> {
		self.change(context, id, "withdraw", "", &[], Vec::new())
	}
	fn change(
		&self,
		context: &AcceptedDirect,
		id: LineId,
		verb: &str,
		text: &str,
		keep: &[u32],
		files: Vec<Source>,
	) -> Result<Sending, String> {
		let (line, plan) = {
			let rows = self.state.rows.borrow();
			let row = rows
				.iter()
				.find(|row| row.id == id && row.context.same_context(context))
				.ok_or("that outgoing line is no longer retained")?;
			if row.uncertain && verb != "withdraw" {
				return Err("the previous line change is uncertain; only withdrawal is safe".into());
			}
			let line = row.line.clone().ok_or("that outgoing line has no edit capability")?;
			(line, plan::Plan::change(id, &row.files, verb, text, keep, files)?)
		};
		self.admit(context, Some(id), Target::Change(line), plan)
	}
	fn admit(
		&self,
		context: &AcceptedDirect,
		id: Option<LineId>,
		target: Target<P>,
		plan: plan::Plan,
	) -> Result<Sending, String> {
		if self.state.closed.get() || *self.stop.borrow() || self.requests.is_closed() || !context.current() {
			return Err("outgoing owner or conversation has retired".into());
		}
		if self.state.busy.borrow().iter().any(|c| c.same_context(context)) {
			return Err("this direct conversation already has a pending effect".into());
		}
		let (count, held) = self.state.held.get();
		let bytes = plan.bytes::<P>();
		if count == OPERATION_LIMIT || bytes > REQUEST_BYTES.saturating_sub(held) {
			return Err("outgoing effects exceeded their count or byte ceiling".into());
		}
		let slot = self
			.requests
			.try_reserve()
			.map_err(|_| "outgoing worker is unavailable")?;
		let event = self
			.events
			.outgoing(context, id, &plan.text, plan.descriptions().map(|d| d.retained_bytes()))?;
		self.reconcile();
		// Reserve room for every in-flight post before any peer can accept it.
		if id.is_none() {
			let mut rows = self.state.rows.borrow_mut();
			if rows.len() + self.state.busy.borrow().len() >= LINE_LIMIT {
				let at = rows
					.iter()
					.position(|r| !self.state.busy.borrow().iter().any(|c| c.same_context(&r.context)))
					.ok_or("outgoing line custody is full")?;
				rows.remove(at);
			}
		}
		self.state.held.set((count + 1, held + bytes));
		let permit = Rc::new(Permit {
			held: self.state.held.clone(),
			bytes,
		});
		self.state.busy.borrow_mut().push(context.clone());
		let busy = Busy {
			state: self.state.clone(),
			context: context.clone(),
		};
		let progress = Rc::new(Cell::new(Delivery::NotSent));
		let (answer, receive) = oneshot::channel();
		slot.send(Request {
			context: context.clone(),
			target,
			plan,
			event,
			progress: progress.clone(),
			answer,
			_permit: permit.clone(),
			_busy: busy,
		});
		Ok(Sending {
			answer: receive,
			progress,
			_permit: permit,
		})
	}
	/// Drive on committed intent changes; admission also checks retirement.
	pub fn reconcile(&self) {
		self.state.rows.borrow_mut().retain(|r| r.context.current());
	}
	pub async fn close(&self) -> Result<(), String> {
		self.state.closed.set(true);
		self.stop.send_replace(true);
		let mut done = self.done.clone();
		loop {
			if let Some(result) = done.borrow().clone() {
				return result;
			}
			done.changed()
				.await
				.map_err(|_| "outgoing worker retired without completing shutdown")?;
		}
	}
}
fn failure(delivery: Delivery, reason: &str) -> Failure {
	Failure {
		delivery,
		reason: rooms_application::failure::reason_prefix(reason).to_owned(),
	}
}
