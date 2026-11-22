//! Keeping the line a posting command returned. A `say`, `sendFiles`, or
//! `refileLine` receipt names the posted line by a result key. The workspace
//! holds line authority only after one acquisition moves that key into the
//! conversation's `lines` row, and editing or withdrawing the line needs it.
//! This module plans that acquisition for the terminal front and attached
//! views. The page plans the same acquisition in its own completion recipe.
use super::{Conversation, Intent, PostedLine, custody};
use alloc::{string::String, vec::Vec};
use core::fmt;
use serde::Deserialize;

/// The conversation a posting command's line lands in, its first argument,
/// or `None` for a command that posts no line to keep.
pub fn posted_conversation<'a>(name: &str, arguments: &'a [String]) -> Option<&'a str> {
	match name {
		"say" | "sendFiles" | "refileLine" => arguments.first().map(String::as_str),
		_ => None,
	}
}

/// What a posting receipt says about the line it posted.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LineReceipt {
	pub id: crate::session::state::SafeInteger,
	pub line: custody::FieldKey<custody::Line>,
}
impl LineReceipt {
	/// Read a command's result text. A result without both fields posted no
	/// numbered line, so there is nothing to keep.
	pub fn read(result: &str) -> Result<Option<Self>, serde_json::Error> {
		#[derive(Deserialize)]
		struct Fields {
			id: Option<crate::session::state::SafeInteger>,
			line: Option<custody::FieldKey<custody::Line>>,
		}
		let fields: Fields = serde_json::from_str(result)?;
		Ok(fields.id.zip(fields.line).map(|(id, line)| Self { id, line }))
	}
}

/// The complete acquisition candidate that keeps one line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LineAdoption {
	/// The current workspace with the line recorded in its conversation.
	pub intent: Intent,
	/// Result keys and the destination each moves to, in role-checked pairs.
	pub mappings: Vec<[custody::Coordinate; 2]>,
	/// Line authority the candidate replaces, to be released with it.
	pub releases: Vec<custody::Coordinate>,
}

/// Why a line cannot be kept. Each leaves the receipt intact for a later try.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
	/// The conversation left the workspace after the line was posted.
	Removed,
	/// The conversation was not part of the workspace the command saw.
	Unknown,
	/// The conversation's authority changed after the command was posted.
	Changed,
	/// The conversation already records the most lines it can.
	Full,
}
impl fmt::Display for Refusal {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.write_str(match self {
			Self::Removed => "the initiating conversation was removed, retain its receipt",
			Self::Unknown => "the original conversation is unavailable",
			Self::Changed => "the initiating conversation authority changed, retain its receipt",
			Self::Full => "the conversation records no more lines",
		})
	}
}
impl core::error::Error for Refusal {}

fn lines_mut(row: &mut Conversation) -> &mut crate::fields::List<PostedLine, 256> {
	match row {
		Conversation::Room(room) => &mut room.lines,
		Conversation::Direct(direct) => &mut direct.lines,
	}
}
/// Whether two views of one conversation hold the same authority. Lines,
/// drafts, names, and standing may change freely between them.
fn same_authority(before: &Conversation, now: &Conversation) -> bool {
	match (before, now) {
		(Conversation::Room(a), Conversation::Room(b)) => {
			a.directory == b.directory
				&& a.source == b.source
				&& a.access == b.access
				&& a.accepted == b.accepted
				&& a.public_entry == b.public_entry
				&& a.publication == b.publication
				&& a.control == b.control
				&& a.moderator == b.moderator
				&& a.seat == b.seat
		}
		(Conversation::Direct(a), Conversation::Direct(b)) => {
			a.directory == b.directory
				&& a.peer == b.peer
				&& a.source == b.source
				&& a.access == b.access
				&& a.introduction == b.introduction
				&& a.closed == b.closed
		}
		_ => false,
	}
}

/// Plan keeping `receipt`'s line in `conversation`. `original` is the
/// workspace the command was prepared against and `current` the workspace the
/// acquisition will be checked at. `destination` is a fresh key for a room's
/// line. A direct conversation's settlement can already hold the line at a
/// key, and that key is kept.
pub fn adopt_line(
	original: &Intent,
	current: &Intent,
	conversation: &str,
	receipt: &LineReceipt,
	destination: custody::FieldKey<custody::Line>,
) -> Result<LineAdoption, Refusal> {
	let find = |intent: &Intent| {
		intent
			.conversations
			.as_slice()
			.iter()
			.position(|row| row.id().text().as_str() == Some(conversation))
	};
	let prior = find(original).ok_or(Refusal::Unknown)?;
	let at = find(current).ok_or(Refusal::Removed)?;
	if !same_authority(
		&original.conversations.as_slice()[prior],
		&current.conversations.as_slice()[at],
	) {
		return Err(Refusal::Changed);
	}
	let mut intent = current.clone();
	let row = &mut intent.conversations.as_mut_slice()[at];
	let direct = matches!(row, Conversation::Direct(_));
	let replaced = row
		.lines()
		.iter()
		.find(|line| line.id == receipt.id)
		.map(|line| line.handle);
	let handle = match replaced {
		Some(held) if direct => held,
		_ => destination,
	};
	let lines = lines_mut(row);
	lines.partition_out(|line| line.id != receipt.id);
	lines
		.try_push(PostedLine { id: receipt.id, handle })
		.map_err(|_| Refusal::Full)?;
	let role = custody::Role::Line;
	Ok(LineAdoption {
		intent,
		mappings: Vec::from([[
			custody::Coordinate::new(role, receipt.line),
			custody::Coordinate::new(role, handle),
		]]),
		releases: replaced
			.filter(|_| !direct)
			.map(|held| custody::Coordinate::new(role, held))
			.into_iter()
			.collect(),
	})
}

#[cfg(test)]
mod tests {
	use super::*;
	use alloc::string::{String, ToString};
	use serde_json::json;

	fn key(slot: u64) -> custody::FieldKey<custody::Line> {
		custody::FieldKey::new(core::num::NonZeroU64::new(slot).unwrap(), core::num::NonZeroU64::MIN)
	}
	fn room(seat: &str, lines: serde_json::Value) -> serde_json::Value {
		json!({"kind":"room","id":"c","directory":"d","name":"n","seat":seat,"lines":lines,
			"access":null,"control":null,"reconnect":"requested","standing":null,"draft":""})
	}
	fn intent(row: serde_json::Value) -> Intent {
		Intent::decode(
			&json!({"version":1,"directories":[],"conversations":[row],"invitations":[],"active":null,
				"standing":"","ignored":[],"keepHistory":false,"connection":"fastest",
				"archive":null,"archiveControl":null,"operators":[],"peering":[]})
			.to_string(),
		)
		.unwrap()
	}
	fn seat(slot: u64) -> String {
		let mut text = String::new();
		for part in [slot, 1] {
			text.push_str(&alloc::format!("{part:016x}"));
		}
		text
	}
	fn receipt() -> LineReceipt {
		LineReceipt::read(&json!({"id":7,"line":seat(40)}).to_string())
			.unwrap()
			.unwrap()
	}

	#[test]
	fn a_receipt_without_a_numbered_line_keeps_nothing() {
		assert_eq!(LineReceipt::read("{}").unwrap(), None);
		assert_eq!(LineReceipt::read(&json!({"id":3}).to_string()).unwrap(), None);
		assert!(LineReceipt::read("[]").is_err());
	}
	#[test]
	fn a_room_line_moves_to_a_fresh_key_and_replaces_an_earlier_one() {
		let before = intent(room(&seat(2), json!([])));
		let current = intent(room(&seat(2), json!([{"id":7,"handle":seat(30)}])));
		let plan = adopt_line(&before, &current, "c", &receipt(), key(50)).unwrap();
		assert_eq!(plan.intent.conversations.as_slice()[0].lines().len(), 1);
		assert_eq!(plan.intent.conversations.as_slice()[0].lines()[0].handle, key(50));
		assert_eq!(
			plan.mappings,
			[[
				custody::Coordinate::new(custody::Role::Line, key(40)),
				custody::Coordinate::new(custody::Role::Line, key(50)),
			]]
		);
		assert_eq!(plan.releases, [custody::Coordinate::new(custody::Role::Line, key(30))]);
	}
	#[test]
	fn a_changed_or_removed_conversation_refuses_without_a_plan() {
		let before = intent(room(&seat(2), json!([])));
		let moved = intent(room(&seat(3), json!([])));
		assert_eq!(
			adopt_line(&before, &moved, "c", &receipt(), key(50)),
			Err(Refusal::Changed)
		);
		assert_eq!(
			adopt_line(&before, &before, "other", &receipt(), key(50)),
			Err(Refusal::Unknown)
		);
	}
	#[test]
	fn a_direct_line_keeps_the_key_its_settlement_holds() {
		let direct = |lines: serde_json::Value| {
			json!({"kind":"direct","id":"c","directory":"d","peer":"p","access":null,
				"lines":lines,"closed":false,"draft":""})
		};
		let before = intent(direct(json!([])));
		let current = intent(direct(json!([{"id":7,"handle":seat(30)}])));
		let plan = adopt_line(&before, &current, "c", &receipt(), key(50)).unwrap();
		assert_eq!(plan.intent.conversations.as_slice()[0].lines()[0].handle, key(30));
		assert_eq!(
			plan.mappings,
			[[
				custody::Coordinate::new(custody::Role::Line, key(40)),
				custody::Coordinate::new(custody::Role::Line, key(30)),
			]]
		);
		assert!(plan.releases.is_empty());
		let fresh = adopt_line(&before, &before, "c", &receipt(), key(50)).unwrap();
		assert_eq!(fresh.intent.conversations.as_slice()[0].lines()[0].handle, key(50));
	}
	#[test]
	fn a_conversation_removed_since_the_command_refuses() {
		let before = intent(room(&seat(2), json!([])));
		let mut gone = before.clone();
		gone.conversations.remove(0);
		assert_eq!(
			adopt_line(&before, &gone, "c", &receipt(), key(50)),
			Err(Refusal::Removed)
		);
	}
	#[test]
	fn entropy_with_a_zero_half_is_no_key() {
		type Key = custody::FieldKey<custody::Line>;
		assert!(Key::from_entropy([1; 16]).is_some());
		assert!(Key::from_entropy([0; 16]).is_none());
		assert!(Key::from_entropy([1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0]).is_none());
	}
}
