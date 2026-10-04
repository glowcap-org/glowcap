//! Durable plans and pure appliers for returned room authority. Obtaining the
//! returned capabilities belongs to the runtime; decoding a plan grants none.
use super::*;
mod entry;
use crate::room::policy::RoomPolicy;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Kind {
	RoomEntry,
	ManagedRoom,
	RoomLink,
	RoomManager,
	RoomSteward,
}
impl Kind {
	pub fn as_str(self) -> &'static str {
		match self {
			Self::RoomEntry => "room-entry",
			Self::ManagedRoom => "managed-room",
			Self::RoomLink => "room-link",
			Self::RoomManager => "room-manager",
			Self::RoomSteward => "room-steward",
		}
	}
	pub fn parse(value: &str) -> Option<Self> {
		match value {
			"room-entry" => Some(Self::RoomEntry),
			"managed-room" => Some(Self::ManagedRoom),
			"room-link" => Some(Self::RoomLink),
			"room-manager" => Some(Self::RoomManager),
			"room-steward" => Some(Self::RoomSteward),
			_ => None,
		}
	}
}
crate::session::command::catalog! { Command {
	TakeRoomLink,
	EnsureRoomLink,
	LinkRoom,
	TakeRoomModerator,
	TakeRoomManager,
	RecoverRoomManager,
	OpenManagedRoom,
} }

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct AuthorityIntent {
	conversation: Room,
	#[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
	steward_link: Option<Bearer>,
	#[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
	manager_link: Option<Bearer>,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct ManagedIntent {
	conversation: Room,
	recovery_key: Text<33, true>,
	policy: RoomPolicy,
}
#[derive(PartialEq, Eq)]
enum Intent {
	Entry(entry::Intent),
	Authority(AuthorityIntent),
	Managed(ManagedIntent),
}
pub struct Plan {
	kind: Kind,
	intent: Intent,
}

impl Command {
	pub fn arity(self) -> core::ops::RangeInclusive<usize> {
		match self {
			Self::OpenManagedRoom => 5..=5,
			Self::TakeRoomModerator => 1..=2,
			Self::TakeRoomManager => 2..=2,
			_ => 1..=1,
		}
	}
	pub fn prepare(
		self,
		current: &Checkpoint,
		args: &[DocumentText],
		routes: &impl Routes,
		allow_existing: bool,
	) -> Result<Plan, Error> {
		if !self.arity().contains(&args.len()) {
			return Err(Error::Arguments);
		}
		if self == Self::TakeRoomLink {
			return entry::prepare(current, json(&args[0], MAX_JSON)?, routes);
		}
		if self == Self::OpenManagedRoom {
			let modes = [
				args[2].as_str().ok_or(Error::Arguments)?,
				args[3].as_str().ok_or(Error::Arguments)?,
				args[4].as_str().ok_or(Error::Arguments)?,
			];
			let policy = RoomPolicy::parse(&modes).ok_or(Error::Arguments)?;
			return prepare_managed(
				current,
				ManagedIntent {
					conversation: json(&args[0], MAX_JSON)?,
					recovery_key: text(&args[1])?,
					policy,
				},
				routes,
				allow_existing,
			);
		}
		let room = named_room(&current.0, &args[0])?;
		let kind = match self {
			Self::TakeRoomModerator => Kind::RoomSteward,
			Self::TakeRoomManager | Self::RecoverRoomManager => Kind::RoomManager,
			_ => Kind::RoomLink,
		};
		if kind == Kind::RoomLink && room.link.is_some() && !allow_existing {
			return Err(Error::Conflict);
		}
		let steward_link = if kind == Kind::RoomSteward {
			if let Some(arg) = args.get(1) {
				Some(bearer(arg, routes)?)
			} else {
				room.steward.clone()
			}
		} else {
			None
		};
		let manager_link = if self == Self::TakeRoomManager {
			Some(bearer(&args[1], routes)?)
		} else {
			None
		};
		Ok(Plan {
			kind,
			intent: Intent::Authority(AuthorityIntent {
				conversation: room.clone(),
				steward_link,
				manager_link,
			}),
		})
	}
}
fn prepare_managed(
	current: &Checkpoint,
	intent: ManagedIntent,
	routes: &impl Routes,
	allow_existing: bool,
) -> Result<Plan, Error> {
	validate_managed(&intent, routes)?;
	let room = &intent.conversation;
	if room.held == intent.policy.is_listed() {
		return Err(Error::Conflict);
	}
	if let Some(existing) = current.0.conversations.0.iter().find(|c| c.id() == &room.id) {
		let Conversation::Room(existing) = existing else {
			return Err(Error::Conflict);
		};
		if !allow_existing
			|| existing.link.is_none()
			|| existing.directory != room.directory
			|| existing.name != room.name
			|| existing.held != room.held
		{
			return Err(Error::Conflict);
		}
	} else {
		let mut candidate = current.0.clone();
		push(
			&mut candidate.conversations,
			Conversation::Room(alloc::boxed::Box::new(room.clone())),
		)?;
		validate::state(&mut candidate, routes)?;
	}
	if !current
		.0
		.directories
		.0
		.iter()
		.any(|d| d.id == room.directory && d.nick.0.utf16().next().is_some())
	{
		return Err(Error::NamedDirectory);
	}
	Ok(Plan {
		kind: Kind::ManagedRoom,
		intent: Intent::Managed(intent),
	})
}
impl Plan {
	/// Owned plan and graph capacity; shared holders may charge this value
	/// conservatively for each admitted request without copying the graph.
	pub fn retained_bytes(&self) -> usize {
		use super::super::footprint::HeapBytes;
		let heap = match &self.intent {
			Intent::Entry(v) => v.retained_bytes(),
			Intent::Authority(v) => v
				.conversation
				.heap_bytes()
				.saturating_add(v.steward_link.heap_bytes())
				.saturating_add(v.manager_link.heap_bytes()),
			Intent::Managed(v) => v.conversation.heap_bytes().saturating_add(v.recovery_key.heap_bytes()),
		};
		core::mem::size_of::<Self>().saturating_add(heap)
	}
	pub fn kind(&self) -> Kind {
		self.kind
	}
	pub fn intent(&self) -> Result<DocumentText, Error> {
		match &self.intent {
			Intent::Entry(v) => serde_json::to_string(v),
			Intent::Authority(v) => serde_json::to_string(v),
			Intent::Managed(v) => serde_json::to_string(v),
		}
		.map(Into::into)
		.map_err(|_| Error::Json)
	}
	fn room(&self) -> &Room {
		match &self.intent {
			Intent::Entry(v) => &v.conversation,
			Intent::Authority(v) => &v.conversation,
			Intent::Managed(v) => &v.conversation,
		}
	}
	pub fn entry_directory(&self) -> Option<(&DocumentText, &DocumentText, &DocumentText)> {
		match &self.intent {
			Intent::Entry(v) => Some((&v.conversation.directory.0, &v.locator.0, &v.nick.0)),
			_ => None,
		}
	}
	pub fn entry_link(&self) -> Option<&str> {
		match &self.intent {
			Intent::Entry(v) => v.conversation.link.as_ref()?.0.as_str(),
			_ => None,
		}
	}
	pub fn entry_returned(&self, current: &Checkpoint, existing: Option<&str>, name: &str) -> Result<String, Error> {
		entry::returned(current, existing, name)
	}
	pub fn directory(&self) -> &DocumentText {
		&self.room().directory.0
	}
	pub fn conversation(&self) -> &DocumentText {
		&self.room().id.0
	}
	pub fn label(&self) -> &DocumentText {
		&self.room().name.0
	}
	pub fn recovery_key(&self) -> Option<&DocumentText> {
		match &self.intent {
			Intent::Managed(v) => Some(&v.recovery_key.0),
			_ => None,
		}
	}
	pub fn policy(&self) -> Option<RoomPolicy> {
		match &self.intent {
			Intent::Managed(v) => Some(v.policy),
			_ => None,
		}
	}
	pub fn steward(&self) -> Option<&DocumentText> {
		match &self.intent {
			Intent::Authority(v) => v.steward_link.as_ref().map(|v| &v.0),
			_ => None,
		}
	}
	pub fn manager(&self) -> Option<&DocumentText> {
		match &self.intent {
			Intent::Authority(v) => v.manager_link.as_ref().map(|v| &v.0),
			_ => None,
		}
	}
	/// Validate durable intent before publication or recovery execution. Schema
	/// validity does not establish that the checkpoint still admits the operation.
	pub fn decode(kind: Kind, raw: &DocumentText, routes: &impl Routes) -> Result<Self, Error> {
		let intent = if kind == Kind::RoomEntry {
			let intent = json(raw, MAX_JSON)?;
			entry::validate_intent(&intent, routes)?;
			Intent::Entry(intent)
		} else if kind == Kind::ManagedRoom {
			let intent: ManagedIntent = json(raw, MAX_JSON)?;
			validate_managed(&intent, routes)?;
			Intent::Managed(intent)
		} else {
			let intent: AuthorityIntent = json(raw, MAX_JSON)?;
			room_schema(&intent.conversation, routes)?;
			for link in [&intent.steward_link, &intent.manager_link].into_iter().flatten() {
				validate::route(&link.0, routes, true)?;
			}
			Intent::Authority(intent)
		};
		Ok(Self { kind, intent })
	}
	/// Recheck a saved plan against the current checkpoint before asking the
	/// runtime to resume an external call. Retain the original intent in its ledger.
	pub fn resume(&self, current: &Checkpoint, routes: &impl Routes) -> Result<Self, Error> {
		self.reprepare(current, routes, true)
	}
	/// New reservations must still describe the exact checkpoint they inspected.
	/// Completed retries are admitted by the ledger before this fresh-plan check.
	pub fn validate_fresh(&self, current: &Checkpoint, routes: &impl Routes) -> Result<(), Error> {
		let prepared = self.reprepare(current, routes, false)?;
		if prepared.kind != self.kind || prepared.intent != self.intent {
			return Err(Error::Conflict);
		}
		Ok(())
	}
	fn reprepare(&self, current: &Checkpoint, routes: &impl Routes, allow_existing: bool) -> Result<Self, Error> {
		match &self.intent {
			Intent::Entry(intent) => entry::prepare(current, intent.clone(), routes),
			Intent::Managed(intent) => prepare_managed(current, intent.clone(), routes, allow_existing),
			Intent::Authority(intent) => {
				let command = match self.kind {
					Kind::RoomLink => Command::EnsureRoomLink,
					Kind::RoomSteward => Command::TakeRoomModerator,
					_ if intent.manager_link.is_some() => Command::TakeRoomManager,
					_ => Command::RecoverRoomManager,
				};
				let mut args = alloc::vec![intent.conversation.id.0.clone()];
				let link = match self.kind {
					Kind::RoomSteward => intent.steward_link.as_ref(),
					Kind::RoomManager => intent.manager_link.as_ref(),
					_ => None,
				};
				if let Some(link) = link {
					args.push(link.0.clone());
				}
				command.prepare(current, &args, routes, allow_existing)
			}
		}
	}
	pub fn apply(&self, current: &Checkpoint, raw: &DocumentText, routes: &impl Routes) -> Result<Checkpoint, Error> {
		if let Intent::Entry(intent) = &self.intent {
			return entry::apply(current, intent, raw, routes);
		}
		let returned = Returned::decode(self.kind, raw, routes)?;
		let mut next = current.0.clone();
		match &self.intent {
			Intent::Entry(_) => unreachable!("entry handled above"),
			Intent::Authority(intent) => {
				let Conversation::Room(room) = conversation(&mut next, &intent.conversation.id.0)? else {
					return Err(Error::Missing);
				};
				let saved = &intent.conversation;
				if room.directory != saved.directory
					|| room.name != saved.name
					|| room.held != saved.held
					|| room.publication_id != saved.publication_id
					|| room.link.as_ref().is_some_and(|v| v != &returned.room)
					|| (self.kind == Kind::RoomManager
						&& room
							.manager
							.as_ref()
							.is_some_and(|v| Some(v) != returned.manager.as_ref()))
					|| (self.kind == Kind::RoomSteward
						&& room
							.steward
							.as_ref()
							.is_some_and(|v| Some(v) != returned.steward.as_ref()))
					|| (self.kind == Kind::RoomSteward
						&& intent
							.steward_link
							.as_ref()
							.is_some_and(|v| Some(v) != returned.steward.as_ref()))
				{
					return Err(Error::Conflict);
				}
				room.reconnect = None;
				room.link = Some(returned.room);
				if self.kind == Kind::RoomManager {
					room.manager = returned.manager;
				}
				if self.kind == Kind::RoomSteward {
					room.steward = returned.steward;
				}
			}
			Intent::Managed(intent) => {
				let saved = &intent.conversation;
				let room = Room {
					kind: RoomKind::Room,
					id: saved.id.clone(),
					directory: saved.directory.clone(),
					name: saved.name.clone(),
					held: saved.held,
					link: Some(returned.room),
					manager: returned.manager,
					standing: saved.standing.clone(),
					draft: saved.draft.clone(),
					reconnect: None,
					steward: None,
					publication_id: None,
					bridge_intent: Presence::Missing,
				};
				if let Some(existing) = next.conversations.0.iter().find(|c| c.id() == &saved.id) {
					if matches!(existing, Conversation::Room(existing) if **existing == room)
						&& next.active.as_ref().is_some_and(|a| a.0 == saved.id.0)
					{
						return Ok(Checkpoint(next));
					}
					return Err(Error::Conflict);
				}
				let directory = next
					.directories
					.0
					.iter()
					.find(|d| d.id == room.directory)
					.ok_or(Error::Missing)?;
				let intent = join::Intent {
					locator: text(&directory.locator.0)?,
					nick: directory.nick.clone(),
					nick_allocation: directory.nick_allocation,
					conversation: room,
				};
				join::apply(&mut next, intent, routes, &())?;
			}
		}
		validate::state(&mut next, routes)?;
		Ok(Checkpoint(next))
	}
}

fn room_schema(room: &Room, routes: &impl Routes) -> Result<(), Error> {
	for link in [&room.link, &room.manager, &room.steward].into_iter().flatten() {
		validate::route(&link.0, routes, true)?;
	}
	Ok(())
}
fn validate_managed(intent: &ManagedIntent, routes: &impl Routes) -> Result<(), Error> {
	room_schema(&intent.conversation, routes)?;
	let room = &intent.conversation;
	let id = intent.recovery_key.0.as_str().ok_or(Error::Arguments)?;
	if !crate::directory::creation::RecoveryKey::accepts(id)
		|| room.link.is_some()
		|| room.steward.is_some()
		|| room.publication_id.is_some()
	{
		return Err(Error::Arguments);
	}
	Ok(())
}
fn bearer(text: &DocumentText, routes: &impl Routes) -> Result<Bearer, Error> {
	let value = super::text(text)?;
	validate::route(text, routes, true)?;
	Ok(value)
}
struct Returned {
	room: Bearer,
	manager: Option<Bearer>,
	steward: Option<Bearer>,
}
impl Returned {
	fn decode(kind: Kind, raw: &DocumentText, routes: &impl Routes) -> Result<Self, Error> {
		#[derive(Deserialize)]
		#[serde(deny_unknown_fields, rename_all = "camelCase")]
		struct Link {
			room_link: Bearer,
		}
		#[derive(Deserialize)]
		#[serde(deny_unknown_fields, rename_all = "camelCase")]
		struct Manager {
			room_link: Bearer,
			manager_link: Bearer,
		}
		#[derive(Deserialize)]
		#[serde(deny_unknown_fields, rename_all = "camelCase")]
		struct Steward {
			room_link: Bearer,
			steward_link: Bearer,
		}
		let value = match kind {
			Kind::RoomLink => {
				let v: Link = json(raw, MAX_JSON)?;
				Self {
					room: v.room_link,
					manager: None,
					steward: None,
				}
			}
			Kind::RoomSteward => {
				let v: Steward = json(raw, MAX_JSON)?;
				Self {
					room: v.room_link,
					manager: None,
					steward: Some(v.steward_link),
				}
			}
			_ => {
				let v: Manager = json(raw, MAX_JSON)?;
				Self {
					room: v.room_link,
					manager: Some(v.manager_link),
					steward: None,
				}
			}
		};
		for link in [Some(&value.room), value.manager.as_ref(), value.steward.as_ref()]
			.into_iter()
			.flatten()
		{
			validate::route(&link.0, routes, true)?;
		}
		Ok(value)
	}
}
/// Shared result callback for the durable engine's marker/checkpoint protocol.
pub fn apply(
	current: &Checkpoint,
	kind: &crate::session::state::ResultKind,
	intent: &crate::session::state::ResultText,
	result: &crate::session::state::ResultText,
	routes: &impl Routes,
) -> Result<Checkpoint, crate::session::state::Error> {
	let kind = kind
		.text()
		.as_str()
		.and_then(Kind::parse)
		.ok_or(crate::session::state::Error::ResultChanged)?;
	Plan::decode(kind, intent.text(), routes)
		.and_then(|plan| plan.apply(current, result.text(), routes))
		.map_err(crate::session::state::Error::Command)
}
