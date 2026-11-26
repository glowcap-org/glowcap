//! Park an actual transport write without copying or consuming its bytes, as
//! a connection whose far side stops reading does, and let it go on later.
use std::{
	cell::RefCell,
	pin::Pin,
	rc::Rc,
	task::{Context, Poll, Waker},
};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

/// The switch a test holds over a [`Stream`]'s writes. Clones share one switch.
#[derive(Clone, Default)]
pub struct Gate {
	state: Rc<RefCell<State>>,
	parked: Rc<tokio::sync::Notify>,
}
/// Whether writes park, whether one has, and the write waiting to go on.
#[derive(Default)]
struct State {
	blocked: bool,
	observed: bool,
	waiter: Option<Waker>,
}
impl Gate {
	/// Park every write from now until [`Gate::open`].
	pub fn block(&self) {
		self.state.borrow_mut().blocked = true;
	}
	/// Whether a write has parked at the gate.
	pub fn observed(&self) -> bool {
		self.state.borrow().observed
	}
	/// Resolve once a write has parked at the gate.
	pub async fn parked(&self) {
		loop {
			let parked = self.parked.notified();
			tokio::pin!(parked);
			parked.as_mut().enable();
			if self.observed() {
				return;
			}
			parked.await;
		}
	}
	/// Let the parked write, and every write after it, go on.
	pub fn open(&self) {
		let waiter = {
			let mut state = self.state.borrow_mut();
			state.blocked = false;
			state.waiter.take()
		};
		if let Some(waiter) = waiter {
			waiter.wake();
		}
	}
}
/// A transport whose writes pass through `gate`, and whose reads pass straight
/// through.
pub struct Stream<S> {
	/// The transport the bytes travel.
	pub inner: S,
	/// The switch that parks this stream's writes.
	pub gate: Gate,
}
impl<S: AsyncRead + Unpin> AsyncRead for Stream<S> {
	fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<std::io::Result<()>> {
		Pin::new(&mut self.inner).poll_read(cx, buf)
	}
}
impl<S: AsyncWrite + Unpin> AsyncWrite for Stream<S> {
	fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, bytes: &[u8]) -> Poll<std::io::Result<usize>> {
		let parked = {
			let mut state = self.gate.state.borrow_mut();
			if state.blocked {
				state.observed = true;
				state.waiter = Some(cx.waker().clone());
			}
			state.blocked
		};
		if parked {
			self.gate.parked.notify_waiters();
			return Poll::Pending;
		}
		Pin::new(&mut self.inner).poll_write(cx, bytes)
	}
	fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
		Pin::new(&mut self.inner).poll_flush(cx)
	}
	fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
		Pin::new(&mut self.inner).poll_shutdown(cx)
	}
}
