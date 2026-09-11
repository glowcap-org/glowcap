//! Relative preference gestures resolve against the checkpoint being committed.
use super::{conversation, push, text, Conversation, DocumentText, Error, Nullable, State};

pub(super) fn ignored(state: &mut State, name: &DocumentText, ignored: &DocumentText) -> Result<(), Error> {
	let name = name.lowercase();
	let enabled = match ignored.as_str() {
		Some("true") => true,
		Some("false") => false,
		_ => return Err(Error::Arguments),
	};
	if enabled {
		if !state.ignored.0.iter().any(|entry| entry.0.lowercase() == name) {
			push(&mut state.ignored, text(&name)?)?;
		}
	} else {
		state.ignored.0.retain(|entry| entry.0.lowercase() != name);
	}
	Ok(())
}

/// Update the closest explicit standing, preserving the existing distinction
/// between clearing an override (null) and an explicit empty standing (here).
pub(super) fn standing(state: &mut State, id: &DocumentText, reason: &DocumentText) -> Result<(), Error> {
	let Conversation::Room(room) = conversation(state, id)? else {
		return Err(Error::Missing);
	};
	let value = text(reason)?;
	let override_value = if reason.utf16().next().is_none() {
		Nullable::Null
	} else {
		Nullable::Value(value.clone())
	};
	if room.standing.as_ref().is_some() {
		room.standing = override_value;
		return Ok(());
	}
	let directory = room.directory.clone();
	let directory = state
		.directories
		.0
		.iter_mut()
		.find(|entry| entry.id == directory)
		.ok_or(Error::Missing)?;
	if directory.standing.as_ref().is_some() {
		directory.standing = override_value;
	} else {
		state.standing = value;
	}
	Ok(())
}
