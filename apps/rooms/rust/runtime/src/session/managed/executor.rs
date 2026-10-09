//! Each reserved worker owns one confirmed continuation and exact target call.
use super::{
	MAX_JOBS, State,
	results::{Acquisition, Prepared, Settlement},
};
use glowcap::{
	Argument, Host, Ref, Result,
	loam::{self, Continuation, ControlPowers, EffectExecution, EffectResult, PendingContinuation, PolicyValue},
};
use rooms_application::session::effect::Reply;
use rooms_glowcap::client::{Deadline, Tasks};
use std::{
	cell::{Cell, RefCell},
	future::Future,
	pin::Pin,
	rc::{Rc, Weak},
};
use tokio::sync::Mutex;
type ExecutionReporter = dyn Fn(&str, &glowcap::Error);

mod writer;
pub(super) use writer::Writer;

/// One bounded job retains its actual observation across interruption or drive
/// refusal. Loam owns the receipt; these phases cannot reconstruct dispatch.
pub(super) struct Job<P: Tasks> {
	pub task: Option<P::Task>,
	work: Rc<Mutex<Option<Work<P>>>>,
	pub failure: Option<glowcap::Error>,
	pub batch_released: Option<Rc<Cell<bool>>>,
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
const OBSERVATION_MS: u64 = 20_000;
enum Phase {
	Confirming {
		pending: PendingContinuation,
		action: Option<Action>,
	},
	Preparing {
		continuation: Option<Continuation>,
		action: Option<Action>,
	},
	Executing(EffectExecution),
	Uploading(Box<super::uploads::Pipeline>),
	Bridging(Box<super::bridge::pipeline::Pipeline>),
	SharingArchive(Box<super::archive_sharing::Pipeline>),
	Acquiring {
		prepared: Rc<Acquisition>,
		pending: Option<Observation<Settlement>>,
	},
	Settling {
		outcome: Settlement,
		// The bounded worker retains this entire observation, including the
		// writer lock and vow receiver, across cancellation of its polling task.
		pending: Option<Observation<Argument>>,
	},
}
enum Action {
	// Bridge declarations are much larger than ordinary call inputs. Only an
	// admitted bridge job pays for this box; every other phase stays compact.
	Bridge(Box<super::bridge::pipeline::Intent>),
	Archive(Box<super::archive_sharing::Intent>),
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
		let mut held = work.lock().await;
		loop {
			let Some(work) = held.as_mut() else {
				return Ok(());
			};
			let next =
				match &mut work.phase {
					Phase::Confirming { pending, action } => {
						let continuation = match pending.confirmed().await {
							Ok(continuation) => continuation,
							Err(error) if error.code() == loam::UNCHANGED => {
								if let Some(retirement) = &work.retirement {
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
						let continuation = continuation.take().expect("confirmed continuation");
						match action.take().expect("unconfirmed action") {
							Action::Archive(intent) => {
								Phase::SharingArchive(Box::new(super::archive_sharing::Pipeline::new(
									writer.host.clone(),
									continuation,
									*intent,
									reply_bytes,
								)))
							}
							Action::Bridge(intent) => Phase::Bridging(Box::new(
								super::bridge::pipeline::Pipeline::new(continuation, *intent, reply_bytes),
							)),
							Action::Call { verb, args } => match continuation.execute(0, &verb, &args, reply_bytes) {
								Ok(execution) => Phase::Executing(execution),
								Err(_) => {
									if let Some(retirement) = &work.retirement {
										retirement.absent();
									}
									Phase::Settling {
										outcome: Settlement::absent(),
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
							.ok_or_else(|| {
								loam::refusal(
									"archive sharing observation deadline expired; exact pipeline remains retained",
								)
							})??;
						let Some(outcome) = outcome else {
							*held = None;
							return Ok(());
						};
						match outcome {
							super::archive_sharing::Completion::Settled(outcome) => {
								Phase::Settling { outcome, pending: None }
							}
							super::archive_sharing::Completion::Unknown(error) => {
								writer.report(id, &error);
								Phase::Settling {
									outcome: Settlement::unknown(&error),
									pending: None,
								}
							}
						}
					}
					Phase::Bridging(pending) => {
						let outcome = platform
							.within(OBSERVATION_MS, pending.advance())
							.await
							.ok_or_else(|| {
								loam::refusal("bridge observation deadline expired; exact pipeline remains retained")
							})??;
						let Some(outcome) = outcome else {
							*held = None;
							return Ok(());
						};
						Phase::Settling { outcome, pending: None }
					}
					Phase::Uploading(pending) => {
						let outcome = platform
							.within(OBSERVATION_MS, pending.advance())
							.await
							.ok_or_else(|| {
								loam::refusal("upload observation deadline expired; exact pipeline remains retained")
							})??;
						let Some(outcome) = outcome else {
							*held = None;
							return Ok(());
						};
						let mut outcome = outcome;
						if let Some(capture) = &mut work.outgoing {
							work.provenance = capture.complete(
								&owner
									.upgrade()
									.ok_or_else(|| loam::refusal("outgoing session has closed"))?,
								&mut outcome,
							)?;
						}
						Phase::Settling { outcome, pending: None }
					}
					Phase::Executing(execution) => {
						let observed = platform
							.within(OBSERVATION_MS, execution.completed())
							.await
							.ok_or_else(|| {
								loam::refusal("effect observation deadline expired; exact execution remains retained")
							})??;
						match observed {
							EffectResult::Ready(value) => {
								match Prepared::read(work.reply, &value, &work.intent.canonical) {
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
							EffectResult::Unsent(_) => {
								if let Some(retirement) = &work.retirement {
									retirement.absent();
								}
								Phase::Settling {
									outcome: Settlement::absent(),
									pending: None,
								}
							}
							// Terminal uncertainty supplies no reason to dispatch
							// again. Its receipt retains the diagnostic and wakes
							// ordinary durable observers through settlement.
							EffectResult::Unknown(error) => match Prepared::negative(work.reply, &error) {
								Some(outcome) => Phase::Settling { outcome, pending: None },
								None => {
									if let Some(retirement) = &work.retirement {
										retirement.unknown(error.clone());
									}
									writer.report(id, &error);
									Phase::Settling {
										outcome: Settlement::unknown(&error),
										pending: None,
									}
								}
							},
							EffectResult::Pending => unreachable!("completed observation is terminal"),
						}
					}
					Phase::Acquiring { prepared, pending } => {
						if pending.is_none() {
							let prepared = Rc::clone(prepared);
							let host = writer.host.clone();
							*pending = Some(Box::pin(async move { prepared.acquire(&host).await }));
						}
						let result = platform
							.within(OBSERVATION_MS, pending.as_mut().expect("owned result acquisition"))
							.await
							.ok_or_else(|| {
								loam::refusal("result acquisition deadline expired; exact lookup remains retained")
							})?;
						*pending = None;
						Phase::Settling {
							outcome: result?,
							pending: None,
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
						let result = platform
							.within(OBSERVATION_MS, pending.as_mut().expect("owned settlement observation"))
							.await
							.ok_or_else(|| {
								loam::refusal("settlement deadline expired; exact observation remains retained")
							})?;
						// Only a terminal observation retires its receiver. A failed
						// attempt retains the exact outcome for strict receipt retry.
						*pending = None;
						result?;
						if let Some(capture) = &mut work.outgoing {
							capture.publish();
						}
						if let Some(retirement) = &work.retirement
							&& retirement.closing()
						{
							platform
								.within(OBSERVATION_MS, retirement.close())
								.await
								.ok_or_else(|| {
									loam::refusal(
										"membership retirement deadline expired; exact observation remains retained",
									)
								})??;
						}
						*held = None;
						return Ok(());
					}
				};
			work.phase = next;
		}
	}
}
/// Interruption before the first poll and during an await preserves Work in
/// its separate owner. Recovery resumes that same observation, never dispatch.
struct Retirement<P: Tasks + Deadline + Clone + 'static> {
	owner: Weak<State<P>>,
	id: String,
}
impl<P: Tasks + Deadline + Clone + 'static> Drop for Retirement<P> {
	fn drop(&mut self) {
		if let Some(owner) = self.owner.upgrade() {
			if let Some(job) = owner.jobs.borrow_mut().get_mut(&self.id)
				&& job.failure.is_none()
			{
				job.failure = Some(loam::refusal(
					"effect worker interrupted; exact observation remains retained",
				));
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
		if job.task.is_some() && job.failure.is_none() {
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
	};
	let task = owner.platform.spawn(async move {
		let _retirement = retirement;
		let result = Work::advance(&work, &id, &writer, &platform, reply_bytes, &weak).await;
		if let Some(owner) = weak.upgrade() {
			let retired = {
				let mut jobs = owner.jobs.borrow_mut();
				match result {
					Ok(()) => jobs.remove(&id),
					Err(error) => {
						jobs.get_mut(&id).expect("owned worker").failure = Some(error);
						None
					}
				}
			};
			drop(retired);
			owner.changes.execution_changed();
			owner.changed.notify_waiters();
		}
	});
	owner.jobs.borrow_mut().get_mut(&task_id).expect("reserved worker").task = Some(task);
	Ok(())
}
/// Reserve before Loam staging; failure withdraws this inert worker seat.
pub(super) struct Seat<P: Tasks + Deadline + Clone + 'static> {
	owner: Weak<State<P>>,
	id: String,
	installed: bool,
	retirement: Option<Rc<super::supervision::retirement::Owner>>,
}
impl<P: Tasks + Deadline + Clone + 'static> Seat<P> {
	pub fn reserve(owner: &Rc<State<P>>, id: &str) -> Result<Self> {
		if owner.closing.get() {
			return Err(loam::refusal("session is closing"));
		}
		let mut jobs = owner.jobs.borrow_mut();
		if jobs.len() >= MAX_JOBS || jobs.contains_key(id) {
			return Err(loam::refusal("session effect workers are full"));
		}
		jobs.insert(
			id.into(),
			Job {
				task: None,
				work: Rc::new(Mutex::new(None)),
				failure: None,
				batch_released: None,
			},
		);
		let retirement = owner.memberships.retirement(id);
		if let Some(retirement) = &retirement {
			retirement.begin();
		}
		Ok(Self {
			owner: Rc::downgrade(owner),
			id: id.into(),
			installed: false,
			retirement,
		})
	}
	pub fn start(
		self,
		pending: PendingContinuation,
		source: Ref,
		canonical: String,
		intent: CallIntent,
		outgoing: Option<super::outgoing::Capture<P>>,
	) -> Result<()> {
		self.install(
			pending,
			source,
			canonical,
			intent.reply,
			Action::Call {
				verb: intent.verb,
				args: intent.args,
			},
			outgoing,
		)
	}
	pub fn start_upload(
		self,
		pending: PendingContinuation,
		source: Ref,
		canonical: String,
		intent: super::uploads::Intent,
		direct: bool,
		outgoing: Option<super::outgoing::Capture<P>>,
	) -> Result<()> {
		let released = Rc::new(Cell::new(false));
		if let Some(owner) = self.owner.upgrade() {
			owner
				.jobs
				.borrow_mut()
				.get_mut(&self.id)
				.expect("reserved worker")
				.batch_released = Some(Rc::clone(&released));
		}
		self.install(
			pending,
			source,
			canonical,
			Reply::Upload,
			Action::Upload {
				intent,
				released,
				direct,
			},
			outgoing,
		)
	}
	pub fn start_bridge(
		self,
		pending: PendingContinuation,
		source: Ref,
		canonical: String,
		intent: super::bridge::pipeline::Intent,
	) -> Result<()> {
		self.install(
			pending,
			source,
			canonical,
			Reply::Acknowledgment,
			Action::Bridge(Box::new(intent)),
			None,
		)
	}
	pub fn start_archive(
		self,
		pending: PendingContinuation,
		source: Ref,
		canonical: String,
		intent: super::archive_sharing::Intent,
	) -> Result<()> {
		self.install(
			pending,
			source,
			canonical,
			Reply::Acknowledgment,
			Action::Archive(Box::new(intent)),
			None,
		)
	}
	fn install(
		mut self,
		pending: PendingContinuation,
		source: Ref,
		canonical: String,
		reply: Reply,
		action: Action,
		outgoing: Option<super::outgoing::Capture<P>>,
	) -> Result<()> {
		let owner = self
			.owner
			.upgrade()
			.ok_or_else(|| loam::refusal("session owner is closed"))?;
		let work = Rc::clone(&owner.jobs.borrow().get(&self.id).expect("reserved worker").work);
		*work.try_lock().expect("unstarted observation") = Some(Work {
			intent: Intent { source, canonical },
			reply,
			outgoing,
			provenance: Argument::Void,
			retirement: self.retirement.clone(),
			phase: Phase::Confirming {
				pending,
				action: Some(action),
			},
		});
		resume(&owner, &self.id)?;
		self.installed = true;
		Ok(())
	}
}
impl<P: Tasks + Deadline + Clone + 'static> Drop for Seat<P> {
	fn drop(&mut self) {
		if !self.installed
			&& let Some(owner) = self.owner.upgrade()
		{
			if let Some(retirement) = &self.retirement {
				retirement.absent();
			}
			let retired = owner.jobs.borrow_mut().remove(&self.id);
			drop(retired);
			owner.changed.notify_waiters();
		}
	}
}
