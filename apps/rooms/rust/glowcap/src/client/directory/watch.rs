use super::*;
use directory::{Event, Snapshot, queue::Queue};
use std::{
	cell::RefCell,
	future::poll_fn,
	task::{Poll, Waker},
};

#[derive(Default)]
struct State {
	queue: Queue,
	waiter: Option<Waker>,
}
/// Watch replacement is scoped to the held directory on this connection.
/// Distinct directories may share a Host/session without sharing their views.
#[derive(Clone, Default)]
pub(crate) struct Registry(Rc<RefCell<Vec<Entry>>>);
struct Entry {
	directory: Ref,
	state: std::rc::Weak<RefCell<State>>,
}
impl Registry {
	fn replace(&self, reference: &Ref, state: &Rc<RefCell<State>>) {
		let prior = {
			let mut entries = self.0.borrow_mut();
			if let Some(entry) = entries.iter_mut().find(|entry| &entry.directory == reference) {
				Some(core::mem::replace(&mut entry.state, Rc::downgrade(state)))
			} else {
				entries.push(Entry {
					directory: reference.clone(),
					state: Rc::downgrade(state),
				});
				None
			}
		};
		if let Some(prior) = prior.and_then(|v| v.upgrade()) {
			close(&prior);
		}
	}
	fn remove(&self, state: &Rc<RefCell<State>>) {
		let mut entries = self.0.borrow_mut();
		let exact = Rc::downgrade(state);
		entries.retain(|entry| !entry.state.ptr_eq(&exact));
		if entries.is_empty() {
			*entries = Vec::new();
		}
	}
}
struct Registration<D: Tasks> {
	state: Rc<RefCell<State>>,
	registry: Registry,
	_observer: Ref,
	_client: Client<D>,
	closed: Option<D::Task>,
}
pub struct Watch<D: Tasks> {
	snapshot: Snapshot,
	updates: Updates<D>,
}
/// The callback registration without its initial snapshot. Splitting a watch
/// transfers discovery rows to a live view without cloning their metadata.
pub struct Updates<D: Tasks> {
	registration: Registration<D>,
}
impl<D: Tasks> Watch<D> {
	pub fn snapshot(&self) -> &Snapshot {
		&self.snapshot
	}
	pub fn into_parts(self) -> (Snapshot, Updates<D>) {
		(self.snapshot, self.updates)
	}
	pub async fn next(&mut self) -> Result<Option<Event>, directory::Error> {
		self.updates.next().await
	}
}
impl<D: Tasks> Updates<D> {
	pub fn status(&self) -> Result<(), directory::Error> {
		self.registration.state.borrow().queue.status()
	}
	pub async fn next(&mut self) -> Result<Option<Event>, directory::Error> {
		poll_fn(|cx| {
			let mut state = self.registration.state.borrow_mut();
			match state.queue.pop() {
				Ok(Some(event)) => Poll::Ready(Ok(Some(event))),
				Err(directory::Error::Closed) => Poll::Ready(Ok(None)),
				Err(error) => Poll::Ready(Err(error)),
				Ok(None) => {
					state.waiter = Some(cx.waker().clone());
					Poll::Pending
				}
			}
		})
		.await
	}
}
impl<D: Deadline + Tasks + Clone + 'static> Directory<D> {
	pub async fn watch(&self) -> Result<Watch<D>, Error> {
		let state = Rc::new(RefCell::new(State::default()));
		let weak = Rc::downgrade(&state);
		let observer = self.client.session.spawn_owned(move |verb, args| {
			if verb != rooms_application::protocol_data::NOTIFY {
				return Err("unknown directory observer method".into());
			}
			let state = weak.upgrade().ok_or("the directory observer has ended")?;
			if let Some(event) = directory::event_fields(args.len(), |i| args.get(i).map(Value)) {
				let (result, waiter) = {
					let mut state = state.borrow_mut();
					(state.queue.push(event), state.waiter.take())
				};
				if let Some(waiter) = waiter {
					waiter.wake();
				}
				result.map_err(|e| e.to_string())?;
			}
			Ok(Argument::Void)
		})?;
		let weak = Rc::downgrade(&state);
		let session = self.client.session.clone();
		let closed = self.client.deadline.spawn(async move {
			let _ = session.closed().await;
			if let Some(state) = weak.upgrade() {
				close(&state);
			}
		});
		let registration = Registration {
			state,
			registry: self.client.directory_watches.clone(),
			_observer: observer.clone(),
			_client: self.client.clone(),
			closed: Some(closed),
		};
		registration.registry.replace(&self.reference, &registration.state);
		let reply = self
			.client
			.call(
				&self.reference,
				directory::WATCH,
				&[observer.into()],
				"the directory did not answer watching its rooms",
			)
			.await?;
		let snapshot = directory::snapshot(&Value(&reply.0))?;
		registration.state.borrow().queue.status()?;
		Ok(Watch {
			snapshot,
			updates: Updates { registration },
		})
	}
}
fn close(shared: &Rc<RefCell<State>>) {
	let waiter = {
		let mut state = shared.borrow_mut();
		state.queue.close();
		state.waiter.take()
	};
	if let Some(waiter) = waiter {
		waiter.wake();
	}
}
impl<D: Tasks> Drop for Registration<D> {
	fn drop(&mut self) {
		self.closed = None;
		self.registry.remove(&self.state);
		close(&self.state);
	}
}
