//! A live reference lookup chooses an existing membership or a room label.
//! Durable application rechecks the exact retained authority before selection.
use super::*;
#[cfg(test)]
mod tests;
pub(super) type Intent = join::Intent;

impl Intent {
	pub(super) fn retained_bytes(&self) -> usize {
		use super::super::super::footprint::HeapBytes;
		self.conversation.heap_bytes() + self.locator.heap_bytes() + self.nick.heap_bytes()
	}
}

pub(super) fn prepare(current: &Checkpoint, intent: Intent, routes: &impl Routes) -> Result<Plan, Error> {
	validate_intent(&intent, routes)?;
	if let Some(directory) = current
		.0
		.directories
		.0
		.iter()
		.find(|d| d.id == intent.conversation.directory)
		&& (directory.locator.0 != intent.locator.0 || directory.nick != intent.nick)
	{
		return Err(Error::Conflict);
	}
	let mut candidate = current.0.clone();
	join::apply(&mut candidate, intent.clone(), routes, &())?;
	validate::state(&mut candidate, routes)?;
	Ok(Plan {
		kind: Kind::RoomEntry,
		intent: super::Intent::Entry(intent),
	})
}

pub(super) fn validate_intent(intent: &Intent, routes: &impl Routes) -> Result<(), Error> {
	let link = intent.conversation.link.as_ref().ok_or(Error::Arguments)?;
	if !intent.conversation.held
		|| validate::route(&link.0, routes, true)? != intent.conversation.directory.0
		|| validate::route(&intent.locator.0, routes, false)? != intent.conversation.directory.0
		|| !validate::nick(&intent.nick.0, false)
	{
		return Err(Error::Conflict);
	}
	room_schema(&intent.conversation, routes)
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Existing {
	id: Id,
	directory: Id,
	link: Option<Bearer>,
	publication_id: Option<Field>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Returned {
	existing: Option<Existing>,
	name: Text<32, true>,
}

pub(super) fn returned(current: &Checkpoint, existing: Option<&str>, name: &str) -> Result<String, Error> {
	let existing = existing
		.map(|id| {
			let room = named_room(&current.0, &DocumentText::from(id))?;
			Ok::<_, Error>(Existing {
				id: room.id.clone(),
				directory: room.directory.clone(),
				link: room.link.clone(),
				publication_id: room.publication_id.clone(),
			})
		})
		.transpose()?;
	serde_json::to_string(&Returned {
		existing,
		name: text(&DocumentText::from(name))?,
	})
	.map_err(|_| Error::Json)
}

pub(super) fn apply(
	current: &Checkpoint,
	intent: &Intent,
	raw: &DocumentText,
	routes: &impl Routes,
) -> Result<Checkpoint, Error> {
	prepare(current, intent.clone(), routes)?;
	let returned: Returned = json(raw, MAX_JSON)?;
	let mut next = current.0.clone();
	if let Some(existing) = returned.existing {
		let room = named_room(&next, &existing.id.0)?;
		if room.directory != intent.conversation.directory
			|| room.directory != existing.directory
			|| room.link != existing.link
			|| room.publication_id != existing.publication_id
		{
			return Err(Error::Conflict);
		}
		next.active = Nullable::Value(text(&existing.id.0)?);
	} else {
		let mut intent = intent.clone();
		intent.conversation.name = returned.name;
		join::apply(&mut next, intent, routes, &())?;
	}
	validate::state(&mut next, routes)?;
	Ok(Checkpoint(next))
}
