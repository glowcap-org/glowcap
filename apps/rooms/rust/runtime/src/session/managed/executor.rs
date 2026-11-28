//! Each reserved worker owns one confirmed continuation and exact target call.
use super::{
	State,
	results::{Acquired, Acquisition, Prepared, Settlement},
};
use glowcap::{
	Argument, Host, Ref, Result,
	loam::{self, Continuation, ControlPowers, EffectExecution, EffectResult, PendingContinuation, PolicyValue, Scope},
};
use rooms_application::{content::session::effects::OBSERVATION_MS, session::effect::Reply};
use rooms_glowcap::client::{Deadline, Tasks};
use std::{
	cell::{Cell, RefCell},
	future::Future,
	pin::Pin,
	rc::{Rc, Weak},
};
use tokio::sync::Mutex;
type ExecutionReporter = dyn Fn(&str, &crate::Error);

mod ended;
mod ending;
mod seat;
mod unrecorded;
mod writer;
pub(super) use ended::retire_ended;
pub(super) use ending::Ending;
pub(super) use seat::Seat;
pub(super) use unrecorded::release_unrecorded;
pub(super) use writer::Writer;

/// One bounded job retains its actual observation across interruption or drive
/// refusal. Loam owns the receipt. These phases cannot reconstruct dispatch.
pub(super) struct Job<P: Tasks> {
	pub task: Option<P::Task>,
	work: Rc<Mutex<Option<Work<P>>>>,
	/// The installed observation while it waits on commit, so a retry under
	/// the same id can see a confirmed absence the worker has not yet woken to.
	confirming: Weak<PendingContinuation>,
	/// The source whose request this job runs, once its observation is
	/// installed. A release of an operation with no receipt answers from the
	/// job only for this source, so it never learns of another's job.
	source: Option<Ref>,
	pub failure: Option<glowcap::Error>,
	pub batch_released: Option<Rc<Cell<bool>>>,
}
impl<P: Tasks> Job<P> {
	/// Whether this job is paused: its observation failed or its worker was
	/// interrupted, no worker runs, and only a resume by its source or its
	/// retirement ends it. A seat reserved but not yet started is not paused.
	pub(super) fn is_paused(&self) -> bool {
		self.failure.is_some()
	}
	/// Whether this job's commit is confirmed absent, which is final: the
	/// installed observation still waits on it and Loam answers that nothing
	/// was written. A pending or installed commit answers false. It reads only
	/// the observer, so a content callback may ask.
	pub(super) fn confirms_absent(&self) -> bool {
		self.confirming
			.upgrade()
			.is_some_and(|pending| matches!(pending.absent(), Ok(true)))
	}
}
struct Intent {
	source: Ref,
	canonical: String,
}
struct Work<P: Tasks> {
	intent: Intent,
	phase: Phase,
	reply: Reply,
	outgoing: Option<super::outgoing::Capture<P>>,
	provenance: Argument,
	retirement: Option<Rc<super::supervision::retirement::Owner>>,
}
type Observation<T> = Pin<Box<dyn Future<Output = Result<T>>>>;

enum Phase {
	Confirming {
		pending: Rc<PendingContinuation>,
		action: Option<Action>,
	},
	Preparing {
		continuation: Option<Continuation>,
		action: Option<Action>,
	},
	Executing {
		execution: EffectExecution,
		/// Private context the observed result is read with. Only manager
		/// recovery carries one, from its own confirmed identity read.
		identity: Option<String>,
	},
	ReadingIdentity(Box<super::manager_recovery::Pipeline>),
	Uploading(Box<super::uploads::Pipeline>),
	Bridging(Box<super::bridge::pipeline::Pipeline>),
	SharingArchive(Box<super::archive_sharing::Pipeline>),
	Acquiring {
		prepared: Rc<Acquisition>,
		pending: Option<Observation<Acquired>>,
	},
	Settling {
		outcome: Settlement,
		// The bounded worker retains this entire observation, including the
		// writer lock and vow receiver, across cancellation of its polling task.
		pending: Option<Observation<Argument>>,
	},
}
impl Phase {
	/// Whether the request may have reached its target. Before execution the
	/// confirmed continuation has dispatched nothing.
	fn dispatched(&self) -> bool {
		!matches!(self, Self::Confirming { .. } | Self::Preparing { .. })
	}
}
enum Action {
	// Bridge declarations are much larger than ordinary call inputs. Only an
	// admitted bridge job pays for this box; every other phase stays compact.
	Bridge(Box<super::bridge::pipeline::Intent>),
	Archive(Box<super::archive_sharing::Intent>),
	Manager,
	Call {
		verb: String,
		args: Vec<Argument>,
	},
	Upload {
		intent: super::uploads::Intent,
		released: Rc<Cell<bool>>,
		direct: bool,
	},
}
pub(super) struct CallIntent {
	pub reply: Reply,
	pub verb: String,
	pub args: Vec<Argument>,
}
impl<P: Tasks + Deadline + Clone + 'static> Work<P> {
	async fn advance(
		work: &Mutex<Option<Self>>,
		id: &str,
		writer: &Rc<Writer>,
		platform: &P,
		reply_bytes: usize,
		owner: &Weak<State<P>>,
	) -> Result<()> {
		let cell: *const Mutex<Option<Self>> = work;
		let mut held = work.lock().await;
		loop {
			let Some(work) = held.as_mut() else {
				return Ok(());
			};
			let next =
				match &mut work.phase {
					Phase::Confirming { pending, action } => {
						// A commit already confirmed needs no timer. One still
						// pending is waited on within the observation deadline, so
						// a stalled commit pauses the job like any observation.
						let confirmed = match pending.try_take() {
							Ok(Some(continuation)) => Ok(continuation),
							Ok(None) => platform
								.within(OBSERVATION_MS, pending.confirmed())
								.await
								.ok_or_else(|| paused("dispatch confirmation deadline expired"))?,
							Err(error) => Err(error),
						};
						let continuation = match confirmed {
							Ok(continuation) => continuation,
							Err(error) if error.code() == loam::UNCHANGED => {
								// A retry that superseded this attempt has begun the
								// same retirement, so only the seated job reports.
								let seated = owner.upgrade().is_some_and(|owner| {
									owner
										.jobs
										.borrow()
										.get(id)
										.is_some_and(|job| std::ptr::eq(&*job.work, cell))
								});
								if seated && let Some(retirement) = &work.retirement {
									retirement.absent();
								}
								// Confirmed receipt absence justifies neither a
								// private settlement nor any upstream target act.
								*held = None;
								return Ok(());
							}
							Err(error) => return Err(error),
						};
						Phase::Preparing {
							continuation: Some(continuation),
							action: action.take(),
						}
					}
					Phase::Preparing { continuation, action } => {
						// Confirmation transfers once. Fallible actor preparation keeps
						// that exact observer here until preparation succeeds on retry.
						if let Some(capture) = &mut work.outgoing {
							capture.prepare()?;
						}
						let continuation = continuation
							.take()
							.ok_or_else(|| loam::refusal("confirmed continuation is absent"))?;
						match action
							.take()
							.ok_or_else(|| loam::refusal("confirmed action is absent"))?
						{
							Action::Archive(intent) => {
								Phase::SharingArchive(Box::new(super::archive_sharing::Pipeline::new(
									writer.host.clone(),
									continuation,
									*intent,
									reply_bytes,
								)))
							}
							Action::Manager => Phase::ReadingIdentity(Box::new(
								super::manager_recovery::Pipeline::new(writer.host.clone(), continuation),
							)),
							Action::Bridge(intent) => Phase::Bridging(Box::new(
								super::bridge::pipeline::Pipeline::new(continuation, *intent, reply_bytes),
							)),
							Action::Call { verb, args } => match continuation.execute(0, &verb, &args, reply_bytes) {
								Ok(execution) => Phase::Executing {
									execution,
									identity: None,
								},
								Err(error) => {
									if let Some(retirement) = &work.retirement {
										retirement.absent();
									}
									Phase::Settling {
										outcome: Settlement::refused(&error),
										pending: None,
									}
								}
							},
							Action::Upload {
								intent,
								released,
								direct,
							} => Phase::Uploading(Box::new(super::uploads::Pipeline::new(
								writer.host.clone(),
								continuation,
								intent,
								released,
								reply_bytes,
								direct,
							))),
						}
					}
					Phase::SharingArchive(pending) => {
						let outcome = platform
							.within(OBSERVATION_MS, pending.advance())
							.await
							.ok_or_else(|| paused("archive sharing observation deadline expired"))??;
						let Some(outcome) = outcome.and_then(|ending| ending.settlement(id, writer)) else {
							*held = None;
							return Ok(());
						};
						Phase::Settling { outcome, pending: None }
					}
					Phase::Bridging(pending) => {
						let outcome = platform
							.within(OBSERVATION_MS, pending.advance())
							.await
							.ok_or_else(|| paused("bridge observation deadline expired"))??;
						let Some(outcome) = outcome.and_then(|ending| ending.settlement(id, writer)) else {
							*held = None;
							return Ok(());
						};
						Phase::Settling { outcome, pending: None }
					}
					Phase::Uploading(pending) => {
						// The pipeline bounds each of its steps itself: the fill after
						// an acknowledged post must not pause on the observation.
						let outcome = pending.advance(platform).await?;
						let Some(mut outcome) = outcome.and_then(|ending| ending.settlement(id, writer)) else {
							*held = None;
							return Ok(());
						};
						if let Some(capture) = &mut work.outgoing {
							let provenance = owner
								.upgrade()
								.ok_or_else(|| loam::refusal("outgoing session has closed"))
								.and_then(|owner| capture.complete(&owner, &mut outcome));
							match provenance {
								Ok(value) => work.provenance = value,
								Err(cause) => {
									// The upload finished. No resumed observation can recover
									// its consumed settlement.
									writer.report(id, &cause);
									*held = None;
									return Ok(());
								}
							}
						}
						Phase::Settling { outcome, pending: None }
					}
					Phase::ReadingIdentity(pending) => {
						let step = platform
							.within(OBSERVATION_MS, pending.advance())
							.await
							.ok_or_else(|| paused("identity observation deadline expired"))??;
						match step {
							super::manager_recovery::Step::Identified(continuation, identity) => {
								// One operator dispatch, with the observed identity as its
								// only argument. Refusal at admission is a known-unsent act.
								match continuation.execute(
									0,
									rooms_application::server::operations::operator::verbs::GIVE_MANAGER,
									&[Argument::String(identity.clone())],
									reply_bytes,
								) {
									Ok(execution) => Phase::Executing {
										execution,
										identity: Some(identity),
									},
									Err(error) => Phase::Settling {
										outcome: Settlement::refused(&error),
										pending: None,
									},
								}
							}
							super::manager_recovery::Step::Refused(error) => Phase::Settling {
								outcome: Settlement::refused(&error),
								pending: None,
							},
						}
					}
					Phase::Executing { execution, identity } => {
						let waited = if crate::session::fault::expires_observation(work.reply) {
							None
						} else {
							platform.within(OBSERVATION_MS, execution.completed()).await
						};
						let observed = waited.ok_or_else(|| paused("effect observation deadline expired"))??;
						match observed {
							EffectResult::Ready(value) => {
								match Prepared::read(work.reply, &value, &work.intent.canonical, identity.as_deref()) {
									Ok(Prepared::Complete(outcome)) => {
										let mut outcome = outcome;
										if let Some(capture) = &mut work.outgoing {
											work.provenance = capture.complete(
												&owner
													.upgrade()
													.ok_or_else(|| loam::refusal("outgoing session has closed"))?,
												&mut outcome,
											)?;
										}
										if let Some(retirement) = &work.retirement {
											match outcome.retirement_target(work.reply)? {
												Some(target) => retirement.ready(target)?,
												None => retirement.absent(),
											}
										}
										Phase::Settling { outcome, pending: None }
									}
									Ok(Prepared::Capability(prepared)) => Phase::Acquiring {
										prepared: Rc::new(prepared),
										pending: None,
									},
									Err(error) => {
										if let Some(retirement) = &work.retirement {
											retirement.unknown(error.clone());
										}
										writer.report(id, &error);
										Phase::Settling {
											outcome: Settlement::unknown(&error),
											pending: None,
										}
									}
								}
							}
							EffectResult::Unsent(error) => {
								if let Some(retirement) = &work.retirement {
									retirement.absent();
								}
								Phase::Settling {
									outcome: Settlement::refused(&error),
									pending: None,
								}
							}
							// An occupied directory name is refused before registration.
							// Transport loss still leaves its exact outcome unknown.
							EffectResult::Unknown(error) if Settlement::confirmed_refusal(work.reply, &error) => {
								if let Some(retirement) = &work.retirement {
									retirement.absent();
								}
								Phase::Settling {
									outcome: Settlement::refused(&error),
									pending: None,
								}
							}
							EffectResult::Unknown(error) => {
								if let Some(retirement) = &work.retirement {
									retirement.unknown(error.clone());
								}
								writer.report(id, &error);
								Phase::Settling {
									outcome: Settlement::unknown(&error),
									pending: None,
								}
							}
							EffectResult::Pending => unreachable!("completed observation is terminal"),
						}
					}
					Phase::Acquiring { prepared, pending } => {
						if pending.is_none() {
							let prepared = Rc::clone(prepared);
							let host = writer.host.clone();
							*pending = Some(Box::pin(async move { prepared.acquire(&host).await }));
						}
						let acquiring = pending
							.as_mut()
							.ok_or_else(|| loam::refusal("result acquisition is not started"))?;
						let result = platform
							.within(OBSERVATION_MS, acquiring)
							.await
							.ok_or_else(|| paused("result acquisition deadline expired"))?;
						*pending = None;
						match result? {
							super::results::Acquired::Settled(outcome) => Phase::Settling { outcome, pending: None },
							super::results::Acquired::Unanswerable(error) => {
								writer.report(id, &error);
								Phase::Settling {
									outcome: Settlement::unknown(&error),
									pending: None,
								}
							}
						}
					}
					Phase::Settling { outcome, pending } => {
						if pending.is_none() {
							let args = [
								Argument::String(id.into()),
								Argument::Reference(work.intent.source.clone()),
								Argument::String(work.intent.canonical.clone()),
								outcome.0.clone(),
								work.provenance.clone(),
							];
							let writer = Rc::clone(writer);
							*pending = Some(Box::pin(async move { writer.idempotent("settle-effect", &args).await }));
						}
						let settling = pending
							.as_mut()
							.ok_or_else(|| loam::refusal("settlement observation is not started"))?;
						let result = platform
							.within(OBSERVATION_MS, settling)
							.await
							.ok_or_else(|| paused("settlement deadline expired"))?;
						// Only a terminal observation retires its receiver. A failed
						// attempt retains the exact outcome for strict receipt retry.
						*pending = None;
						result?;
						if crate::session::fault::settles_late(work.reply) {
							return Err(paused("settlement deadline expired"));
						}
						if let Some(capture) = &mut work.outgoing {
							capture.publish();
						}
						if let Some(retirement) = &work.retirement
							&& retirement.closing()
						{
							platform
								.within(OBSERVATION_MS, retirement.close())
								.await
								.ok_or_else(|| paused("membership retirement deadline expired"))??;
						}
						*held = None;
						return Ok(());
					}
				};
			work.phase = next;
		}
	}
}
/// The failure a job pauses on when `what` happened to it: an observation
/// missed its deadline or its worker was interrupted. Its work stays held
/// until its sender resumes it, or gives its receipt back and so retires it.
pub(in crate::session::managed) fn paused(what: &str) -> glowcap::Error {
	loam::refusal(what)
}
/// Interruption before the first poll and during an await preserves Work in
/// its separate owner. Recovery resumes that same observation, never dispatch.
struct Retirement<P: Tasks + Deadline + Clone + 'static> {
	owner: Weak<State<P>>,
	id: String,
	work: Weak<Mutex<Option<Work<P>>>>,
}
impl<P: Tasks + Deadline + Clone + 'static> Drop for Retirement<P> {
	fn drop(&mut self) {
		if let Some(owner) = self.owner.upgrade() {
			if let Some(job) = owner.jobs.borrow_mut().get_mut(&self.id)
				&& Weak::ptr_eq(&Rc::downgrade(&job.work), &self.work)
				&& job.failure.is_none()
			{
				job.failure = Some(paused("effect worker interrupted"));
			}
			owner.changes.execution_changed();
			owner.changed.notify_waiters();
		}
	}
}
pub(super) fn resume<P: Tasks + Deadline + Clone + 'static>(owner: &Rc<State<P>>, id: &str) -> Result<()> {
	let (work, old_task) = {
		let mut jobs = owner.jobs.borrow_mut();
		let job = jobs
			.get_mut(id)
			.ok_or_else(|| loam::refusal("effect has no live observation"))?;
		if job.task.is_some() && !job.is_paused() {
			return Ok(());
		}
		job.failure = None;
		(Rc::clone(&job.work), job.task.take())
	};
	drop(old_task);
	let writer = Rc::clone(&owner.writer);
	let platform = owner.platform.clone();
	let reply_bytes = owner.reply_bytes.get();
	let weak = Rc::downgrade(owner);
	let id = id.to_owned();
	let task_id = id.clone();
	let retirement = Retirement {
		owner: weak.clone(),
		id: id.clone(),
		work: Rc::downgrade(&work),
	};
	let task = owner.platform.spawn(async move {
		let _retirement = retirement;
		let result = Work::advance(&work, &id, &writer, &platform, reply_bytes, &weak).await;
		if let Some(owner) = weak.upgrade() {
			let retired = {
				let mut jobs = owner.jobs.borrow_mut();
				// A job under this id that holds other work superseded this one
				// and owns its own outcome, as the `Retirement` drop also checks.
				match jobs.get_mut(&id).filter(|job| Rc::ptr_eq(&job.work, &work)) {
					None => None,
					Some(_) if result.is_ok() => jobs.remove(&id),
					Some(job) => {
						job.failure = result.err();
						None
					}
				}
			};
			drop(retired);
			owner.changes.execution_changed();
			owner.changed.notify_waiters();
		}
	});
	owner
		.jobs
		.borrow_mut()
		.get_mut(&task_id)
		.ok_or_else(|| loam::refusal("effect has no live observation"))?
		.task = Some(task);
	Ok(())
}
/// Retire the paused job `id`, as a session restart does: the job leaves the
/// table and its worker's state is dropped, so nothing observes, settles, or
/// dispatches it again. The receipt stays as the caller leaves it. A running
/// job, a seat not yet started, and an id with no job stay, and the answer is
/// whether a paused job was retired. With `settled`, the receipt's settlement
/// committed, so the line activity the job captured is published first, as the
/// worker publishes it once its settlement answers, and a retirement whose
/// receipt did not commit publishes nothing. A membership whose admission the job
/// owned learns the job's end the way the worker reports it: absent before
/// dispatch and unknown after, unless the worker already reported more. A
/// paused upload's staged files are not discarded here: the room's file store
/// expires each one `UPLOAD_IDLE_MS` (the Rooms application's `files.rs`)
/// after its last write, and a paused job writes nothing.
pub(super) fn retire<P: Tasks + Deadline + Clone + 'static>(owner: &State<P>, id: &str, settled: bool) -> bool {
	let (retired, work) = {
		let mut jobs = owner.jobs.borrow_mut();
		let Some(job) = jobs.get(id).filter(|job| job.is_paused()) else {
			return false;
		};
		// A paused job has no worker, so nothing holds its work's lock. A job
		// whose lock is held has a worker after all, so it stays as a running
		// job does, and that worker reports its own end.
		let Ok(mut held) = job.work.try_lock() else {
			return false;
		};
		let work = held.take();
		drop(held);
		(jobs.remove(id), work)
	};
	if let Some(job) = retired {
		if let Some(mut work) = work {
			if settled && let Some(capture) = &mut work.outgoing {
				capture.publish();
			}
			if let Some(retirement) = &work.retirement {
				retirement.forfeit(work.phase.dispatched().then(|| job.failure.clone()).flatten());
			}
		}
		drop(job);
		owner.changes.execution_changed();
		owner.changed.notify_waiters();
	}
	true
}
/// Retire every paused job, as [`retire`] does for one.
pub(super) fn retire_paused<P: Tasks + Deadline + Clone + 'static>(owner: &State<P>) {
	let paused: Vec<_> = owner
		.jobs
		.borrow()
		.iter()
		.filter(|(_, job)| job.is_paused())
		.map(|(id, _)| id.clone())
		.collect();
	for id in paused {
		retire(owner, &id, false);
	}
}
