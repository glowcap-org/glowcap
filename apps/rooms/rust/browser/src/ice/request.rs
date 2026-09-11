use super::*;
use tokio::sync::Notify;
use web_sys::AbortController;

type Outcome = Result<Rc<Servers>, Error>;
pub(super) struct Attempt {
	abort: AbortController,
	reason: RefCell<Option<Error>>,
	result: RefCell<Option<Outcome>>,
	running: Cell<bool>,
	retirement_failed: Cell<bool>,
	observers: Cell<usize>,
	changed: Notify,
}
// Declared before the fetch future: cancellation drops that future and its
// browser resources before publishing the task's retirement.
struct Worker(Rc<Attempt>);
impl Drop for Worker {
	fn drop(&mut self) {
		self.0.abort.abort();
		if self.0.result.borrow().is_none() {
			self.0.retirement_failed.set(true);
			*self.0.result.borrow_mut() = Some(Err(Error::Platform("Rooms ICE worker ended without a result")));
		}
		self.0.running.set(false);
		self.0.changed.notify_waiters();
	}
}
struct Observer<'a>(&'a Cell<usize>);
impl Drop for Observer<'_> {
	fn drop(&mut self) {
		self.0.set(self.0.get() - 1);
	}
}
impl Attempt {
	pub(super) fn start(url: &str) -> Result<Rc<Self>, Error> {
		let attempt = Rc::new(Self {
			abort: AbortController::new().map_err(|_| Error::Platform("creating ICE cancellation failed"))?,
			reason: RefCell::new(None),
			result: RefCell::new(None),
			running: Cell::new(true),
			retirement_failed: Cell::new(false),
			observers: Cell::new(0),
			changed: Notify::new(),
		});
		let worker = Worker(attempt.clone());
		let url = url.to_owned();
		// The LocalSet is the application's executor. It drives this owner even
		// if every current request observer disappears.
		tokio::task::spawn_local(async move {
			let worker = worker;
			let work = fetch::read(&url, &worker.0.abort);
			tokio::pin!(work);
			let result = tokio::select! {
				result = &mut work => result,
				() = gloo_timers::future::TimeoutFuture::new(FETCH_TIMEOUT_MS) => {
					worker.0.abort(Error::Timeout);
					// Fetch abort rejects its outstanding fetch/body promise. Await
					// that same future so JsFuture releases both Rust callbacks.
					work.await
				},
			};
			*worker.0.result.borrow_mut() = Some(match worker.0.reason.borrow().clone() {
				Some(reason) => Err(reason),
				None => result.map(Rc::new),
			});
		});
		Ok(attempt)
	}
	pub(super) fn running(&self) -> bool {
		self.running.get()
	}
	pub(super) fn abort(&self, reason: Error) {
		if self.running.get() {
			self.reason.borrow_mut().get_or_insert(reason);
			self.abort.abort();
		}
	}
	pub(super) async fn retired(&self) -> Result<(), Error> {
		loop {
			let changed = self.changed.notified();
			tokio::pin!(changed);
			changed.as_mut().enable();
			if !self.running.get() {
				return if self.retirement_failed.get() {
					Err(Error::Platform("ICE worker ended before fetch retirement was observed"))
				} else {
					Ok(())
				};
			}
			changed.await;
		}
	}
	pub(super) async fn observe(&self) -> Outcome {
		let count = self.observers.get();
		if count == MAX_OBSERVERS {
			return Err(Error::Busy);
		}
		self.observers.set(count + 1);
		let _observer = Observer(&self.observers);
		self.retired().await?;
		self.result.borrow().clone().expect("retired request result")
	}
}
