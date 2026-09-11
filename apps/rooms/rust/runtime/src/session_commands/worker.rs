use super::*;
use std::{collections::VecDeque, time::Duration};

const RETRY_FLOOR: Duration = Duration::from_secs(1);
const RETRY_CEILING: Duration = Duration::from_secs(30);
struct PendingFact {
	fact: Fact,
	guard: Option<FactGuard>,
	first: Option<oneshot::Sender<Result<(), String>>>,
	_permit: Permit,
}
pub struct SessionWorker<S: Documents, G: Entropy, C: Clock> {
	clock: C,
	state: DurableSession<S, G>,
	rx: mpsc::Receiver<Envelope>,
	stop: watch::Receiver<bool>,
	done: watch::Sender<Option<Result<(), String>>>,
	admitting: Rc<Cell<bool>>,
	view: SessionView,
	facts: VecDeque<PendingFact>,
	retry_at: Option<C::Instant>,
	delay: Duration,
	last_failure: Option<String>,
}
impl<S: Documents, G: Entropy, C: Clock> SessionWorker<S, G, C> {
	pub(super) fn new(
		state: DurableSession<S, G>,
		rx: mpsc::Receiver<Envelope>,
		stop: watch::Receiver<bool>,
		done: watch::Sender<Option<Result<(), String>>>,
		admitting: Rc<Cell<bool>>,
		view: SessionView,
		clock: C,
	) -> Self {
		Self {
			clock,
			state,
			rx,
			stop,
			done,
			admitting,
			view,
			facts: VecDeque::new(),
			retry_at: None,
			delay: RETRY_FLOOR,
			last_failure: None,
		}
	}
	/// Owns the state until shutdown. Cancellation retires the owner and all
	/// replies; document workers retain their lease until underlying I/O finishes.
	pub async fn run(mut self, mut events: impl SessionEvents) -> Result<(), String> {
		let result = async {
			events.settled(&self.view).await?;
			self.drive(&mut events).await?;
			events.settled(&self.view).await
		}
		.await;
		self.admitting.set(false);
		self.rx.close();
		self.refuse_pending("Rooms session command owner stopped");
		self.done.send_replace(Some(result.clone()));
		result
	}
	async fn drive(&mut self, events: &mut impl SessionEvents) -> Result<(), String> {
		loop {
			self.discard_retired(events);
			if *self.stop.borrow() || self.stop.has_changed().is_err() {
				self.admitting.set(false);
				self.rx.close();
				// Owned permits held by unsent admissions must not stall close.
				while let Ok(request) = self.rx.try_recv() {
					self.receive(request, events).await?;
				}
				self.discard_retired(events);
				return if self.facts.is_empty() {
					Ok(())
				} else {
					Err(format!(
						"Rooms session closed with {} unsynchronized facts{}",
						self.facts.len(),
						self.last_failure.as_ref().map(|v| format!(": {v}")).unwrap_or_default()
					))
				};
			}
			if !self.facts.is_empty() && self.retry_at.is_none_or(|at| at <= self.clock.now()) {
				self.synchronize(events).await?;
				continue;
			}
			let request = if let Some(at) = self.retry_at {
				tokio::select! { request = self.rx.recv() => request, _ = self.stop.changed() => continue,
				_ = retired(&mut self.facts) => continue,
				_ = self.clock.sleep_until(at) => continue }
			} else {
				tokio::select! { request = self.rx.recv() => request, _ = self.stop.changed() => continue }
			};
			match request {
				Some(request) => self.receive(request, events).await?,
				None => {
					if self.facts.is_empty() {
						return Ok(());
					}
					return Err("Rooms session callers retired with unsynchronized facts".into());
				}
			}
		}
	}
	async fn receive(&mut self, request: Envelope, events: &mut impl SessionEvents) -> Result<(), String> {
		let Envelope { work, permit } = request;
		match work {
			Work::Fact { fact, answer, guard } => self.facts.push_back(PendingFact {
				fact,
				guard,
				first: Some(answer),
				_permit: permit,
			}),
			Work::Transaction(transaction) => {
				transaction.execute(&mut self.state, events, &self.view).await;
				drop(permit);
				self.usable()?;
			}
		}
		Ok(())
	}
	async fn synchronize(&mut self, events: &mut impl SessionEvents) -> Result<(), String> {
		self.discard_retired(events);
		if self.facts.is_empty() {
			return Ok(());
		}
		let pending = self.facts.front_mut().expect("pending reconciliation");
		let result = async {
			events
				.settled(&self.view)
				.await
				.map_err(crate::session_state::Error::Effects)?;
			if let Some(change) = self.state.reconcile_fact(&pending.fact).await? {
				events.changed(change, &self.view);
			}
			events
				.settled(&self.view)
				.await
				.map_err(crate::session_state::Error::Effects)
		}
		.await;
		match result {
			Ok(()) => {
				events.reconciliation_issue(&pending.fact, None);
				if let Some(first) = pending.first.take() {
					let _ = first.send(Ok(()));
				}
				self.facts.pop_front();
				self.last_failure = None;
				self.retry_at = None;
				self.delay = RETRY_FLOOR;
			}
			Err(error) => {
				let error = error.to_string();
				events.reconciliation_issue(&pending.fact, Some(&error));
				if let Some(first) = pending.first.take() {
					let _ = first.send(Err(error.clone()));
				}
				self.last_failure = Some(error);
				self.retry_at = Some(self.clock.now() + self.delay);
				self.delay = self.delay.saturating_mul(2).min(RETRY_CEILING);
				self.usable()?;
			}
		}
		Ok(())
	}
	fn discard_retired(&mut self, events: &mut impl SessionEvents) {
		let mut index = 0;
		while index < self.facts.len() {
			if self.facts[index].guard.as_ref().is_some_and(|guard| !guard.current()) {
				let mut pending = self.facts.remove(index).expect("pending fact index");
				events.reconciliation_issue(&pending.fact, None);
				if let Some(first) = pending.first.take() {
					let _ = first.send(Err("the runtime fact scope retired before admission".into()));
				}
				if index == 0 {
					self.retry_at = None;
					self.delay = RETRY_FLOOR;
					self.last_failure = None;
				}
			} else {
				index += 1;
			}
		}
	}
	fn usable(&self) -> Result<(), String> {
		self.state
			.state()
			.and_then(|s| s.revision().map_err(Into::into))
			.map(|_| ())
			.map_err(|e| format!("Rooms session storage requires recovery: {e}"))
	}
	fn refuse_pending(&mut self, reason: &str) {
		while let Ok(Envelope { work, .. }) = self.rx.try_recv() {
			match work {
				Work::Transaction(transaction) => transaction.refuse(reason),
				Work::Fact { answer, .. } => {
					let _ = answer.send(Err(reason.into()));
				}
			}
		}
		for pending in self.facts.drain(..) {
			if let Some(first) = pending.first {
				let _ = first.send(Err(reason.into()));
			}
		}
	}
}
impl<S: Documents, G: Entropy, C: Clock> Drop for SessionWorker<S, G, C> {
	fn drop(&mut self) {
		self.admitting.set(false);
		self.rx.close();
		self.refuse_pending("Rooms session worker was cancelled");
		if self.done.borrow().is_none() {
			self.done
				.send_replace(Some(Err("Rooms session worker was cancelled".into())));
		}
	}
}

async fn retired(facts: &mut VecDeque<PendingFact>) {
	use std::{future::Future, task::Poll};
	// At most MAX_PENDING_FACTS waiters. Keep watch futures alive across polls:
	// dropping a pending changed() future would unregister its wakeup.
	let mut waiters: Vec<_> = facts
		.iter_mut()
		.filter_map(|fact| fact.guard.as_mut())
		.map(|guard| Box::pin(guard.retired()))
		.collect();
	std::future::poll_fn(|cx| {
		for waiter in &mut waiters {
			if waiter.as_mut().poll(cx).is_ready() {
				return Poll::Ready(());
			}
		}
		Poll::Pending
	})
	.await
}
