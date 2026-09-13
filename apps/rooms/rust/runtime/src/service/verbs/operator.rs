//! The Rooms operator capability, relayed from the retained credential:
//! inspection verbs reshape the operator's CapTP answer into the JSON the
//! browser parses, and mutation actions map onto the operator's own methods.
use crate::service::Platform;
use crate::service::error::Error;
use crate::service::facet::Facet;
use crate::service::facet::Rights;
use glowcap::Argument;
use rooms_application::session::verbs;

pub(super) mod json;

const MAX_QUERY_UNITS: usize = 128;
const PAGE_ROWS: i64 = 32;
const MAX_RETIRE_BATCH: i64 = 256;

/// The operator's inventory categories, in the order its snapshot lists them.
pub const CATEGORIES: [&str; 7] = [
	"stewardships",
	"links",
	"registrations",
	"sessions",
	"rooms",
	"references",
	"trouble",
];

/// The operator verb the relay calls, with the arguments it takes.
type Relay = (&'static str, Vec<Argument>);

pub fn inspect<P: Platform>(
	facet: &Facet<P>,
	rights: &Rights,
	verb: &str,
	args: &[Argument],
) -> Result<Argument, Error> {
	if !rights.is_admin() {
		return Err(Error::refused(
			"this Rooms session facet cannot inspect operator authority",
		));
	}
	let snapshot = verb == verbs::OPERATOR_SNAPSHOT;
	prepare(facet, verb, args, move |reply| {
		if snapshot {
			json::snapshot(&reply).map(Argument::String)
		} else {
			Ok(reply)
		}
	})?
	.wire_with(facet, rooms_application::session::verbs::OPERATIONS_SNAPSHOT, Ok)
}
pub(in crate::service) fn prepare<P: Platform, T: 'static>(
	facet: &Facet<P>,
	verb: &str,
	args: &[Argument],
	convert: impl FnOnce(Argument) -> Result<T, Error> + 'static,
) -> Result<crate::service::revision::Prepared<T>, Error> {
	// Checked retirement binds the mutation to the observed session revision.
	// Existing unversioned clients retain their explicit-scope behavior.
	let args = if verb == verbs::OPERATOR_RETIRE && args.len() >= 5 {
		if let Some(Argument::Integer(base)) = args.last() {
			let current = facet.0.commands.view().read(|state| state.revision())??;
			if *base < 0 || *base as u64 != current {
				return Err(Error::stale(
					"Rooms operations changed; repeat retirement against the current view",
				));
			}
			&args[..args.len() - 1]
		} else {
			args
		}
	} else {
		args
	};
	let Some(scope) = args
		.first()
		.and_then(Argument::as_str)
		.filter(|scope| !scope.is_empty())
	else {
		return Err(Error::invalid(format!(
			"{verb} takes a capability scope{}",
			if verb == verbs::OPERATOR_SNAPSHOT {
				" and an optional search"
			} else {
				""
			}
		)));
	};
	let (relay_verb, relay_args) = match verb {
		verbs::OPERATOR_SNAPSHOT => snapshot_args(args)?,
		verbs::OPERATOR_PAGE => page_args(args)?,
		_ => retire_args(args)?,
	};
	super::operations::prepare_relay(facet, "operator", scope, relay_verb, relay_args, convert)
}

fn query_fits(query: &str) -> bool {
	query.encode_utf16().count() <= MAX_QUERY_UNITS
}

fn snapshot_args(args: &[Argument]) -> Result<Relay, Error> {
	match args {
		[_] => Ok(("operatorSnapshot", Vec::new())),
		[_, Argument::String(query)] if query_fits(query) => Ok(("operatorSnapshot", vec![query.clone().into()])),
		[_, Argument::String(query), Argument::String(kind)] if query_fits(query) && reference_kind(kind) => {
			Ok(("operatorSnapshot", vec![query.clone().into(), kind.clone().into()]))
		}
		_ => Err(Error::invalid(
			"operatorSnapshot takes a capability scope and an optional search",
		)),
	}
}

fn page_args(args: &[Argument]) -> Result<Relay, Error> {
	const SHAPE: &str = "operatorPage takes a capability scope, category, cursor, and optional search";
	let (category, cursor, query, kind) = match args {
		[_, Argument::String(category), Argument::Integer(cursor)] => (category, *cursor, "", None),
		[
			_,
			Argument::String(category),
			Argument::Integer(cursor),
			Argument::String(query),
		] => (category, *cursor, query.as_str(), None),
		[
			_,
			Argument::String(category),
			Argument::Integer(cursor),
			Argument::String(query),
			Argument::String(kind),
		] => (category, *cursor, query.as_str(), Some(kind.as_str())),
		_ => return Err(Error::invalid(SHAPE)),
	};
	if !CATEGORIES.contains(&category.as_str())
		|| cursor < 0
		|| !query_fits(query)
		|| kind.is_some_and(|kind| !reference_kind(kind) || category != "references")
	{
		return Err(Error::invalid(SHAPE));
	}
	let mut relay = vec![
		category.clone().into(),
		Argument::Integer(cursor),
		Argument::Integer(PAGE_ROWS),
		query.into(),
	];
	relay.extend(kind.map(Argument::from));
	Ok(("operatorSnapshot", relay))
}

fn retire_args(args: &[Argument]) -> Result<Relay, Error> {
	const SHAPE: &str = "operatorRetire takes a scope, category, search, and batch limit";
	let (category, query, limit, kind) = match args {
		[
			_,
			Argument::String(category),
			Argument::String(query),
			Argument::Integer(limit),
		] => (category, query, *limit, None),
		[
			_,
			Argument::String(category),
			Argument::String(query),
			Argument::Integer(limit),
			Argument::String(kind),
		] => (category, query, *limit, Some(kind.as_str())),
		_ => return Err(Error::invalid(SHAPE)),
	};
	if !CATEGORIES.contains(&category.as_str())
		|| !query_fits(query)
		|| !(1..=MAX_RETIRE_BATCH).contains(&limit)
		|| kind.is_some_and(|kind| !reference_kind(kind) || category != "references")
	{
		return Err(Error::invalid(SHAPE));
	}
	let mut relay = vec![category.clone().into(), query.clone().into(), Argument::Integer(limit)];
	relay.extend(kind.map(Argument::from));
	Ok(("operatorRetireMatching", relay))
}

fn reference_kind(value: &str) -> bool {
	matches!(
		value,
		"membership"
			| "line" | "upload"
			| "foreign-room"
			| "pending-peering"
			| "registration"
			| "offered-inbox"
			| "signaling"
			| "signal-exchange"
	)
}

/// An operator mutation from the `operator` command, as the operator's own
/// verb and arguments.
pub fn mutation_args(action: &str, args: &[String]) -> Result<(String, Vec<Argument>), Error> {
	let invalid = || Error::invalid(format!("Rooms operator action {action} has invalid arguments"));
	let text = |value: &String| Argument::from(value.clone());
	Ok(match (action, args) {
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
		("revokeModerator", [name]) => ("revokeSteward".into(), vec![text(name)]),
		_ => return Err(invalid()),
	})
}
