//! A received room link is acknowledged only after its durable receipt finishes.
//! The parent owns replies and outcomes; hosted actors retain a weak producer.
use crate::directory_runtime::{room_invitations::RoomLinkReceiver, AcceptedDirect, Platform};
use crate::session_commands::Reply;
use glowcap::{Argument, Resolver, Session};
use rooms_application::failure::MAX_REASON_BYTES as REASON_BYTES;
use std::{
	cell::Cell,
	rc::{Rc, Weak},
};
use tokio::sync::{mpsc, watch};

pub const RECEIPT_LIMIT: usize = 64;
pub const RECEIPT_BYTES: usize = 2 * 1024 * 1024;

pub struct RoomOffers<P: Platform>(Rc<State<P>>);
#[derive(Clone)]
pub struct OfferReceiver<P: Platform>(Weak<State<P>>);
pub struct Outcomes(mpsc::Receiver<Outcome>);
pub struct Outcome {
	pub context: AcceptedDirect,
	/// Persistence and wire delivery are independent outcomes. A lost caller
	/// cannot turn a committed receipt into a failed durable transaction.
	pub revision: Result<u64, String>,
	pub acknowledged: Result<(), String>,
	_permit: Permit,
}
impl Outcomes {
	pub async fn next(&mut self) -> Option<Outcome> {
		self.0.recv().await
	}
}
struct State<P: Platform> {
	source: RoomLinkReceiver<P>,
	requests: mpsc::Sender<Request>,
	outcomes: mpsc::WeakSender<Outcome>,
	held: Rc<Cell<(usize, usize)>>,
	stop: watch::Sender<bool>,
	done: watch::Receiver<Option<Result<(), String>>>,
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
struct Request {
	context: AcceptedDirect,
	result: Result<Reply<u64>, String>,
	reply: Resolver,
	permit: Permit,
}
pub struct OfferWorker<P: Platform> {
	state: Rc<State<P>>,
	requests: mpsc::Receiver<Request>,
	outcomes: mpsc::Sender<Outcome>,
	finished: watch::Sender<Option<Result<(), String>>>,
}
impl<P: Platform> RoomOffers<P> {
	pub fn new(source: RoomLinkReceiver<P>) -> (Self, OfferWorker<P>, Outcomes) {
		let (requests, rx) = mpsc::channel(RECEIPT_LIMIT);
		let (outcomes, observed) = mpsc::channel(RECEIPT_LIMIT);
		let (stop, _) = watch::channel(false);
		let (finished, done) = watch::channel(None);
		let state = Rc::new(State {
			source,
			requests,
			outcomes: outcomes.downgrade(),
			held: Rc::new(Cell::new((0, 0))),
			stop,
			done,
		});
		(
			Self(state.clone()),
			OfferWorker {
				state,
				requests: rx,
				outcomes,
				finished,
			},
			Outcomes(observed),
		)
	}
	pub fn receiver(&self) -> OfferReceiver<P> {
		OfferReceiver(Rc::downgrade(&self.0))
	}
	/// Close and observe this worker before closing SessionCommands. Already
	/// sent durable commands retain their acknowledgement owner through drain.
	pub async fn close(&self) -> Result<(), String> {
		self.0.stop.send_replace(true);
		let mut done = self.0.done.clone();
		loop {
			if let Some(result) = done.borrow().clone() {
				return result;
			}
			done.changed()
				.await
				.map_err(|_| "room offer worker retired without observing completion")?;
		}
	}
}
impl<P: Platform> Drop for RoomOffers<P> {
	fn drop(&mut self) {
		self.0.stop.send_replace(true);
	}
}
impl<P: Platform> State<P> {
	fn reserve(&self, context: &AcceptedDirect) -> Result<Permit, String> {
		if *self.stop.borrow()
			|| self.done.borrow().is_some()
			|| self.done.has_changed().is_err()
			|| self.outcomes.upgrade().is_none_or(|sender| sender.is_closed())
		{
			return Err("the room offer owner has ended".into());
		}
		// Context owns no Host. Conservatively charge all retained text and both
		// possible failure reports before deferring a turn or admitting a write.
		let bytes = core::mem::size_of::<Request>().max(core::mem::size_of::<Outcome>())
			+ context.conversation().text().heap_bytes()
			+ context.directory().text().heap_bytes()
			+ context.peer().text().heap_bytes()
			+ context.registration().as_str().len()
			+ 2 * REASON_BYTES;
		let (count, held) = self.held.get();
		if count == RECEIPT_LIMIT || bytes > RECEIPT_BYTES.saturating_sub(held) {
			return Err("the room offer backlog has reached its count or byte limit".into());
		}
		self.held.set((count + 1, held + bytes));
		Ok(Permit {
			held: self.held.clone(),
			bytes,
		})
	}
}
impl<P: Platform> OfferReceiver<P> {
	/// Call on the actual delivering turn. Admission owns the validated record
	/// and reply slot before deferral; receipt does not accept or join a room.
	pub fn receive(
		&self,
		context: &AcceptedDirect,
		session: &Session,
		label: &str,
		link: &str,
	) -> Result<Argument, String> {
		let state = self.0.upgrade().ok_or("the room offer owner has ended")?;
		let permit = state.reserve(context)?;
		let slot = state
			.requests
			.try_reserve()
			.map_err(|_| "the room offer worker is unavailable")?;
		let admission = state.source.prepare(context, label, link)?;
		let reply = session.host().defer_turn().map_err(|e| e.to_string())?;
		let result = admission.send().map_err(|e| e.to_string());
		slot.send(Request {
			context: context.clone(),
			result,
			reply,
			permit,
		});
		Ok(Argument::Void)
	}
}
impl<P: Platform> OfferWorker<P> {
	/// One serial reply observer follows the already-serialized durable queue.
	/// No task is started in a hosted callback. Consumer loss stops admission
	/// and drains all submitted writes and replies before reporting failure.
	pub async fn run(mut self) -> Result<(), String> {
		let mut stop = self.state.stop.subscribe();
		let mut result = Ok(());
		loop {
			if *stop.borrow() || self.outcomes.is_closed() {
				self.state.stop.send_replace(true);
				self.requests.close();
			}
			if self.outcomes.is_closed() {
				result = Err("the room offer outcome consumer has ended".into());
			}
			let request = tokio::select! {
				request = self.requests.recv() => request,
				_ = stop.changed(), if !self.requests.is_closed() => continue,
				_ = self.outcomes.closed(), if !self.requests.is_closed() => continue,
			};
			let Some(request) = request else {
				break;
			};
			let Request {
				context,
				result: receipt,
				mut reply,
				permit,
			} = request;
			let revision = match receipt {
				Ok(receipt) => receipt.wait().await,
				Err(error) => Err(error),
			}
			.map_err(|error| rooms_application::failure::reason_prefix(&error).to_owned());
			let acknowledged = match &revision {
				Ok(_) => reply.fulfill(&Argument::Void),
				Err(reason) => reply.break_with(reason),
			}
			.map_err(|error| rooms_application::failure::reason_prefix(&error.to_string()).to_owned());
			if self
				.outcomes
				.try_send(Outcome {
					context,
					revision,
					acknowledged,
					_permit: permit,
				})
				.is_err()
			{
				result = Err("the room offer outcome consumer has ended".into());
				self.state.stop.send_replace(true);
			}
		}
		self.finished.send_replace(Some(result.clone()));
		result
	}
}
impl<P: Platform> Drop for OfferWorker<P> {
	fn drop(&mut self) {
		self.state.stop.send_replace(true);
		self.requests.close();
	}
}
