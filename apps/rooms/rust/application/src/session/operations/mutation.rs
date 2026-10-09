//! Mutations select an exact operations interface, never an arbitrary verb.
use crate::session::effect::{Argument, Mutation, Reply};
use alloc::{string::String, vec, vec::Vec};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
	Listeners,
	Diagnostics,
	Trace,
	Peering,
	IrcGateway,
	IrcConnection,
}
impl Kind {
	pub const ALL: &'static [Self] = &[
		Self::Listeners,
		Self::Diagnostics,
		Self::Trace,
		Self::Peering,
		Self::IrcGateway,
		Self::IrcConnection,
	];
}
#[derive(Clone, Copy, Debug)]
pub struct Refusal;

pub fn mutation(kind: Kind, action: &str, args: &[String]) -> Result<Mutation, Refusal> {
	let text = |value: &String| Argument::Text(value.clone());
	let (args, reply) = match (kind, action, args) {
		(Kind::Listeners, "up", [transport]) if !transport.is_empty() => (vec![text(transport)], Reply::Listener),
		(Kind::Listeners, "up", [transport, options]) if !transport.is_empty() => {
			let mut args = vec![text(transport)];
			let options = listener_options(options)?;
			if !options.is_empty() {
				args.push(Argument::List(options));
			}
			(args, Reply::Listener)
		}
		(Kind::Listeners, "down", [id]) => {
			let id = id
				.parse::<i64>()
				.ok()
				.filter(|id| *id > 0 && *id < (1i64 << 53))
				.ok_or(Refusal)?;
			(vec![Argument::Integer(id)], Reply::Acknowledgment)
		}
		(Kind::IrcGateway, "openConnection", [answers]) if !answers.is_empty() => (vec![text(answers)], Reply::Text),
		(Kind::IrcGateway, "connection", [name]) if !name.is_empty() => (vec![text(name)], Reply::IrcConnection),
		(Kind::IrcConnection, "closeConnection", []) => (Vec::new(), Reply::Acknowledgment),
		(Kind::IrcConnection, "addLease", [answers]) if !answers.is_empty() => (vec![text(answers)], Reply::Text),
		(Kind::IrcConnection, "removeLease", [lease]) if !lease.is_empty() => (vec![text(lease)], Reply::Text),
		_ => return Err(Refusal),
	};
	Ok(Mutation {
		verb: action.into(),
		args,
		reply,
	})
}

fn listener_options(raw: &str) -> Result<Vec<Argument>, Refusal> {
	if raw.encode_utf16().take(128 * 1024 + 1).count() > 128 * 1024 {
		return Err(Refusal);
	}
	let serde_json::Value::Object(options) = serde_json::from_str(raw).map_err(|_| Refusal)? else {
		return Err(Refusal);
	};
	if options.len() > 16 {
		return Err(Refusal);
	}
	options
		.into_iter()
		.map(|(name, value)| {
			if name.is_empty() || name.encode_utf16().count() > 64 {
				return Err(Refusal);
			}
			let value = match value {
				serde_json::Value::String(value) => Argument::Text(value),
				serde_json::Value::Number(value) => Argument::Integer(value.as_i64().ok_or(Refusal)?),
				_ => return Err(Refusal),
			};
			Ok(Argument::List(vec![Argument::Text(name), value]))
		})
		.collect()
}
