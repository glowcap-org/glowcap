//! Private supervision rechecks the original grant without consuming public
//! query debt. The root witness is mandatory, and a paused, revoked or
//! retired grant still refuses. Reads keep their ordinary requirements. A
//! workspace acquisition is the session's own custody write for a row that
//! grant was admitted to start, so it needs the grant's participation right
//! rather than custody management.
use super::*;

/// Whether the call arrived on the private continuation channel. Only
/// [`input`] decides whether that channel admits it.
pub(super) fn private(input: Invocation<'_>) -> bool {
	input.verb == "continue-workspace"
}

/// The session installs a row's callback and retires a lost route under the
/// grant that started the row. Every command that starts a supervised row
/// requires `InteractWorkspace`, so that right, and not `ManageCustody` or
/// `ReplaceWorkspace`, admits the session's follow-up write. The candidate is
/// built by the session from its own snapshot, never by the grant's holder.
pub(super) fn acquisition_requirement() -> Result<Requirement> {
	Requirement::new(&[Permission::InteractWorkspace.key()], &[])
}

/// Whether a private workspace acquisition is one of the session's own
/// writes for a row its grant started, compared against the `current`
/// workspace. Each command that starts such a row needs only
/// `InteractWorkspace`, and the session follows each with one of these:
///
/// - Installing a callback: one import of a direct, directory, or room inbox,
///   which becomes exactly one row's inbox, releasing at most the inbox it
///   replaces. `startDirect` and an accepted introduction install a direct
///   inbox, `joinDirectory` a directory inbox, and `joinRoom` a room inbox.
/// - Retiring a lost connection: no import and no release, with each changed
///   row cleared by its `retire_connection`.
///
/// An exact replay of a committed write changes nothing and is admitted.
/// Anything else, such as a draft, a standing, or another role's import,
/// needs the grant's custody rights on the ordinary channel.
pub(super) fn admits(
	current: &workspace::Intent,
	next: &workspace::Intent,
	imports: &[custody::Coordinate],
	releases: &[custody::Coordinate],
) -> bool {
	if next == current {
		return true;
	}
	match imports {
		[] => releases.is_empty() && retires(current, next),
		[import] => installs(current, next, *import, releases),
		_ => false,
	}
}

/// Whether `next` is `current` with one row's inbox replaced by `import`.
fn installs(
	current: &workspace::Intent,
	next: &workspace::Intent,
	import: custody::Coordinate,
	releases: &[custody::Coordinate],
) -> bool {
	use custody::{Coordinate, Role};
	let mut restored = next.clone();
	let prior = match import.role {
		Role::DirectInbox => restored
			.conversations
			.as_mut_slice()
			.iter_mut()
			.zip(current.conversations.as_slice())
			.find_map(|pair| match pair {
				(workspace::Conversation::Direct(row), workspace::Conversation::Direct(was))
					if row.inbox.map(|key| Coordinate::new(import.role, key)) == Some(import) =>
				{
					row.inbox = was.inbox;
					Some(was.inbox.map(|key| Coordinate::new(import.role, key)))
				}
				_ => None,
			}),
		Role::RoomInbox => restored
			.conversations
			.as_mut_slice()
			.iter_mut()
			.zip(current.conversations.as_slice())
			.find_map(|pair| match pair {
				(workspace::Conversation::Room(row), workspace::Conversation::Room(was))
					if row.inbox.map(|key| Coordinate::new(import.role, key)) == Some(import) =>
				{
					row.inbox = was.inbox;
					Some(was.inbox.map(|key| Coordinate::new(import.role, key)))
				}
				_ => None,
			}),
		Role::DirectoryInbox => restored
			.directories
			.as_mut_slice()
			.iter_mut()
			.zip(current.directories.as_slice())
			.find_map(|(row, was)| {
				(row.inbox.map(|key| Coordinate::new(import.role, key)) == Some(import)).then(|| {
					row.inbox = was.inbox;
					was.inbox.map(|key| Coordinate::new(import.role, key))
				})
			}),
		_ => None,
	};
	let Some(prior) = prior else {
		return false;
	};
	restored == *current && releases.iter().all(|release| Some(*release) == prior) && releases.len() <= 1
}

/// Whether `next` is `current` with some rows' connections retired.
fn retires(current: &workspace::Intent, next: &workspace::Intent) -> bool {
	let mut retired = current.clone();
	for (row, after) in retired
		.conversations
		.as_mut_slice()
		.iter_mut()
		.zip(next.conversations.as_slice())
	{
		if row != after {
			match row {
				workspace::Conversation::Direct(row) => row.retire_connection(),
				workspace::Conversation::Room(row) => row.retire_connection(),
			}
		}
	}
	for (row, after) in retired
		.directories
		.as_mut_slice()
		.iter_mut()
		.zip(next.directories.as_slice())
	{
		if row != after {
			row.retire_connection();
		}
	}
	retired == *next
}

pub(super) fn input<'a, P: Tasks + Deadline + Clone + 'static>(
	content: &SessionContent<P>,
	input: Invocation<'a>,
) -> Result<Invocation<'a>> {
	if !private(input) {
		return Ok(input);
	}
	super::super::retained::authorize(input, &content.owner(input.verb)?.writer.root()?)?;
	let method = match input.args.get(1) {
		Some(Argument::Integer(tag)) => rooms_application::content::session::continuing::Method::read(*tag),
		_ => None,
	}
	.ok_or_else(|| refuse("invalid private continuation method"))?;
	Ok(Invocation {
		verb: method.verb(),
		args: match method {
			rooms_application::content::session::continuing::Method::AcceptRoomInvitation => input
				.args
				.get(3..)
				.ok_or_else(|| refuse("directory witness required"))?,
			_ => &input.args[2..],
		},
		..input
	})
}

#[cfg(test)]
mod tests;
