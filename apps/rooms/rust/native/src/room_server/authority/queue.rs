//! Bounded custody of durable room-authority changes. Accepted jobs belong
//! to this writer; callers can observe completion but cannot cancel the write.
use super::super::{
	answer::busy,
	document::ServerState,
	notice::Notice,
	state::{Shared, State},
};
use glowcap::{current_session, Argument, Resolver, Session};
use rooms_application::server::links::Authority;
use tokio::sync::{mpsc, oneshot, watch};
mod names;

pub(super) type Prepare = Box<dyn FnOnce(&State) -> Result<Option<Authority>, String>>;
pub(super) type Commit = Box<dyn FnOnce(&mut State) -> Result<Argument, String>>;
type Outcome = Result<Argument, String>;
const LIMIT: usize = 256;
struct Job {
	verb: &'static str,
	prepare: Prepare,
	commit: Commit,
	answer: Answer,
}
enum Answer {
	Turn(Resolver, Session),
	Observed(oneshot::Sender<Outcome>),
}
pub(in crate::room_server) struct Handle {
	jobs: mpsc::Sender<Job>,
	stop: watch::Sender<bool>,
	names: names::Pending,
}
pub(in crate::room_server) struct Writer {
	jobs: mpsc::Receiver<Job>,
	stop: watch::Receiver<bool>,
	server: ServerState,
	names: names::Pending,
}
pub(in crate::room_server) fn open(server: ServerState) -> (Handle, Writer) {
	let (jobs, receiver) = mpsc::channel(LIMIT);
	let (stop, stopping) = watch::channel(false);
	let names = names::Pending::default();
	(
		Handle {
			jobs,
			stop,
			names: names.clone(),
		},
		Writer {
			jobs: receiver,
			stop: stopping,
			server,
			names,
		},
	)
}
impl Handle {
	pub fn holds_name(&self, name: &str) -> bool {
		self.names.holds(name)
	}
	pub fn stop(&self) {
		self.stop.send_replace(true);
	}
	fn reserve(&self) -> Result<mpsc::Permit<'_, Job>, String> {
		if *self.stop.borrow() {
			return Err("the room authority writer is stopping".into());
		}
		self.jobs.try_reserve().map_err(|_| busy())
	}
}

/// Carry the calling session through durable work. Commit callbacks execute
/// outside the turn and must use this context for caller-specific replies.
pub(in crate::room_server) fn submit(
	state: &State,
	verb: &'static str,
	prepare: impl FnOnce(&State) -> Result<Option<Authority>, String> + 'static,
	commit: impl FnOnce(&mut State, &Session) -> Outcome + 'static,
) -> Outcome {
	let seat = state.authority_writer.reserve()?;
	let caller = current_session()
		.map_err(|e| e.to_string())?
		.ok_or("a room authority is reachable only over a session")?
		.borrowed();
	let context = caller.borrowed();
	let resolver = caller.host().defer_turn().map_err(|e| e.to_string())?;
	seat.send(Job {
		verb,
		prepare: Box::new(prepare),
		commit: Box::new(move |state| commit(state, &context)),
		answer: Answer::Turn(resolver, caller),
	});
	Ok(Argument::Void)
}

/// A command already admitted by the operations worker may wait for writer
/// capacity. Capture its job now, without borrowing State across that wait.
/// The outer worker bounds waiting commands and owns them through shutdown.
pub(in crate::room_server) fn request(
	state: &State,
	verb: &'static str,
	prepare: impl FnOnce(&State) -> Result<Option<Authority>, String> + 'static,
	commit: impl FnOnce(&mut State) -> Outcome + 'static,
) -> impl std::future::Future<Output = Outcome> + 'static {
	let jobs = state.authority_writer.jobs.clone();
	let stopping = *state.authority_writer.stop.borrow();
	async move {
		if stopping {
			return Err("the room authority writer is stopping".into());
		}
		let seat = jobs
			.reserve_owned()
			.await
			.map_err(|_| "the room authority writer ended")?;
		let (answer, reply) = oneshot::channel();
		seat.send(Job {
			verb,
			prepare: Box::new(prepare),
			commit: Box::new(commit),
			answer: Answer::Observed(answer),
		});
		reply
			.await
			.map_err(|_| "the room authority writer ended before answering")?
	}
}
impl Writer {
	pub async fn run(mut self, shared: Shared) {
		let mut stopping = false;
		loop {
			let job = tokio::select! {
				biased;
				_ = self.stop.changed(), if !stopping => { self.jobs.close(); stopping = true; continue; }
				job = self.jobs.recv() => match job { Some(job) => job, None => return },
			};
			let Job {
				verb,
				prepare,
				commit,
				answer,
			} = job;
			let prepared = self
				.server
				.require_current()
				.map_err(|error| error.to_string())
				.and_then(|()| {
					let state = shared.borrow();
					let next = prepare(&state)?;
					if let Some(next) = &next {
						self.names.reserve(&state, next)?;
					}
					Ok(next)
				});
			let outcome = match prepared {
				Err(reason) => Err(reason),
				Ok(next) => {
					let installed = match next {
						Some(next) => self.server.install(next.clone()).await.map(|()| Some(next)),
						None => Ok(None),
					};
					match installed {
						Err(error) => Err(error.to_string()),
						Ok(next) => {
							let mut state = shared.borrow_mut();
							if let Some(next) = next {
								state.authority = next;
							}
							let result = commit(&mut state);
							state.changed();
							result
						}
					}
				}
			};
			// An uncertain replacement may have committed these claims on disk.
			// Keep them until restart; neither a new publication nor a failed
			// follow-up job may release them from the stale runtime snapshot.
			if self.server.require_current().is_ok() {
				self.names.release();
			}
			match answer {
				Answer::Turn(mut resolver, caller) => {
					let delivery = match outcome {
						Ok(value) => resolver.fulfill_value(&value),
						Err(reason) => resolver.break_with(&reason),
					};
					if let Err(cause) = delivery {
						if caller.is_open() {
							shared.borrow().report(Notice::AnswerUndeliverable { verb, cause });
						}
					}
				}
				Answer::Observed(answer) => {
					if let Err(Err(reason)) = answer.send(outcome) {
						shared.borrow().report(Notice::Trouble {
							source: verb.into(),
							reason,
						});
					}
				}
			}
		}
	}
}
