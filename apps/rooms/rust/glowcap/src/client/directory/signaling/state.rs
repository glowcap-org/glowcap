use super::*;
use std::{
	future::poll_fn,
	task::{Poll, Waker},
};
#[derive(Default)]
pub(super) struct State {
	pub core: policy::Exchange<Error>,
	waiters: Vec<(u64, Waker)>,
	worker: Option<Waker>,
	serial: u64,
}
pub(super) fn wake(state: &Rc<RefCell<State>>) {
	let (waiters, worker) = {
		let mut state = state.borrow_mut();
		(core::mem::take(&mut state.waiters), state.worker.take())
	};
	if let Some(worker) = worker {
		worker.wake();
	}
	for (_, wake) in waiters {
		wake.wake();
	}
}
struct Observation {
	state: Rc<RefCell<State>>,
	ticket: Option<u64>,
}
impl Drop for Observation {
	fn drop(&mut self) {
		if let Some(ticket) = self.ticket {
			let mut state = self.state.borrow_mut();
			state.waiters.retain(|(key, _)| *key != ticket);
			if state.waiters.is_empty() {
				state.waiters = Vec::new();
			}
		}
	}
}
pub(super) async fn wait<T>(
	state: &Rc<RefCell<State>>,
	mut decide: impl FnMut(&mut policy::Exchange<Error>) -> Result<Option<T>, Error>,
) -> Result<T, Error> {
	let mut held = Observation {
		state: state.clone(),
		ticket: None,
	};
	poll_fn(|cx| {
		let mut s = state.borrow_mut();
		match decide(&mut s.core) {
			Ok(Some(value)) => return Poll::Ready(Ok(value)),
			Err(error) => return Poll::Ready(Err(error)),
			Ok(None) => {}
		}
		if let Some(ticket) = held.ticket
			&& let Some((_, wake)) = s.waiters.iter_mut().find(|(key, _)| *key == ticket)
		{
			*wake = cx.waker().clone();
			return Poll::Pending;
		}
		if s.waiters.len() == policy::MAX_EVENTS {
			return Poll::Ready(Err(policy::Error::Full.into()));
		}
		let Some(serial) = s.serial.checked_add(1) else {
			return Poll::Ready(Err(policy::Error::Full.into()));
		};
		s.serial = serial;
		held.ticket = Some(serial);
		s.waiters.push((serial, cx.waker().clone()));
		Poll::Pending
	})
	.await
}
#[derive(Clone, Default)]
pub(crate) struct Registry(Rc<RefCell<Entries>>);
#[derive(Default)]
struct Entries {
	live: Vec<Entry>,
	failure: Option<CleanupFailure>,
}
struct Entry {
	designator: policy::Id,
	state: std::rc::Weak<RefCell<State>>,
}
pub struct CleanupFailure {
	pub first: Error,
	pub count: usize,
}
impl Registry {
	pub(super) fn same(&self, other: &Self) -> bool {
		Rc::ptr_eq(&self.0, &other.0)
	}
	pub(super) fn insert(&self, designator: &policy::Id, state: &Rc<RefCell<State>>) -> Result<(), Error> {
		let mut entries = self.0.borrow_mut();
		entries
			.live
			.retain(|entry| entry.state.upgrade().is_some_and(|state| !state.borrow().core.ended()));
		if entries.live.iter().any(|entry| &entry.designator == designator) {
			return Err(policy::Error::Duplicate.into());
		}
		if entries.live.len() == policy::MAX_EXCHANGES {
			return Err(policy::Error::Full.into());
		}
		entries.live.push(Entry {
			designator: designator.clone(),
			state: Rc::downgrade(state),
		});
		Ok(())
	}
	pub(super) fn remove(&self, state: &Rc<RefCell<State>>) {
		let exact = Rc::downgrade(state);
		let mut entries = self.0.borrow_mut();
		entries.live.retain(|entry| !entry.state.ptr_eq(&exact));
		if entries.live.is_empty() {
			entries.live = Vec::new();
		}
	}
	pub(super) fn failed(&self, error: Error) {
		let mut entries = self.0.borrow_mut();
		if let Some(failure) = &mut entries.failure {
			failure.count = failure.count.saturating_add(1);
		} else {
			entries.failure = Some(CleanupFailure { first: error, count: 1 });
		}
	}
	pub(super) fn take_failure(&self) -> Option<CleanupFailure> {
		self.0.borrow_mut().failure.take()
	}
}

// The owned handshake has a reserved wake slot. A full caller-observer table
// can refuse another observer, but cannot prevent the exchange from settling.
pub(super) async fn settled(state: &Rc<RefCell<State>>) -> Result<(), Error> {
	poll_fn(|cx| {
		let mut state = state.borrow_mut();
		match state.core.settled() {
			Some(result) => Poll::Ready(result),
			None => {
				state.worker = Some(cx.waker().clone());
				Poll::Pending
			}
		}
	})
	.await
}
