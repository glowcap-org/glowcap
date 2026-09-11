use super::*;

pub(super) fn apply(state: &mut State, command: Command, arg: &DocumentText) -> Result<(), Error> {
	match command {
		Command::PublishPeeredRoom => {
			let intent: Peering = json(arg, MAX_JSON)?;
			if !authorized(&state.capabilities.operations, &intent) {
				return Err(Error::Conflict);
			}
			if let Some(prior) = state.peering.0.iter().find(|p| p.id == intent.id) {
				if prior.destination != intent.destination || prior.source != intent.source || prior.name != intent.name
				{
					return Err(Error::Conflict);
				}
			} else {
				push(&mut state.peering, intent)?;
			}
		}
		Command::RevokePeeredRoom => {
			let index = state
				.peering
				.0
				.iter()
				.position(|p| &p.id.0 == arg)
				.ok_or(Error::Missing)?;
			state.peering.0.remove(index);
		}
		Command::ReplaceOperationsCapabilities => {
			state.capabilities.operations = json(arg, MAX_JSON)?;
			state
				.peering
				.0
				.retain(|p| authorized(&state.capabilities.operations, p));
		}
		_ => unreachable!("peering command dispatch"),
	}
	Ok(())
}
fn authorized(operations: &List<Credential, 64>, intent: &Peering) -> bool {
	operations
		.0
		.iter()
		.any(|c| c.capability == Operation::Peering && c.scope == intent.destination)
}

pub(super) fn retire_directory(state: &mut State, id: &DocumentText) -> Result<(), Error> {
	if !state.directories.0.iter().any(|d| &d.id.0 == id) {
		return Err(Error::Missing);
	}
	let removed: alloc::collections::BTreeSet<_> = state
		.conversations
		.0
		.iter()
		.filter(|c| &c.directory().0 == id)
		.map(|c| c.id().0.clone())
		.collect();
	let selected_removed = state.active.as_ref().is_some_and(|active| removed.contains(&active.0));
	state.directories.0.retain(|d| &d.id.0 != id);
	state.invitations.0.retain(|i| &i.directory.0 != id);
	state.capabilities.operations.0.retain(|c| &c.scope.0 != id);
	state
		.peering
		.0
		.retain(|p| &p.destination.0 != id && !removed.contains(&p.source.0));
	state.conversations.0.retain(|c| &c.directory().0 != id);
	if selected_removed {
		select_remaining(state, None);
	}
	Ok(())
}

pub(super) fn replace_bundle(state: &mut State, raw: &DocumentText, advertised: &DocumentText) -> Result<(), Error> {
	use crate::server::operations::bundle::Draft;
	let draft = Draft::parse(raw.as_str().ok_or(Error::Arguments)?, false).map_err(|_| Error::Arguments)?;
	if !draft.is_empty() && !draft.ready() {
		return Err(Error::Arguments);
	}
	let home = state
		.directories
		.0
		.iter()
		.find(|directory| directory.home)
		.ok_or(Error::Missing)?
		.id
		.0
		.clone();
	let viz = state
		.capabilities
		.operations
		.0
		.iter()
		.find(|credential| credential.capability == Operation::Viz)
		.map(|credential| credential.scope.0.clone())
		.unwrap_or_else(|| {
			if state.viz_override.0.as_str() == Some("") {
				advertised.clone()
			} else {
				state.viz_override.0.clone()
			}
		});
	let mut credentials: alloc::vec::Vec<_> = state
		.capabilities
		.operations
		.0
		.iter()
		.filter(|credential| credential.capability != Operation::Viz && credential.scope.0 != home)
		.cloned()
		.collect();
	for (capability, swiss) in draft.entries() {
		let capability: Operation = serde::Deserialize::deserialize(serde::de::value::StrDeserializer::<
			serde::de::value::Error,
		>::new(capability))
		.map_err(|_| Error::Arguments)?;
		let scope = if capability == Operation::Viz { &viz } else { &home };
		credentials.push(Credential {
			capability,
			scope: Text::new(scope.clone()).ok_or(Error::Arguments)?,
			swiss: Bearer::new(swiss.into()).ok_or(Error::Size)?,
		});
	}
	state.capabilities.operations = List::new(credentials).ok_or(Error::Size)?;
	state
		.peering
		.0
		.retain(|intent| authorized(&state.capabilities.operations, intent));
	Ok(())
}
