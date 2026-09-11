use glowcap::Ref;
use rooms_application::room::inbox::{
	queue::{Error, Queue},
	Message,
};
use std::{
	cell::RefCell,
	future::poll_fn,
	rc::Rc,
	task::{Poll, Waker},
};

pub(super) struct Delivery {
	pub queue: Queue<Ref>,
	pub waiter: Option<Waker>,
}
pub(super) type Shared = Rc<RefCell<Delivery>>;
/// One consumer owns unread-message custody. Cancellation closes the queue and
/// drops every unread attachment without ending other room memberships.
pub struct Messages {
	pub(super) shared: Shared,
}
impl Messages {
	pub async fn next(&mut self) -> Result<Option<Message<String, Ref>>, Error> {
		poll_fn(|cx| {
			let mut delivery = self.shared.borrow_mut();
			match delivery.queue.pop() {
				Ok(Some(message)) => Poll::Ready(Ok(Some(message))),
				Ok(None) => {
					if delivery.waiter.as_ref().is_none_or(|old| !old.will_wake(cx.waker())) {
						delivery.waiter = Some(cx.waker().clone());
					}
					Poll::Pending
				}
				Err(Error::Closed) => Poll::Ready(Ok(None)),
				Err(error) => Poll::Ready(Err(error)),
			}
		})
		.await
	}
}
pub(super) fn close(shared: &Shared) {
	let waker = {
		let mut d = shared.borrow_mut();
		d.queue.close();
		d.waiter.take()
	};
	if let Some(waker) = waker {
		waker.wake();
	}
}
impl Drop for Messages {
	fn drop(&mut self) {
		close(&self.shared);
	}
}
