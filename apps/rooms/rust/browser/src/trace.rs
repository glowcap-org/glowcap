//! Browser websocket effects for the shared visualization publisher. Browser
//! callbacks admit only bounded control text; trace policy stays in the runtime.
use crate::platform::Platform;
use rooms_runtime::Error;
use rooms_runtime::trace::{Input, Socket, Transport};
use tokio::sync::{mpsc, watch};
use wasm_bindgen::{JsCast, closure::Closure};
use web_sys::{CloseEvent, Event, MessageEvent, WebSocket};

#[derive(Clone)]
enum Status {
	Connecting,
	Open,
	Closed(u16, String),
}
pub struct Connection {
	socket: WebSocket,
	status: watch::Receiver<Status>,
	input: mpsc::Receiver<String>,
	_open: Closure<dyn FnMut(Event)>,
	_error: Closure<dyn FnMut(Event)>,
	_close: Closure<dyn FnMut(CloseEvent)>,
	_message: Closure<dyn FnMut(MessageEvent)>,
}
impl Connection {
	fn new(target: &str) -> Result<Self, Error> {
		let socket = WebSocket::new(target).map_err(|_| Error::closed("visualization endpoint could not be opened"))?;
		let (status, changed) = watch::channel(Status::Connecting);
		let (input, incoming) = mpsc::channel(32);
		let update = status.clone();
		let open = Closure::wrap(Box::new(move |_: Event| {
			update.send_replace(Status::Open);
		}) as Box<dyn FnMut(Event)>);
		let update = status.clone();
		let error = Closure::wrap(Box::new(move |_: Event| {
			update.send_replace(Status::Closed(1006, "visualization connection failed".into()));
		}) as Box<dyn FnMut(Event)>);
		let update = status.clone();
		let close = Closure::wrap(Box::new(move |event: CloseEvent| {
			update.send_replace(Status::Closed(event.code(), event.reason()));
		}) as Box<dyn FnMut(CloseEvent)>);
		let message = Closure::wrap(Box::new(move |event: MessageEvent| {
			let data = event.data();
			let Some(text) = data.dyn_ref::<js_sys::JsString>() else {
				return;
			};
			if text.length() > 1024 {
				return;
			}
			if input.try_send(String::from(text)).is_err() {
				status.send_replace(Status::Closed(1009, "visualization control backlog is full".into()));
			}
		}) as Box<dyn FnMut(MessageEvent)>);
		socket.set_onopen(Some(open.as_ref().unchecked_ref()));
		socket.set_onerror(Some(error.as_ref().unchecked_ref()));
		socket.set_onclose(Some(close.as_ref().unchecked_ref()));
		socket.set_onmessage(Some(message.as_ref().unchecked_ref()));
		Ok(Self {
			socket,
			status: changed,
			input: incoming,
			_open: open,
			_error: error,
			_close: close,
			_message: message,
		})
	}
	async fn opened(&mut self) -> Result<(), Error> {
		loop {
			match self.status.borrow().clone() {
				Status::Open => return Ok(()),
				Status::Closed(_, reason) => return Err(Error::closed(reason)),
				Status::Connecting => {}
			}
			self.status.changed().await.map_err(|_| retired())?;
		}
	}
}
impl Drop for Connection {
	fn drop(&mut self) {
		self.socket.set_onopen(None);
		self.socket.set_onerror(None);
		self.socket.set_onclose(None);
		self.socket.set_onmessage(None);
		let _ = self.socket.close();
	}
}
impl Transport for Platform {
	type Socket = Connection;
	async fn connect(&self, target: &str) -> Result<Connection, Error> {
		Connection::new(target)
	}
	async fn sleep(&self, milliseconds: u64) {
		use rooms_runtime::clock::Clock;
		self.sleep_until(self.now() + std::time::Duration::from_millis(milliseconds))
			.await;
	}
}
impl Socket for Connection {
	async fn ready(&mut self) -> Result<(), Error> {
		self.opened().await
	}
	async fn next(&mut self) -> Result<Input, Error> {
		loop {
			if let Status::Closed(code, reason) = self.status.borrow().clone() {
				return Ok(Input::Closed { code, reason });
			}
			tokio::select! {
				next = self.input.recv() => return next.map(Input::Text).ok_or_else(retired),
				changed = self.status.changed() => changed.map_err(|_| retired())?,
			}
		}
	}
	async fn send(&mut self, text: String) -> Result<(), Error> {
		while self.socket.buffered_amount() > 256 * 1024 {
			if self.socket.ready_state() != WebSocket::OPEN {
				return Err(Error::closed("visualization connection is closed"));
			}
			gloo_timers::future::TimeoutFuture::new(5).await;
		}
		// The socket is open, so a refused write is this transport's own
		// failure rather than the far end declining anything.
		self.socket
			.send_with_str(&text)
			.map_err(|_| Error::storage_message("visualization write failed"))
	}
	async fn close(&mut self) -> Result<(), Error> {
		self.socket
			.close()
			.map_err(|_| Error::storage_message("visualization close failed"))?;
		while self.socket.ready_state() != WebSocket::CLOSED {
			self.status.changed().await.map_err(|_| retired())?;
		}
		Ok(())
	}
}

/// The page dropped the callbacks this socket reports through, so nothing more
/// will ever be observed on it.
fn retired() -> Error {
	Error::closed("visualization callbacks retired")
}
