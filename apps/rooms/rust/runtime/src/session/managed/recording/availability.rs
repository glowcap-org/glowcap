//! One selected archive's transport lifetime, observed independently of writes.
use glowcap::Session;
use rooms_application::content::session::custody::{ArchiveAccess, FieldKey};
use std::cell::RefCell;

/// The recording supervisor shares one fixed cell with its private content
/// callback. It retains only the canonical field key and a borrowed exporter
/// Session shell, never archive authority or a URI. Selection replacement
/// releases that observation; pending recordings keep their own exact writer.
/// The existing retention task waits on this session alongside its shared wake
/// feed, so monitoring adds no polling loop, task, or authority inventory.
#[derive(Default)]
pub(super) struct Availability(RefCell<Option<Selection>>);
struct Selection {
	key: FieldKey<ArchiveAccess>,
	session: Option<Session>,
	reported: bool,
}
impl Availability {
	pub fn observe(&self, key: Option<FieldKey<ArchiveAccess>>, session: Option<Session>) {
		let mut selected = self.0.borrow_mut();
		let Some(key) = key else {
			*selected = None;
			return;
		};
		if let Some(previous) = selected.as_ref()
			&& previous.key == key
			&& match (&previous.session, &session) {
				(Some(previous), Some(session)) => previous.same_connection(session),
				(None, None) => true,
				_ => false,
			} {
			return;
		}
		*selected = Some(Selection {
			key,
			session,
			reported: false,
		});
	}
	pub async fn ended(&self) -> FieldKey<ArchiveAccess> {
		let observation = self.0.borrow().as_ref().and_then(|selected| {
			(!selected.reported)
				.then(|| {
					selected
						.session
						.as_ref()
						.map(|session| (selected.key, session.borrowed()))
				})
				.flatten()
		});
		let Some((key, session)) = observation else {
			return std::future::pending().await;
		};
		let _terminal = session.ended().await;
		key
	}
	pub fn reported(&self, key: FieldKey<ArchiveAccess>) {
		if let Some(selected) = self.0.borrow_mut().as_mut()
			&& selected.key == key
		{
			selected.reported = true;
		}
	}
}

#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests;
