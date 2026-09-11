//! Bounded application work on one continuously polled local executor. The
//! stop signal bypasses admission; dropping a JS observation retains its job.
use super::{js_error, observation::Scope, rejected, Environment, Result};
use std::{
	cell::{Cell, RefCell},
	future::Future,
	pin::Pin,
	rc::{Rc, Weak},
};
use tokio::{
	sync::{mpsc, oneshot, watch},
	task::{JoinSet, LocalSet},
};
use wasm_bindgen::JsValue;

// Count bounds task/callback overhead; bytes bound retained command material.
// Both queued and executing work hold a permit until their future is dropped.
const MAX_TASKS: usize = 64;
pub(super) const MAX_BYTES: usize = 4 * 1024 * 1024;
type Work = Pin<Box<dyn Future<Output = Result<JsValue>>>>;
type Start = Box<dyn FnOnce(Rc<Environment>) -> Work>;
struct Budget {
	tasks: Cell<usize>,
	bytes: Cell<usize>,
	stopped: Cell<bool>,
	files: Cell<usize>,
	metadata: Cell<usize>,
	scopes: RefCell<Vec<Weak<Scope>>>,
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
	budget: Rc<Budget>,
}
impl Drop for Inner {
	fn drop(&mut self) {
		let _entered = self.local.enter();
		self.budget.stop();
		self.stop.send_replace(true);
	}
}
#[derive(Clone)]
pub(super) struct Driver(Rc<Inner>);
pub(super) struct Retained {
	budget: Rc<Budget>,
	bytes: usize,
}
impl Drop for Retained {
	fn drop(&mut self) {
		self.budget.files.set(self.budget.files.get() - 1);
		self.budget.metadata.set(self.budget.metadata.get() - self.bytes);
	}
}
impl Budget {
	fn stop(&self) {
		self.stopped.set(true);
		let scopes = std::mem::take(&mut *self.scopes.borrow_mut());
		for scope in scopes.into_iter().filter_map(|scope| scope.upgrade()) {
			scope.close();
		}
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
	pub fn scope(&self) -> Result<Rc<Scope>> {
		self.require_open()?;
		let mut scopes = self.0.budget.scopes.borrow_mut();
		scopes.retain(|scope| scope.strong_count() > 0);
		if scopes.len() >= MAX_TASKS {
			return Err("Rooms attachment capacity is exhausted".into());
		}
		let scope = Rc::new(Scope::default());
		scopes.push(Rc::downgrade(&scope));
		Ok(scope)
	}
	pub fn retain_file(&self, bytes: usize) -> Result<Retained> {
		self.require_open()?;
		let budget = &self.0.budget;
		if budget.files.get() >= rooms_application::files::FileLimits::default().held_files
			|| bytes > MAX_BYTES.saturating_sub(budget.metadata.get())
		{
			return Err("Rooms file view custody capacity is exhausted".into());
		}
		budget.files.set(budget.files.get() + 1);
		budget.metadata.set(budget.metadata.get() + bytes);
		Ok(Retained {
			budget: budget.clone(),
			bytes,
		})
	}
	pub fn start() -> Self {
		Self::start_mode(None)
	}
	pub fn start_local(checkpoint: rooms_application::session::checkpoint::Checkpoint) -> Self {
		Self::start_mode(Some(checkpoint))
	}
	fn start_mode(checkpoint: Option<rooms_application::session::checkpoint::Checkpoint>) -> Self {
		let (jobs, incoming) = mpsc::channel(MAX_TASKS);
		let (stop, stopping) = watch::channel(false);
		let (ended, outcome) = watch::channel(None);
		let budget = Rc::new(Budget {
			tasks: Cell::new(0),
			bytes: Cell::new(0),
			stopped: Cell::new(false),
			files: Cell::new(0),
			metadata: Cell::new(0),
			scopes: RefCell::default(),
		});
		let owned_budget = budget.clone();
		let local = Rc::new(LocalSet::new());
		let running = local.clone();
		wasm_bindgen_futures::spawn_local(async move {
			let result = running
				.run_until(run(incoming, stopping, owned_budget.clone(), checkpoint))
				.await;
			owned_budget.stop();
			ended.send_replace(Some(result));
		});
		Self(Rc::new(Inner {
			local,
			jobs,
			stop,
			ended: outcome,
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
	pub fn background<F, W>(&self, bytes: usize, start: F) -> Result<()>
	where
		F: FnOnce(Rc<Environment>) -> W + 'static,
		W: Future<Output = Result<JsValue>> + 'static,
	{
		self.enqueue(bytes, start, None)
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
		self.with_local(|| self.0.budget.stop());
		self.0.stop.send_replace(true);
	}
	pub fn close(&self) -> js_sys::Promise {
		self.stop();
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
	checkpoint: Option<rooms_application::session::checkpoint::Checkpoint>,
) -> Result<()> {
	let environment = match Environment::open(checkpoint).await {
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
	failure = super::retain(failure, environment.close().await);
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
