//! A host process attached to a Rooms session over CapTP. The view holds one
//! use capability. It reads the session's activity after a cursor the caller
//! keeps, says lines, moves file bytes, and passes any other session command
//! through. It reconnects nothing, retries nothing, and keeps no global state:
//! the caller owns policy, cursors, and operation identities. A line the view
//! says stays editable and withdrawable through the session's ordinary
//! commands, because the session keeps the authority the posting returned.
mod direct;
mod error;
mod events;
mod files;
mod grant;
mod keep;
mod link;

use glowcap::{Ref, Runtime, loam::UseDescription};
use rooms_application::{
	content::session::workspace::Adoption, files::receiving::Budget, room::authority::REQUEST_TIMEOUT_MS,
};
use rooms_glowcap::client::{
	Client, Deadline, Tasks,
	sources::Sources,
	workspace::{Command, Workspace},
};
use std::path::Path;

pub use direct::Opened;
pub use error::Error;
pub use events::{Attachment, Batch, Change, Conversation, Event, Kind, Line, Notice, Step};
pub use files::Outgoing;
pub(crate) use grant::failed;
pub use grant::{
	Grant, GrantId, Grants, Issued, Lifecycle, MAX_LABEL_BYTES, State, change, describe, inventory, issue_at,
	issue_under, place,
};
pub use rooms_application::room::mentions::Mentions;
pub use rooms_glowcap::client::{
	Error as ClientError,
	workspace::{EffectStatus, Snapshot},
};

/// The most events one `View::events` call returns.
pub const MAX_BATCH: usize = 64;
/// The most activity events a session keeps. A reader further behind meets
/// a gap.
pub use rooms_runtime::session::managed::MAX_ACTIVITY_EVENTS;

/// A write that reached the session, and the base it was made at. Keep both
/// to observe the same operation later.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Sent {
	pub operation: String,
	pub base: u64,
	pub status: EffectStatus,
}
pub struct View<D: Deadline + Tasks + Clone + 'static> {
	workspace: Workspace<D>,
	reader: rooms_glowcap::client::workspace::ActivityReader<D>,
	client: Client<D>,
	sources: Sources<D>,
	budget: Budget,
}
impl<D: Deadline + Tasks + Clone + 'static> View<D> {
	/// Dial the session a use link names, fetch its capability, and attach.
	pub async fn attach(runtime: &Runtime, platform: D, link: &str) -> Result<Self, Error> {
		let reached = link::reach(runtime, platform, link).await?;
		Self::attach_reference(reached.client, reached.reference).await
	}
	/// Attach to a use capability already held, such as issued, attenuated
	/// access. The view reports the access state before it reads anything.
	pub async fn attach_reference(client: Client<D>, reference: Ref) -> Result<Self, Error> {
		let workspace = Workspace::new(client.clone(), reference);
		let state = workspace.describe_access().await.map_err(link::refusal)?;
		match state.view() {
			UseDescription::Active(_) => {}
			UseDescription::Paused => return Err(Error::Paused),
			UseDescription::Revoked => return Err(Error::Revoked),
			UseDescription::OutOfScope => return Err(Error::Refused),
		}
		let platform = client.platform().clone();
		Ok(Self {
			reader: workspace.activity_reader().await.map_err(Error::Peer)?,
			workspace,
			client,
			sources: Sources::new(platform),
			budget: Budget::default(),
		})
	}
	/// Read activity after `cursor`, which is empty for the session's whole
	/// retained backlog. With `wait`, the first read waits a bounded time for
	/// news. Reading stops at the first gap or unavailable event, at idle, or
	/// after `MAX_BATCH` events and skipped rows. A row that does not decode is
	/// skipped by its cursor and counted. Persist `Batch::cursor` to resume.
	pub async fn events(&self, cursor: &str, wait: bool) -> Result<Batch, Error> {
		let mut batch = Batch {
			cursor: cursor.into(),
			..Batch::default()
		};
		while batch.events.len() + batch.unreadable < MAX_BATCH {
			let raw = match self.reader.read(&batch.cursor, wait && batch.events.is_empty()).await {
				Ok(raw) => raw,
				Err(error) => return Err(self.read_failure(error, cursor).await),
			};
			match events::decode(&raw)? {
				Step::Idle { cursor } => {
					batch.cursor = cursor;
					break;
				}
				Step::Event(event) => {
					batch.cursor.clone_from(&event.cursor);
					batch.events.push(event);
				}
				Step::Gap { cursor } => {
					batch.cursor = cursor;
					batch.gap = true;
					break;
				}
				Step::Unavailable { cursor } => {
					batch.cursor = cursor;
					batch.unavailable = true;
					break;
				}
				Step::Unreadable { cursor } => {
					batch.cursor = cursor;
					batch.unreadable += 1;
				}
			}
		}
		Ok(batch)
	}
	/// Say `text` in `conversation` under the caller's `operation` identity at
	/// the session's current revision. A `Conflict` status committed nothing,
	/// and a new operation may try again. A committed line is kept: the session
	/// then holds its authority, and `editLine` and `withdrawLine` sent through
	/// `command` change it. `Unkept` reports a line that posted without that
	/// authority, which must not be said again, and whether its receipt was
	/// released.
	pub async fn say(&self, operation: &str, conversation: &str, text: &str) -> Result<Sent, Error> {
		let before = self.snapshot().await?;
		let command = self
			.prepared(operation, before.revision, "say", &[conversation.into(), text.into()])
			.await?;
		self.post(&command, conversation, before).await
	}
	/// Say `text` in `conversation` under `operation` at `base`, a revision
	/// the caller read and kept, and leave the committed line unkept. A caller
	/// that records the base before it sends can repeat the same send after a
	/// crash, and the session answers it from the original receipt. Keep the
	/// line with `keep_line` once its commit is recorded.
	pub async fn say_at(
		&self,
		operation: &str,
		base: u64,
		conversation: &str,
		text: &str,
	) -> Result<EffectStatus, Error> {
		let command = self
			.prepared(operation, base, "say", &[conversation.into(), text.into()])
			.await?;
		self.submit(&command, base).await
	}
	/// Take the authority of the line a committed `say_at` posted, unless the
	/// session already holds it. The workspace is read now and stands for the
	/// one the line was said against, the way a page recovering a posted line
	/// after a reload adopts it. A conversation that is gone, or holds no room
	/// for another kept line, is refused.
	pub async fn keep_line(&self, operation: &str, base: u64, conversation: &str, text: &str) -> Result<(), Error> {
		let command = self
			.prepared(operation, base, "say", &[conversation.into(), text.into()])
			.await?;
		let now = self.snapshot().await?;
		self.keep_line_result(&command, conversation, &now.intent).await
	}
	/// Give up the receipt of a `say_at` the caller will not keep, so it no
	/// longer holds one of the session's receipt places. The line stays as it
	/// posted, or unposted, and the operation must never be sent again. A
	/// receipt already gone answers done. One whose send is still running in
	/// the session is refused.
	pub async fn release_line(&self, operation: &str, base: u64, conversation: &str, text: &str) -> Result<(), Error> {
		let command = self
			.prepared(operation, base, "say", &[conversation.into(), text.into()])
			.await?;
		match command.release().await {
			Ok(()) => Ok(()),
			Err(error) => Err(self.failure(error).await),
		}
	}
	/// Show the member as typing in `conversation`, or stop, through the seat
	/// of a room or the route of an open direct message the workspace holds
	/// now. Readers clear a notice nobody renews within
	/// `rooms_application::room::membership::TYPING_CLEAR_MS`, so a caller
	/// that keeps typing says so again every `TYPING_RENEW_MS`. Each call
	/// opens its own sender, at the cost of two snapshot reads, one here and
	/// one by the sender, and two calls to the session, one to open the
	/// sender and one to set the level. A conversation with no seat or open
	/// route is refused as input.
	pub async fn typing(&self, conversation: &str, on: bool) -> Result<(), Error> {
		use rooms_application::content::session::{custody, workspace};
		let now = self.snapshot().await?;
		let target = now
			.intent
			.conversations
			.as_slice()
			.iter()
			.find(|row| row.id().text().as_str() == Some(conversation))
			.and_then(|row| match row {
				workspace::Conversation::Room(row) => row
					.seat
					.map(|seat| custody::Coordinate::new(custody::Role::RoomSeat, seat)),
				workspace::Conversation::Direct(row) => row
					.installed_access()
					.map(|route| custody::Coordinate::new(custody::Role::DirectAccess, route)),
			})
			.ok_or_else(|| Error::Input(format!("{conversation} holds no seat or open route to show typing in")))?;
		let shown = match self.workspace.typing_sender(conversation, target).await {
			Ok(sender) => sender.set(on).await,
			Err(error) => Err(error),
		};
		match shown {
			Ok(()) => Ok(()),
			Err(error) => Err(self.failure(error).await),
		}
	}
	/// Post up to eight regular files with `caption`. Failure before delivery
	/// leaves nothing posted. An `Uncertain` error may have posted, and the
	/// files must not be sent again. A committed post is kept as `say` keeps
	/// a line.
	pub async fn send_files(
		&self,
		operation: &str,
		conversation: &str,
		caption: &str,
		files: &[Outgoing],
	) -> Result<Sent, Error> {
		let before = self.snapshot().await?;
		let command = self
			.upload(operation, before.revision, conversation, caption, files)
			.await?;
		self.post(&command, conversation, before).await
	}
	/// Send any session command under the caller's identity and base. The
	/// session still decides rights and grammar. A committed posting command
	/// (`say`, `sendFiles`, `refileLine`) has its line kept the way `say`
	/// keeps one, and reports `Unkept` the same way. A committed `startDirect`
	/// has its route kept the way `open_direct` keeps one, and reports
	/// `Unopened` the same way.
	pub async fn command(
		&self,
		operation: &str,
		base: u64,
		name: &str,
		arguments: &[String],
	) -> Result<EffectStatus, Error> {
		let command = self.prepared(operation, base, name, arguments).await?;
		let status = self.submit(&command, base).await?;
		if status == EffectStatus::Committed {
			self.keep_posted(&command, base, name, arguments).await?;
		}
		Ok(status)
	}
	/// Keep the line or route an earlier `command` committed under
	/// `operation` at `base`, the way `command` keeps it. A command that
	/// returns neither keeps nothing.
	pub async fn keep_command(
		&self,
		operation: &str,
		base: u64,
		name: &str,
		arguments: &[String],
	) -> Result<(), Error> {
		let command = self.prepared(operation, base, name, arguments).await?;
		self.keep_posted(&command, base, name, arguments).await
	}
	/// Keep the line or route a committed `command` returned, or give its
	/// receipt back. The workspace is read now and stands for the one the
	/// command was sent against, as `keep_line` does. A read that fails
	/// reports `Unkept` or `Unopened` too, because the command committed
	/// either way.
	async fn keep_posted(
		&self,
		command: &Command<D>,
		base: u64,
		name: &str,
		arguments: &[String],
	) -> Result<(), Error> {
		let Some(adoption) = Adoption::of(name, arguments) else {
			return Ok(());
		};
		let now = match fault("keep-read") {
			Ok(()) => self.snapshot().await,
			Err(fault) => Err(fault),
		};
		match now {
			Ok(now) => self.kept(command, base, adoption, Ok(&now.intent)).await,
			Err(cause) => self.kept(command, base, adoption, Err(cause)).await,
		}
	}
	/// Read the status of an earlier `command` or `say` without sending it
	/// again. The arguments must be the original ones.
	pub async fn observe(
		&self,
		operation: &str,
		base: u64,
		name: &str,
		arguments: &[String],
	) -> Result<EffectStatus, Error> {
		let command = self.prepared(operation, base, name, arguments).await?;
		self.observed(&command).await
	}
	/// Read `attachment` into `destination`, which must not exist and whose
	/// parent must. The bytes land in a hidden sibling first, so a failed
	/// fetch leaves nothing at `destination`. Returns the bytes written.
	pub async fn fetch(&self, attachment: &Attachment, destination: &Path) -> Result<u64, Error> {
		let described = files::description(attachment)?;
		let _charge = self.budget.reserve(attachment.size).ok_or(Error::Budget)?;
		let blob = self
			.workspace
			.activity_file(&attachment.token, attachment.index)
			.await
			.map_err(Error::Peer)?;
		let file = rooms_glowcap::client::files::File::new(
			self.client.clone(),
			rooms_application::room::attachment::Attachment {
				description: described,
				blob,
			},
		);
		files::write(destination, attachment.size, |offset, length| {
			let file = &file;
			async move { file.read(offset, length).await.map_err(Error::Peer) }
		})
		.await?;
		Ok(attachment.size as u64)
	}
	/// The session's current revision, the base a command is sent at.
	pub async fn revision(&self) -> Result<u64, Error> {
		Ok(self.snapshot().await?.revision)
	}
	/// The session's workspace as it is now, with the revision it was read at.
	pub async fn snapshot(&self) -> Result<Snapshot, Error> {
		match self.workspace.snapshot().await {
			Ok(snapshot) => Ok(snapshot),
			Err(error) => Err(self.failure(error).await),
		}
	}
	/// Deliver a posting command, then keep the line it committed.
	async fn post(&self, command: &Command<D>, conversation: &str, before: Snapshot) -> Result<Sent, Error> {
		let base = before.revision;
		let status = self.submit(command, base).await?;
		if status == EffectStatus::Committed {
			self.kept(command, base, Adoption::Line(conversation), Ok(&before.intent))
				.await?;
		}
		Ok(Sent {
			operation: command.operation().into(),
			base,
			status,
		})
	}
	async fn prepared(
		&self,
		operation: &str,
		base: u64,
		name: &str,
		arguments: &[String],
	) -> Result<Command<D>, Error> {
		self.workspace
			.prepare_command(operation, base, name, arguments)
			.await
			.map_err(|error| Error::Input(error.to_string()))
	}
	async fn upload(
		&self,
		operation: &str,
		base: u64,
		conversation: &str,
		caption: &str,
		files: &[Outgoing],
	) -> Result<Command<D>, Error> {
		let (intent, sources) = files::intent(operation, base, conversation, caption, files)?;
		self.workspace
			.prepare_upload(&intent, &self.sources, sources)
			.await
			.map_err(|error| Error::Input(error.to_string()))
	}
	/// Deliver the command, then wait a bounded time for a pending effect to
	/// settle. A status still `Pending` at the bound is returned as it is.
	async fn submit(&self, command: &Command<D>, base: u64) -> Result<EffectStatus, Error> {
		let status = command.submit().await.map_err(|error| (error, false));
		let status = match status {
			Ok(EffectStatus::Pending) => {
				match self
					.client
					.platform()
					.within(REQUEST_TIMEOUT_MS, command.receive())
					.await
				{
					Some(settled) => settled.map_err(|error| (error, true)),
					None => Ok(EffectStatus::Pending),
				}
			}
			other => other,
		};
		match status {
			Ok(status) => Ok(status),
			Err((error, delivered)) => Err(self.after_send(error, base, delivered).await),
		}
	}
	/// A failure after delivery began is unknown unless the session proved the
	/// effect was never dispatched.
	async fn after_send(&self, error: ClientError, base: u64, delivered: bool) -> Error {
		let lost = error.connection_failed() || matches!(error, ClientError::Observation(_));
		if (delivered || !error.known_absent()) && lost {
			Error::Uncertain { base, cause: error }
		} else {
			self.failure(error).await
		}
	}
	async fn observed(&self, command: &Command<D>) -> Result<EffectStatus, Error> {
		match command.status().await {
			Ok(status) => Ok(status),
			Err(error) => Err(self.failure(error).await),
		}
	}
	/// Name a failed read of activity after `cursor`. A refusal that is not a
	/// lost connection or a change of access may mean the session restarted, so
	/// the session's own cursor is read once to tell.
	async fn read_failure(&self, error: ClientError, cursor: &str) -> Error {
		let failed = self.failure(error).await;
		if !cursor.is_empty()
			&& matches!(failed, Error::Peer(_))
			&& let Ok(raw) = self.reader.read("", false).await
			&& let Ok(step) = events::decode(&raw)
			&& events::restarted(cursor, step.cursor())
		{
			return Error::Stale;
		}
		failed
	}
	/// Name a failed call. A lost connection is unreachable. Otherwise the
	/// access is read again, so a pause or revocation is reported as itself.
	/// A read that answers nothing about the access leaves the call's own
	/// failure standing, because only an answer proves the link is refused.
	async fn failure(&self, error: ClientError) -> Error {
		if error.connection_failed() {
			return Error::Unreachable(error);
		}
		match self.workspace.describe_access().await {
			Ok(state) => match state.view() {
				UseDescription::Active(_) => Error::Peer(error),
				UseDescription::Paused => Error::Paused,
				UseDescription::Revoked => Error::Revoked,
				UseDescription::OutOfScope => Error::Refused,
			},
			Err(probe) if probe.connection_failed() => Error::Unreachable(error),
			Err(_) => Error::Peer(error),
		}
	}
}

/// Test-only: with the `test-support` feature, `GLOWCAP_ROOMS_VIEW_FAULT`
/// names one point to fail as a lost connection would, so a process test can
/// prove a committed command is still reported and its receipt given back.
/// `keep-read` fails the workspace read that keeping a committed command's
/// result starts with, and `adopt-direct` fails keeping an introduced route.
/// A build without the feature fails nothing here.
fn fault(point: &'static str) -> Result<(), Error> {
	#[cfg(feature = "test-support")]
	if std::env::var_os("GLOWCAP_ROOMS_VIEW_FAULT").is_some_and(|named| named == point) {
		return Err(Error::Unreachable(ClientError::Timeout(match point {
			"keep-read" => "the injected keep-read fault",
			_ => "the injected adopt-direct fault",
		})));
	}
	#[cfg(not(feature = "test-support"))]
	let _ = point;
	Ok(())
}
