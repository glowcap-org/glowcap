use super::{fields::Presence, model::*, Refusal, Routes};
use crate::text::{js_whitespace, DocumentText};
use alloc::collections::{BTreeMap, BTreeSet};

pub(super) fn nick(text: &DocumentText, empty: bool) -> bool {
	let units = text.utf16().take(33).count();
	if units == 0 {
		return empty;
	}
	units <= 32
		&& !text.as_str().is_some_and(crate::room::inbox::addresses_everyone)
		&& !text
			.utf16()
			.any(|v| matches!(v, 0..=31 | 127..=159 | 0x200e..=0x200f | 0x2028..=0x202e | 0x2066..=0x2069))
}
pub(super) fn route(text: &DocumentText, routes: &impl Routes, link: bool) -> Result<DocumentText, Refusal> {
	let scalar = text.utf8_lossy();
	let text = scalar.as_ref();
	let authority = if link {
		if !text.starts_with("ocapn://") || !text.contains("/s/") {
			return Err(Refusal::Route);
		}
		routes.sturdyref_authority(text)
	} else {
		routes.locator_authority(text)
	};
	Ok(authority.ok_or(Refusal::Route)?.into())
}
fn websocket(text: &DocumentText, canonical: bool) -> bool {
	let scalar = text.utf8_lossy();
	let s = scalar.as_ref();
	let Ok(url) = crate::session::visualizer::parse_endpoint(s) else {
		return false;
	};
	if canonical {
		text.as_str() == Some(url.as_str())
	} else {
		url.fragment().is_none_or(str::is_empty)
	}
}

pub(super) fn state(s: &mut State, routes: &impl Routes) -> Result<(), Refusal> {
	if s.version != 1 {
		return Err(Refusal::Schema);
	}
	if s.viz_override.0.utf16().next().is_some() && !websocket(&s.viz_override.0, false) {
		return Err(Refusal::Visualizer);
	}
	let mut directories = BTreeMap::new();
	let mut homes = 0;
	for d in &s.directories.0 {
		if !nick(&d.nick.0, true)
			|| route(&d.locator.0, routes, false)? != d.id.0
			|| directories.insert(&d.id.0, d).is_some()
		{
			return Err(Refusal::Relation);
		}
		homes += usize::from(d.home);
	}
	if homes > 1 {
		return Err(Refusal::Relation);
	}
	let mut conversations = BTreeMap::new();
	let mut public = BTreeSet::new();
	let mut held = BTreeSet::new();
	let mut direct = BTreeSet::new();
	for c in &s.conversations.0 {
		let d = directories.get(&c.directory().0).ok_or(Refusal::Relation)?;
		if conversations.insert(&c.id().0, c).is_some() {
			return Err(Refusal::Relation);
		}
		match c {
			Conversation::Direct(c) => {
				if !nick(&c.peer.0, false)
					|| !crate::session::fields::registration_id(&c.peer_registration_id.0)
					|| c.peer.0.lowercase() == d.nick.0.lowercase()
					|| (!c.closed && !direct.insert((&c.directory.0, &c.peer_registration_id.0)))
				{
					return Err(Refusal::Relation);
				}
			}
			Conversation::Room(c) => {
				if matches!(
					&c.bridge_intent,
					Presence::Value(bridge) if !bridge.secrets_given && bridge.credential_revision.is_some()
				) {
					return Err(Refusal::Relation);
				}
				for bearer in [&c.link, &c.manager, &c.steward].into_iter().flatten() {
					if route(&bearer.0, routes, true)? != c.directory.0 {
						return Err(Refusal::Relation);
					}
				}
				if c.steward.is_some() && c.link.is_none() {
					return Err(Refusal::Relation);
				}
				if (!c.held && !public.insert((&c.directory.0, c.name.0.lowercase())))
					|| (c.held && c.link.as_ref().is_some_and(|l| !held.insert(&l.0)))
				{
					return Err(Refusal::Relation);
				}
			}
		}
	}
	if s.active.as_ref().is_some_and(|id| !conversations.contains_key(&id.0)) {
		return Err(Refusal::Relation);
	}
	let mut invitations = BTreeSet::new();
	for i in &s.invitations.0 {
		if !nick(&i.nick.0, true) || !invitations.insert(&i.id.0) || route(&i.link.0, routes, true)? != i.directory.0 {
			return Err(Refusal::Relation);
		}
	}
	let mut credentials = BTreeSet::new();
	let mut visualizers = 0;
	for c in &mut s.capabilities.operations.0 {
		c.swiss.0.trim_js();
		let mut previous = [0u16; 2];
		let mut empty = true;
		for unit in c.swiss.0.utf16() {
			if (previous == [58, 47] && unit == 47) || char::from_u32(u32::from(unit)).is_some_and(js_whitespace) {
				return Err(Refusal::Schema);
			}
			previous = [previous[1], unit];
			empty = false;
		}
		if empty {
			return Err(Refusal::Schema);
		}

		if !credentials.insert((c.capability, &c.scope.0)) {
			return Err(Refusal::Relation);
		}
		if c.capability == Operation::Viz {
			visualizers += 1;
			if visualizers > 1 || !websocket(&c.scope.0, true) {
				return Err(Refusal::Visualizer);
			}
		} else if !directories.contains_key(&c.scope.0) {
			return Err(Refusal::Relation);
		}
	}
	if let Some(link) = s.capabilities.archive_peer.as_ref() {
		route(&link.0, routes, true)?;
	}
	let mut peering_ids = BTreeSet::new();
	let mut peering_names = BTreeSet::new();
	for p in &s.peering.0 {
		let Some(Conversation::Room(source)) = conversations.get(&p.source.0) else {
			return Err(Refusal::Relation);
		};
		if !peering_ids.insert(&p.id.0)
			|| !directories.contains_key(&p.destination.0)
			|| source.directory.0 == p.destination.0
			|| !credentials.contains(&(Operation::Peering, &p.destination.0))
			|| !peering_names.insert((&p.destination.0, p.name.0.lowercase()))
		{
			return Err(Refusal::Relation);
		}
	}
	Ok(())
}
