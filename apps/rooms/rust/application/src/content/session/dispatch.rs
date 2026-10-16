//! Resolve command intent to an existing typed field before retaining an effect.
//! Dispatch never selects authority again after admission or a worker wait.
use super::{custody, workspace};
use crate::{
	room::{ArgumentView, authority, policy::RoomPolicy},
	session::{
		checkpoint::commands::{Command, results},
		command::{Effect, Request, Route},
		effect::{Mutation, Reply},
		operator,
	},
};
use alloc::{string::String, vec, vec::Vec};

pub struct Dispatch {
	selection: Selection,
	pub mutation: Mutation,
	argument: Option<ArgumentTarget>,
	// One validated OperationId, at most 128 UTF-16 units, retained until bind
	// moves it into the original post arguments. No content or authority copy.
	operation: Option<String>,
}
enum ArgumentTarget {
	Inbox(custody::FieldKey<custody::RoomInbox>),
	DirectoryInbox(custody::FieldKey<custody::DirectoryInbox>),
	DirectInbox(custody::FieldKey<custody::DirectInbox>),
	Room(custody::FieldKey<custody::RoomAccess>),
	SelectedRoom(String),
	Revocation {
		room: String,
		moderator: bool,
		expected: custody::FieldKey<custody::RoomAccess>,
	},
}
enum Selection {
	Operator(custody::FieldKey<custody::Operator>),
	Operations(custody::Coordinate, crate::session::operations::mutation::Kind),
	Directory(String),
	Invitation(String),
	Direct(String),
	Introduction(String),
	Post(String),
	Publication(String, custody::FieldKey<custody::PublicationLease>),
	Room(String, RoomTarget),
	Line(String, crate::room::message::LineId),
}
enum RoomTarget {
	Entrance,
	Link,
	Seat,
	RetiringSeat(custody::FieldKey<custody::RoomSeat>),
	Subject,
	Moderator,
	Control,
}
#[derive(Clone, Copy, Debug)]
pub struct Refusal;
impl Dispatch {
	/// Request admission bounds the argument count and bytes. This copies the
	/// admitted arguments for grammar matching, then owns only the selected ID
	/// and outgoing mutation. Selection retires before the worker is installed.
	/// The continuation and receipt retain the actual target instead.
	/// Preview selection validation owns bounded temporary URLs. Only its encoded
	/// selection survives in the outgoing mutation, under the same request budget.
	pub fn parse(request: &Request<'_, impl ArgumentView>) -> Result<Self, Refusal> {
		let args: Vec<_> = request.args().map(String::from).collect();
		let acknowledgment = |verb: &str, args: Vec<String>| Mutation {
			verb: verb.into(),
			args: args.into_iter().map(Into::into).collect(),
			reply: Reply::Acknowledgment,
		};
		let mut argument = None;
		let (selection, mutation) = match (request.route(), args.as_slice()) {
			(Route::Effect(Effect::EnterRoom), [directory, publication])
				if crate::fields::Text::<128, true>::accepts_utf16(publication.encode_utf16()) =>
			{
				(
					Selection::Directory(directory.clone()),
					Mutation {
						verb: crate::directory::creation::ENTER_PUBLICATION.into(),
						args: vec![publication.clone().into()],
						reply: Reply::AcceptedAccess,
					},
				)
			}
			(
				Route::Checkpoint(Command::JoinDirectory | Command::SetDirectoryNick),
				[directory, nick, locator, allocation, callback],
			) if crate::room::inbox::valid_nick(nick)
				&& !locator.is_empty()
				&& crate::directory::registration::NicknameAllocation::parse(allocation).is_some() =>
			{
				argument = Some(ArgumentTarget::DirectoryInbox(
					serde_json::from_str(callback).map_err(|_| Refusal)?,
				));
				(
					Selection::Directory(directory.clone()),
					Mutation {
						verb: crate::directory::registration::REGISTER.into(),
						args: vec![nick.clone().into(), locator.clone().into(), allocation.clone().into()],
						reply: Reply::DirectoryRegistration,
					},
				)
			}
			(Route::Checkpoint(Command::StartDirect), [directory, peer, registration, opening])
				if crate::room::inbox::valid_nick(peer)
					&& crate::directory::registration::Id::parse(registration).is_ok()
					&& crate::directory::introduction::valid_opening(opening) =>
			{
				(
					Selection::Directory(directory.clone()),
					Mutation {
						verb: crate::directory::introduction::INTRODUCE.into(),
						args: vec![peer.clone().into(), registration.clone().into(), opening.clone().into()],
						reply: Reply::DirectAccess,
					},
				)
			}
			(Route::Checkpoint(Command::AcceptInvitation), [id, receipt])
				if receipt.len() == 32
					&& receipt
						.bytes()
						.all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f')) =>
			{
				(
					Selection::Invitation(id.clone()),
					Mutation {
						verb: crate::room::invitation::CLAIM.into(),
						args: vec![receipt.clone().into()],
						reply: Reply::AcceptedAccess,
					},
				)
			}
			(Route::Effect(Effect::OfferRoom), [room, direct]) => {
				argument = Some(ArgumentTarget::SelectedRoom(room.clone()));
				(
					Selection::Direct(direct.clone()),
					acknowledgment(crate::direct::HAND_ROOM, Vec::new()),
				)
			}
			(Route::Effect(Effect::DirectReady), [direct, callback]) => {
				argument = Some(ArgumentTarget::DirectInbox(
					serde_json::from_str(callback).map_err(|_| Refusal)?,
				));
				(
					Selection::Direct(direct.clone()),
					acknowledgment(crate::direct::READY, Vec::new()),
				)
			}
			(Route::Effect(Effect::OfferDirectInbox), [direct, callback]) => {
				argument = Some(ArgumentTarget::DirectInbox(
					serde_json::from_str(callback).map_err(|_| Refusal)?,
				));
				(
					Selection::Introduction(direct.clone()),
					acknowledgment(crate::directory::registration::OFFER_INBOX, Vec::new()),
				)
			}
			(Route::Checkpoint(Command::PublishPeeredRoom), [_directory, name, room, publisher])
				if crate::fields::Text::<32, true>::accepts_utf16(name.encode_utf16()) =>
			{
				argument = Some(ArgumentTarget::Room(serde_json::from_str(room).map_err(|_| Refusal)?));
				(
					Selection::Operations(
						custody::Coordinate::decode(publisher).map_err(|_| Refusal)?,
						crate::session::operations::mutation::Kind::Peering,
					),
					Mutation {
						verb: crate::protocol_data::PUBLISH_DURABLE_ROOM.into(),
						args: vec![name.clone().into()],
						reply: Reply::PublicationLease,
					},
				)
			}
			(Route::Checkpoint(Command::RevokePeeredRoom), [publication, expected]) => (
				Selection::Publication(
					publication.clone(),
					serde_json::from_str(expected).map_err(|_| Refusal)?,
				),
				acknowledgment(crate::protocol_data::REVOKE, Vec::new()),
			),
			(
				Route::Result(results::Command::OpenManagedRoom),
				[directory, name, visibility, entry, speaking, recovery],
			) if crate::fields::Text::<32, true>::accepts_utf16(name.encode_utf16())
				&& crate::directory::creation::RecoveryKey::accepts(recovery) =>
			{
				let policy = RoomPolicy::parse(&[visibility, entry, speaking]).ok_or(Refusal)?;
				let mut args = vec![name.clone()];
				args.extend(policy.modes().into_iter().map(String::from));
				args.push(recovery.clone());
				(
					Selection::Directory(directory.clone()),
					Mutation {
						verb: crate::directory::creation::OPEN_MANAGED.into(),
						args: args.into_iter().map(Into::into).collect(),
						reply: Reply::ManagedRoom,
					},
				)
			}
			(Route::Checkpoint(Command::JoinRoom), [room, nick, callback]) if crate::room::inbox::valid_nick(nick) => {
				argument = Some(ArgumentTarget::Inbox(
					serde_json::from_str(callback).map_err(|_| Refusal)?,
				));
				(
					Selection::Room(room.clone(), RoomTarget::Entrance),
					Mutation {
						verb: crate::room::membership::SUBSCRIBE.into(),
						args: vec![nick.clone().into()],
						reply: Reply::Membership,
					},
				)
			}
			(Route::Effect(Effect::Say), [conversation, text, previews @ ..])
				if text.len() <= crate::room::line::MAX_LINE_BYTES && previews.len() <= 1 =>
			{
				let selection = previews
					.first()
					.map(|encoded| crate::open_graph::Selection::decode(text, encoded).map_err(|_| Refusal))
					.transpose()?;
				let mut args = vec![text.clone().into()];
				let verb = if let Some(selection) = selection.filter(|selection| !selection.is_empty()) {
					args.push(selection.encode().into());
					crate::open_graph::ROOM_POST_VERB
				} else {
					crate::protocol_data::POST
				};
				(
					Selection::Post(conversation.clone()),
					Mutation {
						verb: verb.into(),
						args,
						reply: Reply::Line,
					},
				)
			}
			(Route::Effect(Effect::SetRoomAway), [room, text])
				if crate::fields::Text::<{ crate::room::membership::MAX_AWAY }>::accepts_utf16(text.encode_utf16()) =>
			{
				(
					Selection::Room(room.clone(), RoomTarget::Seat),
					acknowledgment(crate::room::membership::AWAY, vec![text.clone()]),
				)
			}
			(Route::Effect(Effect::RetireRoomMembership), [room, expected]) => (
				Selection::Room(
					room.clone(),
					RoomTarget::RetiringSeat(serde_json::from_str(expected).map_err(|_| Refusal)?),
				),
				acknowledgment(crate::room::membership::LEAVE, Vec::new()),
			),
			(Route::Effect(Effect::SetRoomSubject), [room, description, link @ ..])
				if link.len() <= 1
					&& crate::room::subject::Subject::new(description.as_str(), link.first().map(String::as_str))
						.is_ok() =>
			{
				(
					Selection::Room(room.clone(), RoomTarget::Subject),
					acknowledgment(
						crate::room::membership::SET_SUBJECT,
						core::iter::once(description).chain(link).cloned().collect(),
					),
				)
			}
			(Route::Effect(Effect::EditLine), [room, line, text])
				if text.len() <= crate::room::line::MAX_LINE_BYTES =>
			{
				(
					Selection::Line(
						room.clone(),
						line.parse()
							.ok()
							.and_then(crate::room::message::LineId::new)
							.ok_or(Refusal)?,
					),
					acknowledgment(crate::protocol_data::EDIT, vec![text.clone()]),
				)
			}
			(Route::Effect(Effect::WithdrawLine), [room, line]) => (
				Selection::Line(
					room.clone(),
					line.parse()
						.ok()
						.and_then(crate::room::message::LineId::new)
						.ok_or(Refusal)?,
				),
				acknowledgment(crate::protocol_data::WITHDRAW, Vec::new()),
			),
			(Route::Effect(Effect::Operator), [coordinate, action, rest @ ..]) => (
				Selection::Operator(serde_json::from_str(coordinate).map_err(|_| Refusal)?),
				operator::mutation(action, rest).map_err(|_| Refusal)?,
			),
			(Route::Effect(Effect::Operations), [coordinate, kind, action, rest @ ..]) => {
				let kind = serde_json::from_value(serde_json::Value::String(kind.clone())).map_err(|_| Refusal)?;
				(
					Selection::Operations(custody::Coordinate::decode(coordinate).map_err(|_| Refusal)?, kind),
					crate::session::operations::mutation::mutation(kind, action, rest).map_err(|_| Refusal)?,
				)
			}
			(Route::Effect(Effect::KickRoomMember), [room, nick]) if !nick.is_empty() => (
				Selection::Room(room.clone(), RoomTarget::Moderator),
				acknowledgment(authority::KICK, vec![nick.clone()]),
			),
			(Route::Effect(Effect::IssueRoomModerator), [room]) => (
				Selection::Room(room.clone(), RoomTarget::Control),
				Mutation {
					verb: authority::GIVE_STEWARD.into(),
					args: Vec::new(),
					reply: Reply::RoomModerator,
				},
			),
			(Route::Result(results::Command::EnsureRoomLink), [room]) => (
				Selection::Room(room.clone(), RoomTarget::Link),
				Mutation {
					verb: authority::LINK.into(),
					args: Vec::new(),
					reply: Reply::RoomLink,
				},
			),
			(Route::Effect(Effect::UnregisterManagedRoom), [room]) => (
				Selection::Room(room.clone(), RoomTarget::Control),
				Mutation {
					verb: authority::UNREGISTER_ROOM.into(),
					args: Vec::new(),
					reply: Reply::RoomPolicy,
				},
			),
			(Route::Effect(Effect::SetManagedRoomPolicy), [room, visibility, entry, speaking]) => {
				let policy = RoomPolicy::parse(&[visibility, entry, speaking]).ok_or(Refusal)?;
				(
					Selection::Room(room.clone(), RoomTarget::Control),
					Mutation {
						verb: authority::SET_POLICY.into(),
						args: policy.modes().into_iter().map(Into::into).collect(),
						reply: Reply::RoomPolicy,
					},
				)
			}
			(Route::Effect(Effect::RevokeManagedRoomAuthority), [room, kind, token]) if !token.is_empty() => {
				let verb = match kind.as_str() {
					"room" => authority::REVOKE_ROOM_LINK,
					"steward" => authority::REVOKE_STEWARD,
					_ => return Err(Refusal),
				};
				argument = Some(ArgumentTarget::Revocation {
					room: room.clone(),
					moderator: kind == "steward",
					expected: serde_json::from_str(token).map_err(|_| Refusal)?,
				});
				(
					Selection::Room(room.clone(), RoomTarget::Control),
					acknowledgment(verb, Vec::new()),
				)
			}
			_ => return Err(Refusal),
		};
		let operation = matches!(selection, Selection::Post(_)).then(|| request.id().into());
		Ok(Self {
			operation,
			selection,
			mutation,
			argument,
		})
	}
	/// Retirement changes workspace selection in the same transaction as its
	/// receipt. The already captured target remains independent of that change.
	pub fn retires_membership(&self) -> bool {
		matches!(self.selection, Selection::Room(_, RoomTarget::RetiringSeat(_)))
	}
	pub fn retires_publication(&self) -> bool {
		matches!(self.selection, Selection::Publication(..))
	}
	/// Inbox callbacks lend source-restricted authority. Direct room sharing
	/// passes the exact held reference, preserving any existing dependency.
	pub fn dependent_argument(&self) -> bool {
		matches!(
			self.argument,
			Some(ArgumentTarget::Inbox(_) | ArgumentTarget::DirectoryInbox(_)) | Some(ArgumentTarget::DirectInbox(_))
		)
	}
	/// Register places the retained inbox before its allocation mode.
	pub fn argument_position(&self) -> Option<usize> {
		matches!(self.argument, Some(ArgumentTarget::DirectoryInbox(_))).then_some(2)
	}
	/// Revocation resolves a selected recipe locally, without handing its
	/// capability to the remote manager as an argument.
	pub fn revokes_selected(&self) -> bool {
		matches!(self.argument, Some(ArgumentTarget::Revocation { .. }))
	}
	/// The admitted revocation's exact field, independently of later intent.
	pub fn revoked_authority(&self) -> Option<custody::FieldKey<custody::RoomAccess>> {
		match self.argument {
			Some(ArgumentTarget::Revocation { expected, .. }) => Some(expected),
			_ => None,
		}
	}
	/// Capture descriptive dispatch data from the same admitted workspace.
	/// This name never selects authority. The coordinate selects held custody.
	pub fn bind(mut self, intent: &workspace::Intent) -> Result<(custody::Coordinate, Mutation), Refusal> {
		let target = self.target(intent)?;
		if let Selection::Room(id, RoomTarget::Link) = &self.selection
			&& target.role == custody::Role::DirectoryAccess
		{
			let publication = Self::room(intent, id)?.publication.as_ref().ok_or(Refusal)?;
			self.mutation.verb = crate::directory::creation::LINK_PUBLICATION.into();
			self.mutation.args = vec![publication.text().as_str().ok_or(Refusal)?.into()];
		}
		if let Selection::Room(id, RoomTarget::Entrance) = &self.selection
			&& Self::room(intent, id)?.public_entry.is_some()
		{
			let publication = Self::room(intent, id)?.publication.as_ref().ok_or(Refusal)?;
			self.mutation.verb = crate::directory::creation::SUBSCRIBE_PUBLICATION.into();
			self.mutation
				.args
				.insert(0, publication.text().as_str().ok_or(Refusal)?.into());
		}
		if let Selection::Introduction(id) = &self.selection {
			let direct = Self::direct(intent, id)?;
			let witness = direct.introduction.as_ref().ok_or(Refusal)?;
			self.mutation.args = vec![
				direct.peer.text().as_str().ok_or(Refusal)?.into(),
				witness.registration.text().as_str().ok_or(Refusal)?.into(),
				witness.opening.text().as_str().ok_or(Refusal)?.into(),
			];
		}
		if matches!(self.selection, Selection::Post(_)) && target.role == custody::Role::DirectAccess {
			if self.mutation.verb == crate::open_graph::ROOM_POST_VERB {
				self.mutation.args.insert(1, crate::open_graph::WIRE_TAG.into());
			}
			self.mutation.verb = crate::direct::DM.into();
		}
		if matches!(self.selection, Selection::Post(_)) && target.role != custody::Role::DirectAccess {
			if self.mutation.args.len() == 1 {
				self.mutation.args.push("[]".into());
			}
			self.mutation.args.push(self.operation.take().ok_or(Refusal)?.into());
			self.mutation.verb = crate::room::correlation::POST.into();
		}
		if let Some(ArgumentTarget::SelectedRoom(id)) = &self.argument {
			self.mutation
				.args
				.push(Self::room(intent, id)?.name.text().as_str().ok_or(Refusal)?.into());
		}
		if self.mutation.verb == authority::SET_POLICY {
			let Selection::Room(id, _) = &self.selection else {
				return Err(Refusal);
			};
			let room = Self::room(intent, id)?;
			self.mutation
				.args
				.push(room.name.text().as_str().ok_or(Refusal)?.into());
		}
		Ok((target, self.mutation))
	}
}
mod selection;
