//! One bounded output owner, including the line currently being written.
//! Control lines bypass pacing; they cannot interrupt a partially written line.
use rooms_application::server::irc::protocol::{LINE_BYTES, parse_line};
use std::{cell::Cell, fmt, rc::Rc, time::Duration};
use tokio::{
	io::{AsyncWrite, AsyncWriteExt},
	sync::{mpsc, oneshot, watch},
	time::Instant,
};

const LINES: usize = 64;
const BYTES: usize = 32 * 1024;
const WRITE_TIMEOUT: Duration = Duration::from_secs(30);

/// Transport evidence, not an acknowledgement from the IRC application.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Delivery {
	NotWritten,
	Uncertain,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WriteError {
	pub delivery: Delivery,
	pub reason: String,
}
impl fmt::Display for WriteError {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.write_str(&self.reason)
	}
}
impl std::error::Error for WriteError {}
pub struct WriteReceipt(oneshot::Receiver<Result<(), WriteError>>);
impl WriteReceipt {
	/// A successful receipt means this complete line was written and flushed.
	/// Losing observation does not cancel an already admitted write.
	pub async fn wait(self) -> Result<(), WriteError> {
		self.0.await.unwrap_or_else(|_| {
			Err(WriteError {
				delivery: Delivery::Uncertain,
				reason: "IRC write owner ended without evidence".into(),
			})
		})
	}
}

struct State {
	usage: Cell<(usize, usize)>,
	failure: watch::Sender<Option<String>>,
}
impl State {
	fn fail(&self, reason: String) {
		if self.failure.borrow().is_none() {
			self.failure.send_replace(Some(reason));
		}
	}
}
#[derive(Clone)]
pub(crate) struct Writer {
	state: Rc<State>,
	control: mpsc::Sender<Pending>,
	data: mpsc::Sender<Pending>,
}
pub(crate) struct Pump {
	state: Rc<State>,
	control: mpsc::Receiver<Pending>,
	data: mpsc::Receiver<Pending>,
	interval: Duration,
}
struct Pending {
	state: Rc<State>,
	bytes: Vec<u8>,
	started: bool,
	answer: Option<oneshot::Sender<Result<(), WriteError>>>,
}
impl Drop for Pending {
	fn drop(&mut self) {
		let (lines, bytes) = self.state.usage.get();
		self.state.usage.set((lines - 1, bytes - self.bytes.len()));
		if let Some(answer) = self.answer.take() {
			let reason = self
				.state
				.failure
				.borrow()
				.clone()
				.unwrap_or_else(|| "IRC write was retired".into());
			let _ = answer.send(Err(WriteError {
				delivery: if self.started {
					Delivery::Uncertain
				} else {
					Delivery::NotWritten
				},
				reason,
			}));
		}
	}
}
impl Writer {
	pub fn open(interval: Duration) -> (Self, Pump) {
		let (control, control_in) = mpsc::channel(LINES);
		let (data, data_in) = mpsc::channel(LINES);
		let state = Rc::new(State {
			usage: Cell::new((0, 0)),
			failure: watch::channel(None).0,
		});
		(
			Self {
				state: state.clone(),
				control,
				data,
			},
			Pump {
				state,
				control: control_in,
				data: data_in,
				interval,
			},
		)
	}
	pub fn failure(&self) -> Option<String> {
		self.state.failure.borrow().clone()
	}
	pub fn fail(&self, reason: impl Into<String>) {
		self.state.fail(reason.into());
	}
	pub async fn failed(&self) -> String {
		let mut changes = self.state.failure.subscribe();
		loop {
			if let Some(reason) = changes.borrow().clone() {
				return reason;
			}
			if changes.changed().await.is_err() {
				return "IRC output owner ended".into();
			}
		}
	}
	pub fn enqueue(&self, bytes: Vec<u8>, control: bool) -> Result<WriteReceipt, WriteError> {
		let refuse = |reason| WriteError {
			delivery: Delivery::NotWritten,
			reason,
		};
		if let Some(reason) = self.failure() {
			return Err(refuse(reason));
		}
		let payload = bytes
			.strip_suffix(b"\r\n")
			.ok_or_else(|| refuse("IRC output requires one complete CRLF line".into()))?;
		let text = std::str::from_utf8(payload).map_err(|_| refuse("IRC output is not UTF-8".into()))?;
		parse_line(text).map_err(|e| refuse(e.to_string()))?;
		let (lines, held) = self.state.usage.get();
		if lines >= LINES || bytes.len() > BYTES.saturating_sub(held) {
			self.fail("IRC output queue is full");
			return Err(refuse("IRC output queue is full".into()));
		}
		debug_assert!(bytes.len() <= LINE_BYTES);
		// The producer may have reserved much more than one protocol line.
		let bytes = bytes.into_boxed_slice().into_vec();
		self.state.usage.set((lines + 1, held + bytes.len()));
		let (answer, reply) = oneshot::channel();
		let pending = Pending {
			state: self.state.clone(),
			bytes,
			started: false,
			answer: Some(answer),
		};
		let queue = if control { &self.control } else { &self.data };
		if let Err(rejected) = queue.try_send(pending) {
			self.fail("IRC output owner cannot accept another line");
			drop(rejected);
			return Err(refuse("IRC output owner cannot accept another line".into()));
		}
		Ok(WriteReceipt(reply))
	}
}
impl Pump {
	pub async fn run(mut self, mut io: impl AsyncWrite + Unpin) -> Result<(), String> {
		let mut failure = self.state.failure.subscribe();
		let failed = async {
			loop {
				if let Some(reason) = failure.borrow().clone() {
					return reason;
				}
				if failure.changed().await.is_err() {
					return "IRC output owner ended".into();
				}
			}
		};
		let result = tokio::select! {
			biased;
			reason = failed => Err(reason),
			result = self.drive(&mut io) => result,
		};
		if let Err(reason) = &result {
			self.state.fail(reason.clone());
		}
		result
	}
	async fn drive(&mut self, io: &mut (impl AsyncWrite + Unpin)) -> Result<(), String> {
		let mut delayed = None;
		let mut next = Instant::now();
		loop {
			let (pending, paced) = if delayed.is_some() {
				tokio::select! {
					biased;
					pending = self.control.recv() => (pending, false),
					_ = tokio::time::sleep_until(next) => (delayed.take(), true),
				}
			} else {
				tokio::select! {
					biased;
					pending = self.control.recv() => (pending, false),
					pending = self.data.recv() => (pending, true),
				}
			};
			let Some(mut pending) = pending else {
				let reason = "IRC output queue closed".to_owned();
				self.state.fail(reason.clone());
				return Err(reason);
			};
			if paced && Instant::now() < next {
				delayed = Some(pending);
				continue;
			}
			// From this point cancellation or write failure cannot prove absence
			// of bytes on the peer. Dropping this Pending preserves that evidence.
			pending.started = true;
			let written = tokio::time::timeout(WRITE_TIMEOUT, async {
				io.write_all(&pending.bytes).await?;
				io.flush().await
			})
			.await
			.map_err(|_| "IRC socket write timed out".to_owned())
			.and_then(|result| result.map_err(|e| format!("IRC socket write failed: {e}")));
			if let Err(reason) = written {
				// Record the cause before either the active or delayed receipt
				// retires. Their drops preserve each line's delivery evidence.
				self.state.fail(reason.clone());
				return Err(reason);
			}
			if let Some(answer) = pending.answer.take() {
				let _ = answer.send(Ok(()));
			}
			if paced {
				next = Instant::now() + self.interval;
			}
		}
	}
}
impl Drop for Pump {
	fn drop(&mut self) {
		self.state.fail("IRC output owner retired".into());
	}
}
