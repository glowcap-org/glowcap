//! One admission path for typed messages, slash results, and attachment descriptions.
use super::{
	catalog::Name,
	input,
	interpret::{self, Context, Place, Plan},
};
use crate::{
	fields::Text,
	room::line::{MAX_LINE_BYTES, MAX_MESSAGE_FILES},
	text::DocumentText,
};
use alloc::{
	format,
	string::{String, ToString},
	vec::Vec,
};
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Submission {
	pub text: Text<65536>,
	pub place: Place,
	pub you: Text<65536>,
	pub away: bool,
	pub line_limit: Option<usize>,
	/// Whether this membership holds the files facet a room hands over
	/// where it can hold bytes. A direct line always can. Files are refused
	/// here, at the one admission every controller submits through, so a
	/// file that came in by paste or drop meets the same answer as one picked.
	pub can_post_files: bool,
	pub files: Vec<Attachment>,
	pub keeping: bool,
	#[serde(default)]
	pub editing: bool,
	#[serde(default)]
	pub audience: crate::room::audience::Audience,
	/// Which of the selected names are online in this conversation.
	#[serde(default)]
	pub available_audience: crate::room::audience::Names,
}
/// Descriptions cross the presentation boundary. Source readers stay with the host.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Attachment {
	pub name: Text<65536>,
	pub mime: Text<65536>,
	pub size: u64,
}
#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Prepared {
	Nothing,
	Refused { why: String },
	Send { text: DocumentText },
	Command { plan: Plan },
}
const DIRECTORY_NO_CHAT: &str = "This view does not carry messages. Use a command.";
const ROOM_NO_FILES: &str = "This room does not carry files.";
pub fn line_refusal(text: &DocumentText, limit: Option<usize>) -> Option<String> {
	let maximum = limit.unwrap_or(MAX_LINE_BYTES).min(MAX_LINE_BYTES);
	(text.utf8_lossy().len() > maximum).then(|| format!("Message too long (max {maximum} bytes)"))
}
fn refuse(why: impl Into<String>) -> Prepared {
	Prepared::Refused { why: why.into() }
}
pub fn prepare(submission: &Submission) -> Prepared {
	let text = submission.text.text();
	if submission.place == Place::None
		|| (input::empty(&input::trimmed(text)) && submission.files.is_empty() && !submission.keeping)
	{
		return Prepared::Nothing;
	}
	if submission.place == Place::Directory && !submission.files.is_empty() {
		return refuse("This view does not carry files.");
	}
	if submission.place == Place::Room && !submission.can_post_files && !submission.files.is_empty() {
		return refuse(ROOM_NO_FILES);
	}
	let limit = if submission.place == Place::Room {
		submission.line_limit
	} else {
		None
	};
	if submission.place != Place::Directory
		&& let Some(why) = line_refusal(text, limit)
	{
		return refuse(why);
	}
	let context = Context {
		place: submission.place,
		you: submission.you.text(),
		away: submission.away,
	};
	let text = if let Some(read) = super::read(text) {
		let Some(name) = Name::parse(read.name) else {
			return refuse("That command is not in the catalog.");
		};
		let rest = input::slice(text, read.rest_start, usize::MAX);
		match interpret::interpret(name, &rest, &context) {
			Plan::Refused { why } => return refuse(why),
			plan @ Plan::Effect { .. } => return Prepared::Command { plan },
			Plan::Action { text } => {
				if submission.place == Place::Directory {
					return refuse(DIRECTORY_NO_CHAT);
				}
				if !submission.files.is_empty() {
					return refuse("An /me action cannot carry files. Send them as a separate message.");
				}
				input::decorate("/me ", &text, "")
			}
			Plan::Say { text } => text,
		}
	} else if let Some(token) = super::unknown(text) {
		return refuse(format!("There is no /{token} command. Type /help to see them."));
	} else {
		if submission.place == Place::Room
			&& !submission.editing
			&& !submission.keeping
			&& !submission.audience.is_empty()
		{
			match addressed(submission, text, limit) {
				Ok(text) => text,
				Err(why) => return refuse(why),
			}
		} else {
			text.clone()
		}
	};
	if submission.place == Place::Directory {
		return refuse(DIRECTORY_NO_CHAT);
	}
	if submission.files.len() > MAX_MESSAGE_FILES {
		return refuse(format!("A message may carry at most {MAX_MESSAGE_FILES} files."));
	}
	let mut file_bytes = 0_u64;
	for file in &submission.files {
		if let Err(error) =
			crate::files::validate_description(file.name.text().utf16(), file.mime.text().utf16(), file.size)
		{
			return refuse(error.to_string());
		}
		file_bytes = file_bytes.saturating_add(file.size);
	}
	if submission.place == Place::Direct && file_bytes > crate::files::sources::MAX_BYTES as u64 {
		return refuse(format!(
			"A direct message may carry at most {} MB.",
			crate::files::sources::MAX_BYTES / (1024 * 1024)
		));
	}
	// Expansion (such as /shrug) must fit the same cap as literal text. The
	// session still checks actual files and current room limits at publication.
	if let Some(why) = line_refusal(&text, limit) {
		return refuse(why);
	}
	Prepared::Send { text }
}

fn addressed(submission: &Submission, text: &DocumentText, limit: Option<usize>) -> Result<DocumentText, String> {
	use crate::room::{inbox::same_nick, mentions::visit_line};
	let mut explicit = false;
	visit_line(&text.utf8_lossy(), |_, _| explicit = true);
	if explicit {
		return Ok(text.clone());
	}
	for name in submission.audience.names() {
		if submission.you.text().as_str().is_some_and(|own| same_nick(name, own)) {
			return Err(format!(
				"The audience includes your own name, {name}. Change the audience to send."
			));
		}
		if !submission
			.available_audience
			.as_slice()
			.iter()
			.any(|online| online.text().as_str().is_some_and(|online| same_nick(name, online)))
		{
			return Err(format!(
				"{name} is offline. Change the audience or address this message explicitly."
			));
		}
	}
	let mut prefix = submission.audience.prefix();
	if text.utf16().next().is_some() {
		prefix.push_str("\n\n");
	}
	let line = input::decorate(&prefix, text, "");
	if let Some(why) = line_refusal(&line, limit) {
		return Err(why);
	}
	// Combined Markdown can change the reading of names which worked in isolation.
	// Confirm the actual published line addresses every selection, once and in order.
	let mut expected = submission.audience.names();
	let mut exact = true;
	visit_line(&line.utf8_lossy(), |name, room| {
		exact &= !room && expected.next() == Some(name)
	});
	if !exact || expected.next().is_some() {
		return Err(
			"These names cannot be mentioned together in this message. Change the audience or address it explicitly."
				.into(),
		);
	}
	Ok(line)
}

#[cfg(test)]
mod tests;
