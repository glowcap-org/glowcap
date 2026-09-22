use super::{failure::Failure, worker};
use rooms_runtime::{
	rooms::ConversationEvent,
	service::{Local, LocalObserver as Observer},
};
use serde_json::json;
use std::cell::RefCell;
pub(super) type Application = Local<rooms_platform::HostPlatform>;
pub(super) struct Feed {
	pub app: Application,
	pub inbox: worker::Worker,
	pub failure: RefCell<Option<Failure>>,
}
impl Observer for Feed {
	fn changed(&self) -> Result<(), rooms_runtime::Error> {
		Ok(())
	}
	fn event(&self, event: &ConversationEvent) -> Result<(), rooms_runtime::Error> {
		let snapshot = self.app.snapshot().inspect_err(|error| {
			*self.failure.borrow_mut() = Some(Failure::from(error.clone()));
		})?;
		let room = snapshot
			.checkpoint
			.rooms()
			.find(|r| r.id.text().as_str() == Some(&event.conversation_id));
		let direct = snapshot
			.checkpoint
			.directs()
			.find(|d| d.id.text().as_str() == Some(&event.conversation_id));
		let files: Vec<_> = event
			.files
			.iter()
			.map(|f| {
				let d = f.description();
				json!({"name": d.name(), "mime": d.mime(), "size": d.size()})
			})
			.collect();
		let row = json!({"conversation": event.conversation_id, "author": event.from,
			"channel": if direct.is_some() { "dm" } else if room.is_some() { "room" } else { "unknown" },
			"room": room.and_then(|r| r.name.text().as_str()),
			"peer": direct.and_then(|d| d.peer.text().as_str()),
			"text": event.text, "at": event.at, "line": event.line_id,
			"change": event.change.map(|c| c.event_change()), "system": event.system,
			"editable": event.editable, "presence": event.presence, "facts": event.facts,
			"files": files});
		if let Err(error) = self.inbox.event(row) {
			*self.failure.borrow_mut() = Some(error.clone());

			return Err(rooms_runtime::Error::storage(error));
		}
		Ok(())
	}
	fn history_changed(&self, _: &rooms_application::archive::change::Change) -> Result<(), rooms_runtime::Error> {
		self.changed()
	}
	fn operations_changed(&self, _: &str) -> Result<(), rooms_runtime::Error> {
		self.changed()
	}
	fn closed(&self) {
		if self.failure.borrow().is_none() {
			*self.failure.borrow_mut() = Some(Failure::new(
				"closed",
				"after-state-change",
				"observation ended; inspect the session report",
			));
		}
		self.inbox.wake();
	}
}
