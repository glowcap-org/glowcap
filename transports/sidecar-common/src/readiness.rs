use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::marker::PhantomData;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};

/// One endpoint's readiness channel: the self-pipe the loop polls plus the
/// authoritative queue of pending records. Wake bytes are coalescing hints.
/// Records, not byte counts, carry state.
///
/// `E` is the sidecar's own `#[repr(C)]` record, built from `(subject, events)`
/// only as `drain` writes it out, so each C ABI keeps its own layout type over
/// one shared queue.
pub struct Readiness<E> {
	/// The read half, the only half that crosses the sidecar boundary.
	pub reader: UnixStream,
	writer: Mutex<UnixStream>,
	queue: Mutex<ReadyQueue>,
	// A record is produced at drain time and never stored, so the marker is a
	// function type: the channel stays `Send` and `Sync` whatever `E` is.
	event: PhantomData<fn() -> E>,
}

struct ReadyQueue {
	order: VecDeque<usize>,
	events: HashMap<usize, u32>,
}

impl ReadyQueue {
	fn new() -> ReadyQueue {
		ReadyQueue {
			order: VecDeque::new(),
			events: HashMap::new(),
		}
	}

	fn len(&self) -> usize {
		self.order.len()
	}

	fn is_empty(&self) -> bool {
		self.order.is_empty()
	}

	fn push_or_coalesce(&mut self, subject: usize, events: u32) {
		if let Some(existing) = self.events.get_mut(&subject) {
			*existing |= events;
			return;
		}
		self.order.push_back(subject);
		self.events.insert(subject, events);
	}

	fn pop_front(&mut self) -> Option<(usize, u32)> {
		let subject = self.order.pop_front()?;
		let events = self.events.remove(&subject)?;
		Some((subject, events))
	}
}

impl<E: From<(usize, u32)>> Readiness<E> {
	pub fn new() -> Option<Arc<Readiness<E>>> {
		let (reader, writer) = UnixStream::pair().ok()?;
		reader.set_nonblocking(true).ok()?;
		writer.set_nonblocking(true).ok()?;
		// Only the read half crosses the sidecar boundary. Make misuse fail at
		// the fd instead of allowing a caller to manufacture spurious wakes.
		reader.shutdown(std::net::Shutdown::Write).ok()?;
		Some(Arc::new(Readiness {
			reader,
			writer: Mutex::new(writer),
			queue: Mutex::new(ReadyQueue::new()),
			event: PhantomData,
		}))
	}

	/// Best-effort self-pipe wake used both when publishing an event and when a
	/// short drain leaves queued records. `WouldBlock` is safe to discard because
	/// it means the pipe is full of unread bytes, which makes the read fd already
	/// poll-readable. An interrupted write has no such guarantee and is retried.
	fn nudge(&self) {
		if let Ok(mut writer) = self.writer.lock() {
			loop {
				match writer.write(&[1]) {
					Ok(_) => return,
					Err(err) if err.kind() == std::io::ErrorKind::Interrupted => continue,
					Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => return,
					// The read half is gone, so there is no live poller left to wake.
					Err(_) => return,
				}
			}
		}
	}

	pub fn signal(&self, subject: usize, events: u32) {
		{
			let mut queue = self.queue.lock().unwrap();
			queue.push_or_coalesce(subject, events);
		}
		self.nudge();
	}

	/// Clear coalesced wake bytes before draining authoritative records. A signal
	/// racing this operation either joins this drain or leaves a byte for the next
	/// poll. A short record drain re-nudges the fd for its remaining backlog.
	pub fn drain(&self, dest: &mut [E]) -> usize {
		let mut wake = [0u8; 256];
		let mut reader = &self.reader;
		loop {
			match reader.read(&mut wake) {
				Ok(0) => break,
				Ok(_) => {}
				Err(err) if err.kind() == std::io::ErrorKind::Interrupted => continue,
				Err(_) => break,
			}
		}

		let mut queue = self.queue.lock().unwrap();
		let count = dest.len().min(queue.len());
		for slot in dest.iter_mut().take(count) {
			*slot = E::from(queue.pop_front().unwrap());
		}
		let remaining = !queue.is_empty();
		drop(queue);
		if remaining {
			self.nudge();
		}
		count
	}

	/// How many records wait to be drained. Test support for the sidecars'
	/// coalescing proofs, behind the `test-support` feature.
	#[cfg(feature = "test-support")]
	pub fn pending_len(&self) -> usize {
		self.queue.lock().unwrap().len()
	}

	/// Fill the wake pipe until a write would block, so a test can show that a
	/// full pipe is already a readable wakeup. Behind the `test-support` feature.
	#[cfg(feature = "test-support")]
	pub fn fill_wake_pipe(&self) {
		let fill = [1u8; 4096];
		let mut writer = self.writer.lock().unwrap();
		loop {
			match writer.write(&fill) {
				Ok(_) => {}
				Err(err) if err.kind() == std::io::ErrorKind::Interrupted => continue,
				Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => return,
				Err(err) => panic!("unexpected self-pipe fill error: {err}"),
			}
		}
	}
}
