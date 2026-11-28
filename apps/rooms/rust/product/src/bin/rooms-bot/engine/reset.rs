//! `/reset`: a line that asks the bot to start a new conversation with its
//! agent. The agent's saved conversation for that Rooms conversation is
//! dropped before the turn runs, and the bot says so in one line.

use super::Env;
use crate::bot::{
	error::Error,
	ledger::{Asked, TurnId},
	rooms::{Kind, Rooms},
	words::RESET_CONFIRMED,
};

/// Whether `text`, a trigger line of a `kind` conversation, asks for a new
/// one. A direct line asks by being exactly `/reset`. A room line is a trigger
/// only because it mentions this member, and the bot does not know its own
/// nickname, so it cannot read whom a mention in the text names. It reads that
/// the line mentions it, so when the text is `/reset` and one other `@` word
/// and nothing else, that word is the mention that made the line a trigger and
/// names the bot. A bare `/reset` in a room reaches no one. Any further word or mention addresses someone else or asks
/// for more, and the line is an ordinary request.
pub fn asks(kind: Kind, text: &str) -> bool {
	let mut words = text.split_whitespace();
	match kind {
		Kind::Direct => words.next() == Some("/reset") && words.next().is_none(),
		Kind::Room => {
			let (first, second) = (words.next(), words.next());
			words.next().is_none()
				&& matches!((first, second),
					(Some("/reset"), Some(mention)) | (Some(mention), Some("/reset")) if mention.starts_with('@'))
		}
		Kind::Other => false,
	}
}

/// Whether any line that started the turn asks for a new conversation.
pub fn last(turn: &Asked) -> Option<crate::bot::classify::Seq> {
	turn.triggers
		.iter()
		.rev()
		.find(|trigger| asks(turn.kind, &trigger.text))
		.map(|trigger| trigger.seq)
}

/// Whether a reset is the whole of what the turn was asked.
pub fn is_whole(turn: &Asked) -> bool {
	!turn.triggers.is_empty() && turn.triggers.iter().all(|trigger| asks(turn.kind, &trigger.text))
}

/// Drop the agent's saved conversation for the turn's Rooms conversation.
pub fn begin<R: Rooms>(env: &Env<'_, R>, id: TurnId, asked: &Asked) -> Result<(), Error> {
	env.harness_sessions
		.borrow_mut()
		.forget(env.store, env.harness.name(), &asked.conversation)?;
	env.store.log(&format!(
		"turn {}: /reset starts a new agent conversation in {}",
		id.0, asked.conversation
	));
	Ok(())
}

/// An answer led by the confirmation when the turn asked for a reset.
pub fn lead(answer: &str, resets: bool) -> String {
	if resets {
		format!("{RESET_CONFIRMED}\n\n{answer}")
	} else {
		answer.to_owned()
	}
}

#[cfg(test)]
mod tests {
	use super::{Kind, asks};
	use crate::bot::{
		classify::{Class, Seq, classify},
		rooms::{Body, Change, ConversationId, Cursor, Incoming, Line, Mentions, Sender},
	};

	/// Whether a room line `text` from another member, which the session says
	/// mentions the bot when `mentions_bot`, reaches the bot as a reset.
	fn room_reset(text: &str, mentions_bot: bool) -> bool {
		let event = Incoming {
			cursor: Cursor::new("x1").unwrap(),
			conversation: ConversationId::new("r1"),
			kind: Kind::Room,
			body: Body::Line(Line {
				id: "l1".into(),
				sender: Sender::Member("ann".into()),
				change: Change::Said,
				text: text.into(),
				files: Vec::new(),
				mentions: Mentions {
					member: mentions_bot,
					room: false,
				},
			}),
		};
		match classify(&event, Seq(1)) {
			Class::Trigger(trigger) => asks(Kind::Room, &trigger.text),
			_ => false,
		}
	}

	#[test]
	fn a_direct_line_asks_only_by_being_exactly_reset() {
		assert!(asks(Kind::Direct, "/reset"));
		assert!(asks(Kind::Direct, "  /reset\n"));
		for no in [
			"",
			"/reset now",
			"please /reset",
			"/RESET",
			"/resets",
			"@helper /reset",
			"@bob /reset",
			"/reset @helper",
		] {
			assert!(!asks(Kind::Direct, no), "{no:?}");
		}
	}

	#[test]
	fn a_room_line_asks_by_reset_with_its_one_mention() {
		for yes in ["@helper /reset", "/reset @helper", "  @helper   /reset\n"] {
			assert!(asks(Kind::Room, yes), "{yes:?}");
		}
		for no in [
			"",
			"/reset",
			"/reset now",
			"please /reset",
			"/RESET",
			"@a @b /reset",
			"@helper",
			"@helper reset",
			"helper /reset",
		] {
			assert!(!asks(Kind::Room, no), "{no:?}");
		}
		assert!(!asks(Kind::Other, "/reset"));
	}

	#[test]
	fn a_room_reset_is_the_one_mention_that_reached_the_bot() {
		assert!(room_reset("@bot /reset", true));
		assert!(room_reset("/reset @bot", true));
		assert!(
			!room_reset("@bot @bob /reset", true),
			"two mentions address two members"
		);
		assert!(!room_reset("@bot /reset please", true));
		assert!(
			!room_reset("@bob /reset", false),
			"a line that never mentions the bot is context"
		);
		assert!(!room_reset("/reset", false), "a bare `/reset` in a room reaches no one");
	}
}
