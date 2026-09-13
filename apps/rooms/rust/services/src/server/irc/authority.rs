//! Durable moderator authority for one exact IRC channel publication.
//! The operations writer saves changes before live authority advances.
use super::*;
use glowcap::Argument;
use rooms_application::{
	failure::FailureCode,
	room::authority::{GOVERNS, KICK, room_identity},
	server::{
		irc::{model::entropy_bytes, room::prefix_refusal},
		operations::faces::{StewardshipRow, Visibility},
	},
};

pub(in crate::server) fn named(state: &State, asked: &str) -> Option<Rc<Publication>> {
	let core = state.irc.core.borrow();
	let named = core.by_room_name(asked).map(|(key, _)| key);
	state
		.irc
		.publications
		.values()
		.find(|publication| {
			publication.active.get() && (publication.id == asked || named == Some(publication.key.as_str()))
		})
		.cloned()
}

pub(in crate::server) fn by_token(state: &State, token: &str) -> Option<Rc<Publication>> {
	state
		.irc
		.publications
		.values()
		.find(|publication| publication.active.get() && publication.steward.borrow().as_deref() == Some(token))
		.cloned()
}

pub(in crate::server) fn token(publication: &Publication) -> Option<String> {
	publication.steward.borrow().clone()
}

pub(in crate::server) fn row(
	state: &State,
	publication: &Publication,
	locator: &glowcap::Locator,
) -> Result<StewardshipRow, String> {
	let authority = publication.authority.borrow();
	let core = state.irc.core.borrow();
	let bridge = core.bridge(&publication.key).ok_or_else(retired)?;
	let steward = if authority.issued {
		publication
			.steward
			.borrow()
			.as_deref()
			.map(|token| {
				glowcap::format_sturdyref(locator, token.as_bytes(), glowcap::CaptpVersion::V1_0)
					.map_err(|e| e.to_string())
			})
			.transpose()?
	} else {
		None
	};
	Ok(StewardshipRow {
		name: publication.id.clone(),
		label: bridge.room.name().into(),
		visibility: Visibility::Listed,
		generation: authority.generation,
		issued: steward.is_some(),
		steward,
	})
}

/// Repeating issuance repairs a saved issuance whose host publication failed.
/// No answer claims that a capability exists until the host publishes it.
pub(super) fn publish(shared: &Shared, publication: &Rc<Publication>) -> Result<(), String> {
	let authority = publication.authority.borrow();
	if !authority.issued || publication.steward.borrow().is_some() {
		return Ok(());
	}
	let entropy = entropy_bytes(&authority.steward_entropy).ok_or("invalid IRC moderator entropy")?;
	let generation = authority.generation;
	drop(authority);
	let held = publication.clone();
	let state = shared.borrow();
	let shared = shared.clone();
	let token = state
		.host
		.publish_durable_with_entropy(entropy, move || Box::new(behavior(shared, held, generation)))
		.map_err(|e| format!("IRC moderator issuance is saved; publication failed: {e}"))?;
	*publication.steward.borrow_mut() = Some(token);
	Ok(())
}

fn behavior(
	shared: Shared,
	publication: Rc<Publication>,
	generation: u64,
) -> impl FnMut(&str, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		let mut state = shared.borrow_mut();
		let authority = publication.authority.borrow();
		if state.irc.stopping || !publication.active.get() || !authority.issued || authority.generation != generation {
			return Err(format!(
				"{}: this IRC moderator capability was retired",
				FailureCode::NotSteward.wire()
			));
		}
		drop(authority);
		match (verb, args) {
			(GOVERNS, []) => room_identity(publication.swiss.borrow().as_deref().ok_or_else(retired)?)
				.map(Argument::from)
				.map_err(|e| e.to_string()),
			(KICK, [Argument::String(nick)]) if !nick.is_empty() => {
				if prefix_refusal(nick).is_some() {
					return Err(
						"this moderator governs Rooms memberships, not identities bridged from elsewhere".into(),
					);
				}
				let connection = state
					.irc
					.core
					.borrow()
					.bridge(&publication.key)
					.and_then(|bridge| bridge.room.member_by_nick(nick))
					.ok_or_else(|| format!("{nick} is not a Rooms member of this bridge"))?;
				members::retire(
					&mut state,
					&publication,
					connection,
					Some("A moderator ended this membership."),
				);
				Ok(Argument::Void)
			}
			(GOVERNS, _) => Err("governs takes no arguments".into()),
			(KICK, _) => Err("kick takes one Rooms member name".into()),
			_ => Err(format!("IRC moderator has no method {verb}")),
		}
	}
}

/// Issuance and revocation share the lease's network gate, so a retirement
/// cannot publish authority after the channel has been removed.
pub(in crate::server) fn change(
	shared: &Shared,
	publication: Rc<Publication>,
	revoke: Option<String>,
	answer_row: bool,
) -> Result<Argument, String> {
	let state = shared.borrow();
	let caller = glowcap::current_session().map_err(|e| e.to_string())?;
	let locator = state.advertised_locator(caller.as_ref());
	let shared = shared.clone();
	state.operations.later(
		&state,
		if revoke.is_some() {
			"revokeSteward"
		} else {
			"giveSteward"
		},
		move |store| {
			Box::pin(async move {
				update(&shared, &store, &publication, revoke.as_deref()).await?;
				if !answer_row {
					return Ok(Argument::Void);
				}
				let row = row(&shared.borrow(), &publication, &locator)?;
				Ok(
					rooms_application::server::operations::operator::rows::wire_stewardship::<
						super::super::operations::operator::Wire,
					>(&row),
				)
			})
		},
	)
}

/// Shared persisted mutation for the direct verb and observed operator batches.
pub(super) async fn update(
	shared: &Shared,
	store: &super::super::operations::document::Store,
	publication: &Rc<Publication>,
	revoke: Option<&str>,
) -> Result<(), String> {
	let network = shared
		.borrow()
		.irc
		.core
		.borrow()
		.bridge(&publication.key)
		.ok_or_else(retired)?
		.network
		.clone();
	let gate = shared.borrow_mut().irc.gate(&network);

	let _held = gate.lock_owned().await;
	if !publication.active.get() {
		return Err(retired());
	}
	let entropy = if revoke.is_some() {
		Some(commands::draw()?)
	} else {
		None
	};
	store
		.change(
			|current| {
				let mut next = current.clone();
				if let Some(token) = revoke {
					if publication.steward.borrow().as_deref() != Some(token) {
						return Err(format!(
							"{}: this IRC moderator capability was retired",
							FailureCode::NotSteward.wire()
						));
					}
					next.revoke_irc_bridge_steward(
						&publication.id,
						&publication.authority.borrow().steward_entropy,
						|| entropy.expect("revocation entropy"),
					)
					.map_err(|e| e.to_string())?;
				} else {
					next.issue_irc_bridge_steward(&publication.id)
						.map_err(|e| e.to_string())?;
				}
				Ok(next)
			},
			|document| {
				*publication.authority.borrow_mut() = document
					.irc_bridge_authority(&publication.id)
					.expect("committed bridge authority")
					.clone();
				if let Some(token) = revoke {
					publication.steward.borrow_mut().take();
					let state = shared.borrow();
					if let Err(error) = state.host.remove_durable(token) {
						trouble(&state, "unpublishing a revoked IRC moderator", error.to_string());
					}
					let effects = state
						.irc
						.core
						.borrow()
						.bridge(&publication.key)
						.ok_or_else(retired)?
						.room
						.authority_changed("steward", token);
					apply(&state, &publication.key, effects)?;
				} else {
					shared.borrow().changed();
					publish(shared, publication)?;
				}
				Ok(())
			},
		)
		.await?
}
