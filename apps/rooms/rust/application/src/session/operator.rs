//! Bounded operator action grammar, shared by session dispatchers.
use super::effect::{Mutation, Reply};
use alloc::{string::String, vec, vec::Vec};

#[derive(Clone, Copy, Debug)]
pub struct InvalidAction;

/// An operator mutation from the `operator` command, as the operator's own
/// verb and arguments.
pub fn mutation(action: &str, args: &[String]) -> Result<Mutation, InvalidAction> {
	if action == "retireMatching" {
		let [category, query, limit, rest @ ..] = args else {
			return Err(InvalidAction);
		};
		let limit = limit.parse::<i64>().map_err(|_| InvalidAction)?;
		let mut values = vec![
			category.clone().into(),
			query.clone().into(),
			super::effect::Argument::Integer(limit),
		];
		values.extend(rest.iter().cloned().map(Into::into));
		crate::server::operations::operator::read_retire(&values).map_err(|_| InvalidAction)?;
		return Ok(Mutation {
			verb: crate::server::operations::operator::verbs::RETIRE_MATCHING.into(),
			args: values,
			reply: Reply::RetireBatch,
		});
	}
	let invalid = || InvalidAction;
	let text = |value: &String| value.clone();
	let (verb, args): (String, Vec<String>) = match (action, args) {
		("revokeRoomLink", [name]) => (action.into(), vec![text(name)]),
		("revokeRoomAuthority", [kind, token]) if matches!(kind.as_str(), "room" | "steward" | "manager") => {
			(action.into(), vec![text(kind), text(token)])
		}
		("revokeNick", [nick, session]) => (action.into(), vec![text(nick), text(session)]),
		("disconnectSession", [session]) => (action.into(), vec![text(session)]),
		("removeRoom", [room]) => ("removeOperatorRoom".into(), vec![text(room)]),
		("releaseReference", [reference]) => ("releaseOperatorReference".into(), vec![text(reference)]),
		("clearTrouble", []) => ("clearOperatorTrouble".into(), Vec::new()),
		("reset", [scope])
			if matches!(
				scope.as_str(),
				"links" | "registrations" | "sessions" | "rooms" | "runtime" | "all"
			) =>
		{
			("resetOperatorScope".into(), vec![text(scope)])
		}
		("giveModerator", [name]) => ("giveSteward".into(), vec![text(name)]),
		("giveManager", [identity]) if !identity.is_empty() => ("giveManager".into(), vec![text(identity)]),
		("revokeModerator", [name]) => ("revokeSteward".into(), vec![text(name)]),
		_ => return Err(invalid()),
	};
	let reply = match verb.as_str() {
		"giveSteward" | "revokeSteward" => Reply::Stewardship,
		"giveManager" => Reply::RoomManager,
		_ => Reply::Acknowledgment,
	};
	Ok(Mutation {
		verb,
		args: args.into_iter().map(Into::into).collect(),
		reply,
	})
}
