//! Slash syntax produces requests, never capabilities. Session effect owners
//! admit those requests against their current target and grant generations.
use super::{catalog::Name, input::*};
use crate::text::DocumentText;
use alloc::{format, string::String};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Place {
	None,
	Room,
	Direct,
	Directory,
}
/// Observed facts used for input advice and relative gestures. These confer no
/// authority: the session revalidates every resulting effect before mutation.
pub struct Context<'a> {
	pub place: Place,
	pub you: &'a DocumentText,
	pub away: bool,
}
#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Plan {
	Refused {
		why: String,
	},
	Action {
		text: DocumentText,
	},
	Say {
		text: DocumentText,
	},
	Effect {
		op: &'static str,
		text: DocumentText,
		#[serde(skip_serializing_if = "Option::is_none")]
		extra: Option<DocumentText>,
		#[serde(skip_serializing_if = "Option::is_none")]
		refusal: Option<&'static str>,
	},
}
fn refused(why: impl Into<String>) -> Plan {
	Plan::Refused { why: why.into() }
}
fn effect(op: &'static str, text: DocumentText, refusal: Option<&'static str>) -> Plan {
	Plan::Effect {
		op,
		text,
		extra: None,
		refusal,
	}
}
fn room(context: &Context<'_>, why: &'static str) -> Result<(), Plan> {
	if context.place == Place::Room {
		Ok(())
	} else {
		Err(refused(why))
	}
}
pub fn everyone(text: &DocumentText) -> bool {
	text.as_str().is_some_and(crate::room::inbox::addresses_everyone)
}
pub fn invite_refusal(who: &DocumentText, you: &DocumentText) -> Option<String> {
	let who = person(&trimmed(who));
	if empty(&who) {
		return Some("Name who to offer this room to.".into());
	}
	if everyone(&who) {
		return Some(format!(
			"@{} is everyone in the room. Hand it to one person.",
			who.utf8_lossy()
		));
	}
	if !empty(you) && who.lowercase() == you.lowercase() {
		return Some("You already hold this room.".into());
	}
	None
}
pub fn interpret(name: Name, rest: &DocumentText, context: &Context<'_>) -> Plan {
	let text = trimmed(rest);
	let plan = || -> Result<Plan, Plan> {
		use Name::*;
		Ok(match name {
			Me => {
				if empty(&text) {
					refused("Use /me followed by an action.")
				} else {
					Plan::Action { text }
				}
			}
			Notice => {
				if empty(&text) {
					refused("Use /notice followed by what to say quietly.")
				} else {
					Plan::Say {
						text: decorate("/notice ", &text, ""),
					}
				}
			}
			Shrug => Plan::Say {
				text: if empty(&text) {
					"¯\\_(ツ)_/¯".into()
				} else {
					decorate("", &text, " ¯\\_(ツ)_/¯")
				},
			},
			Join => match join(&text) {
				None => refused("Use /join followed by a room name or a link."),
				Some(super::input::Join::Name { name }) => effect("joinRoom", name, None),
				Some(super::input::Join::Link { link, label }) => Plan::Effect {
					op: "joinLink",
					text: link,
					extra: Some(label),
					refusal: None,
				},
			},
			Msg => {
				let who = person(&text);
				if empty(&who) {
					refused("Use /msg followed by who to message.")
				} else if everyone(&who) {
					refused(format!(
						"@{} is everyone in the room. A direct message needs one person.",
						who.utf8_lossy()
					))
				} else if !empty(context.you) && who.lowercase() == context.you.lowercase() {
					refused("You can't start a direct message with yourself.")
				} else {
					effect("directMessage", who, None)
				}
			}
			Theme => {
				let choice = text.lowercase();
				if matches!(choice.as_str(), Some("light" | "dark")) {
					effect("theme", choice, None)
				} else {
					refused("Use /theme light or /theme dark.")
				}
			}
			Leave | Clear | Details => {
				if context.place == Place::None {
					refused(match name {
						Leave => "There is nothing open to leave.",
						Clear => "There is nothing open to clear.",
						_ => "Open a conversation first.",
					})
				} else {
					effect(name.definition().name, "".into(), None)
				}
			}
			Members => {
				room(context, "Only a room has a member list.")?;
				effect("members", "".into(), None)
			}
			Away => {
				room(context, "Only a room has anyone to tell.")?;
				let maximum = crate::room::membership::MAX_AWAY;
				if text.utf16().count() > maximum {
					refused(format!("A reason may be at most {maximum} characters."))
				} else {
					effect(
						"away",
						if empty(&text) {
							if context.away { "".into() } else { "away".into() }
						} else {
							text
						},
						Some("There is no room to say that in."),
					)
				}
			}
			Topic => {
				room(context, "Only a room has a topic.")?;
				if empty(&text) {
					effect("showTopic", text, None)
				} else {
					let text = if text.as_str() == Some("-") { "".into() } else { text };
					let maximum = crate::server::document::MAX_TOPIC;
					if text.utf16().count() > maximum {
						refused(format!("A topic may be at most {maximum} characters."))
					} else {
						effect("setTopic", text, Some("This room did not offer a topic to set."))
					}
				}
			}
			Invite => {
				room(context, "Only a room can be offered.")?;
				let who = person(&text);
				if empty(&who) {
					refused("Use /invite followed by who to hand it to.")
				} else if let Some(why) = invite_refusal(&who, context.you) {
					refused(why)
				} else {
					effect("invite", who, Some("There is no room here to hand over."))
				}
			}
			Kick => {
				room(context, "Only a room can ask somebody to leave.")?;
				let who = person(&text);
				if empty(&who) {
					refused("Use /kick followed by who to ask out.")
				} else {
					effect(
						"kick",
						who,
						Some("This room did not hand this tab its moderator capability."),
					)
				}
			}
			Link => {
				room(context, "Only a room has a link.")?;
				let wanted = strip(&text, b'#');
				let why = if empty(&wanted) {
					"There is no room here to link to."
				} else {
					"There is no directory here to link a room on."
				};
				effect("roomLink", wanted, Some(why))
			}
			Moderator => {
				room(context, "Only a room has a moderator capability.")?;
				effect("moderator", text, Some("There is no connected room here to moderate."))
			}
			Edit => {
				if empty(&text) {
					refused("Use /edit followed by what the message should say.")
				} else {
					effect(
						"edit",
						text,
						Some("There is no message of yours here that can still be changed."),
					)
				}
			}
			Delete => effect(
				"delete",
				"".into(),
				Some("There is no message of yours here that can still be taken back."),
			),
			Ignore => {
				let who = person(&text);
				effect(if empty(&who) { "ignored" } else { "ignore" }, who, None)
			}
			Unignore | Whois => {
				let who = person(&text);
				if empty(&who) {
					refused(if name == Unignore {
						"Use /unignore followed by who to hear again."
					} else {
						"Use /whois followed by who to ask about."
					})
				} else {
					effect(name.definition().name, who, None)
				}
			}
			Help | Directories | Quit => effect(name.definition().name, "".into(), None),
			List => effect("list", text, None),
		})
	};
	plan().unwrap_or_else(|refusal| refusal)
}
