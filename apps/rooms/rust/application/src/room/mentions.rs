//! Whom a line addresses. A line mentions a member when its Markdown reading
//! holds `@name` outside code, links, and other literal text, and it mentions
//! the room when that name is one of the room-wide words. One reading serves
//! the browser, the host session views, and every attached consumer.
use super::inbox::{nick_key, same_nick};
use crate::markdown::{Document, Node, rich};
use alloc::vec::Vec;
use serde::{Deserialize, Serialize};

/// The two facts a line carries about who it addresses. A line that mentions
/// both a member and the room reports both.
#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default)]
pub struct Mentions {
	/// The line names this member.
	pub member: bool,
	/// The line carries a room-wide mention such as `@room` or `@here`.
	pub room: bool,
}

impl Mentions {
	/// What a line from `from` says to the member named `own`. A member's own
	/// line addresses nobody. Without a known name only room-wide mentions can
	/// be found, because no member can be named. Names compare without regard
	/// to case. A line from an IRC bridge is read by the runs its formatting
	/// codes make, so a mention inside bold or colour is still found.
	#[must_use]
	pub fn of_line(from: &str, text: &str, own: Option<&str>) -> Self {
		let own = own.filter(|name| !name.is_empty());
		if own.is_some_and(|name| same_nick(name, from)) {
			return Self::default();
		}
		let own = own.unwrap_or("");
		rich::read(text).iter().fold(Self::default(), |found, part| {
			let part = Self::of_document(&part.document, own);
			Self {
				member: found.member | part.member,
				room: found.room | part.room,
			}
		})
	}

	/// The mentions in an already read document for the member named `nick`.
	/// An empty name matches no member.
	#[must_use]
	pub fn of_document(document: &Document, nick: &str) -> Self {
		let nick = nick_key(nick);
		let mut found = Self::default();
		let mut pending: Vec<&Node> = document.blocks.iter().collect();
		while let Some(node) = pending.pop() {
			if let Node::Mention { name, room } = node {
				found.room |= *room;
				found.member |= !nick.is_empty() && nick_key(name) == nick;
			}
			if let Some(children) = node.children() {
				pending.extend(children);
			}
		}
		found
	}
}

#[cfg(test)]
mod tests {
	use super::Mentions;
	use alloc::format;

	fn member() -> Mentions {
		Mentions {
			member: true,
			room: false,
		}
	}

	#[test]
	fn a_member_mention_names_exactly_that_member() {
		assert_eq!(Mentions::of_line("bob", "hi @zoe, ready?", Some("zoe")), member());
		assert_eq!(Mentions::of_line("bob", "@zoe", Some("zoe")), member());
		assert_eq!(Mentions::of_line("bob", "hi @amy", Some("zoe")), Mentions::default());
		assert_eq!(Mentions::of_line("bob", "hi zoe", Some("zoe")), Mentions::default());
	}

	#[test]
	fn names_compare_without_regard_to_case() {
		assert_eq!(Mentions::of_line("bob", "hi @ZOE", Some("zoe")), member());
		assert_eq!(Mentions::of_line("bob", "hi @zoe", Some("Zoe")), member());
	}

	#[test]
	fn a_nick_that_is_a_prefix_of_another_is_not_mentioned_by_it() {
		assert_eq!(Mentions::of_line("bob", "hi @zoey", Some("zoe")), Mentions::default());
		assert_eq!(Mentions::of_line("bob", "hi @zoe", Some("zoey")), Mentions::default());
		assert_eq!(Mentions::of_line("bob", "hi @zoe-", Some("zoe")), member());
		assert_eq!(Mentions::of_line("bob", "hi @zoe_2", Some("zoe")), Mentions::default());
	}

	#[test]
	fn room_wide_words_are_room_mentions_for_any_member() {
		let room = Mentions {
			member: false,
			room: true,
		};
		for word in ["here", "room", "channel", "everyone", "all", "HERE"] {
			assert_eq!(Mentions::of_line("bob", &format!("@{word} look"), Some("zoe")), room);
		}
		assert_eq!(Mentions::of_line("bob", "@room", None), room);
		assert_eq!(
			Mentions::of_line("bob", "@room and @zoe", Some("zoe")),
			Mentions {
				member: true,
				room: true
			}
		);
	}

	#[test]
	fn a_member_never_mentions_themselves() {
		assert_eq!(
			Mentions::of_line("Zoe", "note to @zoe and @room", Some("zoe")),
			Mentions::default()
		);
	}

	#[test]
	fn literal_text_names_nobody() {
		for text in [
			"`@zoe`",
			"```\n@zoe @room\n```",
			"[label](https://example.com/@zoe)",
			"zoe@example.com",
			"<span data-owner=\"@zoe\">",
			"@ zoe",
		] {
			let found = Mentions::of_line("bob", text, Some("zoe"));
			assert_eq!(found, Mentions::default(), "{text}");
		}
	}

	#[test]
	fn markup_around_a_mention_still_finds_it() {
		for text in [
			"**@zoe**",
			"> @zoe said so",
			"- item @zoe",
			"|| @zoe ||",
			"[@zoe](https://example.com)",
			"line one\n@zoe",
		] {
			assert_eq!(Mentions::of_line("bob", text, Some("zoe")), member(), "{text}");
		}
	}

	/// `|` and `-` belong to a name, so a delimiter written against the name is
	/// part of the word and no mention starts there.
	#[test]
	fn a_name_character_before_the_at_sign_prevents_a_mention() {
		assert_eq!(Mentions::of_line("bob", "||@zoe||", Some("zoe")), Mentions::default());
		assert_eq!(Mentions::of_line("bob", "a_@zoe", Some("zoe")), Mentions::default());
	}

	#[test]
	fn formatting_codes_from_an_irc_bridge_carry_no_text() {
		for text in [
			"\x02@zoe\x02 hi",
			"\x034@zoe\x03",
			"\x034,1@zoe\x03",
			"\x0304,12@zoe",
			"hey\x0f @zoe",
			"    \x02@zoe",
			"\x1d@zoe\x1d\x1f",
		] {
			assert_eq!(Mentions::of_line("bob", text, Some("zoe")), member(), "{text:?}");
		}
		assert!(Mentions::of_line("bob", "\x034@here", Some("zoe")).room);
		assert_eq!(
			Mentions::of_line("bob", "\x034@zoey\x03", Some("zoe")),
			Mentions::default()
		);
		assert_eq!(
			Mentions::of_line("bob", "\x034,1zoe@x\x03", Some("zoe")),
			Mentions::default()
		);
	}

	#[test]
	fn an_unknown_member_can_only_be_addressed_room_wide() {
		assert_eq!(Mentions::of_line("bob", "@zoe", None), Mentions::default());
		assert_eq!(Mentions::of_line("bob", "@zoe", Some("")), Mentions::default());
	}
}
