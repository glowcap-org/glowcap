//! A host process attached to a Rooms session over CapTP. The view holds one
//! use capability. It reads the session's activity after a cursor the caller
//! keeps, says lines, moves file bytes, and passes any other session command
//! through. It reconnects nothing, retries nothing, and keeps no global state outside the
//! test-support build: the caller owns policy, cursors, and operation identities. A line the view
//! says stays editable and withdrawable through the session's ordinary
//! commands, because the session keeps the authority the posting returned.
mod direct;
mod error;
mod events;
mod fault;
mod files;
mod grant;
mod holder;
mod keep;
mod link;
mod recovered;

use glowcap::{Ref, Runtime, loam::UseDescription};
use rooms_application::{
	content::session::workspace::Adoption,
	files::receiving::Budget,
	room::authority::REQUEST_TIMEOUT_MS,
	session::{command::Request, effect::Reply},
};
use rooms_glowcap::client::{
	Client, Deadline, Tasks,
	sources::Sources,
	workspace::{Command, Workspace},
};
use std::path::Path;

pub use direct::{First, Introduction, Opened, Reach};
pub use error::{Error, GiveBack};
pub use events::{Attachment, Batch, Change, Conversation, Event, Kind, Line, Notice, Step};
use fault::ViewFault;
#[cfg(feature = "test-support")]
pub use fault::{forfeit_reached, meet_before_keeping_direct};
pub use files::Outgoing;
pub(crate) use grant::failed;
pub use grant::{
	Grant, GrantId, Grants, Issued, Lifecycle, MAX_LABEL_BYTES, State, change, describe, inventory, issue_at,
	issue_under, place,
};
use keep::Effect;
pub(crate) use keep::released_within;
pub use recovered::Recovered;
pub use rooms_application::room::mentions::Mentions;
pub use rooms_glowcap::client::{
	Error as ClientError,
	workspace::{EffectStatus, Holder, Release, Snapshot},
};

/// The most events one `View::events` call returns.
pub const MAX_BATCH: usize = 64;
/// The most activity events a session keeps. A reader further behind meets
/// a gap.
pub use rooms_runtime::session::managed::MAX_ACTIVITY_EVENTS;
use rooms_runtime::session::managed::command_reply;

/// A write that reached the session, and the base it was made at. Keep both
/// to observe the same operation later.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Sent {
	pub operation: String,
	pub base: u64,
	pub status: EffectStatus,
}
/// How a post's files stand when [`View::send_files`] returns.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Files {
	/// Every file reached the room.
	Complete,
	/// The line stands and its files could not be completed, for the cause.
	Incomplete(String),
	/// The post's answer was not settled within the wait, so its files may
	/// still be filling.
	Unfinished,
}
/// A post with files: the write, and how its files stand.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Uploaded {
	pub sent: Sent,
	pub files: Files,
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
		let state = workspace.describe_access().await.map_err(link::failure)?;
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
	/// released or is held to keep it later.
	pub async fn say(&self, operation: &str, conversation: &str, text: &str) -> Result<Sent, Error> {
		let before = self.snapshot().await?;
		if let Some(sent) = conflicted(ViewFault::SayConflict, operation, before.revision) {
			return Ok(sent);
		}
		let command = self
			.prepared(operation, before.revision, "say", &[conversation.into(), text.into()])
			.await?;
		Ok(self
			.post(&command, conversation, before, REQUEST_TIMEOUT_MS, false)
			.await?
			.0)
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
		self.keep_line_result(Effect::Command(&command), conversation, &now.intent)
			.await
	}
	/// Give up the receipt of a `say_at` the caller will not keep, so it no
	/// longer holds one of the session's receipt places. The line stays as it
	/// posted, or unposted, and the operation must never be sent again. A
	/// receipt already released or gone answers [`Release::Released`]. One
	/// whose executor runs answers [`Release::Running`] and stays until the
	/// executor settles or pauses, and the session retires a paused executor.
	/// One whose line was adopted answers [`Release::Kept`] and stays adopted.
	/// The session keeps a released receipt until newer receipts push it out,
	/// and answers a resend of its operation from it.
	pub async fn release_line(
		&self,
		operation: &str,
		base: u64,
		conversation: &str,
		text: &str,
	) -> Result<Release, Error> {
		let command = self
			.prepared(operation, base, "say", &[conversation.into(), text.into()])
			.await?;
		match command.release().await {
			Ok(release) => Ok(release),
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
	/// Post up to eight regular files with `caption`, and wait up to `wait_ms`
	/// for the room to hold every file. Failure before delivery leaves nothing
	/// posted. An `Uncertain` error may have posted, and the files must not be
	/// sent again. A committed post is kept as `say` keeps a line, and a
	/// failure to read how its files stand is reported as `Unkept` the same
	/// way. Its files are [`Files::Complete`], or [`Files::Incomplete`] when the room
	/// stopped receiving them. A post that has not settled when the wait ends
	/// has [`Files::Unfinished`] files, which go on filling while this session
	/// reads the sources.
	pub async fn send_files(
		&self,
		operation: &str,
		conversation: &str,
		caption: &str,
		files: &[Outgoing],
		wait_ms: u64,
	) -> Result<Uploaded, Error> {
		let before = self.snapshot().await?;
		if let Some(sent) = conflicted(ViewFault::SendConflict, operation, before.revision) {
			return Ok(Uploaded {
				sent,
				files: Files::Unfinished,
			});
		}
		let command = self
			.upload(operation, before.revision, conversation, caption, files)
			.await?;
		let (sent, files) = self.post(&command, conversation, before, wait_ms, true).await?;
		Ok(Uploaded { sent, files })
	}
	/// Send any session command under the caller's identity and base. The
	/// session still decides rights and grammar. A committed posting command
	/// (`say`, `sendFiles`, `refileLine`) has its line kept the way `say`
	/// keeps one, and reports `Unkept` the same way. A committed `startDirect`
	/// has its route kept the way `open_direct` keeps one, and reports
	/// `Unopened` the same way. Any other command that returns a capability
	/// is refused as [`Error::Unkeepable`] before it is sent, because nothing
	/// here would keep it. One that returns data only is sent, and if its
	/// receipt still holds a place once it committed, that reports
	/// [`Error::Forfeited`].
	pub async fn command(
		&self,
		operation: &str,
		base: u64,
		name: &str,
		arguments: &[String],
	) -> Result<EffectStatus, Error> {
		if fault::conflicts(ViewFault::CommandConflict, operation) {
			return Ok(EffectStatus::Conflict);
		}
		unkeepable(operation, base, name, arguments)?;
		let command = self.prepared(operation, base, name, arguments).await?;
		let status = self.submit(&command, base).await?;
		if status == EffectStatus::Committed {
			self.keep_posted(&command, base, name, arguments).await?;
		}
		Ok(status)
	}
	/// Keep the line or route an earlier `command` committed under
	/// `operation` at `base`, the way `command` keeps it. A command that
	/// returns neither keeps nothing, and one whose receipt still holds a
	/// place for it is [`Error::Forfeited`] with that receipt given back.
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
	/// Keep the line or route a committed `command` returned. The workspace is
	/// read now and stands for the one the command was sent against, as
	/// `keep_line` does. A result that cannot be kept reports `Unkept` or
	/// `Unopened`, because the command committed either way, and the cause
	/// decides its receipt (`Error::refuses_keeping`): a refusal that never
	/// clears gives it back, and a failure that clears with time, such as a
	/// failed read, a lost connection, or a workspace that moved on every
	/// attempt, holds it (`GiveBack::Held`), so a later keep or the sweep's
	/// `settle_effect` can still adopt the line. Any other result is forfeited
	/// (`forfeit`).
	async fn keep_posted(
		&self,
		command: &Command<D>,
		base: u64,
		name: &str,
		arguments: &[String],
	) -> Result<(), Error> {
		let Some(adoption) = Adoption::of(name, arguments) else {
			return self.forfeit(Effect::Command(command), base).await;
		};
		let now = match fault::lose(ViewFault::KeepRead) {
			Ok(()) => self.snapshot().await,
			Err(injected) => Err(injected),
		};
		match now {
			Ok(now) => {
				self.kept(Effect::Command(command), base, adoption, Ok(&now.intent))
					.await
			}
			Err(cause) => self.kept(Effect::Command(command), base, adoption, Err(cause)).await,
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
	async fn post(
		&self,
		command: &Command<D>,
		conversation: &str,
		before: Snapshot,
		wait_ms: u64,
		uploads: bool,
	) -> Result<(Sent, Files), Error> {
		let base = before.revision;
		let status = self.submit_for(command, base, wait_ms).await?;
		if status == EffectStatus::Committed
			&& let Some(cause) = fault::once(ViewFault::PostLost).or_else(|| fault::once(ViewFault::PostLostUnkept))
		{
			// The command committed and its receipt is held, and its answer is
			// lost.
			return Err(Error::Uncertain { base, cause });
		}
		let status = match status {
			// The command committed and its receipt is held, and the caller is
			// told it is still pending, as an answer past its bound leaves it.
			EffectStatus::Committed if fault::once(ViewFault::PostUnconfirmed).is_some() => EffectStatus::Pending,
			status => status,
		};
		// The outcome is read before the line is kept, which may give the
		// receipt back.
		let files = if !uploads || status != EffectStatus::Committed {
			Files::Unfinished
		} else {
			self.upload_outcome(Effect::Command(command), base, conversation)
				.await?
		};
		if status == EffectStatus::Committed {
			self.kept(
				Effect::Command(command),
				base,
				Adoption::Line(conversation),
				Ok(&before.intent),
			)
			.await
			.map_err(|error| error.read_files(uploads.then(|| files.clone())))?;
		}
		let sent = Sent {
			operation: command.operation().into(),
			base,
			status,
		};
		Ok((sent, files))
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
		self.submit_for(command, base, REQUEST_TIMEOUT_MS).await
	}
	/// [`Self::submit`], waiting up to `wait_ms` for the effect to settle.
	async fn submit_for(&self, command: &Command<D>, base: u64, wait_ms: u64) -> Result<EffectStatus, Error> {
		self.submitted_for(command, base, wait_ms)
			.await
			.map_err(Failed::into_error)
	}
	/// [`Self::submit`], with its failure saying whether it proves the command
	/// was never dispatched: nothing reached the session and the session
	/// admitted nothing, so the caller owes no look at it.
	async fn submitted(&self, command: &Command<D>, base: u64) -> Result<EffectStatus, Failed> {
		self.submitted_for(command, base, REQUEST_TIMEOUT_MS).await
	}
	async fn submitted_for(&self, command: &Command<D>, base: u64, wait_ms: u64) -> Result<EffectStatus, Failed> {
		let status = command.submit().await.map_err(|error| (error, false));
		let status = match status {
			Ok(EffectStatus::Pending) => match self.client.platform().within(wait_ms, command.receive()).await {
				Some(settled) => settled.map_err(|error| (error, true)),
				None => Ok(EffectStatus::Pending),
			},
			other => other,
		};
		match status {
			Ok(status) => Ok(status),
			Err((error, delivered)) => {
				let unsent = !delivered && error.known_absent();
				let error = self.after_send(error, base, delivered).await;
				Err(if unsent {
					Failed::Unsent(error)
				} else {
					Failed::Dispatched(error)
				})
			}
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

/// How a submitted command failed.
enum Failed {
	/// Nothing reached the session, and the session admitted nothing.
	Unsent(Error),
	/// The command may have been dispatched.
	Dispatched(Error),
}

impl Failed {
	fn into_error(self) -> Error {
		match self {
			Self::Unsent(error) | Self::Dispatched(error) => error,
		}
	}
}

/// How the files of a committed post stand, from its result text.
fn files_of(result: &str) -> Result<Files, Error> {
	let outcome: rooms_application::content::session::uploads::Outcome =
		serde_json::from_str(result).map_err(|_| Error::Malformed("the post's outcome did not decode"))?;
	Ok(if outcome.files_complete {
		Files::Complete
	} else {
		Files::Incomplete(
			outcome
				.failure
				.map_or_else(String::new, |text| text.text().as_str().unwrap_or_default().to_owned()),
		)
	})
}
/// What a session whose workspace moved under a `say` or `send_files` would
/// answer when `point` is armed and `operation` conflicts: a conflict, which
/// committed nothing.
fn conflicted(point: ViewFault, operation: &str, base: u64) -> Option<Sent> {
	fault::conflicts(point, operation).then(|| Sent {
		operation: operation.into(),
		base,
		status: EffectStatus::Conflict,
	})
}

/// Refuse, before anything is sent, a command whose result carries a
/// capability that no keeper here adopts (`Adoption::of`). The kind of result
/// comes from the route the session's admission takes (`command_reply`), so
/// this view and the session read one decision. A request the grammar refuses
/// is invalid input, as preparing it would answer.
fn unkeepable(operation: &str, base: u64, name: &str, arguments: &[String]) -> Result<(), Error> {
	let request =
		Request::from_parts(operation, base, name, arguments).map_err(|refusal| Error::Input(refusal.to_string()))?;
	if Adoption::of(name, arguments).is_none() && command_reply(&request).is_some_and(Reply::may_retain_capabilities) {
		return Err(Error::Unkeepable { command: name.into() });
	}
	Ok(())
}
