//! `watch`: attach one observer for the caller's session, retired when that
//! session closes or the authority it came through goes away.
use crate::session_service::error::Error;
use crate::session_service::facet::Facet;
use crate::session_service::facet::Rights;
use crate::session_service::views::Grantor;
use crate::session_service::Platform;
use glowcap::{current_session, Argument};
use std::rc::Rc;

pub fn watch<P: Platform>(
	facet: &Facet<P>,
	rights: &Rights,
	grantor: &Grantor,
	args: &[Argument],
) -> Result<Argument, Error> {
	let observer = match args {
		[Argument::Reference(observer)] => observer.clone(),
		_ => return Err(Error::refused("session watch takes one observer")),
	};
	let session =
		current_session()?.ok_or_else(|| Error::refused("a Rooms session facet is reachable only over a session"))?;
	let closing = session.borrowed();
	let id = facet
		.views()
		.attach(session, observer, grantor.clone(), rights.clone())?;
	let weak = Rc::downgrade(&facet.0);
	let watch = tokio::task::spawn_local(async move {
		// tolerant: the session's terminal result is its owner's to act on;
		// this task only needs to learn that it ended.
		let _ = closing.closed().await;
		if let Some(inner) = weak.upgrade() {
			Facet(inner).views().remove(id);
		}
	});
	facet.views().watch_close(id, watch);
	facet.snapshot(rights)
}
