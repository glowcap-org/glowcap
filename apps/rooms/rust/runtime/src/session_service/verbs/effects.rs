//! Effects against a live room or direct partner, ledgered through the session
//! command owner so an interrupted one is recovered rather than repeated.
use super::{checkpoint::operation_id, command::material};
use crate::direct_commands::Command;
use crate::direct_commands::LineKey;
use crate::direct_commands::Operation;
use crate::direct_dispatch::Opening;
use crate::directory_runtime::AcceptedDirect;
use crate::rooms::Failure;
use crate::rooms::RoomRuntime;
use crate::session_commands::Admission;
use crate::session_commands::AdmissionError;
use crate::session_commands::SessionCommands;
use crate::session_service::error::Error;
use crate::session_service::facet::Facet;
use crate::session_service::revision::Revision;
use crate::session_service::Platform;
use crate::session_state::OrdinaryStatus;
use crate::session_state::SessionView;
use rooms_application::{
	archive::ConversationKind,
	room::message::LineId,
	session::{
		command::{Effect, Request},
		state::{OperationId, Outcome},
	},
	text::DocumentText,
};
use std::future::Future;

/// One ledgered effect's identity: the operation and the revision it was
/// asked against, plus the material it is remembered by.
pub struct Ledgered {
	pub id: OperationId,
	pub base: u64,
	pub material: DocumentText,
}

pub fn apply<P: Platform>(
	facet: &Facet<P>,
	effect: Effect,
	request: &Request<'_, impl rooms_application::room::ArgumentView>,
) -> Result<Revision, Error> {
	let id = operation_id(request.id())?;
	let name = request.name();
	let args: Vec<String> = request.args().map(str::to_owned).collect();
	let ledgered = Ledgered {
		id,
		base: request.base(),
		material: material(name, &args)?,
	};
	match (effect, args.as_slice()) {
		(Effect::Say, [conversation, text]) => say(facet, ledgered, conversation, text),
		(Effect::EditLine, [conversation, line, text]) => {
			edit_line(facet, ledgered, conversation, parse_line(line)?, text)
		}
		(Effect::WithdrawLine, [conversation, line]) => withdraw_line(facet, ledgered, conversation, parse_line(line)?),
		(Effect::SetRoomTopic, [conversation, text]) => {
			let (conversation, text) = (conversation.clone(), text.clone());
			ledger(facet, ledgered, move |rooms| async move {
				rooms.set_topic(&conversation, &text).await
			})
		}
		(Effect::KickRoomMember, [conversation, nick]) => {
			let (conversation, nick) = (conversation.clone(), nick.clone());
			ledger(facet, ledgered, move |rooms| async move {
				rooms.kick(&conversation, &nick).await
			})
		}
		(Effect::OfferRoom, [room, direct]) => offer_room(facet, ledgered, room, direct),
		(Effect::RevokeManagedRoomAuthority, [conversation, kind, token]) => {
			if !matches!(kind.as_str(), "room" | "steward") || token.is_empty() {
				return Err(Error::refused(
					"managed room revocation takes a room, authority kind, and exact token",
				));
			}
			let (conversation, kind, token) = (conversation.clone(), kind.clone(), token.clone());
			ledger(facet, ledgered, move |rooms| async move {
				rooms.revoke_authority(&conversation, &kind, &token).await
			})
		}
		(Effect::UnregisterManagedRoom, [conversation]) => {
			require_manager(
				facet,
				conversation,
				"managed room unregistration needs a retained manager",
			)?;
			let conversation = conversation.clone();
			ledger(facet, ledgered, move |rooms| async move {
				rooms.unregister(&conversation).await
			})
		}
		(Effect::SetManagedRoomPolicy, [conversation, visibility, entry, speaking]) => {
			let policy = rooms_application::room::policy::RoomPolicy::parse(&[visibility, entry, speaking])
				.ok_or_else(|| Error::refused("managed room policy takes one room and three policy modes"))?;
			let name = require_manager(facet, conversation, "managed room policy needs a retained manager")?;
			let conversation = conversation.clone();
			ledger(facet, ledgered, move |rooms| async move {
				rooms.set_policy(&conversation, &name, policy).await
			})
		}
		(Effect::Operator, rest) => super::operations::operator_effect(facet, ledgered, rest),
		(Effect::Operations, rest) => super::operations::operations_effect(facet, ledgered, rest),
		_ => Err(Error::refused(format!("this session peer does not yet apply {name}"))),
	}
}

/// Which kind of conversation a checkpoint id names, or a refusal when the
/// session no longer intends it.
pub fn conversation_kind(view: &SessionView, conversation: &str) -> Result<ConversationKind, Error> {
	view.read(|state| {
		let checkpoint = state.checkpoint()?;
		if checkpoint
			.rooms()
			.any(|room| room.id.text().as_str() == Some(conversation))
		{
			return Ok(ConversationKind::Room);
		}
		if checkpoint
			.directs()
			.any(|direct| direct.id.text().as_str() == Some(conversation))
		{
			return Ok(ConversationKind::Direct);
		}
		Err(Error::refused(
			"that conversation is no longer part of this Rooms session",
		))
	})?
}

fn say<P: Platform>(facet: &Facet<P>, ledgered: Ledgered, conversation: &str, text: &str) -> Result<Revision, Error> {
	match conversation_kind(&facet.0.commands.view(), conversation)? {
		ConversationKind::Direct => send_direct(
			facet,
			ledgered.id,
			ledgered.base,
			conversation,
			Command::Send {
				text: text.to_owned(),
				files: Vec::new(),
			},
		),
		ConversationKind::Room => {
			let (conversation, text) = (conversation.to_owned(), text.to_owned());
			ledger(facet, ledgered, move |rooms| async move {
				rooms.say(&conversation, &text).await
			})
		}
	}
}

fn edit_line<P: Platform>(
	facet: &Facet<P>,
	ledgered: Ledgered,
	conversation: &str,
	line: u64,
	text: &str,
) -> Result<Revision, Error> {
	match conversation_kind(&facet.0.commands.view(), conversation)? {
		ConversationKind::Direct => send_direct(
			facet,
			ledgered.id,
			ledgered.base,
			conversation,
			Command::Edit {
				line: direct_line(facet, line)?,
				text: text.to_owned(),
			},
		),
		ConversationKind::Room => {
			let (conversation, text) = (conversation.to_owned(), text.to_owned());
			ledger(facet, ledgered, move |rooms| async move {
				rooms.edit(&conversation, line, &text).await
			})
		}
	}
}

fn withdraw_line<P: Platform>(
	facet: &Facet<P>,
	ledgered: Ledgered,
	conversation: &str,
	line: u64,
) -> Result<Revision, Error> {
	match conversation_kind(&facet.0.commands.view(), conversation)? {
		ConversationKind::Direct => send_direct(
			facet,
			ledgered.id,
			ledgered.base,
			conversation,
			Command::Withdraw {
				line: direct_line(facet, line)?,
			},
		),
		ConversationKind::Room => {
			let conversation = conversation.to_owned();
			ledger(facet, ledgered, move |rooms| async move {
				rooms.withdraw(&conversation, line).await
			})
		}
	}
}

fn offer_room<P: Platform>(facet: &Facet<P>, ledgered: Ledgered, room: &str, direct: &str) -> Result<Revision, Error> {
	struct Offer {
		room: String,
		label: String,
		link: Option<String>,
		direct: String,
	}
	let offer = facet.0.commands.view().read(|state| {
		let checkpoint = state.checkpoint()?;
		let room_intent = checkpoint
			.rooms()
			.find(|held| held.id.text().as_str() == Some(room))
			.ok_or_else(|| Error::refused("offerRoom needs a room in this session"))?;
		let direct_intent = checkpoint
			.directs()
			.find(|held| held.id.text().as_str() == Some(direct))
			.filter(|held| !held.closed && held.directory.text() == room_intent.directory.text())
			.ok_or_else(|| Error::refused("offerRoom needs an open direct conversation on the room's directory"))?;
		Ok::<_, Error>(Offer {
			room: room.to_owned(),
			label: room_intent.name.text().as_str().unwrap_or("").to_owned(),
			link: room_intent
				.link
				.and_then(|link| link.text().as_str().map(str::to_owned)),
			direct: direct_intent.id.text().as_str().unwrap_or("").to_owned(),
		})
	})??;
	let context = facet
		.0
		.directories
		.intended_direct(&offer.direct)
		.map_err(Error::runtime)?;
	let rooms = facet.0.rooms.clone();
	let routes = facet.0.routes.clone();
	let dispatcher = facet.0.dispatcher.clone();
	ledger_task(facet, ledgered, async move {
		if !routes.live(&context) {
			dispatcher.ensure(&context)?.wait().await?;
		}
		let line = routes.live_line(&context)?;
		if let Ok(live) = rooms.live(&offer.room) {
			return line
				.hand_room(&offer.label, live.reference())
				.await
				.map_err(|e| e.to_string());
		}
		let Some(link) = offer.link else {
			return Err("the room is not live and has no durable entry link to offer".into());
		};
		line.offer_room(&offer.label, &link).await.map_err(|e| e.to_string())
	})
}

/// The room's name, when the session retains its manager; the refusal names
/// what the caller lacks otherwise.
fn require_manager<P: Platform>(facet: &Facet<P>, conversation: &str, missing: &'static str) -> Result<String, Error> {
	facet.0.commands.view().read(|state| {
		let room = state
			.checkpoint()?
			.rooms()
			.find(|room| room.id.text().as_str() == Some(conversation) && room.manager.is_some())
			.ok_or_else(|| Error::refused(missing))?;
		Ok::<_, Error>(room.name.text().as_str().unwrap_or("").to_owned())
	})?
}

/// Run `work` against the live rooms as one ledgered ordinary effect.
pub fn ledger<P: Platform, F, Fut, E>(facet: &Facet<P>, ledgered: Ledgered, work: F) -> Result<Revision, Error>
where
	F: FnOnce(RoomRuntime<P>) -> Fut + 'static,
	Fut: Future<Output = Result<(), E>> + 'static,
	E: Into<Failure>,
{
	let admission = facet
		.0
		.commands
		.prepare_ordinary(ledgered.id.clone(), ledgered.base, ledgered.material.clone())?;
	let commands = facet.0.commands.clone();
	let rooms = facet.0.rooms.clone();
	Ok(Revision::new(async move {
		let revision = run(admission, commands, rooms, ledgered, work).await?;
		Ok(revision)
	}))
}

/// `ledger` for work that needs nothing but its own captures.
pub fn ledger_task<P: Platform, Fut, E>(facet: &Facet<P>, ledgered: Ledgered, work: Fut) -> Result<Revision, Error>
where
	Fut: Future<Output = Result<(), E>> + 'static,
	E: Into<Failure>,
{
	ledger(facet, ledgered, move |_| work)
}

/// Drive one ledgered effect to the outcome its work reports. What the room
/// applied is committed even when the rest failed, what it never saw is
/// abandoned so the reader can send the intent again, and an answer that was
/// lost stays pending for the reader to settle.
async fn run<P: Platform, F, Fut, E>(
	admission: Admission<OrdinaryStatus>,
	commands: SessionCommands,
	rooms: RoomRuntime<P>,
	ledgered: Ledgered,
	work: F,
) -> Result<u64, Error>
where
	F: FnOnce(RoomRuntime<P>) -> Fut,
	Fut: Future<Output = Result<(), E>>,
	E: Into<Failure>,
{
	let prepared = admission.send()?.wait().await.map_err(Error::runtime)?;
	if let OrdinaryStatus::Committed(revision) = prepared {
		return Ok(revision);
	}
	let failure = match work(rooms).await {
		Ok(()) => None,
		Err(failure) => Some(failure.into()),
	};
	let settle = |admission: Result<Admission<u64>, AdmissionError>| async move {
		admission?.send()?.wait().await.map_err(Error::runtime)
	};
	match failure {
		None => settle(commands.commit_ordinary(ledgered.id, ledgered.material)).await,
		Some(Failure::Applied(reason)) => {
			settle(commands.commit_ordinary(ledgered.id, ledgered.material)).await?;
			Err(Error::runtime(reason))
		}
		Some(Failure::NotApplied(reason)) => {
			settle(commands.resolve(ledgered.id, Outcome::Abandoned)).await?;
			Err(Error::runtime(reason))
		}
		Some(Failure::Unknown(reason)) => Err(Error::runtime(format!(
			"the room's answer was lost; whether it applied the effect needs your decision: {reason}"
		))),
	}
}

/// Send a direct-conversation command, opening the route first when it is
/// intended but not yet live.
pub fn send_direct<P: Platform>(
	facet: &Facet<P>,
	id: OperationId,
	base: u64,
	conversation: &str,
	command: Command,
) -> Result<Revision, Error> {
	let operation = Operation { id, base };
	let (needs_open, context) = match facet.0.routes.conversation(conversation) {
		Ok(context) => (false, context),
		Err(_) => {
			let context = facet
				.0
				.directories
				.intended_direct(conversation)
				.map_err(Error::runtime)?;
			(true, context)
		}
	};
	let directs = facet.0.directs.clone();
	let dispatcher = facet.0.dispatcher.clone();
	Ok(Revision::new(async move {
		let opening = if needs_open {
			Some(dispatcher.ensure(&context).map_err(Error::runtime)?)
		} else {
			None
		};
		let revision = deliver(opening, directs, operation, context, command).await?;
		Ok(revision)
	}))
}

async fn deliver<P: Platform>(
	opening: Option<Opening<P>>,
	directs: crate::direct_commands::DirectCommands,
	operation: Operation,
	context: AcceptedDirect,
	command: Command,
) -> Result<u64, Error> {
	if let Some(opening) = opening {
		opening.wait().await.map_err(Error::runtime)?;
	}
	directs
		.submit(operation, &context, command)
		.map_err(Error::runtime)?
		.wait()
		.await
		.map(|committed| committed.revision)
		.map_err(|failure| Error::runtime(failure.reason))
}

/// A direct line is named by the event generation it was seen in.
pub fn direct_line<P: Platform>(facet: &Facet<P>, line: u64) -> Result<LineKey, Error> {
	Ok(LineKey {
		generation: facet.0.events.generation().map_err(Error::runtime)?,
		line: LineId::new(line).ok_or_else(|| Error::refused("that line id is not a positive integer"))?,
	})
}

fn parse_line(value: &str) -> Result<u64, Error> {
	value
		.parse::<u64>()
		.ok()
		.filter(|id| *id > 0 && *id < (1u64 << 53))
		.ok_or_else(|| Error::refused("editLine takes a conversation id, positive line id, and bounded text"))
}
