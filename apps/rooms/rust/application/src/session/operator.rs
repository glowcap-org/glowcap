//! Bounded operator action grammar, shared by session dispatchers.
use super::effect::{Mutation, Reply};
use crate::{
	room::{authority, stewardship::Kind},
	server::operations::operator::verbs,
};
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
		(authority::REVOKE_ROOM_LINK, [name]) => (action.into(), vec![text(name)]),
		(verbs::REVOKE_ROOM_AUTHORITY, [kind, token]) if Kind::parse(kind).is_some() => {
			(action.into(), vec![text(kind), text(token)])
		}
		(verbs::REVOKE_NICK, [nick, session]) => (action.into(), vec![text(nick), text(session)]),
		(verbs::DISCONNECT_SESSION, [session]) => (action.into(), vec![text(session)]),
		("removeRoom", [room]) => (verbs::REMOVE_ROOM.into(), vec![text(room)]),
		("releaseReference", [reference]) => (verbs::RELEASE_REFERENCE.into(), vec![text(reference)]),
		("clearTrouble", []) => (verbs::CLEAR_TROUBLE.into(), Vec::new()),
		("reset", [scope])
			if matches!(
				scope.as_str(),
				"links" | "registrations" | "sessions" | "rooms" | "runtime" | "all"
			) =>
		{
			(verbs::RESET_SCOPE.into(), vec![text(scope)])
		}
		("giveModerator", [name]) => (authority::GIVE_STEWARD.into(), vec![text(name)]),
		(verbs::GIVE_MANAGER, [identity]) if !identity.is_empty() => (verbs::GIVE_MANAGER.into(), vec![text(identity)]),
		("revokeModerator", [name]) => (authority::REVOKE_STEWARD.into(), vec![text(name)]),
		_ => return Err(invalid()),
	};
	let reply = match verb.as_str() {
		authority::GIVE_STEWARD | authority::REVOKE_STEWARD => Reply::Stewardship,
		verbs::GIVE_MANAGER => Reply::RoomManager,
		_ => Reply::Acknowledgment,
	};
	Ok(Mutation {
		verb,
		args: args.into_iter().map(Into::into).collect(),
		reply,
	})
}
