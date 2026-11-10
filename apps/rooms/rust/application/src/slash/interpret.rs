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
	},
}
fn refused(why: impl Into<String>) -> Plan {
	Plan::Refused { why: why.into() }
}
fn effect(op: &'static str, text: DocumentText) -> Plan {
	Plan::Effect { op, text, extra: None }
}
/// A leading `ocapn://` word is the subject's link, and the words after it
/// describe it. Any other text is a description alone. This is the grammar
/// `Subject::typed` reads, kept here in UTF-16 so a browser's text survives.
fn subject_refusal(invalid: crate::room::subject::Invalid) -> String {
	use crate::room::subject::{Invalid, MAX_DESCRIPTION, MAX_LINK};
	match invalid {
		Invalid::DescriptionLength => format!("A subject may be described in at most {MAX_DESCRIPTION} characters."),
		Invalid::DescriptionLines => "A subject is one line of text.".into(),
		Invalid::DescriptionStartsWithLink => "Put the link first: /subject ocapn://… what it is.".into(),
		Invalid::LinkWithoutDescription => "Say what the link is after it: /subject ocapn://… what it is.".into(),
		Invalid::LinkShape => format!("A subject's link is one ocapn:// sturdyref of at most {MAX_LINK} characters."),
		Invalid::LinkUnreadable => "A subject's link must be a sturdyref this room can read.".into(),
	}
}
fn room(context: &Context<'_>, why: &'static str) -> Result<(), Plan> {
	if context.place == Place::Room {
		Ok(())
	} else {
		Err(refused(why))
	}
}
/// A command that takes nothing refuses words after it. Acting on the open
/// conversation while the reader named another would be a surprise.
fn nothing_after(text: &DocumentText, name: Name) -> Result<(), Plan> {
	if empty(&trimmed(text)) {
		return Ok(());
	}
	let definition = name.definition();
	Err(refused(format!(
		"/{} takes nothing after it. Write it as {}.",
		definition.name, definition.usage
	)))
}
/// The one person a command names, without its `@`. `None` when no name was
/// written, which covers a sigil on its own. Words after the name refuse,
/// because the command would otherwise act on the first word and drop the
/// rest unseen.
fn one_person(text: &DocumentText, name: Name) -> Result<Option<DocumentText>, Plan> {
	let who = person(text);
	if empty(&who) {
		return Ok(None);
	}
	let after = trimmed(&slice(&strip(text, b'@'), who.utf16().count(), usize::MAX));
	if empty(&after) {
		return Ok(Some(who));
	}
	let definition = name.definition();
	Err(refused(format!(
		"/{} takes one name. Write it as {}.",
		definition.name, definition.usage
	)))
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
				Some(super::input::Join::Name { name }) => effect("joinRoom", name),
				Some(super::input::Join::Link { link, label }) => Plan::Effect {
					op: "joinLink",
					text: link,
					extra: Some(label),
				},
			},
			Msg => match one_person(&text, name)? {
				None => refused("Use /msg followed by who to message."),
				Some(who) if everyone(&who) => refused(format!(
					"@{} is everyone in the room. A direct message needs one person.",
					who.utf8_lossy()
				)),
				Some(who) if !empty(context.you) && who.lowercase() == context.you.lowercase() => {
					refused("You can't start a direct message with yourself.")
				}
				Some(who) => effect("directMessage", who),
			},
			Theme => {
				let choice = text.lowercase();
				if matches!(choice.as_str(), Some("light" | "dark")) {
					effect("theme", choice)
				} else {
					refused("Use /theme light or /theme dark.")
				}
			}
			Leave | Clear | Details => {
				nothing_after(&text, name)?;
				if context.place == Place::None {
					refused(match name {
						Leave => "There is nothing open to leave.",
						Clear => "There is nothing open to clear.",
						_ => "Open a conversation first.",
					})
				} else {
					effect(name.definition().name, "".into())
				}
			}
			Members => {
				nothing_after(&text, name)?;
				room(context, "Only a room has a member list.")?;
				effect("members", "".into())
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
					)
				}
			}
			Subject => {
				room(context, "Only a room has a subject.")?;
				if empty(&text) {
					effect("showSubject", text)
				} else {
					let subject = if text.as_str() == Some("-") {
						Ok(crate::room::subject::Subject::default())
					} else {
						text.as_str()
							.ok_or(None)
							.and_then(|text| crate::room::subject::Subject::typed(text).map_err(Some))
					};
					match subject {
						Err(None) => refused("A subject must be well-formed text."),
						Err(Some(invalid)) => refused(subject_refusal(invalid)),
						Ok(subject) => Plan::Effect {
							op: "setSubject",
							text: subject.description().into(),
							extra: subject.link().map(DocumentText::from),
						},
					}
				}
			}
			Invite => {
				room(context, "Only a room can be offered.")?;
				match one_person(&text, name)? {
					None => refused("Use /invite followed by who to hand it to."),
					Some(who) => match invite_refusal(&who, context.you) {
						Some(why) => refused(why),
						None => effect("invite", who),
					},
				}
			}
			Kick => {
				room(context, "Only a room can ask somebody to leave.")?;
				match one_person(&text, name)? {
					None => refused("Use /kick followed by who to ask out."),
					Some(who) => effect("kick", who),
				}
			}
			Link => {
				room(context, "Only a room has a link.")?;
				let wanted = strip(&text, b'#');
				if !empty(&text) && empty(&wanted) {
					refused("Use /link on its own for this room, or /link followed by a listed room's name.")
				} else {
					effect("roomLink", wanted)
				}
			}
			Moderator => {
				room(context, "Only a room has a moderator capability.")?;
				effect("moderator", text)
			}
			Edit => {
				if empty(&text) {
					refused("Use /edit followed by what the message should say.")
				} else {
					effect("edit", text)
				}
			}
			Delete => {
				nothing_after(&text, name)?;
				effect("delete", "".into())
			}
			Ignore => match one_person(&text, name)? {
				None if empty(&text) => effect("ignored", text),
				None => refused("Use /ignore followed by who to stop hearing, or /ignore on its own to list them."),
				Some(who) => effect("ignore", who),
			},
			Unignore | Whois => match one_person(&text, name)? {
				None => refused(if name == Unignore {
					"Use /unignore followed by who to hear again."
				} else {
					"Use /whois followed by who to ask about."
				}),
				Some(who) => effect(name.definition().name, who),
			},
			Help | Directories | Quit => {
				nothing_after(&text, name)?;
				effect(name.definition().name, "".into())
			}
			List => effect("list", text),
		})
	};
	plan().unwrap_or_else(|refusal| refusal)
}

#[cfg(test)]
mod tests {
	use super::*;

	fn in_room(name: Name, rest: &str) -> Plan {
		let you = DocumentText::from("");
		let context = Context {
			place: Place::Room,
			you: &you,
			away: false,
		};
		interpret(name, &DocumentText::from(rest), &context)
	}
	fn refusal(plan: Plan) -> String {
		match plan {
			Plan::Refused { why } => why,
			_ => panic!("expected a refusal"),
		}
	}

	#[test]
	fn a_person_command_takes_one_name_and_refuses_words_after_it() {
		for name in [
			Name::Msg,
			Name::Invite,
			Name::Kick,
			Name::Whois,
			Name::Ignore,
			Name::Unignore,
		] {
			let command = name.definition().name;
			let Plan::Effect { text, .. } = in_room(name, " @bob ") else {
				panic!("/{command} did not act on one name");
			};
			assert_eq!(text.as_str(), Some("bob"), "/{command}");
			let why = refusal(in_room(name, "bob hi there"));
			assert!(
				why.starts_with(&format!("/{command} takes one name")),
				"/{command}: {why}"
			);
		}
	}

	#[test]
	fn a_command_that_takes_nothing_refuses_words_after_it() {
		for name in [
			Name::Help,
			Name::Leave,
			Name::Clear,
			Name::Members,
			Name::Details,
			Name::Directories,
			Name::Quit,
			Name::Delete,
		] {
			let command = name.definition().name;
			let why = refusal(in_room(name, "#other"));
			assert!(
				why.starts_with(&format!("/{command} takes nothing after it")),
				"/{command}: {why}"
			);
		}
	}
}
