//! Bounded custody of durable room-authority changes. Accepted jobs belong
//! to this writer. Callers can observe completion but cannot cancel the write.
use super::super::{
	answer::busy,
	document::ServerState,
	notice::Notice,
	state::{Shared, State},
};
use glowcap::{Argument, Resolver, Session, current_session};
use rooms_application::server::links::Authority;
use tokio::sync::{mpsc, oneshot, watch};
mod names;

pub(super) type Prepare = Box<dyn FnOnce(&State) -> Result<Option<Authority>, String>>;
pub(super) type Commit = Box<dyn FnOnce(&mut State) -> Result<Argument, String>>;
type Outcome = Result<Argument, String>;
/// A job's prepare half. It answers the successor authority to save and the
/// commit that finishes the job, which owns whatever prepare resolved.
type Stage = Box<dyn FnOnce(&State) -> Result<(Option<Authority>, Commit), String>>;
const LIMIT: usize = 256;
struct Job {
	verb: &'static str,
	prepare: Stage,
	answer: Answer,
}
enum Answer {
	Turn(Resolver, Session),
	Observed(oneshot::Sender<Outcome>),
}
pub(in crate::server) struct Handle {
	jobs: mpsc::Sender<Job>,
	stop: watch::Sender<bool>,
	names: names::Pending,
}
pub(in crate::server) struct Writer {
	jobs: mpsc::Receiver<Job>,
	stop: watch::Receiver<bool>,
	server: ServerState,
	names: names::Pending,
}
pub(in crate::server) fn open(server: ServerState) -> (Handle, Writer) {
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
	/// A seat in the writer's queue, or the busy refusal when it is full. A
	/// verb takes its seat before it charges the verb's allowance, so that
	/// refusal has not spent it.
	pub fn reserve(&self) -> Result<Seat, String> {
		if *self.stop.borrow() {
			return Err(STOPPING.into());
		}
		self.jobs
			.clone()
			.try_reserve_owned()
			.map(Seat)
			.map_err(|refused| match refused {
				mpsc::error::TrySendError::Full(_) => busy("room authority writer").reason(),
				mpsc::error::TrySendError::Closed(_) => STOPPING.into(),
			})
	}
}
const STOPPING: &str = "the room authority writer is stopping";

/// One reserved place in the writer's queue.
pub(in crate::server) struct Seat(mpsc::OwnedPermit<Job>);

/// Carry the calling session through durable work, in the seat
/// `Handle::reserve` gave the caller. Commit callbacks execute outside the
/// turn and must use this context for caller-specific replies.
pub(in crate::server) fn submit(
	seat: Seat,
	verb: &'static str,
	prepare: impl FnOnce(&State) -> Result<Option<Authority>, String> + 'static,
	commit: impl FnOnce(&mut State, &Session) -> Outcome + 'static,
) -> Outcome {
	submit_resolved(
		seat,
		verb,
		move |state| Ok((prepare(state)?, ())),
		move |state, caller, ()| commit(state, caller),
	)
}

/// `submit` for a job whose prepare resolves a value its commit needs. The
/// commit receives exactly what prepare returned for this job.
pub(in crate::server) fn submit_resolved<T: 'static>(
	seat: Seat,
	verb: &'static str,
	prepare: impl FnOnce(&State) -> Result<(Option<Authority>, T), String> + 'static,
	commit: impl FnOnce(&mut State, &Session, T) -> Outcome + 'static,
) -> Outcome {
	let caller = current_session()
		.map_err(|e| e.to_string())?
		.ok_or("a room authority is reachable only over a session")?
		.borrowed();
	let context = caller.borrowed();
	let resolver = caller.host().defer_turn().map_err(|e| e.to_string())?;
	seat.0.send(Job {
		verb,
		prepare: Box::new(move |state| {
			let (next, resolved) = prepare(state)?;
			let commit: Commit = Box::new(move |state| commit(state, &context, resolved));
			Ok((next, commit))
		}),
		answer: Answer::Turn(resolver, caller),
	});
	Ok(Argument::Void)
}

/// A command already admitted by the operations worker may wait for writer
/// capacity. Capture its job now, without borrowing State across that wait.
/// The outer worker bounds waiting commands and owns them through shutdown.
pub(in crate::server) fn request<P, C>(
	state: &State,
	verb: &'static str,
	prepare: P,
	commit: C,
) -> impl std::future::Future<Output = Outcome> + 'static + use<P, C>
where
	P: FnOnce(&State) -> Result<Option<Authority>, String> + 'static,
	C: FnOnce(&mut State) -> Outcome + 'static,
{
	let jobs = state.authority_writer.jobs.clone();
	let stopping = *state.authority_writer.stop.borrow();
	async move {
		if stopping {
			return Err(STOPPING.into());
		}
		let seat = jobs.reserve_owned().await.map_err(|_| STOPPING)?;
		let (answer, reply) = oneshot::channel();
		seat.send(Job {
			verb,
			prepare: Box::new(move |state| Ok((prepare(state)?, Box::new(commit) as Commit))),
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
			let Job { verb, prepare, answer } = job;
			let prepared = self
				.server
				.require_current()
				.map_err(|error| error.to_string())
				.and_then(|()| {
					let state = shared.borrow();
					let (next, commit) = prepare(&state)?;
					if let Some(next) = &next {
						self.names.reserve(&state, next)?;
					}
					Ok((next, commit))
				});
			let outcome = match prepared {
				Err(reason) => Err(reason),
				Ok((next, commit)) => {
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
					if let Err(cause) = delivery
						&& caller.is_open()
					{
						shared.borrow().report(Notice::AnswerUndeliverable { verb, cause });
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
