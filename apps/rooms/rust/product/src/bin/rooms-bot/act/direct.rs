//! `--dm <nickname>`: the direct conversation a `say` or `send` posts to.
//! It reaches only someone taking part in the turn's conversation: a member
//! whose room line the turn was shown, or the other person of the turn's
//! direct conversation. The nickname is looked up in the directory of the
//! turn's conversation, and the session reuses the open conversation with
//! that member or opens one (`View::reach_direct` and `View::introduce`). The
//! introduction an open sends is kept in the turn's action budget first, so
//! looking again at an uncertain open sends that same introduction. The bot's
//! log names the peer and the conversation before every post `--dm` reaches,
//! and says "opened" only once the open committed.
use super::{Turn, failure};
use crate::bot::{actions, engine, error::Error, request::Request, rooms::ConversationId, rooms::captp::Live, store};
use rooms_application::{
	content::session::workspace::Conversation,
	failure::{FailureCode, Retry},
	room::inbox::same_nick,
};
use rooms_services::session::{
	attached::{Error as ViewError, Introduction, Opened, Reach},
	control::Failure,
};
use serde_json::{Value, json};

/// The flags `--dm` reads beside a verb's own.
pub const FLAGS: [&str; 3] = ["dm", "operation", "base"];

/// What `--dm` asks for, read before the turn spends a place.
pub struct Ask {
	peer: String,
	/// The operation and base of an earlier open whose outcome was uncertain.
	again: Option<(String, u64)>,
}

/// The `--dm` a request names, or none. `--conversation` names another
/// place, so the two are refused together, and `--operation` with `--base`
/// only looks again at an uncertain open.
pub fn ask(request: &Request) -> Result<Option<Ask>, Error> {
	let again = match (request.single("operation")?, request.single("base")?) {
		(Some(operation), Some(base)) => Some((
			operation.to_owned(),
			base.parse::<u64>()
				.map_err(|_| Error::Usage("--base must be a revision number".into()))?,
		)),
		(None, None) => None,
		_ => return Err(Error::Usage("--operation and --base go together".into())),
	};
	let Some(peer) = request.single("dm")? else {
		return match again {
			Some(_) => Err(Error::Usage(
				"--operation and --base look again at an uncertain --dm open, so they need --dm".into(),
			)),
			None => Ok(None),
		};
	};
	if request.single("conversation")?.is_some() {
		return Err(Error::Usage(
			"--dm and --conversation each name where to post; choose one".into(),
		));
	}
	Ok(Some(Ask {
		peer: peer.to_owned(),
		again,
	}))
}

/// Whether `peer` takes part in the turn's conversation `row`: the other
/// person of a direct conversation, or one of the `members` whose room lines
/// the turn was shown.
fn takes_part(row: &Conversation, members: &[String], peer: &str) -> bool {
	match row {
		Conversation::Room(_) => members.iter().any(|member| same_nick(member, peer)),
		Conversation::Direct(row) => row.peer.text().as_str().is_some_and(|nick| same_nick(nick, peer)),
	}
}

/// The direct conversation `ask` reaches, and the open that made it, or null
/// when an open conversation was reused. Every failure is the open's, and
/// says so, because nothing was posted yet.
pub async fn reach(live: &Live, turn: &Turn, ask: &Ask) -> Result<(String, Value), Error> {
	reached(live, turn, ask).await.map_err(failure::opening)
}

async fn reached(live: &Live, turn: &Turn, ask: &Ask) -> Result<(String, Value), Error> {
	let root = store::directory(&turn.bot)?;
	let log = store::Log::in_directory(&root);
	let snapshot = live.view.snapshot().await.map_err(|cause| failure::call(&cause))?;
	let row = snapshot
		.intent
		.conversations
		.as_slice()
		.iter()
		.find(|row| row.id().text().as_str() == Some(turn.conversation.as_str()))
		.ok_or_else(|| {
			Error::Usage(format!(
				"conversation {} is no longer in the session, so --dm has no directory to find {} in",
				turn.conversation, ask.peer
			))
		})?;
	if !takes_part(row, &turn.members, &ask.peer) {
		return Err(failure::refused(&Failure::invalid(format!(
			"--dm reaches only someone in this conversation, and {} has not written in it this turn: answer here, or use the from nickname of a line in this conversation",
			ask.peer
		))));
	}
	let directory = match row {
		Conversation::Room(row) => row.directory.text(),
		Conversation::Direct(row) => row.directory.text(),
	};
	let directory = directory
		.as_str()
		.ok_or(Error::Usage("the turn's conversation names no directory".into()))?;
	let budget = ConversationId::new(turn.conversation.as_str());
	let (operation, base, introduction) = match &ask.again {
		Some((operation, base)) => {
			let introduction = actions::noted_open(&root, &budget, operation)?
				.filter(|introduction| same_nick(&introduction.peer, &ask.peer))
				.ok_or_else(|| {
					Error::Usage(format!(
						"this turn sent no --dm open to {} under operation {operation}: run the verb without --operation and --base",
						ask.peer
					))
				})?;
			(operation.clone(), Some(*base), introduction)
		}
		None => match live.view.reach_direct(directory, &ask.peer).await {
			Ok(Reach::Open(conversation)) => {
				log.line(&format!(
					"a turn in conversation {} reused direct conversation {conversation} with {}",
					turn.conversation, ask.peer
				));
				return Ok((conversation, Value::Null));
			}
			Ok(Reach::Introduce(introduction)) => {
				let operation = engine::operation()?;
				actions::note_open(&root, &budget, &operation, &introduction)?;
				(operation, None, introduction)
			}
			Err(ViewError::Peer(cause)) if cause.failure_code() == Some(FailureCode::PeerOffline) => {
				return Err(failure::refused(&Failure::new(
					FailureCode::PeerOffline.wire(),
					Retry::AfterStateChange,
					format!(
						"no member named {} is registered in this conversation's directory now: answer here, or use the from nickname of a line in this conversation",
						ask.peer
					),
				)));
			}
			Err(cause) => return Err(failure::call(&cause)),
		},
	};
	introduce(live, turn, &log, &operation, base, &introduction).await
}

/// Send the open and log what it did before anything posts through it.
async fn introduce(
	live: &Live,
	turn: &Turn,
	log: &store::Log,
	operation: &str,
	base: Option<u64>,
	introduction: &Introduction,
) -> Result<(String, Value), Error> {
	let line = |what: &str, landed: &str| {
		log.line(&format!(
			"a turn in conversation {} {what} a direct conversation with {} under operation {operation}{landed}",
			turn.conversation, introduction.peer
		))
	};
	match live.view.introduce(operation, base, introduction).await {
		Ok(Opened::Opened { conversation, sent }) => {
			line("opened", &format!(", as conversation {conversation}"));
			Ok((conversation, json!({"operation": sent.operation, "base": sent.base})))
		}
		Ok(Opened::Reused { conversation, .. }) => {
			let landed = format!(", and another open had made it, as conversation {conversation}");
			line("reused", &landed);
			Ok((conversation, Value::Null))
		}
		Ok(Opened::Unapplied(sent)) => Err(failure::with_operation(
			failure::unapplied(sent.status.wire()),
			operation,
		)),
		Ok(Opened::Uncertain(sent)) => {
			line("may have opened", "");
			Err(failure::with_operation(failure::unsettled(&sent), operation))
		}
		Err(cause @ ViewError::Uncertain { .. }) => {
			line("may have opened", "");
			Err(failure::with_operation(failure::call(&cause), operation))
		}
		Err(cause) => Err(failure::with_operation(failure::call(&cause), operation)),
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	fn asked(named: &str) -> Result<Option<Ask>, Error> {
		ask(&Request::parse(&format!(
			r#"{{"verb":"say","state":"","named":{named},"arguments":[]}}"#
		))
		.unwrap())
	}

	#[test]
	fn dm_names_one_place_and_a_look_again_needs_its_operation_and_base_and_dm() {
		assert!(asked(r#"{"text":["hi"]}"#).unwrap().is_none());
		let first = asked(r#"{"dm":["ana"]}"#).unwrap().unwrap();
		assert_eq!((first.peer.as_str(), first.again), ("ana", None));
		let again = asked(r#"{"dm":["ana"],"operation":["op"],"base":["7"]}"#)
			.unwrap()
			.unwrap();
		assert_eq!(again.again, Some(("op".to_owned(), 7)));
		for refused in [
			r#"{"dm":["ana"],"conversation":["room"]}"#,
			r#"{"operation":["op"],"base":["7"]}"#,
			r#"{"dm":["ana"],"operation":["op"]}"#,
			r#"{"dm":["ana"],"base":["7"]}"#,
			r#"{"dm":["ana"],"operation":["op"],"base":["seven"]}"#,
		] {
			assert!(matches!(asked(refused), Err(Error::Usage(_))), "{refused}");
		}
	}

	#[test]
	fn dm_reaches_a_member_the_turn_saw_in_a_room_or_the_other_person_of_a_direct_conversation() {
		use rooms_application::content::session::workspace::Intent;
		let intent = Intent::decode(
			&json!({"version":1,"directories":[],"invitations":[],"active":null,
			"standing":"","ignored":[],"keepHistory":false,"connection":"fastest",
			"archive":null,"archiveControl":null,"operators":[],"peering":[],
			"conversations":[
				{"kind":"room","id":"r","directory":"d","name":"n","access":null,"control":null,
					"reconnect":"requested","standing":null,"draft":""},
				{"kind":"direct","id":"m","directory":"d","peer":"Ann","access":null,"closed":false,"draft":""},
			]})
			.to_string(),
		)
		.unwrap();
		let [room, direct] = intent.conversations.as_slice() else {
			panic!("two conversations");
		};
		let members = ["ann".to_owned(), "bo".to_owned()];
		assert!(takes_part(room, &members, "Bo"));
		assert!(!takes_part(room, &members, "cy"));
		assert!(!takes_part(room, &[], "ann"), "a room member the turn did not see");
		assert!(takes_part(direct, &[], "ANN"));
		assert!(
			!takes_part(direct, &members, "bo"),
			"a room member is not in a direct conversation"
		);
	}
}
