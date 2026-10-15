//! Acknowledgment journal owned by one blocking worker, independent of history.
//! Appends and acknowledgments append records. Compaction only reclaims a full
//! journal. It serializes borrowed retained rows instead of cloning the inbox.
use super::failure::Failure;
use rooms_application::documents::WriteFailure;
use rooms_platform::storage::{self, Directory, atomic};
use serde::Serialize;
use serde_json::{Value, json};
use std::{collections::BTreeSet, path::PathBuf};

const MAX_BYTES: usize = 16 * 1024 * 1024;
const MAX_ROWS: usize = 4096;
/// Rows one `pending` read returns.
const PAGE_ROWS: usize = 64;
// Leave enough room to dismiss every retained identifier even when full.
const ACK_RESERVE: usize = MAX_ROWS * 22 + 64;
const NAME: &str = "events.jsonl";
/// One retained event. The journal owns the identifier so the body stays an
/// arbitrary presentation payload. Serialization renders the identifier first
/// and the body's own keys after it, the row shape clients read.
#[derive(Serialize)]
struct RetainedEvent {
	id: u64,
	#[serde(flatten)]
	body: Value,
}
/// The journal's replay language: one line is an acknowledgment batch, a
/// watermark checkpoint, or a retained event.
enum JournalEntry {
	Ack(Vec<u64>),
	Next(u64),
	Event { id: u64, body: Value },
}
/// Classify one replayed journal line. An acknowledgment batch or a watermark
/// is recognized by its own key. Anything else is a retained event whose
/// identifier moves from the body into the event itself.
fn classify(mut row: Value) -> Result<JournalEntry, Failure> {
	if let Some(ids) = row.get("ack") {
		return Ok(JournalEntry::Ack(serde_json::from_value(ids.clone())?));
	}
	if let Some(next) = row.get("next").and_then(Value::as_u64) {
		return Ok(JournalEntry::Next(next));
	}
	let object = row
		.as_object_mut()
		.ok_or_else(|| Failure::invalid("inbox event has no id"))?;
	let id = object
		.get("id")
		.and_then(Value::as_u64)
		.ok_or_else(|| Failure::invalid("inbox event has no id"))?;
	let body = Value::Object(std::mem::take(object));
	Ok(JournalEntry::Event { id, body })
}
pub struct Inbox {
	directory: Directory,
	rows: Vec<RetainedEvent>,
	next: u64,
	bytes: usize,
	gap: Option<Failure>,
	uncertain: bool,
}
fn write_failure(error: WriteFailure<storage::StorageError>) -> Failure {
	match error {
		WriteFailure::Unchanged(e) => e.into(),
		WriteFailure::Indeterminate(e) => Failure::uncertain(e),
	}
}
impl Inbox {
	pub fn gap(&self) -> Option<Failure> {
		self.gap.clone()
	}
	pub fn open(path: PathBuf) -> Result<Self, Failure> {
		let directory = Directory::open(path, "lock")?;
		let mut this = Self {
			directory,
			rows: Vec::new(),
			next: 1,
			bytes: 0,
			gap: None,
			uncertain: false,
		};
		let raw = storage::read(&this.directory.path().join(NAME), MAX_BYTES)
			.map_err(|e| Failure::new("storage", "after-state-change", e))?;
		if let Some(raw) = raw {
			if !raw.is_empty() && !raw.ends_with(b"\n") {
				return Err(Failure::uncertain(
					"inbox has an incomplete write; preserve it and inspect before restart",
				));
			}
			this.bytes = raw.len();
			for line in raw.split(|b| *b == b'\n').filter(|l| !l.is_empty()) {
				match classify(serde_json::from_slice(line)?)? {
					JournalEntry::Ack(ids) => {
						this.remove(&ids.iter().copied().collect());
					}
					JournalEntry::Next(next) => this.next = this.next.max(next),
					JournalEntry::Event { id, body } => {
						if id < this.next {
							return Err(Failure::invalid("inbox identifiers are out of order"));
						}
						this.next = id
							.checked_add(1)
							.ok_or_else(|| Failure::exhausted("inbox identifiers exhausted"))?;
						this.rows.push(RetainedEvent { id, body });
					}
				}
			}
		} else {
			atomic::replace(&this.directory, NAME, [&b""[..]]).map_err(write_failure)?;
		}
		if this.rows.len() > MAX_ROWS {
			return Err(Failure::exhausted("inbox exceeds event budget"));
		}
		let gap = storage::read(&this.directory.path().join("gap.json"), 16 * 1024)
			.map_err(|e| Failure::new("storage", "after-state-change", e))?;
		if let Some(gap) = gap {
			this.gap = serde_json::from_slice(&gap)?;
		}
		let active = storage::read(&this.directory.path().join("active.json"), 16)
			.map_err(|e| Failure::new("storage", "after-state-change", e))?;
		if let Some(active) = active
			&& serde_json::from_slice::<bool>(&active)?
		{
			this.mark_gap(Failure::uncertain(
				"previous listener did not shut down cleanly; queued events may be missing",
			))?;
		}
		Ok(this)
	}
	pub fn begin(&self) -> Result<(), Failure> {
		atomic::replace(&self.directory, "active.json", [&b"true"[..]]).map_err(write_failure)
	}
	pub fn close(&self) -> Result<(), Failure> {
		// Clearing the active marker must not conceal an unpersisted gap.
		if self.gap.is_some() {
			let bytes = serde_json::to_vec(&self.gap)?;
			atomic::replace(&self.directory, "gap.json", [&bytes[..]]).map_err(write_failure)?;
		}
		atomic::replace(&self.directory, "active.json", [&b"false"[..]]).map_err(write_failure)
	}
	fn compact(&mut self) -> Result<(), Failure> {
		let mut bytes = Vec::new();
		for row in &self.rows {
			serde_json::to_writer(&mut bytes, row)?;
			bytes.push(b'\n');
		}
		serde_json::to_writer(&mut bytes, &json!({"next": self.next}))?;
		bytes.push(b'\n');
		if let Err(error) = atomic::replace(&self.directory, NAME, [&bytes[..]]) {
			return Err(self.journal_failure(error));
		}
		self.bytes = bytes.len();
		Ok(())
	}
	/// Compaction and refusal belong to the byte budget. Callers render their
	/// own newline-delimited record so event and acknowledgment rows share one
	/// writer.
	fn write(&mut self, bytes: &[u8], limit: usize) -> Result<(), Failure> {
		if self.uncertain {
			return Err(Failure::uncertain(
				"inbox needs restart to reconcile an uncertain write",
			));
		}
		if self.bytes + bytes.len() > limit {
			self.compact()?;
		}
		if self.bytes + bytes.len() > limit {
			return Err(Failure::exhausted("inbox is full; dismiss reviewed events"));
		}
		if let Err(error) = atomic::append(&self.directory, NAME, bytes) {
			return Err(self.journal_failure(error));
		}
		self.bytes += bytes.len();
		Ok(())
	}
	fn journal_failure(&mut self, error: WriteFailure<storage::StorageError>) -> Failure {
		self.uncertain |= matches!(&error, WriteFailure::Indeterminate(_));
		write_failure(error)
	}
	pub fn append(&mut self, row: Value) -> Result<u64, Failure> {
		if let Some(gap) = &self.gap {
			return Err(gap.clone());
		}
		if self.rows.len() >= MAX_ROWS {
			return Err(Failure::exhausted(
				"inbox is full; dismiss reviewed events, then resume observation",
			));
		}
		let next = self
			.next
			.checked_add(1)
			.ok_or_else(|| Failure::exhausted("inbox identifiers exhausted"))?;
		let event = RetainedEvent {
			id: self.next,
			body: row,
		};
		let mut bytes = serde_json::to_vec(&event)?;
		bytes.push(b'\n');
		self.write(&bytes, MAX_BYTES - ACK_RESERVE)?;
		let id = event.id;
		self.next = next;
		self.rows.push(event);
		Ok(id)
	}
	fn remove(&mut self, ids: &BTreeSet<u64>) -> usize {
		let before = self.rows.len();
		self.rows.retain(|row| !ids.contains(&row.id));
		before - self.rows.len()
	}
	pub fn acknowledge(&mut self, ids: &[u64]) -> Result<Value, Failure> {
		let requested: BTreeSet<_> = ids.iter().copied().collect();
		let retained: Vec<_> = self
			.rows
			.iter()
			.map(|row| row.id)
			.filter(|id| requested.contains(id))
			.collect();
		if retained.is_empty() {
			return Ok(json!({"ok": true, "acknowledged": 0}));
		}
		let mut bytes = serde_json::to_vec(&json!({"ack": retained}))?;
		bytes.push(b'\n');
		self.write(&bytes, MAX_BYTES)?;
		// Every requested identifier names a retained row, so removal reads the
		// request set directly instead of rebuilding a set from the filter.
		let removed = self.remove(&requested);
		Ok(json!({"ok": true, "acknowledged": removed}))
	}
	/// Copy at most one page into the socket response. Identifiers survive
	/// acknowledgments and restart, so paging never depends on shifting offsets.
	/// The response owns its rows after the disk worker finishes this request.
	/// The journal's byte budget also bounds a page containing a single large row.
	pub fn pending(&self, after_id: u64) -> Value {
		let start = self.rows.partition_point(|row| row.id <= after_id);
		let end = (start + PAGE_ROWS).min(self.rows.len());
		json!({"ok": true, "pending": &self.rows[start..end], "more": end < self.rows.len(),
               "remaining": self.rows.len(), "gap": self.gap})
	}
	pub fn mark_gap(&mut self, cause: Failure) -> Result<(), Failure> {
		if self.gap.is_none() {
			self.gap = Some(cause);
		}
		let bytes = serde_json::to_vec(&self.gap)?;
		atomic::replace(&self.directory, "gap.json", [&bytes[..]]).map_err(write_failure)
	}
	pub fn resume(&mut self) -> Result<(), Failure> {
		if self.uncertain {
			return Err(Failure::uncertain("restart to reconcile the inbox before resuming"));
		}
		if self.rows.len() >= MAX_ROWS {
			return Err(Failure::exhausted("dismiss reviewed events before resuming"));
		}
		atomic::replace(&self.directory, "gap.json", [&b"null"[..]]).map_err(write_failure)?;
		self.gap = None;
		Ok(())
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	fn path() -> PathBuf {
		static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
		std::env::temp_dir().join(format!(
			"rooms-inbox-{}-{}",
			std::process::id(),
			NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
		))
	}
	#[test]
	fn journal_uncertainty_comes_from_the_write_outcome_not_its_rendered_class() {
		let path = path();
		let mut inbox = Inbox::open(path.clone()).unwrap();
		inbox.journal_failure(WriteFailure::Unchanged(storage::StorageError::Io(
			std::io::ErrorKind::PermissionDenied.into(),
		)));
		assert!(!inbox.uncertain);
		inbox.journal_failure(WriteFailure::Indeterminate(storage::StorageError::Io(
			std::io::ErrorKind::WriteZero.into(),
		)));
		assert!(inbox.uncertain);
		assert!(
			inbox
				.append(json!({"text":"cannot advance an uncertain journal"}))
				.is_err()
		);
		drop(inbox);
		std::fs::remove_dir_all(path).unwrap();
	}
	#[test]
	fn acknowledgement_journal_replays_without_reusing_identifiers() {
		let path = path();
		let mut inbox = Inbox::open(path.clone()).unwrap();
		inbox.append(json!({"text":"one"})).unwrap();
		inbox.append(json!({"text":"two"})).unwrap();
		let before = std::fs::metadata(path.join(NAME)).unwrap().len();
		inbox.acknowledge(&[2]).unwrap();
		assert!(
			std::fs::metadata(path.join(NAME)).unwrap().len() > before,
			"acknowledgement appends instead of rewriting retained events"
		);
		drop(inbox);
		let mut inbox = Inbox::open(path.clone()).unwrap();
		assert_eq!(inbox.pending(0)["pending"][0]["text"], "one");
		inbox.append(json!({"text":"three"})).unwrap();
		assert_eq!(inbox.pending(0)["pending"][1]["id"], 3);
		inbox.compact().unwrap();
		drop(inbox);
		let inbox = Inbox::open(path.clone()).unwrap();
		assert_eq!(inbox.pending(0)["remaining"], 2);
		drop(inbox);
		std::fs::remove_dir_all(path).unwrap();
	}
	#[test]
	fn full_journal_can_dismiss_and_resume_without_losing_identifier_sequence() {
		let path = path();
		let mut inbox = Inbox::open(path.clone()).unwrap();
		inbox
			.append(json!({"text":"x".repeat(MAX_BYTES - ACK_RESERVE - 128)}))
			.unwrap();
		let error = inbox.append(json!({"text":"y".repeat(1024)})).unwrap_err();
		assert_eq!(error.class, "exhausted");
		inbox.mark_gap(error).unwrap();
		inbox.acknowledge(&[1]).unwrap();
		inbox.resume().unwrap();
		inbox.append(json!({"text":"recovered"})).unwrap();
		assert_eq!(inbox.pending(0)["pending"][0]["id"], 2);
		drop(inbox);
		let inbox = Inbox::open(path.clone()).unwrap();
		assert_eq!(inbox.pending(0)["pending"][0]["text"], "recovered");
		drop(inbox);
		std::fs::remove_dir_all(path).unwrap();
	}
	#[test]
	fn unclean_shutdown_keeps_a_gap_until_explicit_resume() {
		let path = path();
		let inbox = Inbox::open(path.clone()).unwrap();
		inbox.begin().unwrap();
		drop(inbox);
		let mut inbox = Inbox::open(path.clone()).unwrap();
		assert_eq!(inbox.pending(0)["gap"]["class"], "uncertain");
		assert!(inbox.append(json!({"text":"not silently resumed"})).is_err());
		inbox.resume().unwrap();
		inbox.close().unwrap();
		drop(inbox);
		let inbox = Inbox::open(path.clone()).unwrap();
		assert!(inbox.pending(0)["gap"].is_null());
		drop(inbox);
		std::fs::remove_dir_all(path).unwrap();
	}
}
