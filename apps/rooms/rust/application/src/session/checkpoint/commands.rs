//! Pure Rooms checkpoint transitions. The caller supplies current live facts;
//! this module neither fetches authority nor performs storage or network I/O.
mod invitations;
pub use invitations::{accept_handed, receive_room_link};
#[cfg(test)]
mod direct_tests;
mod join;
mod peering;
#[cfg(test)]
mod peering_tests;
mod preferences;
pub mod results;

use super::{fields::*, model::*, validate, Checkpoint, Routes};
use crate::{session::state::Impact, text::DocumentText};
use alloc::{string::String, vec};
use serde::{Deserialize, Serialize};

/// Publication generations come from the adapter's existing sturdyref parser.
/// A generation is an identity comparison, never permission to invoke a room.
pub trait CommandRoutes: Routes {
	fn authority_token(&self, sturdyref: &str) -> Option<String>;
}
pub trait Facts {
	fn room_publication(&self, _directory: &DocumentText, _name: &DocumentText) -> Option<&DocumentText> {
		None
	}
	fn bridge_scope(&self, _conversation: &DocumentText) -> Option<DocumentText> {
		None
	}
}
impl Facts for () {}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Command {
	SetDraft,
	Select,
	AcceptInvitation,
	DismissInvitation,
	ReceiveRoomLinkInvitation,
	SetStanding,
	JoinDirectory,
	LeaveDirectory,
	SetDirectoryNick,
	JoinRoom,
	StartDirect,
	OpenDirect,
	PublishPeeredRoom,
	RevokePeeredRoom,
	ReplaceOperationsCapabilities,
	ReplaceOperationsBundle,
	LeaveConversation,
	CloseDirect,
	SetDirectoryStanding,
	SetRoomStanding,
	SetEffectiveStanding,
	DropRoomModerator,
	DropRoomManager,
	SubmitRoomBridgeForm,
	SetIgnoredNames,
	SetIgnoredName,
	ChooseHistoryRetention,
	ChooseConnection,
	SelectArchive,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	Arguments,
	Size,
	Json,
	Missing,
	Conflict,
	NamedDirectory,
	Generation,
	OperationsScope,
	Publication,
	Checkpoint(super::Refusal),
}
impl From<super::Refusal> for Error {
	fn from(value: super::Refusal) -> Self {
		Self::Checkpoint(value)
	}
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Arguments => "invalid Rooms command arguments",
			Self::Size => "Rooms command exceeds its text or collection limit",
			Self::Json => "Rooms command received invalid JSON data",
			Self::Missing => "Rooms command names no current entry in this session",
			Self::Conflict => "Rooms command conflicts with the current checkpoint",
			Self::NamedDirectory => "choose an acceptable directory nickname before continuing",
			Self::Generation => "the room's retained capability generation changed",
			Self::OperationsScope => "the operations capability scope changed while the edit was pending",
			Self::Publication => "the room's source has no matching current publication",
			Self::Checkpoint(error) => return error.fmt(f),
		})
	}
}
impl core::error::Error for Error {}

impl Command {
	/// Retry identity excludes secret answers. Bridge public answers use their
	/// validated insertion order, exactly as the durable Rooms command does.
	pub fn material(self, args: &[DocumentText]) -> Result<DocumentText, Error> {
		struct Material<'a>(Command, &'a [DocumentText]);
		impl Serialize for Material<'_> {
			fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
				use serde::ser::SerializeSeq;
				let mut seq = serializer.serialize_seq(Some(self.1.len() + 1))?;
				seq.serialize_element(&self.0)?;
				for arg in self.1 {
					seq.serialize_element(arg)?;
				}
				seq.end()
			}
		}
		let mut normalized;
		let args = if self == Self::SubmitRoomBridgeForm {
			let submission = BridgeSubmission::parse(args)?;
			normalized = vec![
				submission.conversation,
				submission.intent.scope.0,
				submission.intent.action.0,
				serde_json::to_string(&submission.intent.answers)
					.map_err(|_| Error::Json)?
					.into(),
			];
			if let Some(revision) = submission.intent.credential_revision {
				normalized.push(revision.0);
			}
			&normalized
		} else {
			args
		};
		serde_json::to_string(&Material(self, args))
			.map(Into::into)
			.map_err(|_| Error::Json)
	}
	pub fn impact(self) -> Impact {
		match self {
			Self::SetStanding | Self::SetDirectoryStanding | Self::SetRoomStanding | Self::SetEffectiveStanding => {
				Impact::Standing
			}
			Self::SetDraft
			| Self::Select
			| Self::DismissInvitation
			| Self::ReceiveRoomLinkInvitation
			| Self::SetIgnoredNames
			| Self::SetIgnoredName
			| Self::ChooseHistoryRetention
			| Self::ChooseConnection => Impact::Presentation,
			_ => Impact::Realization,
		}
	}
	/// A candidate owns a clone of the bounded checkpoint graph. It becomes
	/// observable only after the durable state engine acknowledges its write.
	/// Final relationship validation traverses that graph without a JSON roundtrip.
	pub fn apply(
		self,
		current: &Checkpoint,
		args: &[DocumentText],
		routes: &impl CommandRoutes,
		facts: &impl Facts,
	) -> Result<Checkpoint, Error> {
		let arity = match self {
			Self::Select | Self::SelectArchive => 0..=1,
			Self::SetDirectoryStanding | Self::SetRoomStanding => 1..=2,
			Self::SetDraft
			| Self::SetEffectiveStanding
			| Self::SetIgnoredName
			| Self::AcceptInvitation
			| Self::SetDirectoryNick
			| Self::DropRoomModerator
			| Self::DropRoomManager
			| Self::ChooseConnection => 2..=2,
			Self::ReplaceOperationsBundle => 3..=3,
			Self::SubmitRoomBridgeForm => 5..=6,
			_ => 1..=1,
		};
		if !arity.contains(&args.len()) {
			return Err(Error::Arguments);
		}
		let mut next = current.0.clone();
		match self {
			Self::SetDraft => {
				let draft = text(&args[1])?;
				match conversation(&mut next, &args[0])? {
					Conversation::Room(c) => c.draft = draft,
					Conversation::Direct(c) => c.draft = draft,
				}
			}
			Self::Select => {
				if let Some(id) = args.first() {
					conversation(&mut next, id)?;
				}
				next.active = optional(args.first())?;
			}
			Self::AcceptInvitation => invitations::accept(&mut next, args, routes)?,
			Self::DismissInvitation => {
				let index = next
					.invitations
					.0
					.iter()
					.position(|v| v.id.0 == args[0])
					.ok_or(Error::Missing)?;
				next.invitations.0.remove(index);
			}
			Self::ReceiveRoomLinkInvitation => invitations::receive(&mut next, &args[0], routes)?,
			Self::SetStanding => next.standing = text(&args[0])?,
			Self::SetEffectiveStanding => preferences::standing(&mut next, &args[0], &args[1])?,
			Self::JoinDirectory => {
				let directory: Directory = json(&args[0], MAX_JSON)?;
				if next
					.directories
					.0
					.iter()
					.any(|d| d.id == directory.id || (d.home && directory.home))
				{
					return Err(Error::Conflict);
				}
				push(&mut next.directories, directory)?;
			}
			Self::LeaveDirectory => peering::retire_directory(&mut next, &args[0])?,
			Self::SetDirectoryNick | Self::SetDirectoryStanding => {
				let directory = next
					.directories
					.0
					.iter_mut()
					.find(|d| d.id.0 == args[0])
					.ok_or(Error::Missing)?;
				if self == Self::SetDirectoryNick {
					directory.nick = text(&args[1])?;
				} else {
					directory.standing = optional(args.get(1))?;
				}
			}
			Self::JoinRoom => join::apply(&mut next, json(&args[0], MAX_JSON)?, routes, facts)?,
			Self::StartDirect | Self::OpenDirect => {
				let direct: Direct = json(&args[0], MAX_JSON)?;
				if self == Self::OpenDirect {
					next.active = Nullable::Value(Text(direct.id.0.clone()));
				}
				if let Some(existing) = next.conversations.0.iter_mut().find(|c| c.id() == &direct.id) {
					let Conversation::Direct(existing) = existing else {
						return Err(Error::Conflict);
					};
					if existing.directory != direct.directory
						|| existing.peer_registration_id != direct.peer_registration_id
					{
						return Err(Error::Conflict);
					}
					// Repeated concurrent gestures and reopening retain drafts
					// and identity; they cannot substitute another registration.
					existing.closed = false;
					existing.peer = direct.peer;
				} else {
					push(
						&mut next.conversations,
						Conversation::Direct(alloc::boxed::Box::new(direct)),
					)?;
				}
			}
			Self::ReplaceOperationsBundle => {
				if args[2].as_str() != Some(current.operations_bundle_context().as_str()) {
					return Err(Error::OperationsScope);
				}
				peering::replace_bundle(&mut next, &args[0], &args[1])?;
			}
			Self::PublishPeeredRoom | Self::RevokePeeredRoom | Self::ReplaceOperationsCapabilities => {
				peering::apply(&mut next, self, &args[0])?;
			}
			Self::LeaveConversation => {
				let directory = conversation(&mut next, &args[0])?.directory().clone();
				next.conversations.0.retain(|c| c.id().0 != args[0]);
				next.peering.0.retain(|p| p.source.0 != args[0]);
				if next.active.as_ref().is_some_and(|id| id.0 == args[0]) {
					select_remaining(&mut next, Some(&directory));
				}
			}
			Self::CloseDirect => {
				let Conversation::Direct(d) = conversation(&mut next, &args[0])? else {
					return Err(Error::Missing);
				};
				d.closed = true;
			}
			Self::SetRoomStanding => {
				let Conversation::Room(r) = conversation(&mut next, &args[0])? else {
					return Err(Error::Missing);
				};
				r.standing = optional(args.get(1))?;
			}
			Self::DropRoomModerator | Self::DropRoomManager => {
				let Conversation::Room(r) = conversation(&mut next, &args[0])? else {
					return Err(Error::Missing);
				};
				let slot = if self == Self::DropRoomManager {
					&mut r.manager
				} else {
					&mut r.steward
				};
				let held = slot.as_ref().ok_or(Error::Generation)?;
				let token = routes.authority_token(&held.0.utf8_lossy()).ok_or(Error::Generation)?;
				if token.is_empty() || args[1].as_str() != Some(token.as_str()) {
					return Err(Error::Generation);
				}
				*slot = None;
			}
			Self::SubmitRoomBridgeForm => {
				let submission = BridgeSubmission::parse(args)?;
				let directory = named_room(&next, &args[0])?.directory.clone();
				for c in &mut next.conversations.0 {
					let Conversation::Room(r) = c else {
						continue;
					};
					if r.directory == directory
						&& (r.id.0 == args[0]
							|| facts.bridge_scope(&r.id.0).as_ref() == Some(&submission.intent.scope.0)
							|| matches!(&r.bridge_intent, Presence::Value(b) if b.scope == submission.intent.scope))
					{
						r.bridge_intent = Presence::Value(submission.intent.clone());
					}
				}
			}
			Self::SetIgnoredNames => next.ignored = json(&args[0], MAX_JSON)?,
			Self::SetIgnoredName => preferences::ignored(&mut next, &args[0], &args[1])?,
			Self::ChooseHistoryRetention => {
				next.keep_history = match args[0].as_str() {
					Some("true") => true,
					Some("false") => false,
					_ => return Err(Error::Arguments),
				}
			}
			Self::ChooseConnection => {
				next.dm_mode = match args[0].as_str() {
					Some("webrtc") => DmMode::Webrtc,
					Some("relay") => DmMode::Relay,
					_ => return Err(Error::Arguments),
				};
				next.viz_override = text(&args[1])?;
			}
			Self::SelectArchive => next.capabilities.archive_peer = optional(args.first())?,
		}
		validate::state(&mut next, routes)?;
		Ok(Checkpoint(next))
	}
}

/// Secret answers have a separate owner and accessor; serializing the intent
/// cannot accidentally include them. Adapters retain these only in secret custody.
pub struct BridgeSubmission {
	conversation: DocumentText,
	intent: Bridge,
	secrets: Answers,
}
impl BridgeSubmission {
	pub fn inspect(args: &[DocumentText]) -> Result<Self, Error> {
		if args.len() != 5 {
			return Err(Error::Arguments);
		}
		Self::read(args)
	}
	pub fn parse(args: &[DocumentText]) -> Result<Self, Error> {
		if !(5..=6).contains(&args.len()) {
			return Err(Error::Arguments);
		}
		let submission = Self::read(args)?;
		if submission.intent.secrets_given && submission.intent.credential_revision.is_none() {
			return Err(Error::Arguments);
		}
		Ok(submission)
	}
	fn read(args: &[DocumentText]) -> Result<Self, Error> {
		let secrets: Answers = json(&args[4], 16 * 1024)?;
		let credential_revision = if secrets.is_empty() {
			None
		} else {
			args.get(5).map(text).transpose()?
		};
		Ok(Self {
			conversation: args[0].clone(),
			intent: Bridge {
				scope: text(&args[1])?,
				action: text(&args[2])?,
				answers: json(&args[3], 16 * 1024)?,
				secrets_given: !secrets.is_empty(),
				credential_revision,
			},
			secrets,
		})
	}
	pub fn conversation(&self) -> &DocumentText {
		&self.conversation
	}
	pub fn scope(&self) -> &DocumentText {
		&self.intent.scope.0
	}
	pub fn secrets(&self) -> &Answers {
		&self.secrets
	}
}

pub struct RoomOffer<'a> {
	pub room: &'a DocumentText,
	pub direct: &'a DocumentText,
	pub label: &'a DocumentText,
	pub link: Option<&'a DocumentText>,
}
pub fn prepare_offer<'a>(current: &'a Checkpoint, args: &[DocumentText]) -> Result<RoomOffer<'a>, Error> {
	if args.len() != 2 {
		return Err(Error::Arguments);
	}
	let Some(Conversation::Room(room)) = current.0.conversations.0.iter().find(|c| c.id().0 == args[0]) else {
		return Err(Error::Missing);
	};
	let Some(Conversation::Direct(direct)) = current.0.conversations.0.iter().find(|c| c.id().0 == args[1]) else {
		return Err(Error::Missing);
	};
	if direct.closed || direct.directory != room.directory {
		return Err(Error::Conflict);
	}
	Ok(RoomOffer {
		room: &room.id.0,
		direct: &direct.id.0,
		label: &room.name.0,
		link: room.link.as_ref().map(|v| &v.0),
	})
}

const MAX_JSON: usize = 512 * 1024;
fn json<T: serde::de::DeserializeOwned>(raw: &DocumentText, limit: usize) -> Result<T, Error> {
	if raw.utf16().take(limit + 1).count() > limit {
		return Err(Error::Size);
	}
	// JSON source can contain literal lone UTF-16 surrogates inside a string.
	// Escape only those code units; replacing them would change durable intent.
	let scalar = raw.json_source().ok_or(Error::Json)?;
	serde_json::from_str(&scalar).map_err(|_| Error::Json)
}
fn text<const N: usize, const NONEMPTY: bool>(raw: &DocumentText) -> Result<Text<N, NONEMPTY>, Error> {
	Text::new(raw.clone()).ok_or(Error::Size)
}
fn optional<const N: usize>(raw: Option<&DocumentText>) -> Result<Nullable<Text<N>>, Error> {
	raw.map(text)
		.transpose()
		.map(|v| v.map_or(Nullable::Null, Nullable::Value))
}
fn push<T, const N: usize>(list: &mut List<T, N>, value: T) -> Result<(), Error> {
	list.try_push(value).map_err(|_| Error::Size)
}
fn conversation<'a>(state: &'a mut State, id: &DocumentText) -> Result<&'a mut Conversation, Error> {
	state
		.conversations
		.0
		.iter_mut()
		.find(|c| &c.id().0 == id)
		.ok_or(Error::Missing)
}

/// Reconcile selection after its authoritative conversation is removed.
/// A remaining room keeps its roster available for reopening direct threads;
/// within that, the directory the reader was using is the least surprising
/// continuation. A closed direct thread is never selected as a fallback.
fn select_remaining(state: &mut State, preferred_directory: Option<&Id>) {
	let selected = state
		.conversations
		.0
		.iter()
		.filter(|conversation| !matches!(conversation, Conversation::Direct(direct) if direct.closed))
		.min_by_key(|conversation| {
			(
				matches!(conversation, Conversation::Direct(_)),
				preferred_directory.is_some_and(|directory| conversation.directory() != directory),
			)
		})
		.map(|conversation| conversation.id().0.clone());
	state.active = selected.map_or(Nullable::Null, |id| Nullable::Value(Text(id)));
}
fn named_room<'a>(state: &'a State, id: &DocumentText) -> Result<&'a Room, Error> {
	let Some(Conversation::Room(room)) = state.conversations.0.iter().find(|c| &c.id().0 == id) else {
		return Err(Error::Missing);
	};
	if !state
		.directories
		.0
		.iter()
		.any(|d| d.id == room.directory && d.nick.0.utf16().next().is_some())
	{
		return Err(Error::NamedDirectory);
	}
	Ok(room)
}
