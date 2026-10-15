//! Reading a room's wire values against the generated grammar.
//!
//! `protocol_gen.rs` beside this file declares the shapes, generated from
//! `tools/gen/rooms_protocol.zig` by `zig build gen-rooms-protocol` and shared
//! with every sibling client: the directory's publication record, the watch
//! notifications, the tails a room line carries after its display text, and the
//! subscribe answer. This module is the Rust reading of those shapes, one value
//! at a time, so `room.rs` holds sessions and lines rather than argument
//! positions. Every check here is this language's own. What it checks against is
//! the table.

use glowcap::Argument;

use crate::protocol_gen::{
	Effect, Field, LIST_PAGE_FIELDS, MEMBERSHIP_ENDED, PUBLICATION_FIELDS, REGISTRATION_ID_DASHES,
	REGISTRATION_ID_LENGTH, REGISTRATION_ID_VARIANT_AT, REGISTRATION_ID_VARIANTS, REGISTRATION_ID_VERSION_AT,
	REGISTRATION_ID_VERSIONS, REGISTRATION_ROW_FIELDS, ROOM_SENDER, ROOM_TAILS, RoomTail, SUBSCRIBE_ANSWER_FIELDS,
	Sender, TextRule, Ty, WATCH_KINDS, WATCH_SNAPSHOT_FIELDS,
};

/// One exact directory publication. Foreign occupancy is unknown, not zero.
///
/// The fields are the generated `PUBLICATION_FIELDS` under the names the table
/// gives them, so a validated row is read by name rather than by position.
#[derive(Clone, Debug)]
pub struct RoomInfo {
	pub name: String,
	pub count: Option<i64>,
	pub id: String,
	pub kind: String,
	pub origin: String,
	pub proof: String,
	pub offers: Option<String>,
}

/// A membership change a system line carries as structured wire args, not prose.
/// `kind` is the generated tail's tag, `names` the members it is about (the whole
/// roster, or the one member), and `effect` what the tail does to them.
#[derive(Debug, Clone)]
pub struct Presence {
	pub kind: String,
	pub names: Vec<String>,
	pub effect: Effect,
}

/// Whether one wire value is of the declared type, checked with Rust's own
/// accessors over `Argument`.
fn admits_type(ty: Ty, value: &Argument) -> bool {
	match ty {
		Ty::String => value.as_str().is_some(),
		Ty::Text => value.as_str().is_some_and(|text| !text.is_empty()),
		Ty::Natural => value.as_i64().is_some_and(|count| count >= 0),
		Ty::Boolean => value.as_bool().is_some(),
		Ty::Reference => matches!(value, Argument::Reference(_)),
		Ty::RegistrationId => value.as_str().is_some_and(valid_registration_id),
		Ty::List => value.as_list().is_some(),
		Ty::Any => true,
	}
}

/// Whether one wire value fits its declared field: a wire void where the field
/// admits one, a member of the enumeration where it has one, and the type.
fn admits(field: &Field, value: &Argument) -> bool {
	if value.is_void() {
		return field.nullable;
	}
	if !field.values.is_empty() {
		let named = value.as_str().is_some_and(|text| field.values.contains(&text));
		if !named {
			return false;
		}
	}
	admits_type(field.ty, value)
}

/// Whether a wire list is exactly the declared fields, one value each.
fn fits(fields: &[Field], values: &[Argument]) -> bool {
	values.len() == fields.len() && fields.iter().zip(values).all(|(field, value)| admits(field, value))
}

/// One declared field's value, by the name the table gives it, so a reader asks
/// for what it wants instead of counting positions.
fn field<'a>(fields: &[Field], values: &'a [Argument], name: &str) -> Option<&'a Argument> {
	values.get(fields.iter().position(|declared| declared.name == name)?)
}

/// Whether a string is a registration id in the form the generated
/// `REGISTRATION_ID_*` constants declare: hex text with dashes at the declared
/// offsets, and the version and variant characters the directory mints (the
/// variant without regard to case).
fn valid_registration_id(value: &str) -> bool {
	let bytes = value.as_bytes();
	if bytes.len() != REGISTRATION_ID_LENGTH {
		return false;
	}
	bytes.iter().enumerate().all(|(at, byte)| {
		if REGISTRATION_ID_DASHES.contains(&at) {
			*byte == b'-'
		} else if at == REGISTRATION_ID_VERSION_AT {
			REGISTRATION_ID_VERSIONS.as_bytes().contains(byte)
		} else if at == REGISTRATION_ID_VARIANT_AT {
			REGISTRATION_ID_VARIANTS.as_bytes().contains(&byte.to_ascii_lowercase())
		} else {
			byte.is_ascii_hexdigit()
		}
	})
}

/// One publication row, once the generated record admits it.
fn parse_room(values: &[Argument]) -> Option<RoomInfo> {
	if !fits(PUBLICATION_FIELDS, values) {
		return None;
	}
	let text = |name: &str| -> Option<String> { Some(field(PUBLICATION_FIELDS, values, name)?.as_str()?.to_string()) };
	Some(RoomInfo {
		name: text("name")?,
		// A wire void is an unknown occupancy and an absent offer, not a zero.
		count: field(PUBLICATION_FIELDS, values, "count")?.as_i64(),
		id: text("id")?,
		kind: text("kind")?,
		origin: text("origin")?,
		proof: text("proof")?,
		offers: field(PUBLICATION_FIELDS, values, "offers")?
			.as_str()
			.map(str::to_string),
	})
}

/// One page of a `listPublications` answer: its publications, and the cursor
/// that asks for the next page when more remain.
#[derive(Clone, Debug)]
pub struct RoomPage {
	pub rooms: Vec<RoomInfo>,
	pub next: Option<String>,
}

/// A `listPublications` answer, held to the generated page record.
pub fn parse_room_page(arg: &Argument) -> Result<RoomPage, String> {
	let values = arg
		.as_list()
		.filter(|values| fits(LIST_PAGE_FIELDS, values))
		.ok_or_else(|| "the directory answered a malformed room page".to_string())?;
	let rooms = field(LIST_PAGE_FIELDS, values, "rooms")
		.ok_or_else(|| "the directory answered a malformed room page".to_string())
		.and_then(parse_rooms)?;
	let next = field(LIST_PAGE_FIELDS, values, "next")
		.and_then(Argument::as_str)
		.map(str::to_owned);
	Ok(RoomPage { rooms, next })
}

/// Every publication in a room list.
fn parse_rooms(arg: &Argument) -> Result<Vec<RoomInfo>, String> {
	let rows = arg
		.as_list()
		.ok_or_else(|| "the directory answered a room list that is not a list".to_string())?;
	let mut out = Vec::new();
	for item in rows {
		let room = item
			.as_list()
			.and_then(parse_room)
			.ok_or_else(|| "the directory answered a malformed room publication".to_string())?;
		out.push(room);
	}
	Ok(out)
}

/// The watch baseline: the rooms, the registration rows beside them, and the
/// omission count, each held to the generated snapshot record.
pub fn parse_watch_rooms(arg: &Argument) -> Result<Vec<RoomInfo>, String> {
	let values = arg
		.as_list()
		.filter(|values| fits(WATCH_SNAPSHOT_FIELDS, values))
		.ok_or_else(|| "the directory answered a malformed watch snapshot".to_string())?;
	let registrations = field(WATCH_SNAPSHOT_FIELDS, values, "registrations")
		.and_then(Argument::as_list)
		.ok_or_else(|| "the directory answered malformed registration rows".to_string())?;
	let rows_fit = registrations.iter().all(|row| {
		row.as_list()
			.is_some_and(|values| fits(REGISTRATION_ROW_FIELDS, values))
	});
	if !rows_fit {
		return Err("the directory answered malformed registration rows".to_string());
	}
	let rooms = field(WATCH_SNAPSHOT_FIELDS, values, "rooms")
		.ok_or_else(|| "the directory answered a malformed watch snapshot".to_string())?;
	parse_rooms(rooms)
}

/// Parse every generated watcher shape. Registration and truncation events are
/// valid but carry no room row for this small terminal client to print.
pub fn parse_watch_event(args: &[Argument]) -> Result<Option<(String, RoomInfo)>, String> {
	let tag = args
		.first()
		.and_then(Argument::as_str)
		.ok_or_else(|| "the directory sent a malformed watch notification".to_string())?;
	let kind = WATCH_KINDS
		.iter()
		.find(|kind| kind.tag == tag)
		.ok_or_else(|| format!("the directory sent an unknown watch event {tag}"))?;
	let malformed = || {
		format!(
			"the directory sent a malformed {} watch notification",
			if kind.room { "room" } else { kind.tag }
		)
	};
	if !fits(kind.args, &args[1..]) {
		return Err(malformed());
	}
	if !kind.room {
		return Ok(None);
	}
	let room = parse_room(&args[1..]).ok_or_else(malformed)?;
	Ok(Some((tag.to_string(), room)))
}

/// The generated tail a room line's tag names, if it names one.
fn room_tail(tag: &str) -> Option<&'static RoomTail> {
	ROOM_TAILS.iter().find(|tail| tail.tag == tag)
}

/// Whether a room line's sender, display text, and arguments after the tag are
/// what the generated tail declares.
fn tail_fits(tail: &RoomTail, from: &str, text: &str, rest: &[Argument]) -> bool {
	let said_by = match tail.sender {
		Sender::Room => from == ROOM_SENDER,
		Sender::Member => from != ROOM_SENDER,
		Sender::Either => true,
	};
	let says = match tail.text {
		TextRule::Any => true,
		TextRule::Empty => text.is_empty(),
		TextRule::Nonempty => !text.is_empty(),
	};
	if !said_by || !says || rest.len() < tail.trailing.len() {
		return false;
	}
	let (fixed, more) = rest.split_at(tail.trailing.len());
	if !fits(tail.trailing, fixed) {
		return false;
	}
	match tail.rest {
		Some(ty) => more.iter().all(|value| admits_type(ty, value)),
		None => more.is_empty(),
	}
}

/// Whether a `membershipEnded` line is the whole shape its generated tail
/// declares: said by the room, one nonempty reason as the display text, and
/// nothing after the tag.
pub fn membership_ended_fits(from: &str, text: &str, args: &[Argument]) -> bool {
	let rest = args.get(3..).unwrap_or_default();
	room_tail(MEMBERSHIP_ENDED).is_some_and(|tail| tail_fits(tail, from, text, rest))
}

/// Read the structured presence a room line carries after its display text, when
/// the tag names a presence tail and the arguments are its shape:
/// `notify("room", text, "roster", names…)` or `notify("room", text, tag, name, …)`.
/// Ordinary chat lines carry none, and a malformed tail reads as none, so the
/// line still draws.
pub fn read_presence(from: &str, text: &str, args: &[Argument]) -> Option<Presence> {
	let tag = args.get(2).and_then(Argument::as_str)?;
	let tail = room_tail(tag)?;
	let effect = tail.effect?;
	let rest = &args[3..];
	if !tail_fits(tail, from, text, rest) {
		return None;
	}
	let (fixed, more) = rest.split_at(tail.trailing.len());
	let mut names: Vec<String> = tail
		.trailing
		.iter()
		.zip(fixed)
		.filter(|(declared, _)| declared.name == "name")
		.filter_map(|(_, value)| value.as_str().map(str::to_string))
		.collect();
	// A roster names its members in the arguments the tail leaves open.
	if tail.rest.is_some() {
		names.extend(more.iter().filter_map(Argument::as_str).map(str::to_string));
	}
	Some(Presence {
		kind: tag.to_string(),
		names,
		effect,
	})
}

/// The membership seat `subscribe` answers with, the `seat` of the generated
/// answer record. An observer is answered with void where a participant holds
/// the topic, which the record's nullable field admits.
pub fn membership_seat(answer: &Argument) -> Option<glowcap::Ref> {
	let values = answer
		.as_list()
		.filter(|values| fits(SUBSCRIBE_ANSWER_FIELDS, values))?;
	match field(SUBSCRIBE_ANSWER_FIELDS, values, "seat")? {
		Argument::Reference(seat) => Some(seat.clone()),
		_ => None,
	}
}

/// The wire shapes this module reads, built for its own tests and for the room
/// inbox tests next door, so one fixture serves both.
#[cfg(test)]
pub mod fixtures {
	use super::*;

	/// One publication row in the generated field order, with the two values a
	/// caller varies: the occupancy and the offered membership.
	pub fn publication(count: Argument, offers: Argument) -> Vec<Argument> {
		vec![
			Argument::from("lobby"),
			count,
			Argument::from("id-1"),
			Argument::from("local"),
			Argument::from(""),
			Argument::from("local"),
			offers,
		]
	}

	/// A room line: who said it, its display text, then the tail.
	pub fn notify(from: &str, text: &str, tail: Vec<Argument>) -> Vec<Argument> {
		let mut args = vec![Argument::from(from), Argument::from(text)];
		args.extend(tail);
		args
	}
}

#[cfg(test)]
mod tests {
	use super::fixtures::{notify, publication};
	use super::*;

	#[test]
	fn malformed_watch_callbacks_are_refused() {
		let malformed = [Argument::from("opened"), Argument::from("only-a-name")];
		assert!(parse_watch_event(&malformed).is_err());
		let registration = [
			Argument::from("registered"),
			Argument::from("ada"),
			Argument::from(1_i64),
			Argument::from("00000000-0000-4000-8000-000000000001"),
		];
		assert!(matches!(parse_watch_event(&registration), Ok(None)));
		let truncation = [Argument::from("truncated"), Argument::from(3_i64)];
		assert!(matches!(parse_watch_event(&truncation), Ok(None)));

		// A registration id is held to the generated form, and a tag the table
		// does not carry is refused rather than ignored.
		let forged = [
			Argument::from("registered"),
			Argument::from("ada"),
			Argument::from(1_i64),
			Argument::from("not-a-registration-id"),
		];
		assert!(
			parse_watch_event(&forged)
				.expect_err("a forged registration id")
				.contains("malformed registered watch")
		);
		let unknown = [Argument::from("renamed"), Argument::from("lobby")];
		assert!(
			parse_watch_event(&unknown)
				.expect_err("an unknown kind")
				.contains("unknown watch event")
		);
	}

	#[test]
	fn a_publication_row_is_read_by_the_generated_field_names() {
		let row = publication(Argument::Void, Argument::from("participant"));
		let room = parse_room(&row).expect("the declared record is admitted");
		assert_eq!(room.name, "lobby");
		assert_eq!(room.count, None); // a wire void is an unknown occupancy, not a zero
		assert_eq!(room.id, "id-1");
		assert_eq!(room.kind, "local");
		assert_eq!(room.origin, "");
		assert_eq!(room.proof, "local");
		assert_eq!(room.offers.as_deref(), Some("participant"));
		assert_eq!(row.len(), PUBLICATION_FIELDS.len());
		// Every name this reader asks for is one the table declares.
		for name in ["name", "count", "id", "kind", "origin", "proof", "offers"] {
			assert!(field(PUBLICATION_FIELDS, &row, name).is_some(), "{name} is declared");
		}
	}

	#[test]
	fn a_publication_row_is_held_to_the_declared_types_and_enumerations() {
		assert!(parse_room(&publication(Argument::from(2_i64), Argument::Void)).is_some());
		// A boolean is not a natural, a negative count is not an occupancy, a
		// membership the table does not offer is not one, and a short row is not
		// the record.
		assert!(parse_room(&publication(Argument::from(true), Argument::Void)).is_none());
		assert!(parse_room(&publication(Argument::from(-1_i64), Argument::Void)).is_none());
		assert!(parse_room(&publication(Argument::from(2_i64), Argument::from("steward"))).is_none());
		assert!(parse_room(&publication(Argument::from(2_i64), Argument::Void)[..6]).is_none());
	}

	#[test]
	fn a_room_page_is_held_to_the_generated_record() {
		let rooms = Argument::from(vec![Argument::from(publication(Argument::from(1_i64), Argument::Void))]);
		let last = parse_room_page(&Argument::from(vec![rooms.clone(), Argument::Void])).expect("a last page");
		assert_eq!((last.rooms.len(), last.next), (1, None));
		let more =
			parse_room_page(&Argument::from(vec![rooms.clone(), Argument::from("local:#garden")])).expect("a page");
		assert_eq!(more.next.as_deref(), Some("local:#garden"));
		// A bare row list is not a page, and a cursor is the directory's text.
		assert!(parse_room_page(&rooms).is_err());
		assert!(parse_room_page(&Argument::from(vec![rooms, Argument::from(256_i64)])).is_err());
	}

	#[test]
	fn a_watch_snapshot_is_held_to_the_generated_record() {
		let rooms = Argument::from(vec![Argument::from(publication(Argument::from(1_i64), Argument::Void))]);
		let row = Argument::from(vec![
			Argument::from("ada"),
			Argument::from("00000000-0000-4000-8000-000000000001"),
		]);
		let snapshot = Argument::from(vec![rooms.clone(), Argument::from(vec![row]), Argument::from(0_i64)]);
		let baseline = parse_watch_rooms(&snapshot).expect("the declared snapshot is admitted");
		assert_eq!(baseline.len(), 1);
		assert_eq!(baseline[0].count, Some(1));

		// A registration row is a name and an id in the generated form, and the
		// omission count is a natural.
		let forged = Argument::from(vec![Argument::from("ada"), Argument::from("not-a-registration-id")]);
		let bad_rows = Argument::from(vec![rooms.clone(), Argument::from(vec![forged]), Argument::from(0_i64)]);
		assert!(
			parse_watch_rooms(&bad_rows)
				.expect_err("a forged registration row")
				.contains("malformed registration rows")
		);
		let bad_count = Argument::from(vec![rooms, Argument::List(Vec::new()), Argument::from(-1_i64)]);
		assert!(
			parse_watch_rooms(&bad_count)
				.expect_err("a negative omission count")
				.contains("malformed watch snapshot")
		);
	}

	#[test]
	fn presence_reads_every_generated_tail_with_its_effect() {
		let roster = notify(
			ROOM_SENDER,
			"welcome",
			vec![Argument::from("roster"), Argument::from("ada"), Argument::from("bo")],
		);
		let read = read_presence(ROOM_SENDER, "welcome", &roster).expect("a roster tail");
		assert_eq!(read.kind, "roster");
		assert_eq!(read.names, ["ada".to_string(), "bo".to_string()]);
		assert_eq!(read.effect, Effect::Arrive);

		let gone = notify(
			ROOM_SENDER,
			"bo left",
			vec![Argument::from("leave"), Argument::from("bo")],
		);
		let read = read_presence(ROOM_SENDER, "bo left", &gone).expect("a leave tail");
		assert_eq!(
			(read.names.as_slice(), read.effect),
			(["bo".to_string()].as_slice(), Effect::Depart)
		);

		// A member who is still here: typing says so on an empty display text.
		let typing = notify(
			ROOM_SENDER,
			"",
			vec![Argument::from("typing"), Argument::from("ada"), Argument::from(true)],
		);
		let read = read_presence(ROOM_SENDER, "", &typing).expect("a typing tail");
		assert_eq!(
			(read.names.as_slice(), read.effect),
			(["ada".to_string()].as_slice(), Effect::Stay)
		);

		// An ordinary line carries no tail; a `line` tail says nothing about
		// membership; and a tail whose sender, text, or arguments are not what the
		// table declares reads as none, so the line still draws.
		let chat = notify("ada", "hi", vec![]);
		assert!(read_presence("ada", "hi", &chat).is_none());
		let numbered = notify("ada", "hi", vec![Argument::from("line"), Argument::from(7_i64)]);
		assert!(read_presence("ada", "hi", &numbered).is_none());
		let forged = notify("ada", "hi", vec![Argument::from("join"), Argument::from("bo")]);
		assert!(read_presence("ada", "hi", &forged).is_none());
		let unspecified = notify(ROOM_SENDER, "", vec![Argument::from("typing"), Argument::from("ada")]);
		assert!(read_presence(ROOM_SENDER, "", &unspecified).is_none());
		let talkative = notify(
			ROOM_SENDER,
			"still typing",
			vec![Argument::from("typing"), Argument::from("ada"), Argument::from(true)],
		);
		assert!(read_presence(ROOM_SENDER, "still typing", &talkative).is_none());
	}

	#[test]
	fn the_subscribe_answer_is_held_to_the_generated_record() {
		// The seat is a capability, so only a live session can answer with one;
		// what a test can hold is every way the answer fails to be that record.
		let unseated = Argument::from(vec![
			Argument::from("not-a-seat"),
			Argument::from("participant"),
			Argument::Void,
			Argument::Void,
		]);
		assert!(membership_seat(&unseated).is_none());
		let unoffered = Argument::from(vec![
			Argument::from("not-a-seat"),
			Argument::from("steward"),
			Argument::Void,
			Argument::Void,
		]);
		assert!(membership_seat(&unoffered).is_none());
		assert!(membership_seat(&Argument::from("not-a-list")).is_none());
		assert_eq!(
			SUBSCRIBE_ANSWER_FIELDS
				.iter()
				.map(|field| field.name)
				.collect::<Vec<_>>(),
			["seat", "kind", "topic", "files"],
		);
	}
}
