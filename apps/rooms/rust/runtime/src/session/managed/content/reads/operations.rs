//! Operations inspection lends only the interface declared for an exact
//! selected capability. Mutations remain retained session commands.
use super::*;
use rooms_application::{content::session::workspace, session::operations::mutation::Kind};

fn request(args: &[Argument]) -> Result<(custody::Coordinate, Option<Kind>)> {
	let [coordinate, kind] = args else {
		return Err(refuse("operations-reader takes exact custody and interface"));
	};
	let coordinate =
		custody::Coordinate::decode(text(coordinate)?).map_err(|_| refuse("invalid operations coordinate"))?;
	let kind = match kind {
		Argument::Void if coordinate.role == custody::Role::Operator => None,
		Argument::String(kind) => Some(
			serde_json::from_value(serde_json::Value::String(kind.clone()))
				.map_err(|_| refuse("invalid operations interface"))?,
		),
		_ => return Err(refuse("invalid operations interface")),
	};
	Ok((coordinate, kind))
}
pub(super) fn requirement(args: &[Argument]) -> Result<Requirement> {
	request(args)?;
	Requirement::new(&[Permission::UseOperations.key()], &[])
}
pub(super) fn selection(args: &[Argument], intent: &workspace::Intent) -> Result<custody::Coordinate> {
	let (coordinate, kind) = request(args)?;
	let held = match kind {
		None => intent
			.operators
			.as_slice()
			.iter()
			.any(|key| key.slot() == coordinate.key.slot() && key.generation() == coordinate.key.generation()),
		Some(Kind::Peering) if coordinate.role == custody::Role::PublicationLease => {
			intent.peering.as_slice().iter().any(|row| {
				row.lease.slot() == coordinate.key.slot() && row.lease.generation() == coordinate.key.generation()
			})
		}
		Some(kind) => intent
			.operations
			.as_slice()
			.iter()
			.any(|row| row.handle == coordinate && row.kind == kind && row.valid()),
	};
	if !held {
		return Err(refuse("the original operations interface is no longer selected"));
	}
	Ok(coordinate)
}
pub(super) fn invoke(call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
	let record = records::decode(input)?;
	let coordinate = selection(input.args, &record.intent)?;
	let (_, kind) = request(input.args)?;
	let field = record
		.custody
		.get(coordinate)
		.ok_or_else(|| refuse("operations custody is absent"))?;
	let target = records::reference(&field).resolve(call, input)?;
	let names: &[&str] = match kind {
		None => &[rooms_application::server::operations::operator::verbs::SNAPSHOT],
		Some(Kind::Listeners) => &["list"],
		Some(Kind::Diagnostics | Kind::IrcGateway) => &["snapshot"],
		Some(Kind::IrcConnection) => &["describe"],
		Some(Kind::Trace) => return Err(refuse("trace inspection uses the session publisher")),
		Some(Kind::Peering) if coordinate.role == custody::Role::PublicationLease => {
			&[rooms_application::protocol_data::PUBLICATION_DESCRIBE]
		}
		Some(Kind::Peering) => return Err(refuse("peering inspection requires an exact publication lease")),
	};
	let methods: Vec<_> = names.iter().map(|verb| ReadMethod { verb, results: &[] }).collect();
	call.disclose_reads_copying(&target, &[ReadInterface { methods: &methods }], 0)
		.map(Argument::Reference)
}
