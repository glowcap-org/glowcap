//! Participation can enter an exact listing through directory access this
//! workspace already holds. Only the invoking use grant becomes a new field.
use super::*;
use rooms_glowcap::client::workspace::PublicRoomImport;

struct Join<'a> {
	room: PublicRoomImport,
	access: custody::FieldKey<custody::DirectoryAccess>,
	source: &'a Ref,
}

impl<'a> Join<'a> {
	fn read(input: Invocation<'a>) -> Result<Self> {
		let [Argument::String(selection), Argument::Reference(source)] = input.args else {
			return Err(refuse("joining takes a listed room and its initiating grant"));
		};
		if selection.len() > 16 * 1024 {
			return Err(refuse("oversized public room selection"));
		}
		let (room, access) = serde_json::from_str(selection).map_err(|_| refuse("invalid public room selection"))?;
		Ok(Self { room, access, source })
	}

	fn existing<R: custody::References, C>(&self, record: &workspace::Record<R, C>) -> Result<Option<String>> {
		if !record
			.intent
			.directories
			.as_slice()
			.iter()
			.any(|row| row.id == self.room.directory && row.access == self.access)
		{
			return Err(refuse("the selected directory access is no longer held"));
		}
		for row in record.intent.conversations.as_slice() {
			if let workspace::Conversation::Room(room) = row
				&& room.directory == self.room.directory
				&& room.publication.as_ref() == Some(&self.room.publication)
				&& room
					.public_entry
					.as_ref()
					.is_some_and(|entry| entry.access == self.access)
			{
				return Ok(Some(
					room.id.text().as_str().ok_or_else(|| refuse("invalid room id"))?.into(),
				));
			}
			if matches!(row,workspace::Conversation::Room(room) if room.directory==self.room.directory && room.name==self.room.name)
			{
				return Err(refuse("a same-name room is already held through another entrance"));
			}
			if row.id() == &self.room.id {
				return Err(refuse("the proposed conversation id is already in use"));
			}
		}
		Ok(None)
	}
}

pub(super) fn references(input: Invocation<'_>, record: &MetadataRecord) -> Result<Vec<ReferenceRequest>> {
	let join = Join::read(input)?;
	if join.existing(record)?.is_some() {
		return Ok(vec![]);
	}
	Ok(vec![ReferenceRequest::Save {
		reference: join.source.clone(),
		uri: None,
	}])
}

pub(super) fn invoke(call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
	let join = Join::read(input)?;
	if *join.source != call.source()? {
		return Err(refuse("the joining grant must be the invoking grant"));
	}
	let mut record = records::decode(input)?;
	if let Some(id) = join.existing(&record)? {
		return Ok(id.into());
	}
	let coordinate = custody::Coordinate::new(custody::Role::SessionAccess, join.room.source);
	record
		.custody
		.insert(records::restored(coordinate, Field::Held(join.source.clone())))
		.map_err(|_| refuse("duplicate or full custody"))?;
	let id = join
		.room
		.id
		.text()
		.as_str()
		.ok_or_else(|| refuse("invalid conversation identity"))?
		.to_owned();
	record
		.intent
		.conversations
		.try_push(workspace::Conversation::Room(Box::new(
			join.room.into_room(join.access),
		)))
		.map_err(|_| refuse("workspace conversations are full"))?;
	record.intent.validate(&record.custody).map_err(refuse_configuration)?;
	records::replace(call, input, &mut record)?;
	Ok(id.into())
}

type Membership = (
	custody::FieldKey<custody::RoomInbox>,
	custody::FieldKey<custody::RoomSeat>,
);
fn membership(input: Invocation<'_>) -> Result<Membership> {
	let [selected] = input.args else {
		return Err(refuse("room readiness requires an inbox and seat"));
	};
	let selected = text(selected)?;
	if selected.len() > 256 {
		return Err(refuse("invalid room readiness selection"));
	}
	serde_json::from_str(selected).map_err(|_| refuse("invalid room readiness selection"))
}
fn membership_source(record: &MetadataRecord, (inbox, seat): Membership) -> Option<records::Location> {
	let key = record
		.intent
		.conversations
		.as_slice()
		.iter()
		.find_map(|row| match row {
			workspace::Conversation::Room(room) if room.inbox == Some(inbox) && room.seat == Some(seat) => room.source,
			_ => None,
		})?;
	record
		.custody
		.get(custody::Coordinate::new(custody::Role::SessionAccess, key))
		.map(|held| records::location(&held))
}
pub(super) fn ready_references(input: Invocation<'_>, record: &MetadataRecord) -> Result<Vec<ReferenceRequest>> {
	let Some(source) = membership_source(record, membership(input)?) else {
		return Ok(vec![]);
	};
	Ok(vec![ReferenceRequest::RestorePage {
		page: source
			.page
			.checked_sub(1)
			.ok_or_else(|| refuse("invalid room source page"))?,
		field: source.field,
	}])
}
pub(super) fn ready<P: Tasks + Deadline + Clone + 'static>(
	owner: &std::rc::Rc<State<P>>,
	call: &mut Call<'_>,
	input: Invocation<'_>,
) -> Result<Argument> {
	let keys = membership(input)?;
	let source = membership_source(&records::metadata(input)?, keys);
	if input.verb == "room-membership-reader" {
		let Some(location) = source else {
			return Ok(Argument::Void);
		};
		let target = Field::Retained(location).resolve(call, input)?;
		let methods = [loam::ReadMethod {
			verb: "room-membership-ready",
			results: &[],
		}];
		return call
			.disclose_reads_copying(&target, &[loam::ReadInterface { methods: &methods }], 0)
			.map(Argument::Reference);
	}
	let Some(location) = source else {
		return Ok(false.into());
	};
	if Field::Retained(location).resolve(call, input)? != call.source()? {
		return Ok(false.into());
	}
	owner
		.memberships
		.room_ready(keys.0, keys.1)
		.map(Argument::Boolean)
		.map_err(|e| refuse(&e.to_string()))
}
