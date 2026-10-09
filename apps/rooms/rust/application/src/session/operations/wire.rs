//! Shared admission for direct listener/diagnostic answers before a session
//! renders them as JSON. The same bounded values are read by attached clients.
use super::*;
use crate::{
	room::ListArgument,
	server::operations::operator::view::wire::{boolean, budget, list, number, text, tuple},
};

pub fn listeners<A: ListArgument>(value: &A) -> Result<Snapshot, Refusal> {
	let mut remaining = MAX_JSON_UNITS;
	budget(value, &mut remaining, 5)?;
	let rows = list(value, read_listener)?;
	Ok(Snapshot::Listeners(rows))
}
/// Validate one listener row directly from its borrowed answer.
pub fn listener<A: ListArgument>(value: &A) -> Result<Listener, Refusal> {
	let mut remaining = MAX_JSON_UNITS;
	budget(value, &mut remaining, 4)?;
	read_listener(value)
}
fn read_listener<A: ListArgument>(value: &A) -> Result<Listener, Refusal> {
	let [
		transport,
		description,
		reference,
		reference_name,
		takes,
		unavailable,
		id,
		locator,
		serving,
	] = tuple(value)?;
	let id = number::<false>(&id)?.get();
	let row = Listener {
		transport: text(&transport)?,
		description: text(&description)?,
		reference: text(&reference)?,
		reference_name: text(&reference_name)?,
		takes: list(&takes, |option| {
			let [name, kind, hint] = tuple(option)?;
			Ok(ListenerOption {
				name: text(&name)?,
				kind: match kind.text() {
					Some("host") => OptionKind::Host,
					Some("port") => OptionKind::Port,
					Some("url") => OptionKind::Url,
					_ => return Err(Refusal::Kind),
				},
				hint: text(&hint)?,
			})
		})?,
		unavailable: text(&unavailable)?,
		id: if id == 0 {
			Nullable::Null
		} else {
			Nullable::Value(SafeInteger::new(id).expect("positive admitted id"))
		},
		locator: if locator.text() == Some("") {
			Nullable::Null
		} else {
			Nullable::Value(text(&locator)?)
		},
		serving: boolean(&serving)?,
	};
	row.validate()?;
	Ok(row)
}
pub fn diagnostics<A: ListArgument>(value: &A) -> Result<Snapshot, Refusal> {
	let mut remaining = MAX_JSON_UNITS;
	budget(value, &mut remaining, 3)?;
	Ok(Snapshot::Diagnostics(list(value, |value| {
		let [kind, name, note] = tuple(value)?;
		Ok(Diagnostic {
			kind: text(&kind)?,
			name: text(&name)?,
			note: text(&note)?,
		})
	})?))
}
