use super::{
	socket::{Delivery, Pump, WriteError, WriteReceipt, Writer},
	Endpoint, Tls,
};
use rooms_application::server::irc::{
	protocol::{LineReader, Message},
	registration::{self, Registration, Role, SaslPlain},
};
use std::{cell::Cell, rc::Rc, time::Duration};
use tokio::{
	io::{AsyncRead, AsyncReadExt},
	sync::{mpsc, watch},
	time::Instant,
};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
const REGISTER_TIMEOUT: Duration = Duration::from_secs(30);
const EVENTS: usize = 64;

pub enum Event {
	Registered { nick: String },
	Message(Message),
}
pub struct Events(mpsc::Receiver<Event>);
impl Events {
	pub async fn next(&mut self) -> Option<Event> {
		self.0.recv().await
	}
}

/// A handle is tied to exactly one socket incarnation. A reconnect creates a
/// new owner; queued commands never migrate to a replacement connection.
#[derive(Clone)]
pub struct Connection {
	writer: Writer,
	ready: Rc<Cell<bool>>,
	stopped: Rc<Cell<bool>>,
	done: watch::Receiver<Option<Result<(), String>>>,
}
pub struct Worker {
	endpoint: Endpoint,
	tls: Option<Tls>,
	registration: Registration,
	registration_timeout: Duration,
	writer: Writer,
	pump: Option<Pump>,
	ready: Rc<Cell<bool>>,
	stopped: Rc<Cell<bool>>,
	events: mpsc::Sender<Event>,
	done: Completion,
}
struct Completion(watch::Sender<Option<Result<(), String>>>);
impl Drop for Completion {
	fn drop(&mut self) {
		if self.0.borrow().is_none() {
			self.0
				.send_replace(Some(Err("IRC connection worker retired before completion".into())));
		}
	}
}
impl Connection {
	/// The caller owns and drives Worker, typically in its existing JoinSet.
	/// `interval` paces application lines across every channel on this socket.
	pub fn open(
		endpoint: Endpoint,
		tls: Option<Tls>,
		role: Role,
		nick: &str,
		sasl: Option<SaslPlain>,
		interval: Duration,
	) -> Result<(Self, Worker, Events), String> {
		if endpoint.encrypted() && tls.is_none() {
			return Err("IRC TLS trust has not been loaded".into());
		}
		if sasl.is_some() && !endpoint.encrypted() {
			return Err("IRC account credentials require TLS".into());
		}
		let registration = Registration::new(role, nick, sasl)?;
		let (writer, pump) = Writer::open(interval);
		let (events, received) = mpsc::channel(EVENTS);
		let (done, finished) = watch::channel(None);
		let ready = Rc::new(Cell::new(false));
		let stopped = Rc::new(Cell::new(false));
		let handle = Self {
			writer: writer.clone(),
			ready: ready.clone(),
			stopped: stopped.clone(),
			done: finished,
		};
		let worker = Worker {
			endpoint,
			tls,
			registration,
			registration_timeout: match role {
				Role::Feed => REGISTER_TIMEOUT,
				Role::Member => Duration::from_secs(20),
			},
			writer,
			pump: Some(pump),
			ready,
			stopped,
			events,
			done: Completion(done),
		};
		Ok((handle, worker, Events(received)))
	}
	pub fn registered(&self) -> bool {
		self.ready.get() && self.writer.failure().is_none()
	}
	pub fn write(&self, bytes: Vec<u8>) -> Result<WriteReceipt, WriteError> {
		if !self.registered() {
			return Err(WriteError {
				delivery: Delivery::NotWritten,
				reason: self
					.writer
					.failure()
					.unwrap_or_else(|| "IRC connection is not registered".into()),
			});
		}
		self.writer.enqueue(bytes, false)
	}
	/// Refuse further admission and wake every phase: DNS, TCP, TLS,
	/// registration, read, write, and pacing. Worker observes their retirement.
	pub fn stop(&self) {
		if self.writer.failure().is_none() {
			self.stopped.set(true);
			self.writer.fail("IRC connection stopped");
		}
	}
	pub async fn close(&self) -> Result<(), String> {
		self.stop();
		self.finished().await
	}
	pub async fn finished(&self) -> Result<(), String> {
		let mut done = self.done.clone();
		loop {
			if let Some(result) = done.borrow().clone() {
				return result;
			}
			if done.changed().await.is_err() {
				return Err("IRC connection owner ended without completion".into());
			}
		}
	}
}
impl Worker {
	pub async fn run(mut self) -> Result<(), String> {
		let writer = self.writer.clone();
		let events = self.events.clone();
		let result = tokio::select! {
			biased;
			reason = writer.failed() => Err(reason),
			_ = events.closed() => Err("IRC event consumer retired".into()),
			result = self.drive() => result,
		};
		self.ready.set(false);
		self.writer.fail(
			result
				.as_ref()
				.err()
				.cloned()
				.unwrap_or_else(|| "IRC connection ended".into()),
		);
		// Retire the unopened writer too when cancellation happened during dial.
		drop(self.pump.take());
		let result = if self.stopped.get() { Ok(()) } else { result };
		self.done.0.send_replace(Some(result.clone()));
		result
	}
	async fn drive(&mut self) -> Result<(), String> {
		let stream = tokio::time::timeout(CONNECT_TIMEOUT, self.endpoint.connect(self.tls.as_ref()))
			.await
			.map_err(|_| "IRC connection attempt timed out".to_owned())??;
		let (read, write) = tokio::io::split(stream);
		let pump = self.pump.take().ok_or("IRC output owner was already started")?;
		for bytes in self.registration.start()? {
			self.writer.enqueue(bytes, true).map_err(|e| e.reason)?;
		}
		tokio::select! {
			result = pump.run(write) => result,
			result = self.read(read) => result,
		}
	}
	async fn read(&mut self, mut io: impl AsyncRead + Unpin) -> Result<(), String> {
		let deadline = Instant::now() + self.registration_timeout;
		let mut framing = LineReader::default();
		let mut bytes = [0u8; 4096];
		loop {
			let length = tokio::select! {
				length = io.read(&mut bytes) => length.map_err(|e| format!("IRC socket read failed: {e}"))?,
				_ = tokio::time::sleep_until(deadline), if !self.registration.registered() => return Err("IRC registration timed out".into()),
			};
			if length == 0 {
				framing.end().map_err(|e| e.to_string())?;
				return Err("IRC server ended the connection".into());
			}
			for message in framing.feed(&bytes[..length]).map_err(|e| e.to_string())? {
				let step = self.registration.observe(&message);
				let control = !step.send.is_empty() || message.is("PING");
				for bytes in step.send {
					self.writer.enqueue(bytes, true).map_err(|e| e.reason)?;
				}
				match step.event {
					Some(registration::Event::Failed(reason)) => return Err(reason),
					Some(registration::Event::Registered { nick }) => {
						self.ready.set(true);
						self.deliver(Event::Registered { nick })?;
					}
					None if self.registration.registered() && !control => self.deliver(Event::Message(message))?,
					None => {}
				}
			}
		}
	}
	fn deliver(&self, event: Event) -> Result<(), String> {
		self.events
			.try_send(event)
			.map_err(|_| "IRC event consumer cannot keep up; reconnect to resynchronize".into())
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use tokio::{io::AsyncReadExt, net::TcpListener};

	#[tokio::test(start_paused = true)]
	async fn registration_deadlines_retire_both_roles_and_close_the_socket() {
		tokio::task::LocalSet::new()
			.run_until(async {
				for role in [Role::Feed, Role::Member] {
					let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
					let endpoint = Endpoint::new("127.0.0.1", listener.local_addr().unwrap().port(), false).unwrap();
					let (connection, worker, mut events) =
						Connection::open(endpoint, None, role, "waiting", None, Duration::ZERO).unwrap();
					let deadline = worker.registration_timeout;
					let task = tokio::task::spawn_local(worker.run());
					let (mut socket, _) = listener.accept().await.unwrap();
					let mut bytes = [0; 4096];
					assert!(socket.read(&mut bytes).await.unwrap() > 0);
					tokio::time::advance(deadline).await;
					assert_eq!(connection.finished().await.unwrap_err(), "IRC registration timed out");
					assert_eq!(task.await.unwrap().unwrap_err(), "IRC registration timed out");
					assert!(!connection.registered());
					assert!(events.next().await.is_none());
					while socket.read(&mut bytes).await.unwrap() != 0 {}
				}
			})
			.await;
	}
}
