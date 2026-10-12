//! Live realization uses the exact source that acquired a row. The private
//! owner restores that source only. Public admission selects every target.
use super::Session;
use glowcap::{Result, loam};
use rooms_application::{
	content::session::{custody, results, workspace},
	fields::Text,
};
use rooms_glowcap::client::{
	Deadline, Tasks,
	workspace::{Command, ResultAcquisition, ResultImport, Snapshot, Workspace},
};
mod direct;

/// Scalar target selections survive a worker wait. Drafts, message lists and
/// unrelated workspace choices are neither copied nor treated as generations.
#[derive(Clone, PartialEq, Eq)]
enum Selection {
	Direct {
		id: workspace::Id,
		directory: workspace::Id,
		peer: workspace::Id,
		access: Option<custody::FieldKey<custody::DirectAccess>>,
		introduction: Option<workspace::Introduction>,
		inbox: Option<custody::FieldKey<custody::DirectInbox>>,
		source: custody::FieldKey<custody::SessionAccess>,
	},
	Directory {
		id: workspace::Id,
		access: custody::FieldKey<custody::DirectoryAccess>,
		name: Option<custody::FieldKey<custody::DirectoryName>>,
		inbox: Option<custody::FieldKey<custody::DirectoryInbox>>,
		nick: Text<32>,
		allocation: rooms_application::directory::registration::NicknameAllocation,
		source: custody::FieldKey<custody::SessionAccess>,
	},
	Room {
		id: workspace::Id,
		directory: workspace::Id,
		nickname: workspace::RoomNickname,
		access: Option<custody::FieldKey<custody::RoomAccess>>,
		accepted: Option<custody::FieldKey<custody::AcceptedAccess>>,
		public_entry: Option<workspace::PublicEntry>,
		publication: Option<Text<128, true>>,
		seat: Option<custody::FieldKey<custody::RoomSeat>>,
		topic: Option<custody::FieldKey<custody::RoomTopic>>,
		files: Option<custody::FieldKey<custody::RoomFiles>>,
		inbox: Option<custody::FieldKey<custody::RoomInbox>>,
		source: custody::FieldKey<custody::SessionAccess>,
	},
}
/// A worker can prepare effects and acquire their results. It holds no raw
/// directory, room or private root. Missing source custody is a refusal.
pub struct Source<P> {
	workspace: Workspace<P>,
	selection: Selection,
}
/// A receipt stays bound to the worker selection that prepared it. A newer
/// worker cannot adopt an older operation for the same display ID.
pub struct Operation<P> {
	command: Command<P>,
	selection: Selection,
}
impl<P> core::ops::Deref for Operation<P> {
	type Target = Command<P>;
	fn deref(&self) -> &Self::Target {
		&self.command
	}
}
pub struct MembershipDestinations {
	pub seat: custody::FieldKey<custody::RoomSeat>,
	pub topic: Option<custody::FieldKey<custody::RoomTopic>>,
	pub files: Option<custody::FieldKey<custody::RoomFiles>>,
}
fn refuse(message: &str) -> glowcap::Error {
	loam::refusal(message)
}
fn coordinate<K>(role: custody::Role, key: custody::FieldKey<K>) -> custody::Coordinate {
	custody::Coordinate {
		role,
		key: custody::FieldKey::new(key.slot(), key.generation()),
	}
}
fn encoded<T: serde::Serialize>(value: &T) -> Result<String> {
	serde_json::to_string(value).map_err(|_| refuse("invalid worker field selection"))
}
fn result<T: serde::de::DeserializeOwned>(value: &glowcap::Argument) -> Result<T> {
	let Some([data, glowcap::Argument::List(_)]) = value.as_list() else {
		return Err(refuse("worker effect has no committed result"));
	};
	serde_json::from_str(data.as_str().ok_or_else(|| refuse("invalid worker result"))?)
		.map_err(|_| refuse("invalid worker result"))
}
impl Selection {
	fn id(&self) -> &workspace::Id {
		match self {
			Self::Directory { id, .. } | Self::Room { id, .. } | Self::Direct { id, .. } => id,
		}
	}
	fn source(&self) -> custody::FieldKey<custody::SessionAccess> {
		match self {
			Self::Directory { source, .. } | Self::Room { source, .. } | Self::Direct { source, .. } => *source,
		}
	}
	fn matches(&self, intent: &workspace::Intent) -> bool {
		match self {
			Self::Direct { id, directory, peer, access, introduction, inbox, source } => intent.conversations.as_slice().iter().any(|row| {
				matches!(row, workspace::Conversation::Direct(row) if row.id == *id && !row.closed
					&& row.directory == *directory && row.peer == *peer && (introduction.is_some() || row.access == *access)
					&& row.introduction == *introduction
					&& row.inbox == *inbox && row.source == Some(*source))
			}),
			Self::Directory {
				id,
				access,
				name,
				inbox,
				nick,
				allocation,
				source,
			} => intent.directories.as_slice().iter().any(|row| {
				row.id == *id
					&& row.access == *access
					&& row.name == *name
					&& row.inbox == *inbox
					&& row.nick == *nick
					&& row.nick_allocation == *allocation
					&& row.source == Some(*source)
			}),
			Self::Room {
				id,
				directory,
				nickname,
				access,
				accepted,
				public_entry,
				publication,
				seat,
				topic,
				files,
				inbox,
				source,
			} => intent.conversations.as_slice().iter().any(|row| {
				matches!(row, workspace::Conversation::Room(row) if row.id == *id && row.directory == *directory
					&& row.requests_membership() && row.access == *access && row.accepted == *accepted && row.public_entry == *public_entry && row.publication == *publication
					&& row.seat == *seat && row.topic == *topic && row.files == *files && row.inbox == *inbox && row.source == Some(*source)
					&& nickname.matches(intent, directory))
			}),
		}
	}
}
impl<P: Tasks + Deadline + Clone + 'static> Session<P> {
	/// Create one local callback owner before acquiring its occurrence and row
	/// atomically. Only the row's exact initiating grant admits received work.
	/// Callbacks before installation or after replacement are refused. Retain and
	/// close this owner through the worker lifecycle before closing the session.
	pub async fn inbox(
		&self,
		selected: workspace::InboxSelection,
		mut receive: impl FnMut(&[glowcap::Argument]) -> core::result::Result<(), String> + 'static,
	) -> Result<super::Inbox<P>> {
		if matches!(selected, workspace::InboxSelection::Direct { .. }) {
			return Err(refuse("direct callbacks require the direct inbox receiver"));
		}
		self.open_inbox(selected, move |_, args, _, _| {
			receive(args).map(|()| glowcap::Argument::Void)
		})
		.await
	}
	/// Retain the delivering connection and raw capability occurrences across
	/// original-source admission. The receiver returns the actual posted-line
	/// result. Cancellation breaks the outstanding answer before actor retirement.
	pub async fn direct_inbox(
		&self,
		selected: workspace::InboxSelection,
		mut receive: impl FnMut(
			&str,
			&[glowcap::Argument],
			Option<glowcap::Session>,
		) -> core::result::Result<glowcap::Argument, String>
		+ 'static,
	) -> Result<super::Inbox<P>> {
		if !matches!(selected, workspace::InboxSelection::Direct { .. }) {
			return Err(refuse("direct inbox requires an exact direct selection"));
		}
		self.open_inbox(selected, move |verb, args, delivering, _| {
			receive(verb, args, delivering)
		})
		.await
	}
	pub(super) async fn open_inbox(
		&self,
		selected: workspace::InboxSelection,
		receive: impl FnMut(
			&str,
			&[glowcap::Argument],
			Option<glowcap::Session>,
			&super::InboxOrigin,
		) -> core::result::Result<glowcap::Argument, String>
		+ 'static,
	) -> Result<super::Inbox<P>> {
		if self.state.closing.get() {
			return Err(refuse("session is closing"));
		}
		let mut held = self
			.restore_custody(&[coordinate(custody::Role::SessionAccess, selected.source())])
			.await?;
		if self.state.closing.get() {
			return Err(refuse("session is closing"));
		}
		super::inbox::open(
			&self.state.writer.host,
			self.state.platform.clone(),
			Workspace::local(
				self.state.writer.host.clone(),
				self.state.platform.clone(),
				held.remove(0),
			),
			selected,
			self.state.inboxes.clone(),
			receive,
		)
	}
	pub async fn directory_source(&self, row: &workspace::Directory) -> Result<Source<P>> {
		self.realization_source(Selection::Directory {
			id: row.id.clone(),
			access: row.access,
			name: row.name,
			inbox: row.inbox,
			nick: row.nick.clone(),
			allocation: row.nick_allocation,
			source: row
				.source
				.ok_or_else(|| refuse("directory has no initiating session source"))?,
		})
		.await
	}
	pub async fn room_source(&self, row: &workspace::Room, intent: &workspace::Intent) -> Result<Source<P>> {
		if !row.requests_membership() || !row.has_entrance() {
			return Err(refuse("room has no held entrance"));
		}
		self.realization_source(Selection::Room {
			id: row.id.clone(),
			directory: row.directory.clone(),
			nickname: workspace::RoomNickname::select(intent, &row.directory)
				.ok_or_else(|| refuse("room has no directory nickname"))?,
			access: row.access,
			accepted: row.accepted,
			public_entry: row.public_entry.clone(),
			publication: row.publication.clone(),
			seat: row.seat,
			topic: row.topic,
			files: row.files,
			inbox: row.inbox,
			source: row
				.source
				.ok_or_else(|| refuse("room has no initiating session source"))?,
		})
		.await
	}
	async fn realization_source(&self, selection: Selection) -> Result<Source<P>> {
		if self.state.closing.get() {
			return Err(refuse("session is closing"));
		}
		let mut held = self
			.restore_custody(&[coordinate(custody::Role::SessionAccess, selection.source())])
			.await?;
		let source = held.remove(0);
		// Shared wakes cover this owner's content and grant inventory. Foreign
		// session custody can be imported, but cannot realize a local worker.
		// Compare descriptive keys without passing the private root to a target.
		let expected = self.state.writer.idempotent("resource-key", &[]).await?;
		let actual = self
			.state
			.writer
			.idempotent_through(&source, "resource-key", &[])
			.await?;
		if actual != expected {
			return Err(refuse("worker source belongs to another session"));
		}
		Ok(Source {
			workspace: Workspace::local(self.state.writer.host.clone(), self.state.platform.clone(), source),
			selection,
		})
	}
}
impl<P: Deadline + Clone> Source<P> {
	pub(super) fn workspace(&self) -> &Workspace<P> {
		&self.workspace
	}
	/// Prepare installation through the original source. A full candidate is
	/// retained only through this atomic acquisition, not in the live worker.
	pub(super) async fn prepare_inbox(
		&self,
		selected: &workspace::InboxSelection,
		inbox: &glowcap::Ref,
	) -> Result<(rooms_glowcap::client::workspace::Acquisition<P>, Self)> {
		let mut snapshot = self.snapshot().await?;
		let mut selection = self.selection.clone();
		let retired = match (&mut selection, selected) {
			(
				Selection::Direct { id, inbox: prior, .. },
				workspace::InboxSelection::Direct {
					id: next_id,
					inbox: next,
					..
				},
			) if id == next_id => {
				let retired = direct::install(&mut snapshot.intent, id, *next)?;
				*prior = Some(*next);
				retired
			}
			(
				Selection::Directory { id, inbox: prior, .. },
				workspace::InboxSelection::Directory {
					id: next_id,
					inbox: next,
					..
				},
			) if id == next_id => {
				let row = snapshot
					.intent
					.directories
					.as_mut_slice()
					.iter_mut()
					.find(|row| row.id == *id)
					.ok_or_else(|| refuse("directory was retired"))?;
				let retired = row
					.inbox
					.replace(*next)
					.map(|key| coordinate(custody::Role::DirectoryInbox, key));
				*prior = Some(*next);
				retired
			}
			(
				Selection::Room { id, inbox: prior, .. },
				workspace::InboxSelection::Room {
					id: next_id,
					inbox: next,
					..
				},
			) if id == next_id => {
				let row = snapshot
					.intent
					.conversations
					.as_mut_slice()
					.iter_mut()
					.find_map(|row| match row {
						workspace::Conversation::Room(row) if row.id == *id => Some(row),
						_ => None,
					})
					.ok_or_else(|| refuse("room was retired"))?;
				let retired = row
					.inbox
					.replace(*next)
					.map(|key| coordinate(custody::Role::RoomInbox, key));
				*prior = Some(*next);
				retired
			}
			_ => return Err(refuse("inbox belongs to another worker target")),
		};
		if !selected.matches(&snapshot.intent) {
			return Err(refuse("inbox belongs to another initiating source or entrance"));
		}
		let retired = retired.filter(|old| !snapshot.intent.coordinates().any(|field| field == *old));
		let request = self
			.workspace
			.prepare_acquisition(
				snapshot.revision,
				vec![rooms_glowcap::client::workspace::Import {
					coordinate: selected.coordinate(),
					reference: inbox.clone(),
					uri: None,
				}],
				retired.as_slice(),
				&snapshot.intent,
			)
			.map_err(|e| refuse(&e.to_string()))?;
		Ok((
			request,
			Self {
				workspace: self.workspace.clone(),
				selection,
			},
		))
	}
	async fn snapshot(&self) -> Result<Snapshot> {
		let snapshot = self.workspace.snapshot().await.map_err(|e| refuse(&e.to_string()))?;
		if !self.selection.matches(&snapshot.intent) {
			return Err(refuse("worker target or initiating source changed"));
		}
		Ok(snapshot)
	}
	pub async fn directory_reader(&self) -> Result<rooms_glowcap::client::workspace::DirectoryReader<P>> {
		if !matches!(self.selection, Selection::Directory { .. }) {
			return Err(refuse("directory discovery requires a directory source"));
		}
		self.snapshot().await?;
		self.workspace
			.directory_reader(
				self.selection
					.id()
					.text()
					.as_str()
					.ok_or_else(|| refuse("invalid directory ID"))?,
			)
			.await
			.map_err(|error| refuse(&error.to_string()))
	}
	pub async fn register(
		&self,
		operation: &str,
		locator: &str,
		inbox: custody::FieldKey<custody::DirectoryInbox>,
	) -> Result<Operation<P>> {
		if !matches!(self.selection, Selection::Directory { inbox: Some(selected), .. } if selected == inbox) {
			return Err(refuse("registration requires the directory's installed inbox"));
		}
		let snapshot = self.snapshot().await?;
		let row = snapshot
			.intent
			.directories
			.as_slice()
			.iter()
			.find(|row| row.id == *self.selection.id())
			.ok_or_else(|| refuse("directory was retired"))?;
		let command = self
			.workspace
			.prepare_command(
				operation,
				snapshot.revision,
				"joinDirectory",
				&[
					self.selection
						.id()
						.text()
						.as_str()
						.ok_or_else(|| refuse("invalid directory ID"))?
						.into(),
					row.nick
						.text()
						.as_str()
						.ok_or_else(|| refuse("invalid directory nickname"))?
						.into(),
					locator.into(),
					row.nick_allocation.wire().into(),
					encoded(&inbox)?,
				],
			)
			.await
			.map_err(|e| refuse(&e.to_string()))?;
		Ok(Operation {
			command,
			selection: self.selection.clone(),
		})
	}
	pub async fn subscribe(
		&self,
		operation: &str,
		inbox: custody::FieldKey<custody::RoomInbox>,
	) -> Result<Operation<P>> {
		if !matches!(self.selection, Selection::Room { inbox: Some(selected), .. } if selected == inbox) {
			return Err(refuse("subscription requires the room's installed inbox"));
		}
		let snapshot = self.snapshot().await?;
		let nick = self.room_nick()?;
		let command = self
			.workspace
			.prepare_command(
				operation,
				snapshot.revision,
				"joinRoom",
				&[
					self.selection
						.id()
						.text()
						.as_str()
						.ok_or_else(|| refuse("invalid room ID"))?
						.into(),
					nick.into(),
					encoded(&inbox)?,
				],
			)
			.await
			.map_err(|e| refuse(&e.to_string()))?;
		Ok(Operation {
			command,
			selection: self.selection.clone(),
		})
	}
	fn room_nick(&self) -> Result<&str> {
		let Selection::Room { nickname, .. } = &self.selection else {
			return Err(refuse("room nickname requires a room selection"));
		};
		// snapshot already checked this immutable identity against current intent.
		nickname
			.text()
			.text()
			.as_str()
			.ok_or_else(|| refuse("room has no directory nickname"))
	}
	fn original_arguments(&self, command: &Operation<P>, expected: &str) -> Result<Vec<String>> {
		if command.selection != self.selection || command.source() != self.workspace.reference() {
			return Err(refuse("worker result belongs to another initiating source"));
		}
		let (_, _, name, arguments): (String, u64, String, Vec<String>) =
			serde_json::from_str(command.canonical()).map_err(|_| refuse("invalid worker command"))?;
		if name != expected || arguments.first().map(String::as_str) != self.selection.id().text().as_str() {
			return Err(refuse("worker result belongs to another target or operation"));
		}
		Ok(arguments)
	}
	/// The returned request owns one bounded candidate encoding and scalar
	/// mapping/release spines through unknown outcome and exact replay. Capability
	/// edges move inside Loam. No upstream actor is disclosed to the worker.
	pub async fn acquire_registration(
		&self,
		command: &Operation<P>,
		destination: custody::FieldKey<custody::DirectoryName>,
	) -> Result<ResultAcquisition<P>> {
		let Selection::Directory { id, .. } = &self.selection else {
			return Err(refuse("registration acquisition requires a directory worker"));
		};
		let original = self.original_arguments(command, "joinDirectory")?;
		let acquired: results::Registration = result(&command.result().await.map_err(|e| refuse(&e.to_string()))?)?;
		let mut snapshot = self.snapshot().await?;
		let row = snapshot
			.intent
			.directories
			.as_mut_slice()
			.iter_mut()
			.find(|row| row.id == *id)
			.ok_or_else(|| refuse("directory was retired"))?;
		if original.get(1).map(String::as_str) != row.nick.text().as_str()
			|| original.get(3).map(String::as_str) != Some(row.nick_allocation.wire())
		{
			return Err(refuse("directory nickname intent changed during registration"));
		}
		let releases = row
			.name
			.filter(|old| *old != destination)
			.map(|key| coordinate(custody::Role::DirectoryName, key));
		row.name = Some(destination);
		row.assigned_nick =
			Some(Text::new(acquired.nick.text().clone()).ok_or_else(|| refuse("invalid granted nickname"))?);
		let releases = releases.filter(|old| !snapshot.intent.coordinates().any(|field| field == *old));
		command.prepare_result_acquisition(
			snapshot.revision,
			&[ResultImport {
				result: coordinate(custody::Role::DirectoryName, acquired.name),
				destination: coordinate(custody::Role::DirectoryName, destination),
			}],
			releases.as_slice(),
			&snapshot.intent,
		)
	}
	pub async fn acquire_membership(
		&self,
		command: &Operation<P>,
		destination: MembershipDestinations,
	) -> Result<ResultAcquisition<P>> {
		let Selection::Room { id, .. } = &self.selection else {
			return Err(refuse("membership acquisition requires a room worker"));
		};
		let original = self.original_arguments(command, "joinRoom")?;
		let acquired: results::Membership = result(&command.result().await.map_err(|e| refuse(&e.to_string()))?)?;
		if acquired.topic.is_some() != destination.topic.is_some()
			|| acquired.files.is_some() != destination.files.is_some()
		{
			return Err(refuse("membership destinations do not match the committed facets"));
		}
		let mut snapshot = self.snapshot().await?;
		if original.get(1).map(String::as_str) != Some(self.room_nick()?) {
			return Err(refuse("room nickname intent changed during subscription"));
		}
		let row = snapshot
			.intent
			.conversations
			.as_mut_slice()
			.iter_mut()
			.find_map(|row| match row {
				workspace::Conversation::Room(row) if row.id == *id => Some(row),
				_ => None,
			})
			.ok_or_else(|| refuse("room was retired"))?;
		let selected = [
			(
				Some(coordinate(custody::Role::RoomSeat, acquired.seat)),
				Some(coordinate(custody::Role::RoomSeat, destination.seat)),
				row.seat.map(|key| coordinate(custody::Role::RoomSeat, key)),
			),
			(
				acquired.topic.map(|key| coordinate(custody::Role::RoomTopic, key)),
				destination.topic.map(|key| coordinate(custody::Role::RoomTopic, key)),
				row.topic.map(|key| coordinate(custody::Role::RoomTopic, key)),
			),
			(
				acquired.files.map(|key| coordinate(custody::Role::RoomFiles, key)),
				destination.files.map(|key| coordinate(custody::Role::RoomFiles, key)),
				row.files.map(|key| coordinate(custody::Role::RoomFiles, key)),
			),
		];
		let imports: Vec<_> = selected
			.iter()
			.filter_map(|(result, destination, _)| {
				Some(ResultImport {
					result: (*result)?,
					destination: (*destination)?,
				})
			})
			.collect();
		let mut releases: Vec<_> = selected
			.iter()
			.filter_map(|(_, destination, old)| old.filter(|old| Some(*old) != *destination))
			.collect();
		row.seat = Some(destination.seat);
		row.topic = destination.topic;
		row.files = destination.files;
		releases.retain(|old| !snapshot.intent.coordinates().any(|field| field == *old));
		command.prepare_result_acquisition(snapshot.revision, &imports, &releases, &snapshot.intent)
	}
}
