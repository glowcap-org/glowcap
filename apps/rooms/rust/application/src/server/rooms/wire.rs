//! Room request decoding and member notices in the shape `room::inbox::read`
//! parses. File records need a capability minted on the hearing member's
//! connection, so the adapter supplies the encoder, one blob at a time.
use super::notice::{Blob, Notice};
use crate::room::{
	inbox::{AUTHORITY_CHANGED, ENDED, POLICY_CHANGED, ROOM},
	message::ChangeKind,
};
use alloc::{string::String, vec::Vec};

/// Decode a membership's attachment request. Shape errors and a room refusing
/// a file description have different wire outcomes; generic file parsing does
/// not choose the membership protocol's refusal code.
pub fn attachment<A: crate::room::ArgumentView>(
	len: usize,
	at: impl Fn(usize) -> Option<A>,
) -> Result<crate::files::FileDescription, super::Refusal> {
	use crate::{
		failure::FailureCode,
		files::{FileDescription, FileError},
	};
	let shape = || super::Refusal::plain("attach needs a name, mime type, size, and optional image dimensions");
	if len != 3 && len != 5 {
		return Err(shape());
	}
	let name = at(0).ok_or_else(shape)?;
	let mime = at(1).ok_or_else(shape)?;
	let natural = |index| {
		at(index)
			.and_then(|arg| arg.integer())
			.and_then(|n| u64::try_from(n).ok())
	};
	let (Some(name), Some(mime), Some(size)) = (name.text(), mime.text(), natural(2)) else {
		return Err(shape());
	};
	let (width, height) = if len == 5 {
		(natural(3).ok_or_else(shape)?, natural(4).ok_or_else(shape)?)
	} else {
		(0, 0)
	};
	FileDescription::parse(name, mime, size, width, height).map_err(|error| {
		super::Refusal::coded(
			FailureCode::AttachmentRefused,
			match error {
				FileError::Size => "file exceeds the room attachment limit",
				_ => "room attachment description is invalid",
			},
		)
	})
}

pub trait DataEncoder {
	type Value;
	fn text(&mut self, value: String) -> Self::Value;
	fn integer(&mut self, value: u64) -> Self::Value;
	fn boolean(&mut self, value: bool) -> Self::Value;
}

pub trait Encoder: DataEncoder {
	type Error;
	/// A capability for `blob` on the hearing connection.
	fn blob(&mut self, blob: &Blob) -> Result<Self::Value, Self::Error>;
}

/// The arguments one notice carries: the display line first, its tag and
/// structured fields after. A line copies its sender and text once each,
/// straight from the shared body into the wire value; the room notices
/// render their sentence through `Notice::said`.
pub fn arguments<E: Encoder>(notice: &Notice, e: &mut E) -> Result<Vec<E::Value>, E::Error> {
	let mut out = Vec::new();
	match notice {
		Notice::Line { line, marker, files } => {
			out.push(e.text(line.from.clone()));
			out.push(e.text(line.text.clone()));
			if let Some((kind, id)) = marker {
				out.push(e.text(kind.wire_tag().into()));
				out.push(e.integer(id.get()));
			}
			if marker.is_none_or(|(kind, _)| kind != ChangeKind::Edited && kind != ChangeKind::Withdrawn) {
				for blob in files {
					let description = blob.description();
					let (width, height) = description.dimensions();
					out.push(e.text("file".into()));
					out.push(e.text(description.name().into()));
					out.push(e.text(description.mime().into()));
					out.push(e.integer(description.size() as u64));
					out.push(e.blob(blob)?);
					out.push(e.integer(width as u64));
					out.push(e.integer(height as u64));
				}
			}
			out.push(e.text(crate::open_graph::WIRE_TAG.into()));
			out.push(e.text(line.previews.encode()));
			return Ok(out);
		}
		Notice::Roster(names) => {
			out.push(e.text(ROOM.into()));
			out.push(e.text(notice.said().into_owned()));
			out.push(e.text(crate::protocol_data::ROSTER.into()));
			for name in names {
				out.push(e.text(name.clone()));
			}
		}
		Notice::Join { nick, .. } | Notice::Leave { nick, .. } => {
			out.push(e.text(ROOM.into()));
			out.push(e.text(notice.said().into_owned()));
			out.push(
				e.text(
					if matches!(notice, Notice::Join { .. }) {
						crate::protocol_data::JOIN
					} else {
						crate::protocol_data::LEAVE
					}
					.into(),
				),
			);
			out.push(e.text(nick.clone()));
		}
		Notice::Away { nick, why } => {
			out.push(e.text(ROOM.into()));
			out.push(e.text(notice.said().into_owned()));
			out.push(e.text(crate::protocol_data::AWAY.into()));
			out.push(e.text(nick.clone()));
			out.push(e.text(why.clone()));
		}
		Notice::Topic { text, .. } => {
			out.push(e.text(ROOM.into()));
			out.push(e.text(notice.said().into_owned()));
			out.push(e.text(crate::protocol_data::TOPIC.into()));
			out.push(e.text(text.clone()));
		}
		Notice::Listed(listed) => {
			out.push(e.text(ROOM.into()));
			out.push(e.text(String::new()));
			out.push(
				e.text(
					if *listed {
						crate::protocol_data::LISTED
					} else {
						crate::protocol_data::UNLISTED
					}
					.into(),
				),
			);
			out.push(e.boolean(false));
		}
		Notice::Carries(carries) => {
			out.push(e.text(ROOM.into()));
			out.push(e.text(String::new()));
			out.push(e.text(crate::room::carries::TAG.into()));
			for word in carries.words() {
				out.push(e.text(word));
			}
		}
		Notice::Typing { nick, on } => {
			out.push(e.text(ROOM.into()));
			out.push(e.text(String::new()));
			out.push(e.text(crate::protocol_data::TYPING.into()));
			out.push(e.text(nick.clone()));
			out.push(e.boolean(*on));
		}
		Notice::Said(_) => {
			out.push(e.text(ROOM.into()));
			out.push(e.text(notice.said().into_owned()));
		}
		Notice::Ended(_) => {
			out.push(e.text(ROOM.into()));
			out.push(e.text(notice.said().into_owned()));
			out.push(e.text(ENDED.into()));
		}
		Notice::AuthorityChanged { kind, token } => {
			out.push(e.text(ROOM.into()));
			out.push(e.text(String::new()));
			out.push(e.text(AUTHORITY_CHANGED.into()));
			out.push(e.text(super::Rooms::<u8, u8>::authority_kind_name(*kind).into()));
			out.push(e.text(token.clone()));
			out.push(e.boolean(false));
		}
		Notice::PolicyChanged(policy) => {
			out.push(e.text(ROOM.into()));
			out.push(e.text(String::new()));
			out.push(e.text(POLICY_CHANGED.into()));
			for mode in policy.modes() {
				out.push(e.text(mode.into()));
			}
		}
	}
	Ok(out)
}
