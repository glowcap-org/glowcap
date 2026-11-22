//! A bounded ring of the lines that did not address the bot, per
//! conversation, so a mention arrives with what was said just before it. The
//! ring is advice for the harness: an unreadable ring is moved aside and the
//! conversation starts a new one, so one damaged file never stops a turn.
use super::store::Store;
use super::{classify::ContextLine, error::Error, rooms::ConversationId, store};

const DIRECTORY: &str = "context";
/// Lines kept per conversation.
pub const MAX_LINES: usize = 40;
/// Bytes kept of one line's text. A longer line keeps its beginning.
pub const MAX_TEXT_BYTES: usize = 1000;

fn name(conversation: &ConversationId) -> String {
	format!("{}.json", store::file_stem(conversation))
}

/// The ring of one conversation. A ring that cannot be used, because it is
/// malformed, too large, or not a regular file, is renamed to
/// `<name>.unreadable`, so its bytes stay for inspection, and an empty ring
/// takes its place. A failure that can clear, such as a full disk, is returned.
pub fn lines(store: &Store, conversation: &ConversationId) -> Result<Vec<ContextLine>, Error> {
	let name = name(conversation);
	match store.read_in(DIRECTORY, &name) {
		Ok(ring) => Ok(ring.unwrap_or_default()),
		Err(error @ (Error::Unreadable { .. } | Error::Storage(_))) if !error.is_transient() => {
			let directory = store.root().join(DIRECTORY);
			std::fs::rename(directory.join(&name), directory.join(format!("{name}.unreadable")))
				.map_err(Error::io("moving an unreadable context ring aside"))?;
			// The ring is set aside here, so the fresh-start advice the error
			// carries for an operator does not apply.
			let cause = match &error {
				Error::Unreadable { reason, .. } => reason.clone(),
				other => other.to_string(),
			};
			store.log(&format!(
				"moved the unreadable context ring of {conversation} aside ({cause}). It starts empty"
			));
			Ok(Vec::new())
		}
		Err(error) => Err(error),
	}
}

fn bounded(mut line: ContextLine) -> ContextLine {
	if line.text.len() > MAX_TEXT_BYTES {
		line.text.truncate(line.text.floor_char_boundary(MAX_TEXT_BYTES));
		line.text.push_str(" [cut]");
	}
	line
}

/// Merge `incoming` into the ring. A line whose event the ring already holds
/// is a replay and is dropped. So is a line older than everything kept, which
/// is a replay of a line the ring has already let go.
pub fn merge(mut ring: Vec<ContextLine>, incoming: Vec<ContextLine>) -> Vec<ContextLine> {
	for line in incoming {
		let held = ring.iter().any(|kept| kept.event == line.event);
		let older = ring.first().is_some_and(|oldest| line.seq < oldest.seq);
		if !held && !older {
			ring.push(bounded(line));
		}
	}
	let excess = ring.len().saturating_sub(MAX_LINES);
	ring.drain(..excess);
	ring
}

pub fn append(store: &Store, conversation: &ConversationId, incoming: Vec<ContextLine>) -> Result<(), Error> {
	let ring = lines(store, conversation)?;
	let merged = merge(ring.clone(), incoming);
	if merged == ring {
		return Ok(());
	}
	store.write_in(DIRECTORY, &name(conversation), &merged)
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::bot::{classify::Seq, rooms::Cursor};
	use rooms_testing::scratch::Scratch;

	fn line(seq: u64, text: &str) -> ContextLine {
		ContextLine {
			seq: Seq(seq),
			event: Cursor::new(format!("e{seq:x}")).unwrap(),
			from: Some("ann".into()),
			text: text.into(),
		}
	}

	#[test]
	fn the_ring_keeps_only_the_newest_lines() {
		let incoming = (1..=(MAX_LINES as u64 + 10)).map(|seq| line(seq, "x")).collect();
		let ring = merge(Vec::new(), incoming);
		assert_eq!(ring.len(), MAX_LINES);
		assert_eq!(ring[0].seq, Seq(11));
	}

	#[test]
	fn a_replayed_line_is_recognized_by_its_event_not_its_number() {
		let ring = merge(Vec::new(), vec![line(1, "a"), line(2, "b")]);
		// A replay after a restart may number the same event differently.
		let mut replayed = line(2, "b");
		replayed.seq = Seq(7);
		let again = merge(ring.clone(), vec![replayed, line(3, "c")]);
		assert_eq!(
			again.iter().map(|l| l.text.as_str()).collect::<Vec<_>>(),
			["a", "b", "c"]
		);
	}

	#[test]
	fn a_long_line_is_cut_on_a_character_boundary() {
		let ring = merge(Vec::new(), vec![line(1, &"é".repeat(MAX_TEXT_BYTES))]);
		assert!(ring[0].text.ends_with(" [cut]"));
		assert!(ring[0].text.len() <= MAX_TEXT_BYTES + 6);
	}

	#[test]
	fn an_oversized_ring_is_moved_aside_too() {
		let dir = Scratch::create("bot-context-big");
		let store = Store::open(&dir).unwrap();
		let conversation = ConversationId::new("c1");
		let directory = store.root().join(DIRECTORY);
		std::fs::create_dir_all(&directory).unwrap();
		std::fs::write(directory.join("c1.json"), vec![b' '; 4 * 1024 * 1024 + 1]).unwrap();
		assert_eq!(lines(&store, &conversation).unwrap(), Vec::new());
		assert!(directory.join("c1.json.unreadable").exists());
	}

	#[test]
	fn an_unreadable_ring_is_moved_aside_and_starts_empty() {
		let dir = Scratch::create("bot-context");
		let store = Store::open(&dir).unwrap();
		let conversation = ConversationId::new("c1");
		let directory = store.root().join(DIRECTORY);
		std::fs::create_dir_all(&directory).unwrap();
		std::fs::write(directory.join("c1.json"), "{").unwrap();
		assert_eq!(lines(&store, &conversation).unwrap(), Vec::new());
		assert_eq!(
			std::fs::read_to_string(directory.join("c1.json.unreadable")).unwrap(),
			"{"
		);
		append(&store, &conversation, vec![line(1, "a")]).unwrap();
		assert_eq!(lines(&store, &conversation).unwrap().len(), 1);
	}
}
