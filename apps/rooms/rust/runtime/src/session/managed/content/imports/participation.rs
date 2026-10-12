//! Ordinary completion admits only the result delta of the original gesture.
//! General workspace replacement retains its separate administrative gate.
use super::*;

/// The direct conversation the original `startDirect` gesture reopened: the
/// directory it lives in, the peer it reaches, and the registration that
/// introduced it. Owned because the original arguments die with the branch
/// that decoded them.
struct Reopening {
	directory: String,
	peer: String,
	registration: String,
}

impl Request<'_> {
	/// Decode one bounded candidate, then normalize only its changed row for
	/// comparison. Scratch copies at most one conversation or its 256 line keys.
	/// Authority stays in the receipt and current graph throughout admission.
	pub(in crate::session::managed::content) fn participation(&self, input: Invocation<'_>) -> Result<bool> {
		let canonical = text(self.intent)?;
		// The original gesture names one conversation. A canonical upload intent
		// carries it in its envelope and participates as the verb `upload`; a
		// canonical command names it positionally, and only posting gestures
		// participate here.
		let (conversation, reopening) = if canonical.starts_with('{') {
			let Ok(upload) = uploads::Intent::read(canonical) else {
				return Ok(false);
			};
			(upload.conversation, None)
		} else {
			let original = original_text(canonical)?;
			let [_, _, verb, conversation, ..] = original.as_slice() else {
				return Ok(false);
			};
			let verb = text(verb)?;
			if !matches!(verb, "say" | "upload" | "sendFiles" | "refileLine" | "startDirect") {
				return Ok(false);
			}
			// A startDirect original is its introduction: directory, peer, and
			// registration name the direct conversation it reopened.
			let reopening = if verb == "startDirect" {
				let [_, _, _, directory, peer, registration, _] = original.as_slice() else {
					return Ok(false);
				};
				Some(Reopening {
					directory: text(directory)?.to_owned(),
					peer: text(peer)?.to_owned(),
					registration: text(registration)?.to_owned(),
				})
			} else {
				None
			};
			(text(conversation)?.to_owned(), reopening)
		};
		let record = records::metadata(input)?;
		let receipt = self.receipt(&record)?;
		let Some(replacement) = &self.replacement else {
			return Ok(false);
		};
		if receipt.adopted || replacement.expected != input.content_revision {
			// Adopted requests change nothing. Stale candidates pass through the
			// acquisition's conflict check, which admits no custody or intent delta.
			return Ok(true);
		}
		let mut candidate =
			workspace::Intent::decode(replacement.intent).map_err(|_| refuse("invalid result workspace"))?;
		if let Some(reopening) = reopening {
			self.direct_delta(&record, receipt, replacement, &reopening, &mut candidate)
		} else {
			self.line_delta(&record, receipt, replacement, &conversation, &mut candidate)
		}
	}
	fn line_delta(
		&self,
		record: &MetadataRecord,
		receipt: &custody::EffectReceipt<records::Metadata>,
		replacement: &Replacement,
		conversation: &str,
		candidate: &mut workspace::Intent,
	) -> Result<bool> {
		if replacement.source.is_some() {
			return Ok(false);
		}
		let [selection] = self.selections.as_slice() else {
			return Ok(self.selections.is_empty() && replacement.releases.is_empty() && *candidate == record.intent);
		};
		if selection.result.role != custody::Role::Line {
			return Ok(false);
		}
		self.line_origin(record, receipt, candidate)?;
		let Some(position) = record
			.intent
			.conversations
			.as_slice()
			.iter()
			.position(|row| row.id().text().as_str() == Some(conversation))
		else {
			return Ok(false);
		};
		let current = &record.intent.conversations.as_slice()[position];
		let Some(next) = candidate.conversations.as_mut_slice().get_mut(position) else {
			return Ok(false);
		};
		let Some(line) = next.lines().iter().find(|line| {
			line.handle.slot() == selection.destination.key.slot()
				&& line.handle.generation() == selection.destination.key.generation()
		}) else {
			return Ok(false);
		};
		let prior = current.lines().iter().find(|old| old.id == line.id);
		let release = prior.filter(|old| old.handle != line.handle).map(|old| Coordinate {
			role: custody::Role::Line,
			key: custody::FieldKey::new(old.handle.slot(), old.handle.generation()),
		});
		if replacement.releases.as_slice() != release.as_slice()
			|| (record.custody.get(selection.destination).is_some()
				&& prior.is_none_or(|old| old.handle != line.handle))
		{
			return Ok(false);
		}
		let expected = current
			.lines()
			.iter()
			.filter(|old| old.id != line.id)
			.chain(core::iter::once(line));
		if !next.lines().iter().eq(expected) {
			return Ok(false);
		}
		// Restore only the lines; every other field and every other row must match.
		match (next, current) {
			(workspace::Conversation::Room(next), workspace::Conversation::Room(current)) => {
				next.lines = current.lines.clone()
			}
			(workspace::Conversation::Direct(next), workspace::Conversation::Direct(current)) => {
				next.lines = current.lines.clone()
			}
			_ => return Ok(false),
		}
		Ok(*candidate == record.intent)
	}
	fn direct_delta(
		&self,
		record: &MetadataRecord,
		receipt: &custody::EffectReceipt<records::Metadata>,
		replacement: &Replacement,
		reopening: &Reopening,
		candidate: &mut workspace::Intent,
	) -> Result<bool> {
		let [selection] = self.selections.as_slice() else {
			return Ok(false);
		};
		if selection.result.role != custody::Role::DirectAccess
			|| !replacement.releases.is_empty()
			|| replacement.source.is_none()
		{
			return Ok(false);
		}
		let previous = record
			.intent
			.conversations
			.as_slice()
			.iter()
			.rposition(|row| match row {
				workspace::Conversation::Direct(row) => {
					row.closed
						&& row.directory.text().as_str() == Some(reopening.directory.as_str())
						&& row.introduction.as_ref().is_some_and(|intro| {
							intro.registration.text().as_str() == Some(reopening.registration.as_str())
						})
				}
				_ => false,
			});
		let position = previous.unwrap_or(record.intent.conversations.as_slice().len());
		let Some(workspace::Conversation::Direct(next)) = candidate.conversations.as_slice().get(position) else {
			return Ok(false);
		};
		let expected_id = previous
			.map(|at| record.intent.conversations.as_slice()[at].id().text())
			.unwrap_or(self.operation.text());
		if next.id.text() != expected_id
			|| next.directory.text().as_str() != Some(reopening.directory.as_str())
			|| next.peer.text().as_str() != Some(reopening.peer.as_str())
			|| next.introduction != receipt.introduction
			|| next.closed
			|| next.inbox.is_some()
			|| !next.lines.is_empty()
			|| next.access.map(|key| Coordinate {
				role: custody::Role::DirectAccess,
				key: custody::FieldKey::new(key.slot(), key.generation()),
			}) != Some(selection.destination)
			|| next.source.map(|key| Coordinate {
				role: custody::Role::SessionAccess,
				key: custody::FieldKey::new(key.slot(), key.generation()),
			}) != replacement.source
		{
			return Ok(false);
		}
		if let Some(at) = previous {
			let workspace::Conversation::Direct(old) = &record.intent.conversations.as_slice()[at] else {
				unreachable!()
			};
			if next.draft != old.draft {
				return Ok(false);
			}
			candidate.conversations.as_mut_slice()[at] = record.intent.conversations.as_slice()[at].clone();
		} else {
			if next.draft.text().as_str() != Some("") {
				return Ok(false);
			}
			candidate.conversations.remove(position);
		}
		Ok(*candidate == record.intent)
	}
}
