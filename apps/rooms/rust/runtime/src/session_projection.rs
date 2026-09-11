//! Project the durable session into the shared snapshot contract.
mod error;
use crate::{
	directory_runtime::{Directories, Phase},
	platform::Platform,
	rooms::RoomRuntime,
	session_state::SessionView,
};
pub use error::Error;
use rooms_application::{
	grants::{protocol::GrantView, Access},
	session::{
		directory,
		snapshot::{
			views::{ArchiveShare, DirectoryView, EffectPhase, HandedRoom},
			Field, List, Nullable, SafeInteger, Snapshot, Text, MAX_ISSUES,
		},
		state::{PendingView, SessionState},
	},
	text::DocumentText,
};

#[allow(clippy::too_many_arguments)]
pub fn current<P: Platform>(
	view: &SessionView,
	member_locator: &str,
	directories: &Directories<P>,
	rooms: &RoomRuntime<P>,
	grants: &[GrantView],
	handed: &[HandedRoom],
	shares: &[ArchiveShare],
) -> Result<Snapshot, Error> {
	view.read(|state| {
		let pending = state
			.pending_ids()?
			.map(|id| field(id.text(), "pending effect id"))
			.collect::<Result<Vec<_>, _>>()?;
		Ok(Snapshot {
			revision: SafeInteger::new(state.revision()?)
				.ok_or_else(|| exceeds("session revision is not a safe integer"))?,
			checkpoint: state.checkpoint_handle()?,
			pending_effects: List::new(pending).ok_or_else(|| exceeds("too many pending session effects"))?,
			issues: issues(directories, rooms)?,
			connected_directories: connected(directories)?,
			pending_effect_details: List::new(effect_details(state)?)
				.ok_or_else(|| exceeds("too many pending effect details"))?,
			member_locator: if member_locator.is_empty() {
				Nullable::Null
			} else {
				Nullable::Value(
					Text::new(member_locator.into()).ok_or_else(|| exceeds("member locator exceeds snapshot field"))?,
				)
			},
			room_views: List::new(rooms.views()).ok_or_else(|| exceeds("too many room views"))?,
			archive_shares: List::new(shares.to_vec()).ok_or_else(|| exceeds("too many archive shares"))?,
			directory_views: directory_views(directories)?,
			access: Access::Admin,
			workspace_adoption: state.workspace_adoption()?,
			grants: List::new(grants.to_vec()).ok_or_else(|| exceeds("too many grants"))?,
			suspended_note: None,
			handed_rooms: List::new(handed.to_vec()).ok_or_else(|| exceeds("too many handed rooms"))?,
		})
	})?
}

#[allow(clippy::too_many_arguments)]
pub fn encode<P: Platform>(
	view: &SessionView,
	member_locator: &str,
	directories: &Directories<P>,
	rooms: &RoomRuntime<P>,
	grants: &[GrantView],
	handed: &[HandedRoom],
	shares: &[ArchiveShare],
	access: Access,
	note: &DocumentText,
	extra_issues: &[(Field, Field)],
) -> Result<Vec<glowcap::Argument>, Error> {
	current(view, member_locator, directories, rooms, grants, handed, shares)?
		.project::<rooms_glowcap::snapshot::Arguments>(access, note, extra_issues)
		.map_err(|refusal| Error::Invalid(refusal.to_string()))
}

/// An issue that belongs to one attachment rather than to the session.
pub fn attachment_issue(subject: &str, reason: &str) -> Result<(Field, Field), Error> {
	issue(subject, reason)
}

/// A value that does not fit the snapshot's bounded fields. The session
/// produced it, so it is a runtime fault rather than a caller refusal.
fn exceeds(what: &str) -> Error {
	Error::Invalid(what.into())
}

fn effect_details(state: &SessionState) -> Result<Vec<(Field, Field, Field, EffectPhase)>, Error> {
	state
		.pending()?
		.map(|view| match view {
			PendingView::Ordinary { id, subject } => Ok((
				field(id.text(), "pending effect id")?,
				Field::new("external".into()).ok_or_else(|| exceeds("effect kind exceeds snapshot field"))?,
				field(subject.text(), "pending effect subject")?,
				EffectPhase::Unresolved,
			)),
			PendingView::Result(result) => Ok((
				field(result.id.text(), "pending effect id")?,
				field(result.kind.text(), "pending effect kind")?,
				Field::new(
					describe_result(
						result.kind.text().as_str().unwrap_or(""),
						result.intent.text().as_str().unwrap_or(""),
					)
					.into(),
				)
				.ok_or_else(|| exceeds("pending effect description exceeds snapshot field"))?,
				result.phase,
			)),
		})
		.collect()
}

fn describe_result(kind: &str, intent: &str) -> String {
	let name = serde_json::from_str::<serde_json::Value>(intent)
		.ok()
		.and_then(|value| value.get("conversation")?.get("name")?.as_str().map(str::to_owned));
	match (kind, name.as_deref()) {
		("room-link", Some(name)) => format!("Save a durable link for room \"{name}\""),
		("room-steward", Some(name)) => format!("Take the moderator capability for room \"{name}\""),
		("room-manager", Some(name)) => format!("Take the manager capability for room \"{name}\""),
		("managed-room", Some(name)) => format!("Create managed room \"{name}\""),
		_ => "Recover an external session operation".into(),
	}
}

fn field(text: &DocumentText, what: &str) -> Result<Field, Error> {
	Field::new(text.clone()).ok_or_else(|| exceeds(&format!("{what} exceeds snapshot field")))
}

pub fn handed(rows: &[&rooms_application::room::handoff::View]) -> Vec<HandedRoom> {
	rows.iter()
		.filter_map(|view| {
			Some(HandedRoom {
				id: view.id.clone(),
				directory: view.directory.clone(),
				label: view.label.clone(),
				from: Text::new(view.from.text().clone())?,
			})
		})
		.collect()
}

fn connected<P: Platform>(directories: &Directories<P>) -> Result<List<Field, 32>, Error> {
	let ids = directories
		.rows()
		.iter()
		.filter(|row| row.phase() == Phase::Connected)
		.map(|row| field(row.id().text(), "connected directory id"))
		.collect::<Result<Vec<_>, _>>()?;
	List::new(ids).ok_or_else(|| exceeds("too many connected directories"))
}

fn directory_views<P: Platform>(directories: &Directories<P>) -> Result<List<DirectoryView, 32>, Error> {
	let mut remaining = directory::MAX_ROWS;
	let views = directories
		.rows()
		.iter()
		.filter_map(|row| row.live())
		.map(|live| {
			let view = live.view().snapshot(remaining);
			remaining = remaining.saturating_sub(view.rooms.len() + view.peers().len());
			Ok(DirectoryView {
				directory_id: view.directory_id.clone(),
				rooms: List::new(view.rooms.to_vec())
					.ok_or_else(|| exceeds("directory room page exceeds snapshot field"))?,
				peers: List::new(view.peers().cloned().collect())
					.ok_or_else(|| exceeds("directory peer page exceeds snapshot field"))?,
				truncated: view.truncated,
			})
		})
		.collect::<Result<Vec<_>, Error>>()?;
	List::new(views).ok_or_else(|| exceeds("too many directory views"))
}

fn issues<P: Platform>(
	directories: &Directories<P>,
	rooms: &RoomRuntime<P>,
) -> Result<List<(Field, Field), MAX_ISSUES>, Error> {
	let mut rows = Vec::new();
	if let Some(failure) = directories.failure() {
		rows.push(issue("runtime", failure)?);
	}
	for row in directories.rows() {
		if let Some(error) = row.issue() {
			let id = row
				.id()
				.text()
				.as_str()
				.ok_or_else(|| exceeds("directory id is not Unicode"))?;
			rows.push(issue(&format!("directory:{id}"), error)?);
		}
	}
	for (kind, id, error) in directories.fact_issues() {
		let id = id.as_str().ok_or_else(|| exceeds("issue subject is not Unicode"))?;
		rows.push(issue(&format!("{kind}:{id}"), error)?);
	}
	for (subject, error) in rooms.issues() {
		rows.push(issue(&subject, &error)?);
	}
	List::new(rows).ok_or_else(|| exceeds("too many session issues"))
}

fn issue(subject: &str, reason: &str) -> Result<(Field, Field), Error> {
	Ok((
		Field::new(subject.into()).ok_or_else(|| exceeds("issue subject exceeds snapshot field"))?,
		Field::new(reason.into()).ok_or_else(|| exceeds("issue reason exceeds snapshot field"))?,
	))
}
