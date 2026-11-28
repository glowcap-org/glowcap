//! Incoming direct intent is admitted by the original directory callback.
//! Pending receivers need no invented upstream route or nickname-based recovery.
//! A fresh opening lands where [`workspace::receive_direct`] says, in the
//! open row the opening side's plan names or a new one, and the custody the
//! open row drops is released here.
use super::*;
use rooms_application::fields::{List, Text};

fn admission(input: Invocation<'_>) -> Result<Invocation<'_>> {
	if input.args.len() < 2 {
		return Err(refuse("direct admission requires its original callback"));
	}
	Ok(Invocation {
		verb: "check-inbox",
		args: &input.args[..2],
		..input
	})
}
pub(super) fn references(input: Invocation<'_>, record: &MetadataRecord) -> Result<Vec<ReferenceRequest>> {
	let checked = admission(input)?;
	let mut references = inbox::references(checked, record)?;
	if input.verb == "adopt-direct-route" {
		let (selected, _, reference) = route(input)?;
		let workspace::InboxSelection::Direct { id, .. } = selected else {
			unreachable!()
		};
		let current = record.intent.conversations.as_slice().iter().find_map(|row| match row {
			workspace::Conversation::Direct(row) if row.id == id => row.access,
			_ => None,
		});
		if let Some(existing) = current.and_then(|key| {
			record.custody.get(custody::Coordinate {
				role: custody::Role::DirectAccess,
				key: key.retag(),
			})
		}) {
			let location = records::location(&existing);
			references.push(ReferenceRequest::RestorePage {
				page: location
					.page
					.checked_sub(1)
					.ok_or_else(|| refuse("invalid route page"))?,
				field: location.field,
			});
		}
		references.push(ReferenceRequest::SaveLive(reference.clone()));
	}
	Ok(references)
}
fn route(input: Invocation<'_>) -> Result<(workspace::InboxSelection, custody::Coordinate, &Ref)> {
	let [_, _, Argument::Reference(reference), ordinal] = input.args else {
		return Err(refuse(
			"direct route requires its original callback, actual capability and ordinal",
		));
	};
	let selected = inbox::selection(admission(input)?)?;
	let workspace::InboxSelection::Direct { inbox, .. } = &selected else {
		return Err(refuse("reciprocal route requires a direct callback"));
	};
	let ordinal = ordinal
		.as_i64()
		.and_then(|value| u64::try_from(value).ok())
		.and_then(core::num::NonZeroU64::new)
		.ok_or_else(|| refuse("positive direct route ordinal required"))?;
	let coordinate = custody::Coordinate {
		role: custody::Role::DirectAccess,
		key: workspace::reciprocal_key(*inbox, ordinal).retag(),
	};
	Ok((selected, coordinate, reference))
}
pub(super) fn invoke(call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
	inbox::invoke(call, admission(input)?)?;
	let mut record = records::decode(input)?;
	if input.verb == "adopt-direct-route" {
		let (selected, coordinate, reference) = route(input)?;
		let workspace::InboxSelection::Direct { id, .. } = selected else {
			unreachable!()
		};
		let row = record
			.intent
			.conversations
			.as_mut_slice()
			.iter_mut()
			.find_map(|row| match row {
				workspace::Conversation::Direct(row) if row.id == id => Some(row),
				_ => None,
			})
			.ok_or_else(|| refuse("direct conversation retired"))?;
		if let Some(current) = row.access {
			let previous = custody::Coordinate {
				role: coordinate.role,
				key: current.retag(),
			};
			let held = record
				.custody
				.get(previous)
				.ok_or_else(|| refuse("direct route custody is absent"))?;
			// The exact callback was checked above. A late replay from this same
			// callback cannot roll back a newer committed handoff.
			if current.slot() == coordinate.key.slot() && current.generation() > coordinate.key.generation() {
				return Ok(Argument::Void);
			}
			let equal = records::reference(&held).resolve(call, input)? == *reference;
			if previous == coordinate || row.introduction.is_none() {
				return if equal {
					Ok(Argument::Void)
				} else {
					Err(refuse("direct route ordinal or initiating authority conflicts"))
				};
			}
			// A newer event advances the watermark even for unchanged authority.
			// Otherwise an older distinct route could arrive after this event.
			record
				.custody
				.remove(previous)
				.ok_or_else(|| refuse("selected direct route is not retained"))?;
		}
		record
			.custody
			.insert(records::restored(coordinate, records::Field::Held(reference.clone())))
			.map_err(|_| refuse("reciprocal route custody is full or conflicts"))?;
		row.access = Some(coordinate.key.retag());
		records::replace(call, input, &mut record)?;
		return Ok(Argument::Void);
	}
	let [_, _, id, peer, registration, opening] = input.args else {
		return Err(refuse("direct introduction requires identity, peer and registration"));
	};
	let id = Text::new(text(id)?.into()).ok_or_else(|| refuse("invalid direct identity"))?;
	let peer = text(peer)?;
	if !rooms_application::room::inbox::valid_nick(peer) {
		return Err(refuse("invalid direct peer"));
	}
	let registration = text(registration)?;
	rooms_application::directory::registration::Id::parse(registration)
		.map_err(|_| refuse("invalid peer registration"))?;
	let workspace::InboxSelection::Directory {
		id: directory,
		access,
		source,
		inbox: callback,
		..
	} = inbox::selection(admission(input)?)?
	else {
		return Err(refuse("incoming introduction requires a directory callback"));
	};
	let name = record
		.intent
		.directories
		.as_slice()
		.iter()
		.find(|row| row.id == directory)
		.and_then(|row| row.name)
		.ok_or_else(|| refuse("directory registration has retired"))?;
	let witness = workspace::Introduction {
		access,
		name,
		callback,
		registration: Text::new(registration.into()).ok_or_else(|| refuse("invalid registration"))?,
		opening: Text::new(text(opening)?.into()).ok_or_else(|| refuse("invalid opening identity"))?,
	};
	for row in record.intent.conversations.as_slice() {
		if let workspace::Conversation::Direct(row) = row {
			if row.directory == directory
				&& row.peer.text().as_str() == Some(peer)
				&& row.introduction.as_ref() == Some(&witness)
			{
				if row.closed {
					return Err(refuse("this exact direct conversation was closed"));
				}
				return Ok(row
					.id
					.text()
					.as_str()
					.ok_or_else(|| refuse("invalid direct identity"))?
					.into());
			}
			// A row keeps the openings it took, so a replay of one a later
			// opening replaced is refused, never landed over that one again.
			if row.directory == directory
				&& row.openings.as_slice().contains(&witness.opening)
				&& row
					.introduction
					.as_ref()
					.is_some_and(|held| held.registration == witness.registration)
			{
				return Err(refuse("this direct opening already landed"));
			}
			if row.id == id {
				return Err(refuse("direct identity already names another conversation"));
			}
		}
	}
	// A fresh opening lands in the open row the shared plan names, so one
	// registration holds one open row on this side too. That row keeps its id
	// and adds this opening to the ones it took, which refuse their replays.
	// With none open, it is a new row, which the view follows only when the
	// selected closed row names these exact registrations, so a reused nickname
	// cannot move the view. A closed row keeps its witness for replay refusal.
	let follows_selected = record.intent.conversations.as_slice().iter().any(|row| {
		matches!(row, workspace::Conversation::Direct(row) if row.closed
			&& record.intent.active.as_ref() == Some(&row.id)
			&& row.directory == directory && row.peer.text().as_str() == Some(peer)
			&& row.introduction.as_ref().is_some_and(|previous|
				previous.access == witness.access && previous.name == witness.name
				&& previous.callback == witness.callback && previous.registration == witness.registration))
	});
	let row = workspace::Direct {
		kind: workspace::DirectKind::Direct,
		id: id.clone(),
		directory,
		peer: Text::new(peer.into()).ok_or_else(|| refuse("invalid peer"))?,
		source: Some(source),
		access: None,
		openings: workspace::Openings::new(vec![witness.opening.clone()])
			.ok_or_else(|| refuse("invalid direct opening"))?,
		introduction: Some(witness),
		inbox: None,
		lines: List::default(),
		closed: false,
		draft: Text::new("".into()).ok_or_else(|| refuse("invalid empty draft"))?,
	};
	let (landed, released) = workspace::receive_direct(&mut record.intent, row).map_err(|refusal| match refusal {
		workspace::DirectRefusal::Full => refuse("direct conversation capacity is full"),
		_ => refuse("invalid direct introduction"),
	})?;
	if follows_selected && landed == id {
		record.intent.active = Some(id.clone());
	}
	for coordinate in released {
		record
			.custody
			.remove(coordinate)
			.ok_or_else(|| refuse("released direct custody is absent"))?;
	}
	records::replace(call, input, &mut record)?;
	Ok(landed
		.text()
		.as_str()
		.ok_or_else(|| refuse("invalid direct identity"))?
		.into())
}
