//! `roomBridgeForm`: the declared IRC bridge form of a live room. It carries no
//! secrets, so any observing facet may read it the way any member asks the
//! room itself; submitting stays behind the command's own interact gate.
use crate::service::Platform;
use crate::service::error::Error;
use crate::service::facet::Facet;
use glowcap::Argument;
use rooms_application::session::verbs;

pub fn form<P: Platform>(facet: &Facet<P>, args: &[Argument]) -> Result<Argument, Error> {
	let conversation = match args {
		[Argument::String(id)] => id.clone(),
		_ => return Err(Error::invalid("roomBridgeForm takes a conversation id")),
	};
	let rooms = facet.0.rooms.clone();
	facet.answer(verbs::ROOM_BRIDGE_FORM, async move {
		let form = rooms.bridge_form(&conversation).await?;
		Ok(match form {
			Some(form) => form.encode().map_err(Error::invalid_by)?.into(),
			None => "".into(),
		})
	})
}
