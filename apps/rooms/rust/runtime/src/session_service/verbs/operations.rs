//! The shared operations capabilities a checkpoint retains: `operationsSnapshot`
//! reads one, and the `operator` and `operations` commands mutate through one.
//! Every relay runs against the credential's live reference on its directory.
use super::{
	effects::{ledger_task, Ledgered},
	operator,
};
use crate::session_service::error::Error;
use crate::session_service::facet::Facet;
use crate::session_service::facet::Rights;
use crate::session_service::Platform;
use glowcap::Argument;
use rooms_application::session::verbs;

const MAX_LISTENER_OPTIONS_UNITS: usize = 128 * 1024;
const MAX_LISTENER_OPTIONS: usize = 16;
const MAX_LISTENER_OPTION_NAME_UNITS: usize = 64;

pub fn snapshot<P: Platform>(facet: &Facet<P>, rights: &Rights, args: &[Argument]) -> Result<Argument, Error> {
	if !rights.is_admin() {
		return Err(Error::refused(
			"this Rooms session facet cannot inspect operations authority",
		));
	}
	let [Argument::String(scope), Argument::String(capability)] = args else {
		return Err(Error::refused(
			"operationsSnapshot takes a scope and supported capability name",
		));
	};
	use rooms_application::session::operations::Capability;
	let capability = match capability.as_str() {
		"listeners" => Capability::Listeners,
		"diagnostics" => Capability::Diagnostics,
		"viz" => Capability::Viz,
		"peering" => Capability::Peering,
		"irc" => Capability::Irc,
		_ => return Err(Error::refused("unsupported operations capability")),
	};
	prepare_snapshot(facet, scope, capability)?.wire_with(facet, verbs::OPERATIONS_SNAPSHOT, |snapshot| {
		snapshot
			.encode()
			.map(Argument::String)
			.map_err(|e| Error::refused(e.to_string()))
	})
}
pub(in crate::session_service) fn prepare_snapshot<P: Platform>(
	facet: &Facet<P>,
	scope: &str,
	capability: rooms_application::session::operations::Capability,
) -> Result<crate::session_service::revision::Prepared<rooms_application::session::operations::Snapshot>, Error> {
	use crate::session_service::revision::Prepared;
	use rooms_application::session::operations::{wire, Capability, Snapshot};
	use rooms_glowcap::Value;
	let decode = |reply: Argument| {
		Snapshot::decode(
			capability,
			reply
				.as_str()
				.ok_or_else(|| Error::runtime("operations returned no description"))?,
		)
		.map_err(|e| Error::refused(e.to_string()))
	};
	match capability {
		Capability::Viz => {
			return Ok(Prepared::ready(decode(
				facet.0.viz.snapshot(scope, &facet.0.commands)?,
			)?))
		}
		Capability::Peering => {
			return Ok(Prepared::ready(decode(
				facet
					.0
					.peering
					.snapshot(scope, &facet.0.commands)
					.map_err(Error::runtime)?,
			)?))
		}
		_ => {}
	}
	let operations = facet.0.operations.clone();
	let commands = facet.0.commands.clone();
	let directories = facet.0.directories.clone();
	let scope = scope.to_owned();
	Ok(Prepared::new(async move {
		let verb = if capability == Capability::Listeners {
			"list"
		} else {
			"snapshot"
		};
		let reply = operations
			.call(&commands, &directories, capability.name(), &scope, verb, &[])
			.await
			.map_err(Error::runtime)?;
		match capability {
			Capability::Listeners => wire::listeners(&Value(&reply)),
			Capability::Diagnostics => wire::diagnostics(&Value(&reply)),
			Capability::Irc => Snapshot::decode(
				capability,
				reply
					.as_str()
					.ok_or_else(|| Error::runtime("bridge returned no description"))?,
			),
			_ => unreachable!("synchronous operations snapshot"),
		}
		.map_err(|e| Error::refused(e.to_string()))
	}))
}

/// Call one method on the live capability for `scope` and answer with
/// `convert` applied to its reply.
pub(in crate::session_service) fn prepare_relay<P: Platform, T: 'static>(
	facet: &Facet<P>,
	capability: &str,
	scope: &str,
	verb: &str,
	args: Vec<Argument>,
	convert: impl FnOnce(Argument) -> Result<T, Error> + 'static,
) -> Result<crate::session_service::revision::Prepared<T>, Error> {
	let operations = facet.0.operations.clone();
	let commands = facet.0.commands.clone();
	let directories = facet.0.directories.clone();
	let target = crate::operations::Target::capture(&commands, capability, scope).map_err(Error::runtime)?;
	let verb = verb.to_owned();
	Ok(crate::session_service::revision::Prepared::new(async move {
		let reply = operations
			.call_target(&commands, &directories, &target, &verb, &args)
			.await
			.map_err(Error::runtime)?;
		convert(reply)
	}))
}

/// `operator <scope> <action> <args…>`: a ledgered operator mutation.
pub fn operator_effect<P: Platform>(
	facet: &Facet<P>,
	ledgered: Ledgered,
	args: &[String],
) -> Result<crate::session_service::revision::Revision, Error> {
	let [scope, action, rest @ ..] = args else {
		return Err(Error::refused("operator takes a scope, action, and action arguments"));
	};
	let (verb, call) = operator::mutation_args(action, rest)?;
	mutate(facet, ledgered, "operator", scope.clone(), verb, call)
}

/// `operations <scope> <capability> <action> <args…>`: a ledgered mutation
/// through a shared capability that accepts one.
pub fn operations_effect<P: Platform>(
	facet: &Facet<P>,
	ledgered: Ledgered,
	args: &[String],
) -> Result<crate::session_service::revision::Revision, Error> {
	let [scope, capability, action, rest @ ..] = args else {
		return Err(Error::refused(
			"operations takes a scope, capability, action, and action arguments",
		));
	};
	match capability.as_str() {
		"diagnostics" => Err(Error::refused(
			"the diagnostics capability is inspect-only; use its snapshot and the Rooms operator to act",
		)),
		"operator" => Err(Error::refused(
			"Rooms operator mutations use the operator command, which preserves their typed action scope",
		)),
		"peering" => Err(Error::refused(
			"peering mutations use durable publication intents, not raw operations calls",
		)),
		"viz" => Err(Error::refused(
			"the visualizer capability is reconciled from saved session configuration",
		)),
		"listeners" => {
			let call = listener_args(action, rest)?;
			mutate(facet, ledgered, "listeners", scope.clone(), action.clone(), call)
		}
		"irc" => irc_effect(facet, ledgered, scope, action, rest),
		_ => Err(Error::refused(format!(
			"unknown shared operations capability \"{capability}\""
		))),
	}
}

fn irc_effect<P: Platform>(
	facet: &Facet<P>,
	ledgered: Ledgered,
	scope: &str,
	action: &str,
	args: &[String],
) -> Result<crate::session_service::revision::Revision, Error> {
	let text = |value: &String| Argument::from(value.clone());
	match (action, args) {
		("openConnection", [answers]) => mutate(
			facet,
			ledgered,
			"irc",
			scope.to_owned(),
			action.to_owned(),
			vec![text(answers)],
		),
		("closeConnection", [connection]) if !connection.is_empty() => {
			mutate_connection(facet, ledgered, scope, connection, "closeConnection", Vec::new())
		}
		("removeLease", [connection, lease]) if !connection.is_empty() && !lease.is_empty() => {
			mutate_connection(facet, ledgered, scope, connection, "removeLease", vec![text(lease)])
		}
		("addLease", [connection, answers]) if !connection.is_empty() => {
			mutate_connection(facet, ledgered, scope, connection, "addLease", vec![text(answers)])
		}
		_ => Err(Error::refused(format!(
			"shared bridge gateway action {action} has invalid arguments"
		))),
	}
}

fn mutate<P: Platform>(
	facet: &Facet<P>,
	ledgered: Ledgered,
	capability: &'static str,
	scope: String,
	verb: String,
	args: Vec<Argument>,
) -> Result<crate::session_service::revision::Revision, Error> {
	let operations = facet.0.operations.clone();
	let commands = facet.0.commands.clone();
	let directories = facet.0.directories.clone();
	let target = crate::operations::Target::capture(&commands, capability, &scope);
	ledger_task(facet, ledgered, async move {
		let target = target?;
		operations
			.call_target(&commands, &directories, &target, &verb, &args)
			.await?;
		operations.notify_scope(&scope);
		Ok::<(), String>(())
	})
}

fn mutate_connection<P: Platform>(
	facet: &Facet<P>,
	ledgered: Ledgered,
	scope: &str,
	connection: &str,
	verb: &str,
	args: Vec<Argument>,
) -> Result<crate::session_service::revision::Revision, Error> {
	let operations = facet.0.operations.clone();
	let commands = facet.0.commands.clone();
	let directories = facet.0.directories.clone();
	let (scope, connection, verb) = (scope.to_owned(), connection.to_owned(), verb.to_owned());
	let target = crate::operations::Target::capture(&commands, "irc", &scope);
	ledger_task(facet, ledgered, async move {
		let target = target?;
		operations
			.irc_connection(&commands, &directories, &target, &connection, &verb, &args)
			.await?;
		operations.notify_scope(&scope);
		Ok::<(), String>(())
	})
}

fn listener_args(action: &str, args: &[String]) -> Result<Vec<Argument>, Error> {
	match (action, args) {
		("up", [transport]) => Ok(vec![transport.clone().into()]),
		("up", [transport, options]) => listener_up(transport, options),
		("down", [id]) => {
			let id = id
				.parse::<i64>()
				.ok()
				.filter(|n| *n > 0 && *n < (1i64 << 53))
				.ok_or_else(|| Error::refused("listener down needs a positive listener id"))?;
			Ok(vec![Argument::Integer(id)])
		}
		_ => Err(Error::refused(format!(
			"shared listener action {action} has invalid arguments"
		))),
	}
}

fn listener_up(transport: &str, options: &str) -> Result<Vec<Argument>, Error> {
	const INVALID: &str = "listener up options are incomplete or invalid";
	if options.encode_utf16().count() > MAX_LISTENER_OPTIONS_UNITS {
		return Err(Error::refused("listener up options are too large"));
	}
	let value: serde_json::Value =
		serde_json::from_str(options).map_err(|_| Error::refused("listener up options are not JSON"))?;
	let serde_json::Value::Object(map) = value else {
		return Err(Error::refused(INVALID));
	};
	if map.len() > MAX_LISTENER_OPTIONS {
		return Err(Error::refused(INVALID));
	}
	let mut pairs = Vec::new();
	for (name, value) in map {
		if name.is_empty() || name.encode_utf16().count() > MAX_LISTENER_OPTION_NAME_UNITS {
			return Err(Error::refused(INVALID));
		}
		let value = match value {
			serde_json::Value::String(text) => text.into(),
			serde_json::Value::Number(n) => Argument::Integer(n.as_i64().ok_or_else(|| Error::refused(INVALID))?),
			_ => return Err(Error::refused(INVALID)),
		};
		pairs.push(Argument::List(vec![name.into(), value]));
	}
	if pairs.is_empty() {
		Ok(vec![transport.into()])
	} else {
		Ok(vec![transport.into(), Argument::List(pairs)])
	}
}
