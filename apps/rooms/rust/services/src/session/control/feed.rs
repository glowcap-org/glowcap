//! The local journal records presentation only. Live event custody remains
//! independently held until acknowledgment or observer retirement.
use super::{failure::Failure, worker};
use crate::session::{Event, Local};
use serde_json::json;
use std::{
	cell::{Cell, RefCell},
	collections::BTreeMap,
};
pub(super) type Application = Local;
pub(super) struct Feed {
	pub app: Application,
	pub inbox: worker::Worker,
	pub failure: RefCell<Option<Failure>>,
	live: RefCell<BTreeMap<u64, Event>>,
	pub cursor: Cell<u64>,
}
impl Feed {
	pub fn new(app: Application, inbox: worker::Worker) -> Self {
		Self {
			app,
			inbox,
			failure: RefCell::new(None),
			live: RefCell::new(BTreeMap::new()),
			cursor: Cell::new(0),
		}
	}
	pub async fn receive(&self, token: u64, event: Event) -> Result<(), Failure> {
		if self.live.borrow().len() >= 4096 {
			return Err(Failure::exhausted("acknowledge retained local events"));
		}
		let files = event
			.files
			.iter()
			.map(|file| {
				json!({"name":file.description.name(),
			"mime":file.description.mime(),"size":file.description.size()})
			})
			.collect::<Vec<_>>();
		let mut data: serde_json::Value = serde_json::from_str(&event.data)?;
		data["notice"]["history"] = event
			.history()
			.map_or(serde_json::Value::Null, rooms_application::archive::history_data);
		let token = self.app.activity.token(token).map_err(Failure::uncertain)?;
		let id = self
			.inbox
			.event(json!({"event":data,"live":token,"files":files,
			"incoming":event.incoming.as_ref().map(|incoming|incoming.role())}))
			.await?;
		self.live.borrow_mut().insert(id, event);
		Ok(())
	}
	pub async fn ack(&self, ids: Vec<u64>) -> Result<serde_json::Value, Failure> {
		let result = self.inbox.ack(ids.clone()).await?;
		for id in ids {
			self.live.borrow_mut().remove(&id);
		}
		Ok(result)
	}
	pub fn retire(&self) {
		self.live.borrow_mut().clear();
	}
}
