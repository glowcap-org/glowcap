use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};

use crate::PancakeIrohReadyEvent;

/// One endpoint's readiness channel: the self-pipe the loop polls plus the
/// authoritative queue of pending records. Wake bytes are coalescing hints;
/// records, not byte counts, carry state.
pub(crate) struct Readiness {
	pub(crate) reader: UnixStream,
	writer: Mutex<UnixStream>,
	queue: Mutex<ReadyQueue>,
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

	fn pop_front(&mut self) -> Option<PancakeIrohReadyEvent> {
		let subject = self.order.pop_front()?;
		let events = self.events.remove(&subject)?;
		Some(PancakeIrohReadyEvent { subject, events })
	}
}

impl Readiness {
	pub(crate) fn new() -> Option<Arc<Readiness>> {
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
		}))
	}

	/// Best-effort self-pipe wake used both when publishing an event and when a
	/// short drain leaves queued records. `WouldBlock` means unread bytes already
	/// make the read fd pollable; an interrupted write retries.
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

	pub(crate) fn signal(&self, subject: usize, events: u32) {
		{
			let mut queue = self.queue.lock().unwrap();
			queue.push_or_coalesce(subject, events);
		}
		self.nudge();
	}

	/// Clear coalesced wake bytes before draining authoritative records. A signal
	/// racing this operation either joins this drain or leaves a byte for the next
	/// poll. A short record drain re-nudges the fd for its remaining backlog.
	pub(crate) fn drain(&self, dest: &mut [PancakeIrohReadyEvent]) -> usize {
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
			*slot = queue.pop_front().unwrap();
		}
		let remaining = !queue.is_empty();
		drop(queue);
		if remaining {
			self.nudge();
		}
		count
	}

	#[cfg(test)]
	pub(crate) fn pending_len(&self) -> usize {
		self.queue.lock().unwrap().len()
	}

	#[cfg(test)]
	pub(crate) fn fill_wake_pipe(&self) {
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
