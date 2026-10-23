//! Park an actual transport write without copying or consuming its bytes.
use std::{
	cell::RefCell,
	pin::Pin,
	rc::Rc,
	task::{Context, Poll, Waker},
};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

#[derive(Clone, Default)]
pub(super) struct Gate(Rc<RefCell<State>>, Rc<tokio::sync::Notify>);
#[derive(Default)]
struct State {
	blocked: bool,
	observed: bool,
	waiter: Option<Waker>,
}
impl Gate {
	pub fn block(&self) {
		self.0.borrow_mut().blocked = true;
	}
	pub fn observed(&self) -> bool {
		self.0.borrow().observed
	}
	/// Resolve once a write has parked at the gate.
	pub async fn parked(&self) {
		loop {
			let parked = self.1.notified();
			tokio::pin!(parked);
			parked.as_mut().enable();
			if self.observed() {
				return;
			}
			parked.await;
		}
	}
	pub fn open(&self) {
		let waiter = {
			let mut state = self.0.borrow_mut();
			state.blocked = false;
			state.waiter.take()
		};
		if let Some(waiter) = waiter {
			waiter.wake();
		}
	}
}
pub(super) struct Stream<S> {
	pub inner: S,
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
			let mut state = self.gate.0.borrow_mut();
			if state.blocked {
				state.observed = true;
				state.waiter = Some(cx.waker().clone());
			}
			state.blocked
		};
		if parked {
			self.gate.1.notify_waiters();
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
