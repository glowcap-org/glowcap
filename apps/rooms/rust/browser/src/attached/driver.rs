//! Bounded application work on one continuously polled local executor. The
//! stop signal bypasses admission. Dropping a JS observation retains its job.
use super::{Environment, Result, TroubleReporter, js_error, rejected};
use std::{
	cell::{Cell, RefCell},
	future::Future,
	pin::Pin,
	rc::Rc,
};
use tokio::{
	sync::{mpsc, oneshot, watch},
	task::{JoinSet, LocalSet},
};
use wasm_bindgen::JsValue;
mod held;
pub(super) use held::Held;

// Count bounds task/callback overhead; bytes bound retained command material.
// Both queued and executing work hold a permit until their future is dropped.
const MAX_TASKS: usize = 64;
pub(super) const MAX_BYTES: usize = 4 * 1024 * 1024;
type Work = Pin<Box<dyn Future<Output = Result<JsValue>>>>;
type Start = Box<dyn FnOnce(Rc<Environment>) -> Work>;
struct Budget {
	tasks: Cell<usize>,
	bytes: Cell<usize>,
	stopped: Rc<Cell<bool>>,
	handles: Cell<usize>,
	held_bytes: Cell<usize>,
	retain_failed_close: Cell<bool>,
}
struct Permit {
	budget: Rc<Budget>,
	bytes: usize,
}
impl Drop for Permit {
	fn drop(&mut self) {
		self.budget.tasks.set(self.budget.tasks.get() - 1);
		self.budget.bytes.set(self.budget.bytes.get() - self.bytes);
	}
}
struct Job {
	work: Start,
	reply: Option<oneshot::Sender<Result<JsValue>>>,
	permit: Permit,
}
struct Inner {
	local: Rc<LocalSet>,
	jobs: mpsc::Sender<Job>,
	stop: watch::Sender<bool>,
	ended: watch::Receiver<Option<Result<()>>>,
	completion: watch::Sender<Option<Result<()>>>,
	retry: watch::Sender<bool>,
	retiring: Rc<RefCell<Option<Retirement>>>,
	budget: Rc<Budget>,
}
impl Drop for Inner {
	fn drop(&mut self) {
		let _entered = self.local.enter();
		self.budget.retain_failed_close.set(false);
		self.retiring.borrow_mut().take();
		self.budget.stop();
		self.stop.send_replace(true);
	}
}
#[derive(Clone)]
pub(super) struct Driver(Rc<Inner>);
// Network serving must keep running while a failed managed barrier waits for
// retry. It may carry the exact reply needed by receipt settlement. Retaining
// only Environment and dropping this JoinSet would cancel that recovery path.
struct Retirement {
	environment: Rc<Environment>,
	serving: JoinSet<Result<()>>,
	failure: Result<()>,
}
impl Budget {
	fn stop(&self) {
		self.stopped.set(true);
	}
}
impl Driver {
	// JS exports may synchronously release capabilities. Their finalizers must
	// schedule onto this same continuously driven executor, not an absent
	// ambient Tokio context or a second per-call LocalSet.
	pub fn with_local<T>(&self, work: impl FnOnce() -> T) -> T {
		let _entered = self.0.local.enter();
		work()
	}

	pub fn require_open(&self) -> Result<()> {
		if self.0.budget.stopped.get() {
			Err("Rooms application is closed".into())
		} else {
			Ok(())
		}
	}
	pub fn start_managed(
		tab: String,
		report_trouble: js_sys::Function,
		admission: rooms_application::admission::Settings,
	) -> Self {
		Self::start_mode(tab, report_trouble, admission)
	}
	fn start_mode(
		startup: String,
		report_trouble: js_sys::Function,
		admission: rooms_application::admission::Settings,
	) -> Self {
		let (jobs, incoming) = mpsc::channel(MAX_TASKS);
		let (stop, stopping) = watch::channel(false);
		let (ended, outcome) = watch::channel(None);
		let stopped = Rc::new(Cell::new(false));
		let trouble = TroubleReporter {
			callback: report_trouble,
			stopped: stopped.clone(),
		};
		let budget = Rc::new(Budget {
			tasks: Cell::new(0),
			bytes: Cell::new(0),
			stopped,
			handles: Cell::new(0),
			held_bytes: Cell::new(0),
			retain_failed_close: Cell::new(true),
		});
		let owned_budget = budget.clone();
		let local = Rc::new(LocalSet::new());
		let running = local.clone();
		let retiring = Rc::new(RefCell::new(None));
		let pending_retirement = retiring.clone();
		let completion = ended.clone();
		let (retry, mut retries) = watch::channel(false);
		wasm_bindgen_futures::spawn_local(async move {
			running
				.run_until(async move {
					let result = run(
						incoming,
						stopping,
						owned_budget.clone(),
						startup,
						admission,
						trouble,
						pending_retirement.clone(),
					)
					.await;
					owned_budget.stop();
					ended.send_replace(Some(result));
					// Keep driving the original LocalSet between failed close attempts.
					// Network replies and private settlement cannot depend on the user
					// immediately asking to close again. One owner performs all retries.
					while pending_retirement.borrow().is_some() && owned_budget.retain_failed_close.get() {
						if retries.changed().await.is_err() || !owned_budget.retain_failed_close.get() {
							break;
						}
						retries.borrow_and_update();
						let Some(mut retirement) = pending_retirement.borrow_mut().take() else {
							break;
						};
						let closed = retirement.environment.close().await;
						let outcome = if closed.is_err() {
							let outcome = super::retain(retirement.failure.clone(), closed);
							if owned_budget.retain_failed_close.get() {
								*pending_retirement.borrow_mut() = Some(retirement);
							}
							outcome
						} else {
							// Drained failures are terminal evidence. Retrying an empty
							// JoinSet cannot turn a failed task into successful close.
							super::retain(retirement.failure, drain(&mut retirement.serving).await)
						};
						ended.send_replace(Some(outcome));
					}
					pending_retirement.borrow_mut().take();
				})
				.await;
		});
		Self(Rc::new(Inner {
			local,
			jobs,
			stop,
			ended: outcome,
			completion,
			retry,
			retiring,
			budget,
		}))
	}
	pub fn submit<F, W>(&self, bytes: usize, start: F) -> js_sys::Promise
	where
		F: FnOnce(Rc<Environment>) -> W + 'static,
		W: Future<Output = Result<JsValue>> + 'static,
	{
		let (reply, answer) = oneshot::channel();
		if let Err(error) = self.enqueue(bytes, start, Some(reply)) {
			return rejected(error);
		}
		wasm_bindgen_futures::future_to_promise(async move {
			answer
				.await
				.map_err(|_| js_error("Rooms application closed before answering"))?
				.map_err(|error| js_error(&error))
		})
	}
	fn enqueue<F, W>(&self, bytes: usize, start: F, reply: Option<oneshot::Sender<Result<JsValue>>>) -> Result<()>
	where
		F: FnOnce(Rc<Environment>) -> W + 'static,
		W: Future<Output = Result<JsValue>> + 'static,
	{
		let budget = &self.0.budget;
		if budget.stopped.get() {
			return Err("Rooms application is closed".into());
		}
		if budget.tasks.get() >= MAX_TASKS || bytes > MAX_BYTES.saturating_sub(budget.bytes.get()) {
			return Err("Rooms application work capacity is exhausted".into());
		}
		budget.tasks.set(budget.tasks.get() + 1);
		budget.bytes.set(budget.bytes.get() + bytes);
		let permit = Permit {
			budget: budget.clone(),
			bytes,
		};
		let job = Job {
			work: Box::new(move |environment| Box::pin(start(environment))),
			reply,
			permit,
		};
		self.0
			.jobs
			.try_send(job)
			.map_err(|_| "Rooms application stopped accepting work".into())
	}
	pub fn stop(&self) {
		self.with_local(|| {
			self.0.budget.retain_failed_close.set(false);
			self.0.budget.stop();
			self.0.retiring.borrow_mut().take();
		});
		self.0.stop.send_replace(true);
		self.0.retry.send_replace(true);
	}
	pub fn close(&self) -> js_sys::Promise {
		self.with_local(|| self.0.budget.stop());
		self.0.stop.send_replace(true);
		// The continuously driven owner retries once for concurrent callers.
		// Clearing completion synchronously makes every caller await that retry.
		if self.0.ended.borrow().is_some() && self.0.retiring.borrow().is_some() {
			self.0.completion.send_replace(None);
			self.0.retry.send_replace(true);
		}
		let mut ended = self.0.ended.clone();
		wasm_bindgen_futures::future_to_promise(async move {
			while ended.borrow().is_none() {
				ended
					.changed()
					.await
					.map_err(|_| js_error("Rooms application retirement lost its owner"))?;
			}
			ended
				.borrow()
				.as_ref()
				.expect("terminal application outcome")
				.clone()
				.map(|()| JsValue::UNDEFINED)
				.map_err(|error| js_error(&error))
		})
	}
}
async fn run(
	mut incoming: mpsc::Receiver<Job>,
	mut stop: watch::Receiver<bool>,
	budget: Rc<Budget>,
	startup: String,
	admission: rooms_application::admission::Settings,
	trouble: TroubleReporter,
	retiring: Rc<RefCell<Option<Retirement>>>,
) -> Result<()> {
	let (platform, prepared) = match Environment::prepare(&startup).await {
		Ok(prepared) => prepared,
		Err(error) => {
			// Storage preflight refused before any Host or session existed.
			// Requests observe the startup cause; close observes clean retirement.
			incoming.close();
			while let Ok(job) = incoming.try_recv() {
				if let Some(reply) = job.reply {
					let _ = reply.send(Err(error.clone()));
				}
			}
			return Ok(());
		}
	};
	let environment = match Environment::open(platform, prepared, trouble, admission).await {
		Ok(environment) => Rc::new(environment),
		Err(error) => {
			incoming.close();
			while let Ok(job) = incoming.try_recv() {
				if let Some(reply) = job.reply {
					let _ = reply.send(Err(error.clone()));
				}
			}
			return Err(error);
		}
	};
	let mut tasks = JoinSet::<Result<()>>::new();
	let mut serving = JoinSet::<Result<()>>::new();
	let mut failure = Ok(());
	while !*stop.borrow() {
		tokio::select! {
			biased;
			_ = stop.changed() => break,
			completed = tasks.join_next(), if !tasks.is_empty() => {
				match completed {
					Some(Err(error)) => {
						failure = Err(format!("Rooms application task failed: {error}"));
						break;
					},
					Some(Ok(Err(error))) => report(&error),
					_ => {},
				}
			}
			completed = serving.join_next(), if !serving.is_empty() => {
				match completed {
					Some(Err(error)) => {
						failure = Err(format!("Rooms serving task failed: {error}"));
						break;
					},
					Some(Ok(Err(error))) => report(&error),
					_ => {},
				}
			}
			job = incoming.recv() => {
				let Some(job) = job else { break };
				let environment = environment.clone();
				let owner = if job.reply.is_some() { &mut tasks } else { &mut serving };
				owner.spawn_local(async move {
					let Job { work, reply, permit } = job;
					let outcome = work(environment).await;
					let unobserved = match reply {
						Some(reply) => {
							// Retirement cannot replace an operation's actual failure.
							let outcome = if permit.budget.stopped.get() && outcome.is_ok() { Err("Rooms application closed while the request was pending".into()) } else { outcome };
							match reply.send(outcome) {
								Err(Err(error)) => Err(error),
								_ => Ok(()),
							}
						},
						None => outcome.map(|_| ()),
					};
					drop(permit);
					unobserved
				});
			}
		}
	}
	budget.stop();
	incoming.close();
	// Cancel application-owned observations, including opening handshakes,
	// before retiring Host resources. Serving workers remain driven so their
	// terminal outcomes and cleanup failures survive application shutdown.
	while incoming.try_recv().is_ok() {}
	tasks.abort_all();
	failure = super::retain(failure, drain(&mut tasks).await);
	let close = environment.close().await;
	if close.is_err() {
		if budget.retain_failed_close.get() {
			*retiring.borrow_mut() = Some(Retirement {
				environment,
				serving,
				failure: failure.clone(),
			});
		}
		return super::retain(failure, close);
	}
	failure = super::retain(failure, close);
	failure = super::retain(failure, drain(&mut serving).await);
	failure
}

// While running, failures without a Promise observer have this diagnostic
// owner. During shutdown, drain transfers them to the close barrier instead.
// Reporting immediately avoids an unbounded history of completed task errors.
pub(super) fn report(error: &str) {
	web_sys::console::error_1(&format!("Rooms unobserved operation failed: {error}").into());
}

async fn drain(tasks: &mut JoinSet<Result<()>>) -> Result<()> {
	let mut result = Ok(());
	while let Some(outcome) = tasks.join_next().await {
		match outcome {
			Ok(outcome) => result = super::retain(result, outcome),
			Err(error) if !error.is_cancelled() => result = super::retain(result, Err(error.to_string())),
			Err(_) => {}
		}
	}
	result
}
