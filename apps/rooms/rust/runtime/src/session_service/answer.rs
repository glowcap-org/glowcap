//! Bounded deferred work owned by the session facet, including file replies.
use super::{
	error::Error,
	notice::{Notice, Report},
};
use glowcap::{current_session, Argument};
use std::{
	cell::{Cell, RefCell},
	collections::BTreeMap,
	future::Future,
	rc::{Rc, Weak},
};
use tokio::{sync::Notify, task::JoinHandle};
const MAX_PENDING: usize = 256;
#[derive(Clone)]
pub(super) struct Answers(Rc<State>);
struct State {
	closed: Cell<bool>,
	next: Cell<u64>,
	pending: RefCell<BTreeMap<u64, JoinHandle<()>>>,
	changed: Notify,
}
struct Retire {
	state: Weak<State>,
	id: u64,
}
impl Drop for Retire {
	fn drop(&mut self) {
		if let Some(state) = self.state.upgrade() {
			state.pending.borrow_mut().remove(&self.id);
			state.changed.notify_waiters();
		}
	}
}
impl Answers {
	pub fn new() -> Self {
		Self(Rc::new(State {
			closed: Cell::new(false),
			next: Cell::new(0),
			pending: RefCell::new(BTreeMap::new()),
			changed: Notify::new(),
		}))
	}
	fn admit(&self) -> Result<u64, Error> {
		if self.0.closed.get() {
			return Err(Error::refused("session deferred work is closed"));
		}
		if self.0.pending.borrow().len() >= MAX_PENDING {
			return Err(Error::refused("session deferred work is full"));
		}
		let id = self.0.next.get();
		self.0.next.set(
			id.checked_add(1)
				.ok_or_else(|| Error::refused("session deferred work identifiers exhausted"))?,
		);
		Ok(id)
	}
	fn start(&self, id: u64, work: impl Future<Output = ()> + 'static) {
		// Construct custody before spawning, so cancellation before first poll
		// still releases this admission. Local spawn does not poll inline.
		let retire = Retire {
			state: Rc::downgrade(&self.0),
			id,
		};
		let task = tokio::task::spawn_local(async move {
			let _retire = retire;
			work.await;
		});
		self.0.pending.borrow_mut().insert(id, task);
	}
	pub fn spawn(&self, work: impl Future<Output = ()> + 'static) -> Result<(), Error> {
		let id = self.admit()?;
		self.start(id, work);
		Ok(())
	}
	pub fn later(
		&self,
		report: Report,
		verb: &'static str,
		work: impl Future<Output = Result<Argument, Error>> + 'static,
	) -> Result<Argument, Error> {
		let id = self.admit()?;
		let session = current_session()?
			.ok_or_else(|| Error::refused("a deferred Rooms answer is reachable only over a session"))?
			.borrowed();
		let mut deferred = session.host().defer_turn()?;
		self.start(id, async move {
			let delivery = match work.await {
				Ok(value) => deferred.fulfill(&value),
				Err(error) => deferred.break_with(&error.to_string()),
			};
			if let Err(cause) = delivery {
				if session.is_open() {
					report(Notice::AnswerUndeliverable {
						verb,
						cause: cause.into(),
					});
				}
			}
		});
		Ok(Argument::Void)
	}
	pub fn stop(&self) {
		self.0.closed.set(true);
		for task in self.0.pending.borrow().values() {
			task.abort();
		}
	}
	/// Observe cancellation before the embedding closes the named execution
	/// owners. Durable workers retain their already admitted effects independently.
	pub async fn close(&self) {
		self.stop();
		while !self.0.pending.borrow().is_empty() {
			self.0.changed.notified().await;
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	struct Held(Rc<Cell<usize>>);
	impl Drop for Held {
		fn drop(&mut self) {
			self.0.set(self.0.get() + 1);
		}
	}
	#[tokio::test]
	async fn close_retires_running_and_unpolled_work_before_returning() {
		tokio::task::LocalSet::new()
			.run_until(async {
				let owner = Answers::new();
				let released = Rc::new(Cell::new(0));
				let held = Held(released.clone());
				let (started, waiting) = tokio::sync::oneshot::channel();
				owner
					.spawn(async move {
						let _held = held;
						started.send(()).unwrap();
						std::future::pending::<()>().await;
					})
					.unwrap();
				waiting.await.unwrap();
				for _ in 1..MAX_PENDING {
					let held = Held(released.clone());
					owner
						.spawn(async move {
							let _held = held;
							std::future::pending::<()>().await;
						})
						.unwrap();
				}
				assert!(owner.spawn(async {}).is_err());
				assert_eq!(released.get(), 0);
				// Stop without letting the newly queued work run first.
				owner.stop();
				owner.close().await;
				assert_eq!(released.get(), MAX_PENDING);
				assert!(owner.spawn(async {}).is_err());
				owner.close().await;
			})
			.await;
	}
}
