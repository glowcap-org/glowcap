//! `roomBridgeForm`: the declared IRC bridge form of a live room. It carries no
//! secrets, so any observing facet may read it the way any member asks the
//! room itself; submitting stays behind the command's own interact gate.
use crate::session_service::error::Error;
use crate::session_service::facet::Facet;
use crate::session_service::Platform;
use glowcap::Argument;
use rooms_application::session::verbs;

pub fn form<P: Platform>(facet: &Facet<P>, args: &[Argument]) -> Result<Argument, Error> {
	let conversation = match args {
		[Argument::String(id)] => id.clone(),
		_ => return Err(Error::refused("roomBridgeForm takes a conversation id")),
	};
	let rooms = facet.0.rooms.clone();
	facet.answer(verbs::ROOM_BRIDGE_FORM, async move {
		let form = rooms.bridge_form(&conversation).await.map_err(Error::runtime)?;
		Ok(match form {
			Some(form) => form.encode().map_err(|e| Error::runtime(e.to_string()))?.into(),
			None => "".into(),
		})
	})
}
