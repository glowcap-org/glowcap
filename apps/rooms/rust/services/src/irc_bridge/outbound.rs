//! Admission includes queued and in-flight lines. Only proven unwritten lines
//! retry on a new socket; an uncertain write is refused instead of duplicated.
use super::{notice::Notice, state::Shared};
use glowcap::{Argument, Resolver, Session};
use rooms_application::server::irc::{protocol, room::Post};
use std::sync::Arc;
use tokio::sync::{OwnedSemaphorePermit, Semaphore, mpsc};
const LINES: usize = 64;
pub(super) struct Handle {
	slots: Arc<Semaphore>,
	jobs: mpsc::Sender<Pending>,
}
pub(super) struct Pending {
	pub post: Post,
	pub bytes: Vec<u8>,
	answer: Resolver,
	caller: Session,
	_slot: OwnedSemaphorePermit,
}
pub(super) fn open() -> (Handle, mpsc::Receiver<Pending>) {
	let (jobs, receiver) = mpsc::channel(LINES);
	(
		Handle {
			slots: Arc::new(Semaphore::new(LINES)),
			jobs,
		},
		receiver,
	)
}
impl Handle {
	pub fn pending(&self) -> bool {
		self.slots.available_permits() < LINES
	}
	pub fn stop(&self) {
		self.slots.close();
	}
	pub fn post(&self, session: &Session, post: Post, channel: &str, line_bytes: u64) -> Result<Argument, String> {
		if post.text.len() as u64 > line_bytes {
			return Err(format!("a bridged IRC line may be at most {line_bytes} bytes"));
		}
		let bytes = protocol::encode("PRIVMSG", &[channel, &format!("<{}> {}", post.from, post.text)])
			.map_err(|e| e.to_string())?;
		let slot = self
			.slots
			.clone()
			.try_acquire_owned()
			.map_err(|_| "the IRC outbound queue is full or stopping; retry after earlier lines are delivered")?;
		let seat = self
			.jobs
			.try_reserve()
			.map_err(|_| "the IRC outbound owner has ended")?;
		let answer = session.host().defer_turn().map_err(|e| e.to_string())?;
		seat.send(Pending {
			post,
			bytes,
			answer,
			caller: session.borrowed(),
			_slot: slot,
		});
		Ok(Argument::Void)
	}
}
impl Pending {
	pub fn finish(mut self, state: &Shared, result: Result<(), String>) {
		if result.is_ok() {
			let mut state = state.borrow_mut();
			let effects = state.room.commit_post(&self.post);
			state.apply(effects);
		}
		let delivered = match result {
			Ok(()) => self.answer.fulfill_value(&Argument::Void),
			Err(reason) => self.answer.break_with(&reason),
		};
		if let Err(error) = delivered
			&& self.caller.is_open()
		{
			(state.borrow().report)(Notice::AnswerFailed(error.to_string()));
		}
		drop(self);
		state.borrow_mut().demand();
	}
}
