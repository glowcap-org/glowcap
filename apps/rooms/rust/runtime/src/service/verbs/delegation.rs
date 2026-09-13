//! `facet`: mint a narrower facet on the caller's session, paired with a
//! revoker. Revoking retires the facet and every view it admitted.
use crate::service::Platform;
use crate::service::authority::Authority;
use crate::service::error::Error;
use crate::service::facet::Facet;
use crate::service::facet::Rights;
use crate::service::views::Grantor;
use glowcap::{Argument, current_session};
use rooms_application::{grants::Access, session::verbs, text::DocumentText};
use std::{cell::Cell, rc::Rc};

pub fn mint<P: Platform>(facet: &Facet<P>, rights: &Rights, args: &[Argument]) -> Result<Argument, Error> {
	if !rights.is_admin() {
		return Err(Error::refused("this Rooms session facet cannot delegate"));
	}
	let access = match args {
		[Argument::String(rights)] => match rights.as_str() {
			"observe" => Access::Observe,
			"interact" => Access::Interact,
			"admin" => Access::Admin,
			_ => return Err(Error::invalid(SHAPE)),
		},
		_ => return Err(Error::invalid(SHAPE)),
	};
	let session =
		current_session()?.ok_or_else(|| Error::invalid("a Rooms session facet is reachable only over a session"))?;
	let grantor = Grantor::Delegate(facet.next_delegate()?);
	let granted = Rights {
		access,
		history: true,
		note: DocumentText::from(""),
	};
	let live = Rc::new(Cell::new(true));
	let authority = Authority::Delegate {
		rights: granted,
		live: live.clone(),
	};
	let delegate = session.spawn({
		let facet = facet.clone();
		let live = live.clone();
		let grantor = grantor.clone();
		move |verb, args| {
			if !live.get() {
				return Err(Error::refused("this Rooms session facet was revoked").into_refusal());
			}
			facet.invoke(&authority, &grantor, verb, args)
		}
	})?;
	let revoker = session.spawn({
		let facet = facet.clone();
		move |verb, args| {
			if verb != verbs::REVOKE || !args.is_empty() {
				return Err(
					Error::invalid("Rooms session facet revoker takes revoke with no arguments").into_refusal(),
				);
			}
			live.set(false);
			facet.views().retire_grantor(&grantor);
			Ok(Argument::Void)
		}
	})?;
	Ok(Argument::List(vec![delegate.into(), revoker.into()]))
}

const SHAPE: &str = "facet takes observe, interact, or admin";
