use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};

use crate::GlowcapWebrtcReadyEvent;

/// One endpoint's readiness channel: a non-blocking self-pipe plus the
/// authoritative queue of pending records. Wake bytes are coalescing hints;
/// records, not byte counts, carry state.
pub(crate) struct Readiness {
	pub(crate) reader: UnixStream,
	writer: Mutex<UnixStream>,
	state: Mutex<ReadyState>,
}

struct ReadyState {
	subjects: VecDeque<usize>,
	events: HashMap<usize, u32>,
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
			state: Mutex::new(ReadyState {
				subjects: VecDeque::new(),
				events: HashMap::new(),
			}),
		}))
	}

	pub(crate) fn signal(&self, subject: usize, events: u32) {
		let mut state = self.state.lock().unwrap();
		if let Some(pending) = state.events.get_mut(&subject) {
			*pending |= events;
		} else {
			state.events.insert(subject, events);
			state.subjects.push_back(subject);
		}
		drop(state);
		self.nudge();
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

	/// Clear coalesced wake bytes before draining authoritative records. A signal
	/// racing this operation either joins this drain or leaves a byte for the next
	/// poll. A short record drain re-nudges the fd for its remaining backlog.
	pub(crate) fn drain(&self, dest: &mut [GlowcapWebrtcReadyEvent]) -> usize {
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

		let mut state = self.state.lock().unwrap();
		let count = dest.len().min(state.subjects.len());
		for slot in dest.iter_mut().take(count) {
			let subject = state.subjects.pop_front().unwrap();
			let events = state.events.remove(&subject).unwrap();
			*slot = GlowcapWebrtcReadyEvent { subject, events };
		}
		let remaining = !state.subjects.is_empty();
		drop(state);
		if remaining {
			self.nudge();
		}
		count
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
