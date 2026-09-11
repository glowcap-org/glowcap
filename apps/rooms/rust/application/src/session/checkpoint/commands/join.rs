use super::*;
use alloc::boxed::Box;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Intent {
	pub(super) locator: Text<16384, true>,
	pub(super) nick: Field,
	pub(super) conversation: Room,
}

pub(super) fn apply(state: &mut State, intent: Intent, routes: &impl Routes, facts: &impl Facts) -> Result<(), Error> {
	if !validate::nick(&intent.nick.0, false) {
		return Err(Error::NamedDirectory);
	}
	let authority = validate::route(&intent.locator.0, routes, false)?;
	let mut room = intent.conversation;
	if authority != room.directory.0 {
		return Err(Error::Conflict);
	}
	for bearer in [&room.link, &room.manager, &room.steward].into_iter().flatten() {
		validate::route(&bearer.0, routes, true)?;
	}
	let prior_directory = state.directories.0.iter().position(|d| d.id.0 == authority);
	let directory = if let Some(index) = prior_directory {
		let mut directory = state.directories.0[index].clone();
		directory.locator = Text(intent.locator.0);
		directory.nick = intent.nick;
		directory
	} else {
		Directory {
			id: Text(authority.clone()),
			locator: Text(intent.locator.0),
			home: state.directories.0.is_empty(),
			reached: None,
			nick: intent.nick,
			standing: Nullable::Null,
		}
	};
	let recovering = state.conversations.0.iter().position(
		|c| matches!(c, Conversation::Room(r) if r.id == room.id && matches!(r.reconnect, Some(Reconnect::Manual))),
	);
	let prior_publication = recovering.and_then(|i| match &state.conversations.0[i] {
		Conversation::Room(r) => r.publication_id.as_ref(),
		_ => None,
	});
	let publication = if room.held {
		None
	} else {
		facts.room_publication(&authority, &room.name.0)
	};
	if prior_publication.is_some() && publication.is_none() {
		return Err(Error::Publication);
	}
	if prior_publication.is_none()
		&& publication.is_some()
		&& room.publication_id.as_ref().is_some_and(|p| Some(&p.0) != publication)
	{
		return Err(Error::Publication);
	}
	if prior_publication.is_some() || room.publication_id.is_none() {
		if let Some(value) = publication {
			room.publication_id = Some(text(value)?);
		}
	}
	if let Some(i) = recovering {
		let Conversation::Room(prior) = &state.conversations.0[i] else {
			unreachable!()
		};
		if prior.directory != room.directory || prior.name != room.name || prior.held != room.held {
			return Err(Error::Conflict);
		}
		if prior.held {
			let link = room.link.as_ref().ok_or(Error::Conflict)?;
			if validate::route(&link.0, routes, true)? != authority {
				return Err(Error::Conflict);
			}
		}
	}
	let existing = recovering.or_else(|| {
		state.conversations.0.iter().position(|c| {
			let Conversation::Room(prior) = c else {
				return false;
			};
			if prior.directory.0 != authority {
				return false;
			}
			if !prior.held && !room.held {
				return prior.name.0.lowercase() == room.name.0.lowercase();
			}
			prior.held && room.held && prior.link.is_some() && prior.link == room.link
		})
	});
	if state.conversations.0.iter().any(|c| c.id() == &room.id)
		&& existing.is_none_or(|i| state.conversations.0[i].id() != &room.id)
	{
		return Err(Error::Conflict);
	}
	let chosen = if let Some(i) = existing {
		let Conversation::Room(prior) = &mut state.conversations.0[i] else {
			unreachable!()
		};
		if recovering.is_some() {
			if prior.held {
				prior.link = room.link;
			} else {
				prior.publication_id = room.publication_id;
			}
			prior.reconnect = Some(Reconnect::Requested);
		}
		&**prior
	} else {
		push(&mut state.conversations, Conversation::Room(Box::new(room)))?;
		let Some(Conversation::Room(room)) = state.conversations.0.last() else {
			unreachable!()
		};
		room.as_ref()
	};
	state.active = Nullable::Value(Text(chosen.id.0.clone()));
	if !chosen.held {
		state.join = Join {
			room: Text(chosen.name.0.clone()),
			nick: directory.nick.clone(),
			locator: Text(if directory.home {
				"".into()
			} else {
				directory.locator.0.clone()
			}),
		};
	}
	if let Some(i) = prior_directory {
		state.directories.0[i] = directory;
	} else {
		push(&mut state.directories, directory)?;
	}
	Ok(())
}
