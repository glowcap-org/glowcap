//! `--dm <nickname>`: the direct conversation a `say` or `send` posts to.
//! The nickname is looked up in the directory of the turn's conversation,
//! so it names the member the agent saw there. The session opens a direct
//! conversation with that member or reuses the open one (`View::open_direct`),
//! and the bot's log records each open with the peer it reached.
use super::{Turn, failure};
use crate::bot::{engine, error::Error, request::Request, rooms::captp::Live, store};
use rooms_application::{
	content::session::workspace::Conversation,
	failure::{FailureCode, Retry},
};
use rooms_services::session::{
	attached::{EffectStatus, Error as ViewError, Opened},
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

/// The direct conversation `ask` reaches, and the open that made it, or null
/// when an open conversation was reused. Every failure is the open's, and
/// says so, because nothing was posted yet.
pub async fn reach(live: &Live, turn: &Turn, ask: &Ask) -> Result<(String, Value), Error> {
	let snapshot = live.view.snapshot().await.map_err(|cause| failure::call(&cause))?;
	let directory = snapshot
		.intent
		.conversations
		.as_slice()
		.iter()
		.find(|row| row.id().text().as_str() == Some(turn.conversation.as_str()))
		.and_then(|row| match row {
			Conversation::Room(row) => row.directory.text().as_str(),
			Conversation::Direct(row) => row.directory.text().as_str(),
		})
		.ok_or_else(|| {
			Error::Usage(format!(
				"conversation {} is no longer in the session, so --dm has no directory to find {} in",
				turn.conversation, ask.peer
			))
		})?;
	let (operation, base) = match &ask.again {
		Some((operation, base)) => (operation.clone(), Some(*base)),
		None => (engine::operation()?, None),
	};
	let log = |what: &str| -> Result<(), Error> {
		store::Log::in_directory(&store::directory(&turn.bot)?).line(&format!(
			"a turn in conversation {} {what} a direct conversation with {} under operation {operation}",
			turn.conversation, ask.peer
		));
		Ok(())
	};
	let opened = live.view.open_direct(&operation, base, directory, &ask.peer).await;
	let refused = match opened {
		Ok(Opened::Reused(conversation)) => Ok((conversation, Value::Null)),
		Ok(Opened::Opened { conversation, sent }) => {
			log("opened")?;
			Ok((conversation, json!({"operation": sent.operation, "base": sent.base})))
		}
		Ok(Opened::Unsettled(sent)) => match sent.status {
			EffectStatus::Conflict | EffectStatus::Unsent => Err(failure::with_operation(
				failure::unapplied(sent.status.wire()),
				&operation,
			)),
			EffectStatus::Committed | EffectStatus::Pending | EffectStatus::Unknown => {
				log("may have opened")?;
				Err(failure::with_operation(failure::unsettled(&sent), &operation))
			}
		},
		Err(ViewError::Peer(cause)) if cause.failure_code() == Some(FailureCode::PeerOffline) => {
			Err(failure::refused(&Failure::new(
				FailureCode::PeerOffline.wire(),
				Retry::AfterStateChange,
				format!(
					"no member named {} is registered in this conversation's directory now: answer here, or use the from nickname of a line in this conversation",
					ask.peer
				),
			)))
		}
		Err(cause @ ViewError::Uncertain { .. }) => {
			log("may have opened")?;
			Err(failure::with_operation(failure::call(&cause), &operation))
		}
		Err(cause) => Err(failure::with_operation(failure::call(&cause), &operation)),
	};
	refused.map_err(failure::opening)
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
}
