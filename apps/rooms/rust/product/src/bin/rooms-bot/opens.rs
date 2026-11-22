//! The direct-message opens a turn left uncertain. A `--dm` open is noted in
//! its turn's action budget before it is sent, and the note is dropped once
//! the open settles. A budget that closes with a note still in it hands the
//! note here (`actions::close`), as `opens/<operation>.json` in the bot
//! directory, outside every agent's working directory.
//!
//! The serving bot looks at each such open again (`Rooms::settle_open`) when
//! it starts and after every turn, so the route the session holds for it is
//! kept or given back, across restarts. A look that finds the open still
//! uncertain, or refused, is one of [`MAX_LOOKS`]. After the last, the bot
//! stops looking, and its log and `status` count the open as unsettled: the
//! session keeps its receipt until the bot's access is revoked. A paused
//! access or an unreachable session counts no look. A replaced link takes
//! one last look at each open before the new link serves, because only the
//! access that sent an open can settle it.
use super::{
	engine::Env,
	error::Error,
	rooms::{Base, Rooms, RoomsErrorKind, Settled},
	status::Activity,
	store::Store,
};
use rooms_services::session::attached::Introduction;
use serde::{Deserialize, Serialize};
use std::{io::ErrorKind, path::Path};

/// The most looks at one open that cannot settle it.
pub const MAX_LOOKS: u32 = 5;

const DIRECTORY: &str = "opens";

/// One open sent under an operation: the base it was sent at, the
/// introduction it sent, and how many looks have failed to settle it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Open {
	pub base: Base,
	pub introduction: Introduction,
	#[serde(default)]
	pub looks: u32,
}

/// Whether `operation` is one the bot mints, 32 hexadecimal digits, so it
/// can name a file.
pub fn minted(operation: &str) -> bool {
	operation.len() == 32 && operation.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// Move the note of the open sent under `operation` from `from` to the opens
/// the serving bot settles.
pub fn keep(root: &Path, operation: &str, from: &Path) -> Result<(), Error> {
	if !minted(operation) {
		return Err(Error::state(
			"an open's note",
			format!("{operation} is not an operation the bot made"),
		));
	}
	let directory = root.join(DIRECTORY);
	std::fs::create_dir_all(&directory)
		.and_then(|()| std::fs::rename(from, directory.join(format!("{operation}.json"))))
		.map_err(Error::io("keeping an uncertain open for the bot to settle"))
}

/// Look again at every kept open, and add the ones the bot stopped looking
/// at to `status`.
pub async fn settle<R: Rooms>(env: &Env<'_, R>) -> Result<(), Error> {
	let unsettled = look(env.rooms, env.store, false).await?;
	if unsettled > 0 {
		let mut facts = env.facts.borrow_mut();
		facts.unsettled_opens += unsettled;
		facts.failed(
			Activity::Sending,
			format!("{unsettled} direct-message opens did not settle"),
		);
		drop(facts);
		env.publish();
	}
	Ok(())
}

/// Look once at every kept open. With `last`, stop looking at every open
/// this look does not settle. Returns how many opens the bot stopped looking
/// at.
pub async fn look<R: Rooms>(rooms: &R, store: &Store, last: bool) -> Result<u64, Error> {
	let entries = match std::fs::read_dir(store.root().join(DIRECTORY)) {
		Ok(entries) => entries,
		Err(error) if error.kind() == ErrorKind::NotFound => return Ok(0),
		Err(error) => return Err(Error::io("listing the uncertain opens")(error)),
	};
	let mut names = Vec::new();
	for entry in entries {
		let name = entry.map_err(Error::io("listing the uncertain opens"))?.file_name();
		if let Some(operation) = name
			.to_str()
			.and_then(|name| name.strip_suffix(".json"))
			.filter(|op| minted(op))
		{
			names.push(operation.to_owned());
		}
	}
	names.sort();
	let mut unsettled = 0;
	for operation in names {
		let name = format!("{operation}.json");
		let Some(mut open) = store.read_in::<Open>(DIRECTORY, &name)? else {
			continue;
		};
		let peer = open.introduction.peer.clone();
		let said = |what: &str| {
			store.log(&format!(
				"the direct-message open to {peer} under operation {operation} {what}"
			))
		};
		let why = match rooms.settle_open(&operation, open.base, &open.introduction).await {
			Ok(Settled::Opened(conversation)) => {
				said(&format!("kept its route, as conversation {conversation}"));
				forget(store, &name)?;
				continue;
			}
			Ok(Settled::Reused(conversation)) => {
				said(&format!(
					"gave its route back, because conversation {conversation} already reaches them"
				));
				forget(store, &name)?;
				continue;
			}
			Ok(Settled::Unapplied) => {
				said("committed nothing");
				forget(store, &name)?;
				continue;
			}
			Ok(Settled::Released) => {
				said("could not keep its route, and the session gave it back");
				forget(store, &name)?;
				continue;
			}
			Err(error) if error.kind == RoomsErrorKind::Revoked => {
				said("ended with the revoked access, and the session gives its receipt back");
				forget(store, &name)?;
				continue;
			}
			Err(error) if matches!(error.kind, RoomsErrorKind::Paused | RoomsErrorKind::Unreachable) && !last => {
				said(&format!("could not be looked at ({error}). Looking again later"));
				continue;
			}
			Ok(Settled::Uncertain) => "may still commit".to_owned(),
			Err(error) => error.to_string(),
		};
		open.looks = open.looks.saturating_add(1);
		if last || open.looks >= MAX_LOOKS {
			said(&format!(
				"did not settle ({why}), and the bot stops looking. The session keeps its receipt until this access is revoked"
			));
			forget(store, &name)?;
			unsettled += 1;
		} else {
			said(&format!(
				"did not settle ({why}). Looking again later, look {} of {MAX_LOOKS}",
				open.looks
			));
			store.write_in(DIRECTORY, &name, &open)?;
		}
	}
	Ok(unsettled)
}

fn forget(store: &Store, name: &str) -> Result<(), Error> {
	match std::fs::remove_file(store.root().join(DIRECTORY).join(name)) {
		Err(error) if error.kind() != ErrorKind::NotFound => Err(Error::io("dropping a settled open")(error)),
		_ => Ok(()),
	}
}

#[cfg(test)]
mod tests;
