use super::*;
use std::{
	future::poll_fn,
	task::{Poll, Waker},
};
#[derive(Default)]
struct State {
	events: policy::Queue<policy::Incoming>,
	ended: bool,
	waiter: Option<Waker>,
}
pub struct Inbox<D: Tasks> {
	state: Rc<RefCell<State>>,
	reply: Option<Ref>,
	_client: Caller<D>,
	closed: Option<D::Task>,
}
impl<D: Deadline + Tasks + Clone + 'static> Route<D> {
	/// Host and file the answering inbox on this exact directory connection.
	/// The caller owns its event stream and feeds its WebRTC transport adapter.
	pub async fn signaling_inbox(&self) -> Result<Inbox<D>, Error> {
		let state = Rc::new(RefCell::new(State::default()));
		let weak = Rc::downgrade(&state);
		let reply = self.caller.host().spawn(move |verb, args| {
			let state = weak.upgrade().ok_or("the signaling inbox has ended")?;
			if state.borrow().ended {
				return Err("the signaling inbox has ended".into());
			}
			let verb = verb.ok_or("unknown method")?;
			let incoming = policy::incoming(verb, args.len(), |i| args.get(i).map(Value)).map_err(|e| e.to_string())?;
			let (result, wake) = {
				let mut state = state.borrow_mut();
				(state.events.push(incoming), state.waiter.take())
			};
			if let Some(wake) = wake {
				wake.wake();
			}
			result.map_err(|e| e.to_string())?;
			Ok(Argument::Void)
		})?;
		let weak = Rc::downgrade(&state);
		let session = self.introducer.clone().or_else(|| self.caller.session().cloned());
		let closed = session.map(|session| {
			self.caller.platform().spawn(async move {
				let _ = session.closed().await;
				if let Some(state) = weak.upgrade() {
					close(&state);
				}
			})
		});
		let inbox = Inbox {
			state,
			reply: Some(reply.clone()),
			_client: self.caller.clone(),
			closed,
		};
		self.offer_signaling(&reply).await?;
		Ok(inbox)
	}
}
impl<D: Tasks> Inbox<D> {
	pub async fn next(&mut self) -> Result<Option<policy::Incoming>, Error> {
		poll_fn(|cx| {
			let mut state = self.state.borrow_mut();
			if state.ended {
				return Poll::Ready(Ok(None));
			}
			match state.events.pop() {
				Ok(Some(event)) => Poll::Ready(Ok(Some(event))),
				Err(error) => Poll::Ready(Err(error.into())),
				Ok(None) => {
					state.waiter = Some(cx.waker().clone());
					Poll::Pending
				}
			}
		})
		.await
	}
	pub fn close(&mut self) {
		close(&self.state);
		self.reply = None;
		self.closed = None;
	}
}
fn close(state: &Rc<RefCell<State>>) {
	let wake = {
		let mut state = state.borrow_mut();
		state.ended = true;
		state.events = Default::default();
		state.waiter.take()
	};
	if let Some(wake) = wake {
		wake.wake();
	}
}
impl<D: Tasks> Drop for Inbox<D> {
	fn drop(&mut self) {
		self.close();
	}
}
